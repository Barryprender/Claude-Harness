# 3. Check the commit message in git, not in the command line

Status: accepted, 2026-09-30

## Context

The rule against attribution trailers was enforced by `commit-gate.sh`, a
PreToolUse hook that read the Bash command before it ran and matched it
against a pattern: `git commit` at the start of the command or after a
separator, then `Co-Authored-By` or `Generated with` somewhere after it.

An outside review broke it five ways in a few minutes, and every one of them
was an ordinary way to commit rather than an attack: `git -C . commit`,
`sh -c "git commit ..."`, a subshell, the trailer in capitals, and
`git commit -F msgfile` with the trailer in the file. It also denied
"Generated with protoc", a normal sentence about a normal tool.

Each of those could be patched. The pattern would then be one shape longer,
and still only know the shapes it had been shown. The command line is the
wrong place to look: it describes how a commit is asked for, and there is no
end to the ways of asking. The message is what the rule is about, and git
holds it in one place just before the commit is made.

## Decision

The trailer check moves to `hooks/git/commit-msg`, a git hook. Git passes it
the final message, however the commit was spelled, and a non-zero exit stops
the commit.

It is installed with `git config --global core.hooksPath <harness>/hooks/git`,
or per repository by copying it to `.git/hooks/commit-msg`. With the global
path set, git stops running a repository's own `.git/hooks`, so the hook runs
the repository's own `commit-msg` after its check.

`commit-gate.sh` stays, with a narrower job it can do from the command line:

- deny `--no-verify`, `-n` and `-c core.hooksPath=...`, the ways to switch the
  git hook off for one commit;
- ask when the git hook is not installed for the repository, because the
  message is then checked by nothing;
- ask when the commit touches a `verify.sh`, the hooks, the agent settings or
  the CI workflows - the files that decide what passes;
- ask when more than one file is in the commit.

## Alternatives considered

**Patch the pattern for each reported bypass.** Rejected: it fixes the five
shapes found and not the sixth. A check that has to anticipate its input is
the failure `edit-gate.sh` already made once with tool names.

**Read the message from the command line properly.** Rejected: `-F` files,
editors, `-c` templates and `commit.template` config all put the message
somewhere other than the command. Parsing all of them is rebuilding git.

## Consequences

**Negative.**

- One more thing to install, outside Claude Code's settings. A repository
  where it is not installed asks on every commit until it is.
- A global `core.hooksPath` hides every other hook in a repository's
  `.git/hooks` - a `pre-commit`, a `pre-push`. Only `commit-msg` is passed on.
  A repository that sets its own `core.hooksPath`, as husky does, overrides the
  global one, and the commit gate then asks.
- The list of AI tool names in the "Generated with" check is fixed. A new name
  gets through until it is added.
- The commit gate still reads the command line for its other checks, still
  needs python for that, and can still be fooled about the file count. Being
  fooled there costs a missed question, not a trailer in history.

**Positive.**

- Every way of committing goes through the same check, including the ones
  nobody has thought of yet.
- The check is `sh` and `grep`. It needs no python.
- "Generated with protoc" is allowed.

## Follow-up

1. If the file-count or protected-file checks ever need to be exact rather
   than advisory, move them to a git `pre-commit` hook that reads the index,
   and let the commit gate only check that it is installed.
