"""Checks commit-gate.sh decides correctly.

    python hooks/commit-gate_test.py

It exists because the gate reads the command line, not just the index, and that
parsing is the part that can quietly go wrong. A gate that has stopped matching
fails open and says nothing, which looks exactly like approval. There is no
error to notice, so this file is the only thing that can tell the difference.

Every case runs in a throwaway repository of its own, with the commit-msg git
hook installed unless the case is about it not being installed.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "commit-gate.sh")
GIT_HOOKS = os.path.join(HERE, "git")

# Assembled from pieces so this file's own text cannot trip a gate that
# inspects the command running it.
TRAILER = "Co-" + "Authored-By"
GENERATED = "Generated " + "with"
COMMIT = "git " + "commit"
PR = "gh " + "pr"
ADD = "git " + "add"


def run(d, *a):
    subprocess.run(a, cwd=d, capture_output=True, timeout=30)


def repo(untracked=(), staged=(), modified=(), hook=True, body="x"):
    """A repository with a seed commit, then the given files in the given state."""
    d = tempfile.mkdtemp()
    run(d, "git", "init", "-q")
    run(d, "git", "config", "user.email", "t@t.t")
    run(d, "git", "config", "user.name", "t")
    if hook:
        run(d, "git", "config", "core.hooksPath", GIT_HOOKS)

    def write(name, text):
        p = os.path.join(d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)

    write("seed.txt", "seed")
    for name in modified:
        write(name, "one")
    run(d, "git", "add", ".")
    run(d, "git", "commit", "-qm", "seed")
    for name in modified:
        write(name, "two")
    for name in staged:
        write(name, "x")
        run(d, "git", "add", "--", name)
    for name in untracked:
        write(name, body)
    return d


# The gate never changes the repository it looks at, so cases with the same
# fixture share one. On Windows every git call costs real time.
REPOS = {}


def decide(command, **fixture):
    key = repr(sorted(fixture.items()))
    if key not in REPOS:
        REPOS[key] = repo(**fixture)
    payload = json.dumps({"tool_input": {"command": command}})
    out = subprocess.run(
        ["sh", GATE], input=payload, capture_output=True, text=True, timeout=60, cwd=REPOS[key]
    ).stdout.strip()
    if not out:
        return "silent"
    return json.loads(out)["hookSpecificOutput"]["permissionDecision"]


CASES = [
    # description, command, fixture, expected
    ("two files staged in one command",
     ADD + ' a.go b.go && ' + COMMIT + ' -m "x"', dict(untracked=["a.go", "b.go"]), "ask"),
    ("one file staged in one command",
     ADD + ' a.go && ' + COMMIT + ' -m "x"', dict(untracked=["a.go"]), "silent"),
    ("bare commit, nothing staged",
     COMMIT + ' -m "x"', {}, "silent"),
    ("prose naming a commit, no commit call",
     'echo "how to ' + COMMIT + ' without a ' + TRAILER + ' line"', {}, "silent"),
    ("semicolon separator, three files",
     ADD + ' a.go b.go c.go; ' + COMMIT + ' -m x', {}, "ask"),
    ("quoted path containing a space",
     ADD + ' "my file.go" && ' + COMMIT + ' -m "x"', {}, "silent"),
    ("two paths, one of them quoted",
     ADD + ' "my file.go" other.go && ' + COMMIT + ' -m "x"', {}, "ask"),
    ("flags are not paths",
     ADD + ' -v a.go && ' + COMMIT + ' -m "x"', {}, "silent"),
    ("paths after a -- separator",
     ADD + ' -- a.go b.go && ' + COMMIT + ' -m "x"', {}, "ask"),
    ("nothing to do with git",
     'ls -la && echo done', {}, "silent"),
    ("commit -a with two modified files",
     COMMIT + ' -am "x"', dict(modified=["a.txt", "b.txt"]), "ask"),

    # The review's bypasses: every one of these used to be silent.
    ("git -C . commit, two files staged",
     'git -C . commit -m "x"', dict(staged=["a.go", "b.go"]), "ask"),
    ("sh -c around the whole thing",
     'sh -c "' + ADD + ' a.go b.go && ' + COMMIT + ' -m x"', {}, "ask"),
    ("a subshell around the whole thing",
     '(' + ADD + ' a.go b.go; ' + COMMIT + ' -m x)', {}, "ask"),
    ("one file staged, then add . over the same file",
     ADD + ' . && ' + COMMIT + ' -m "x"', dict(staged=["a.go"]), "silent"),

    # Turning the git hook off.
    ("--no-verify",
     COMMIT + ' --no-verify -m "x"', {}, "deny"),
    ("-n bundled with -m",
     COMMIT + ' -nm "x"', {}, "deny"),
    ("core.hooksPath overridden for one command",
     'git -c core.hooksPath=/dev/null commit -m "x"', {}, "deny"),
    ("a message that merely contains -n is not a flag",
     COMMIT + ' -m -n', {}, "silent"),

    # The git hook is what checks the message, so its absence is could-not-run.
    ("commit-msg hook not installed",
     COMMIT + ' -m "x"', dict(hook=False), "ask"),
    ("the trailer is the git hook's job, not this gate's",
     COMMIT + ' -m "x\n\n' + TRAILER + ': A <a@b.c>"', {}, "silent"),

    # Files that decide what passes.
    ("verify.sh in the commit",
     ADD + ' verify.sh && ' + COMMIT + ' -m "x"', dict(untracked=["verify.sh"]), "ask"),
    ("a nested verify.sh in the commit",
     ADD + ' sub/verify.sh && ' + COMMIT + ' -m "x"', dict(untracked=["sub/verify.sh"]), "ask"),
    ("a harness hook in the commit",
     ADD + ' hooks/x.sh && ' + COMMIT + ' -m "x"', dict(untracked=["hooks/x.sh"]), "ask"),
    ("a CI workflow in the commit",
     ADD + ' .github/workflows/ci.yml && ' + COMMIT + ' -m "x"',
     dict(untracked=[".github/workflows/ci.yml"]), "ask"),
    ("an application hooks folder is not the harness",
     ADD + ' src/hooks/use.ts && ' + COMMIT + ' -m "x"', dict(untracked=["src/hooks/use.ts"]), "silent"),

    ("a command the gate cannot parse",
     COMMIT + ' -m "x', {}, "ask"),

    # Pull requests: no git hook sees them, so this gate reads them.
    ("a pull request body with a trailer",
     PR + ' create --title x --body "y\n\n' + TRAILER + ': A <a@b.c>"', {}, "deny"),
    ("a pull request body naming an AI tool",
     PR + ' edit 5 -b "' + GENERATED + ' [Claude Code](https://claude.com)"', {}, "deny"),
    ("a pull request body with a trailer in capitals",
     PR + ' create -t x -b "y\n\n' + TRAILER.upper() + ': A"', {}, "deny"),
    ("a pull request body in a file",
     PR + ' create -t x --body-file body.md', dict(untracked=["body.md"], body=TRAILER + ": A"), "deny"),
    ("a pull request body on stdin",
     'cat <<EOF | ' + PR + ' create -t x -F -\ny\n\n' + TRAILER + ': A\nEOF', {}, "deny"),
    ("a pull request body file that is not there",
     PR + ' create -t x --body-file missing.md', {}, "ask"),
    ("a clean pull request",
     PR + ' create --title x --body "' + GENERATED + ' protoc"', {}, "silent"),
]

failed = 0
for description, command, fixture, expected in CASES:
    got = decide(command, **fixture)
    ok = got == expected
    failed += not ok
    print("%s  %s: expected %s, got %s"
          % ("PASS" if ok else "FAIL", description, expected, got))

for d in REPOS.values():
    shutil.rmtree(d, ignore_errors=True)

print("\n%d/%d passed" % (len(CASES) - failed, len(CASES)))
sys.exit(1 if failed else 0)
