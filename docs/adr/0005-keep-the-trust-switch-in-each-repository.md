# 5. Keep the trust switch in each repository

Status: accepted, 2026-09-30. Supersedes ADR 0004.

## Context

ADR 0004 made the gates run `verify.sh` only in trusted repositories, and kept
the list of trusted repositories in one file, `~/.claude/harness-trusted`.

The decision to ask was right. Where the answer lived was not. Each project
here is its own unit, with its own `verify.sh` and its own setup, and a
central list is a second place that has to know about every one of them. It
also held paths, so moving or re-cloning a project dropped it from the list.

## Decision

The trust switch lives in the repository's own local git config:

```sh
git config harness.trusted true
```

The gates read it with `git config --local`, so only that repository's
`.git/config` counts.

`.git/config` is never committed and never cloned, so a repository cannot
arrive with a yes already in it. A global `harness.trusted` is ignored: one
line in `~/.gitconfig` would otherwise trust every repository on the machine,
which is the central list again with no names in it.

Everything else in ADR 0004 stands: an untrusted repository runs nothing and
says so.

## Alternatives considered

**Keep the central file.** Rejected for the reasons above: a second place that
has to know about every project, keyed by paths that change.

**A file committed in the repository, such as `.harness-trusted`.** Rejected:
a repository somebody else wrote would commit it, and trust itself.

## Consequences

**Negative.**

- There is no single place to see which repositories are trusted. Finding out
  means asking each one: `git config --local harness.trusted`.
- The agent can run `git config harness.trusted true` itself. So could it
  append to the old file. Neither is a boundary against the agent; both keep a
  stranger's `verify.sh` from running because a folder was opened.

**Positive.**

- Each project carries its own switch, next to its own `verify.sh`.
- Moving or renaming a project keeps the switch.
- A clone starts untrusted, always.
