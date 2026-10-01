# Claude-harness

Five [Claude Code](https://docs.claude.com/en/docs/claude-code) hooks and one
git hook. They run your project's checks after each edit, feed any failure
straight back to the agent, and stop a commit that breaks the rules.

A hook is a script that Claude Code runs at a set moment, such as after a file
edit. In this README, a **gate** is a hook that can stop the agent.

This repository does not make an AI agent write correct code. It makes it hard
to ship code that has not been verified first.

It is a cut-down copy of the setup I use on my own AI-assisted projects: a
handful of hooks, one contract, and a small Go service for the hooks to check. You can
clone it and watch a gate block a bad commit yourself.

My own projects are Go services with `html/template` front ends and SQLite.
The gates do not depend on that stack. Everything stack-specific lives in each
project's own `verify.sh`. Even so, Go and SQLite are the only stack it has
actually been used on.

---

## Requirements

- `sh` and `git`. On Windows, use Git Bash.
- Go.
- Python 3, for the commit gate (it reads the command line) and its test.
- For the full run only: `shellcheck` 0.11.0 (the version in
  `.shellcheck-version`) and `govulncheck`.

If a tool is missing, `verify.sh` exits `2`. That means "could not run". It
does not mean "passed".

## Quick start

```sh
git clone https://github.com/Barryprender/AI-Harness.git claude-harness
cd claude-harness
sh verify.sh --fast          # the fast tier: every hook still parses
sh verify.sh                 # everything: the gates' tests, the linter, the example
```

The **fast tier** is the quick subset of checks. The hooks run it after every
edit, so it must take seconds.

The harness checks itself: the hooks, CI and you all run the same `verify.sh`.

---

## Watch it work

Break the example service on purpose. The gate finds `example/verify.sh`, runs
its fast tier, and blocks. The edit has already happened - a hook that runs
after an edit cannot undo it - so the block is forced feedback: the failure is
the next thing the agent reads.

**Bad formatting:**

```
decision: block

verify.sh --fast failed after an edit. Fix this before continuing.

FAILED: gofmt
These files are not formatted. Run: gofmt -w .

main.go
```

**A behaviour change that breaks a test:**

```
decision: block

verify.sh --fast failed after an edit. Fix this before continuing.

FAILED: go test -short
--- FAIL: TestHealthReportsOK (0.00s)
    main_test.go:17: body = "{\"status\":\"fine\"}\n", want "{\"status\":\"ok\"}\n"
FAIL
FAIL    harness/example    1.874s
```

**An attribution trailer on a commit** (a trailer is a line such as
`Co-Authored-By:` at the end of a commit message). The git hook reads the final
message, so it does not matter how the commit was typed:

```
Commit rejected: the message carries an attribution line.

Co-Authored-By: A <a@b.c>

CLAUDE.md forbids it: never add a Co-Authored-By line or any other
attribution line. The operator is the author of the commit; disclosure of AI
assistance belongs in prose that a human stands behind, not in commit
metadata. Remove the line and commit again.
```

**An old Go toolchain** (the full run, not the fast tier):

```
FAILED: govulncheck

Vulnerability #1: GO-2026-6090
    Limit handshake messages we are willing to accept post-handshake in
    crypto/tls
  Standard library
    Found in: crypto/tls@go1.25.6
    Fixed in: crypto/tls@go1.25.13
```

That last one is real output. The full run reported it on the machine this
repository was written on. The example service imports only the standard
library.

To try the edit gate yourself:

```sh
# 0. Mark this repository as trusted. The gates run nothing without it.
git config harness.trusted true

# 1. Run the example's checks. They pass.
cd example
sh verify.sh --fast

# 2. Add badly formatted code to the example.
printf '%s\n' 'func x()  int {' >> main.go

# 3. Run the edit gate by hand, as Claude Code would after an edit.
#    It prints JSON with "decision":"block" and the failures.
cd ..
printf '{}' | sh hooks/edit-gate.sh

# 4. Undo the change.
git checkout -- example/main.go
```

---

## Wiring it up

Four steps.

**1. The Claude Code hooks.** `settings.example.json` shows the five hooks set
up. Copy its `hooks` block into `~/.claude/settings.json`.

Each hook command points to `$HOME/claude-harness`:

```json
{ "type": "command", "command": "sh $HOME/claude-harness/hooks/edit-gate.sh" }
```

If you cloned somewhere else, change that part of each of the five paths.

**2. The git hook.** It checks every commit message for attribution lines:

```sh
git config --global core.hooksPath "$HOME/claude-harness/hooks/git"
```

This makes git skip every repository's own `.git/hooks`. The hook runs a
repository's own `commit-msg` after its check, but not its other hooks, such
as `pre-commit`. If that matters in a repository, copy
`hooks/git/commit-msg` into its `.git/hooks/` instead. Until the hook is
installed one way or the other, the commit gate asks before every commit.

**3. The trust switch.** The hooks run in every repository you open, and they
run that repository's `verify.sh`. So they only do it in a repository you have
marked. Run this once inside each repository you trust:

```sh
git config harness.trusted true
```

The switch lives in that repository's `.git/config`. It is never committed, so
a clone never arrives trusted. A global setting does not count.

Anywhere else they run nothing and tell you so.

**4. Restart Claude Code.** Then every session loads the new hooks from
`~/.claude/settings.json`. Do not rely on a session that was already open to
pick them up.

Read the scripts before you do this. They are short. A hook you have not read
is a program that gets a shell every time you edit a file.

[SECURITY.md](SECURITY.md) says what the hooks touch. It also says what they
protect against: mistakes and drift. They do not protect against anyone who can
change the hook files. A local gate is only advice. Real enforcement belongs on
a protected branch, in CI, and in a signing key that is not stored on the
machine's disk. See
[ADR 0002](docs/adr/0002-treat-the-harness-as-advisory.md).

---

## What is here

```
CLAUDE.md                   the constitution: authorship, the ladder before
                            writing code, skipping is not passing
HARNESS.md                  the contract: what verify.sh must guarantee, and
                            what the harness guarantees in return
hooks/
  edit-gate.sh              after an edit: runs verify.sh --fast, feeds a
                            failure back to the agent
  commit-gate.sh            before a commit: denies skipping git hooks, asks
                            about multi-file commits and changes to the checks;
                            denies attribution lines in gh pull requests
  stop-build.sh             end of turn: runs verify.sh --fast, reports
  turn-start.sh             prompt sent: snapshots the tree for this turn
  charter-check.sh          session start: names missing standing artifacts
  lib.sh                    helpers the gates share
  git/commit-msg            git hook: rejects attribution lines
  *_test.sh, *_test.py      one test per gate
verify.sh                   this repository's own definition of green: the
                            gates' tests, the linter, the example project
templates/go/verify.sh      a working verify.sh: gofmt, go vet, go test,
                            skip detection, govulncheck, exits 0/1/2
example/                    a stub HTTP service for the harness to check
settings.example.json       how the five hooks are wired up
docs/adr/                   decisions that would otherwise be reconstructed
                            from the code
```

A **turn** is one reply from the agent. The end of a turn is when it stops and
hands control back to you.

### The contract, in one paragraph

The harness decides **when** to check and **what happens** when a check fails.
The project decides **what green means** for itself, in one executable
`verify.sh` in its root. CI runs the same script, so the local and CI
definitions of green cannot drift apart. Neither side adapts to the other, and
the harness never looks inside. A project in any language works with the
harness if its `verify.sh` exits 0, 1 or 2 honestly and has a cheap `--fast`
tier.

Full contract in [HARNESS.md](HARNESS.md).

---

## Why it works this way

Each of these six decisions came from getting something wrong first.

### 1. Block or report is a risk decision

Whether a gate blocks depends on how easy the moment is to undo. How much the
check matters has little to do with it.

A commit is where a change becomes hard to take back. Once it is pushed, it is
in other people's clones, and people who were not there read its message. That
is worth blocking. A half-finished edit is different. The agent is still
working and the fix is known and small, so blocking there is cheap and useful.

A **blocking** end-of-turn hook can trap the agent in a loop. The only thing
that would satisfy the block is the work the block is preventing, and the
operator never gets a turn to look. So `stop-build.sh` reports and hands the
decision back.

Recorded as [ADR 0001](docs/adr/0001-block-where-a-claim-becomes-permanent.md).

### 2. A gate must never crash the session

Every hook here exits `0`, always, whatever it found. The decision travels in
the JSON it prints, never in its own exit status.

A guardrail that crashes takes down the workflow it was guarding. The first
thing anyone does with a guardrail that breaks their workflow is remove it. The
tests check this directly: *the gate itself exits 0 while blocking*.

### 3. Three exit codes, not two

```
0   every check ran and passed
1   a check ran and failed
2   a check could not run at all
```

If `2` collapses into `0`, a verification system reports success for work it
never did, and nothing warns you. A suite that skipped half of itself because a
database was not listening prints `ok` and exits `0`. A vulnerability scanner
that is not installed finds no vulnerabilities.

The example project has a test that skips unless `HARNESS_EXAMPLE_E2E=1` is
set, so you can see the difference for yourself:

```
FAILED: 1 test(s) could not run - they skipped, usually a missing service or
build tag - a skipped test has not passed
--- SKIP: TestHealthEndToEnd (0.00s)
```

Plain `go test ./...` reports this run as a pass.

### 4. Change detection comes from the tree, not the tool payload

An earlier version of the edit gate only ran after the edit tools. But a
careful multi-line change is often easier to make with a shell script than with
an edit tool. So the most careful edits were the ones that skipped the gate.

A gate that guesses *what changed* from the shape of the event will miss
whatever it did not expect. So `edit-gate.sh` reads its input, throws it away,
and compares a hash of every dirty file with the last state it checked. A
deleted file counts. A file whose old timestamp was kept counts. An `ls`
changes nothing, so it runs nothing.

### 5. Gates are tested

A gate that has silently stopped matching prints nothing, blocks nothing, and
looks exactly like approval. No error appears in a normal session to warn you.

Each gate here has a test beside it, and CI runs all of them. An outside
review later found a dozen cases the tests did not cover, from `git -C . commit`
to a deleted file. Each one now has a case that failed against the old gate. This happened while
writing this repository. The edit gate's JSON escaping was wrong, so every real
failure it reported could not be parsed. The test that should have caught it
was passing, because its input had been damaged before it arrived. Both are
fixed, and both fixes are in the git history.

### 6. Disclosure lives in prose

No `Co-Authored-By`, no `Generated with`, on any commit. The `commit-msg` git
hook rejects them outright, and this repository's own history has none. It
used to be a pattern on the command line, which missed `git -C`, `sh -c` and
`-F`; see [ADR 0003](docs/adr/0003-check-the-commit-message-in-git.md).

A trailer claims authorship in a field nobody reads, with no room to qualify
the claim. A paragraph can say what the agent did and what a person checked.
The agent writes code; the operator reviews it, commits it, and is accountable
for it, so the operator is the author.

The disclosure for this repository is therefore a sentence: **the code here was
written with an AI coding agent, under the harness it contains, and I read
every line of it before it was committed.**

---

## Not built yet

- **Multi-language support exists only as a contract.** The gates do not depend
  on a language, and handing checks to `verify.sh` works. But the only
  `verify.sh` template in this repository is the Go one. A TypeScript or Python
  project would have to write its own today.
- **There is no stack auto-detection.** A project either has a `verify.sh` or
  it gets the small fallback check, which is Go-only. Working out a project's
  stack automatically is still only an idea.
- **The fallback paths are a stopgap.** They exist so a project without a
  `verify.sh` still gets some checks. A `verify.sh` is better in every case.
  You can delete the fallbacks once every project has one.
- **`charter-check.sh` probes for existence, not for content.** It can tell
  you there is no `SECURITY.md`. It cannot tell you the one you have is true.
- **The method skills are not published here.** My own setup also has skills
  that load only when needed: house standards for HTML, CSS and TypeScript,
  and writers for ADRs and project charters. They keep
  [CLAUDE.md](CLAUDE.md) at 83 lines instead of 400, because a rule that only
  matters when you open a stylesheet should not load on every turn. They are
  opinions, so they stayed private. This repository has the mechanism only.
- **This is a general version of a private setup.** The mechanism is the one
  I run. The specific checks in the original belong to projects I cannot
  publish.

---

## Licence

[MIT](LICENSE).
