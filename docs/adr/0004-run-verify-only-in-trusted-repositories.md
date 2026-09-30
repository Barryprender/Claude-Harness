# 4. Run verify.sh only in repositories on a trust list

Status: superseded by ADR 0005, 2026-09-30

## Context

The hooks are wired globally, in `~/.claude/settings.json`, so they run in
every repository Claude Code is opened in. The edit gate and the end-of-turn
gate find the nearest `verify.sh` and run it.

`SECURITY.md` described this as running "your own project's `verify.sh`". For
a repository somebody else wrote, that is false. Clone it, open it, make one
edit, and its `verify.sh` runs with your user's rights. Nobody had to attack
anything: opening a repository was enough.

ADR 0002 says the harness is not a security boundary. That covers somebody
who can already write to the hooks. It does not cover the harness itself
handing a stranger a shell.

## Decision

The gates run a repository's `verify.sh` only when the repository's root, as
`git rev-parse --show-toplevel` prints it, is a line in
`~/.claude/harness-trusted` (or the file named by `CLAUDE_HARNESS_TRUST`).

In any other repository they run nothing - not `verify.sh`, not the Go
fallback, which can also download and run a toolchain - and report that
nothing was verified, with the command that adds the repository to the list.
A check that did not run has not passed, so this is never silent.

## Alternatives considered

**Correct `SECURITY.md` and leave the behaviour.** Rejected: an honest warning
about a shell handed to strangers is still a shell handed to strangers.

**Trust any repository whose remote is the operator's.** Rejected: a remote says
where a repository came from, not who wrote the `verify.sh` at the current
commit. A pull from somebody else's branch keeps the remote and changes the
script.

## Consequences

**Negative.**

- Every repository needs one command before the gates do anything in it. Until
  then, every edit produces a report.
- The list holds paths. Moving or re-cloning a repository removes it from the
  list, and the reports start again.
- Trusting a repository trusts every future version of its `verify.sh`,
  including one pulled from somebody else's branch.

**Positive.**

- Opening a repository no longer runs its code.
- The trust decision is one line in one file the operator can read.

## Follow-up

1. If the list becomes a chore, record the hash of `verify.sh` with the path
   and ask again when it changes - before removing the list.
