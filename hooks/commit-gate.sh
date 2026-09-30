#!/bin/sh
# PreToolUse gate for git commits. This one blocks.
#
# A commit is the moment a claim stops being provisional. Once it is pushed it
# cannot be taken back, and its message will be read by people who were not
# here. That is why this gate blocks and the end-of-turn gate does not.
#
# What it decides, in order:
#
#   1. Deny a commit that turns git hooks off: --no-verify, -n, or
#      -c core.hooksPath=... . The attribution check lives in a git hook, and
#      this is the one way to walk around it.
#   2. Ask when that git hook is not installed for the repository. The message
#      is then checked by nothing, and could not run is not passed.
#   3. Ask when the commit touches what decides green: a verify.sh, the hooks,
#      the agent's settings, the CI workflows. An agent that edits its own
#      judge - adds exit 0, deletes a check - turns every gate green, and CI
#      does not help because CI runs the same edited file.
#   4. Ask when more than one file is in the commit. One commit per file is the
#      convention, with legitimate exceptions the operator decides on.
#
# The attribution trailer itself is not checked here any more. It is checked
# by hooks/git/commit-msg, on the final message, which no way of spelling the
# command can get around. See docs/adr/0003-check-the-commit-message-in-git.md.
#
# The file count comes from the command line as well as the index. Asking git
# what is staged is only correct once staging has happened: `git add a b c &&
# git commit` runs this hook before the add, so the index is empty and the
# check passes silently on exactly the commits it exists to catch. `git commit
# -a` has the same hole from the other direction - it stages at commit time,
# after this hook has already looked.
#
# Contract: reads the PreToolUse payload on stdin, writes hook JSON on stdout.
# Never exits non-zero - a broken gate must not break the session.

set -u

payload=$(cat)

# Cheap prefilter. Nearly every command this hook sees has nothing to do with
# committing, and there is no reason to start an interpreter for those.
case "$payload" in
    *commit*) ;;
    *) exit 0 ;;
esac

emit() { # $1 = deny|ask, $2 = reason
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
    exit 0
}

# Probed by running it, not by looking for it on PATH. On Windows, python3 is
# often an App Execution Alias that exists, resolves, and then refuses to run -
# `command -v` says yes and the interpreter produces nothing. That is the same
# class of bug this whole harness is about: present is not the same as working.
PY=""
for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then
        PY="$c"
        break
    fi
done

# Could not run is not passed. At a blocking point that means asking the
# operator, not waving it through and not crashing the session.
[ -n "$PY" ] || emit ask "The commit gate could not run: no python interpreter is on PATH, so the command line and the staged files were never inspected. This is not an approval. Confirm the staging is deliberate before you continue."

HARNESS_GIT_HOOKS="$(cd "$(dirname "$0")" && pwd)/git"
export HARNESS_GIT_HOOKS

# The program is held in a quoted heredoc, and the quoted delimiter is the
# point. Passing it as `python -c "..."` puts it inside a double-quoted shell
# string, where $, backslash and backticks still belong to the shell. A pair of
# backticks in a *Python comment* was once run as a command substitution before
# Python ever saw the file. A quoted heredoc hands the text over untouched.
decide=$(cat <<'PYPROG'
import json, os, re, shlex, subprocess, sys

def emit(decision, reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason}}))
    sys.exit(0)

def git(cwd, *args):
    try:
        out = subprocess.run(('git',) + args, cwd=cwd, capture_output=True,
                             text=True, timeout=10)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return [l for l in out.stdout.splitlines() if l.strip()]

try:
    raw = (json.load(sys.stdin).get('tool_input') or {}).get('command') or ''
except Exception:
    sys.exit(0)

# --- finding the git invocations ---------------------------------------------
#
# Matching text was the first version, and it only knew the shapes it had been
# shown. This walks the command the way a shell would, well enough to follow
# the usual disguises: git -C dir, sh -c "...", a subshell, eval, cd first.

OPS = set(';&|()')
REDIRECT = {'>', '>>', '<', '<<', '<<<', '>&', '<&', '&>', '&>>', '>|', '<<-'}
SHELLS = {'sh', 'bash', 'dash', 'zsh', 'ksh', 'ash'}
PREFIX = {'sudo', 'command', 'exec', 'time', 'env', 'nohup'}
GIT_OPT_ARG = {'-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env'}

def segments(text):
    # Newlines separate commands; inside quotes they only become text.
    lex = shlex.shlex(text.replace('\n', ';'), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    cur, skip = [], False
    for t in lex:
        if skip:
            skip = False
            continue
        if t in REDIRECT:
            if cur and cur[-1].isdigit():
                cur.pop()
            skip = True
            continue
        if t and all(c in OPS for c in t):
            yield cur
            cur = []
            continue
        cur.append(t)
    yield cur

def walk(text, cwd, found, depth=0):
    if depth > 4:
        raise ValueError('nested too deep')
    for seg in segments(text):
        while seg and (seg[0] in PREFIX or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', seg[0])):
            seg = seg[1:]
        if not seg:
            continue
        prog = os.path.basename(seg[0]).lower()
        if prog.endswith('.exe'):
            prog = prog[:-4]
        if prog == 'cd':
            if len(seg) > 1:
                cwd = os.path.join(cwd, seg[1])
        elif prog == 'eval':
            walk(' '.join(seg[1:]), cwd, found, depth + 1)
        elif prog in SHELLS:
            for i, a in enumerate(seg[1:], 1):
                if a.startswith('-') and not a.startswith('--') and 'c' in a[1:]:
                    if i + 1 < len(seg):
                        walk(seg[i + 1], cwd, found, depth + 1)
                    break
        elif prog == 'git':
            i, gcwd, conf = 1, cwd, []
            while i < len(seg) and seg[i].startswith('-'):
                a = seg[i]
                if a in GIT_OPT_ARG and i + 1 < len(seg):
                    if a == '-C':
                        gcwd = os.path.join(gcwd, seg[i + 1])
                    elif a in ('-c', '--config-env'):
                        conf.append(seg[i + 1])
                    i += 2
                    continue
                if a.startswith('--config-env='):
                    conf.append(a.split('=', 1)[1])
                i += 1
            if i < len(seg) and seg[i] in ('add', 'commit'):
                found.append((seg[i], gcwd, seg[i + 1:], conf))

found = []
try:
    walk(raw, os.getcwd(), found)
except ValueError:
    if re.search(r'\bgit\b', raw) and re.search(r'\bcommit\b', raw):
        emit('ask', 'The commit gate could not parse this command, so it could not tell what it commits. This is not an approval. Check the staging and the message before you continue.')
    sys.exit(0)

commits = [f for f in found if f[0] == 'commit']
if not commits:
    sys.exit(0)

# --- reading commit and add arguments ----------------------------------------

COMMIT_OPT_ARG = {'-m', '-F', '-C', '-c', '-t', '--message', '--file',
                  '--reuse-message', '--reedit-message', '--template', '--author',
                  '--date', '--cleanup', '--fixup', '--squash', '--trailer',
                  '--pathspec-from-file'}

def commit_flags(args):
    """(no_verify, all, pathspecs) for one commit's arguments."""
    no_verify = every = False
    paths, i, ddash = [], 0, False
    while i < len(args):
        a = args[i]
        i += 1
        if ddash or not a.startswith('-') or a == '-':
            paths.append(a)
        elif a == '--':
            ddash = True
        elif a == '--no-verify':
            no_verify = True
        elif a == '--all':
            every = True
        elif a in COMMIT_OPT_ARG:
            i += 1
        elif re.match(r'^-[A-Za-z]+', a) and not a.startswith('--'):
            # Bundled short flags: -anm "x". Everything after a flag that takes
            # a value is that value, not more flags.
            for ch in a[1:]:
                if ch == 'n':
                    no_verify = True
                elif ch == 'a':
                    every = True
                elif ch in 'mFCctuS':
                    if ch in 'mFCct' and a.endswith(ch):
                        i += 1
                    break
    return no_verify, every, paths

for _, cwd, args, conf in commits:
    if any(c.split('=', 1)[0].strip().lower() == 'core.hookspath' for c in conf):
        emit('deny', 'This commit overrides core.hooksPath, which switches off the commit-msg hook that checks the message for attribution lines. Commit without the override.')
    if commit_flags(args)[0]:
        emit('deny', 'This commit skips the git hooks (--no-verify or -n). The commit-msg hook is what checks the message for attribution lines, and CLAUDE.md does not allow skipping hooks. If a hook is wrong, fix the hook. Commit again without the flag.')

asks = []
hooks_dir = os.environ.get('HARNESS_GIT_HOOKS', '<harness>/hooks/git')

def rel(root, cwd, p):
    try:
        r = os.path.relpath(os.path.normpath(os.path.join(cwd, p)), root)
    except ValueError:
        r = p
    return r.replace('\\', '/')

def tree_paths(root):
    out = []
    for l in git(root, 'status', '--porcelain', '--untracked-files=all') or []:
        p = l[3:]
        if ' -> ' in p:
            p = p.split(' -> ', 1)[1]
        out.append(p.strip('"'))
    return out

def protected(p):
    parts = p.split('/')
    return (parts[-1] == 'verify.sh'
            or parts[0] in ('hooks', '.claude', '.husky', '.githooks')
            or p.startswith('.github/workflows/')
            or (len(parts) == 1 and parts[0].startswith('settings') and parts[0].endswith('.json')))

EVERYTHING = {'.', '-A', '--all', '-u', '--update', ':/', '*'}

for _, cwd, args, conf in commits:
    # Is the message going to be checked at all?
    hook = git(cwd, 'rev-parse', '--git-path', 'hooks/commit-msg')
    body = ''
    if hook:
        try:
            with open(os.path.join(cwd, hook[0]), encoding='utf-8', errors='replace') as f:
                body = f.read()
        except OSError:
            pass
    if 'claude-harness:commit-msg' not in body:
        asks.append('The attribution check could not run: the claude-harness commit-msg git hook is not installed for this repository, so nothing will read the final commit message. This is not an approval. Check the message yourself, and install the hook with: git config --global core.hooksPath "%s"' % hooks_dir)

    root = (git(cwd, 'rev-parse', '--show-toplevel') or [None])[0]
    if root is None:
        continue

    # What this commit would hold: staged now, plus what the same command line
    # is about to stage. One set of root-relative paths, so a file named twice
    # is counted once.
    paths = set(git(root, 'diff', '--cached', '--name-only') or [])
    for kind, acwd, aargs, _ in found:
        if kind != 'add':
            continue
        ddash = False
        for a in aargs:
            if a == '--':
                ddash = True
            elif a in EVERYTHING or any(ch in a for ch in '*?['):
                paths.update(tree_paths(root))
            elif ddash or not a.startswith('-'):
                paths.add(rel(root, acwd, a))
    no_verify, every, pathspecs = commit_flags(args)
    if every:
        paths.update(git(root, 'diff', '--name-only') or [])
    for p in pathspecs:
        paths.add(rel(root, cwd, p))

    judged = sorted(p for p in paths if protected(p))
    if judged:
        asks.append('This commit changes files that decide what passes: %s. An agent that edits its own judge can turn every gate green, and CI runs the same edited files. Read these changes before you confirm.' % ', '.join(judged))
    if len(paths) > 1:
        asks.append('%d files are in one commit. The convention here is one commit per file, ordered so the history builds up sensibly and each commit can be read on its own. Confirm if this is a deliberate exception (a rename, or a file that cannot stand alone); otherwise stage and commit them one at a time.' % len(paths))

if asks:
    emit('ask', '\n\n'.join(dict.fromkeys(asks)))
PYPROG
)

out=$(printf '%s' "$payload" | "$PY" -c "$decide" 2>/dev/null)
rc=$?
# A crash prints nothing, and nothing reads as approval.
[ "$rc" -eq 0 ] || emit ask "The commit gate failed while inspecting this command (python exit $rc). This is not an approval. Check the staging and the message before you continue."
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
