# The contract

The harness and the project meet at one file: `verify.sh`, in the project root.

The harness decides **when** to check and **what happens** when a check fails.
The project decides **what green means** for itself. Neither side adapts to the
other, and neither side needs to know what the other is made of. A Go project, a
TypeScript project and a project that is mostly YAML are all governable, because
the harness never looks inside.

## What a project must supply

A project is governable when it has an executable `verify.sh` in its root that
meets all of the following.

### 1. Three exit codes, not two

| Code | Meaning |
|------|---------|
| `0`  | Every check ran and passed. |
| `1`  | At least one check ran and failed. |
| `2`  | At least one check **could not run** — a tool is missing, a service is down, the environment is broken. |

`2` is the whole point. A suite that skipped half of itself because a database
was not listening still exits `0` in most setups, and a green run that measured
nothing looks exactly like a green run that measured everything. If a check
could not run, `verify.sh` must say so with `2` and never with `0`.

The harness treats the three differently: `1` can block, `2` never blocks but is
always reported. A missing tool is not a reason to trap the session; it is a
reason to tell the operator loudly.

### 2. A `--fast` tier

`verify.sh --fast` runs the cheap checks only — seconds, not minutes.

This is the tier the harness calls inside the edit loop and at the end of a
turn. Formatting, static analysis and unit tests belong here. Vulnerability
scans, SBOM regeneration, integration suites and anything that talks to a
network belong in the full run, which CI and the operator call.

With no argument, `verify.sh` runs everything.

### 3. A `FAILED:` summary line

When a check fails or cannot run, the script prints a line beginning with
`FAILED:` naming it. The harness shows the operator everything from the first
`FAILED:` onwards, and drops the transcript of passes above it.

Without it, a failure report is a wall of successful output with one bad line
hidden in the middle of it.

```
FAILED: go vet
FAILED: go test
SKIPPED (could not run): govulncheck - not installed
```

`templates/go/verify.sh` is a working implementation of all three. Copy it,
point it at your project, delete what does not apply.

## What the harness supplies

Five Claude Code hooks and one git hook. Each Claude Code hook is a shell
script that reads a JSON event on stdin and writes a JSON decision on stdout.

| Gate | Fires | Acts |
|------|-------|------|
| `hooks/edit-gate.sh` | after any edit, however it was made | **forced feedback** |
| `hooks/commit-gate.sh` | before a `git commit` runs | **blocks** |
| `hooks/git/commit-msg` | inside git, on the final commit message | **blocks** |
| `hooks/stop-build.sh` | when the agent's turn ends | reports |
| `hooks/turn-start.sh` | when the operator sends a prompt | snapshots the tree |
| `hooks/charter-check.sh` | once, at session start | reports |

Wire the Claude Code hooks with `settings.example.json`, and the git hook with
`git config --global core.hooksPath <harness>/hooks/git`.

The edit gate's block comes *after* the edit. PostToolUse cannot undo or
prevent anything; the block puts the failure in front of the agent as the next
thing it reads. That is forced feedback, and nothing here claims it is more.

### Only in repositories you trust

The hooks are global, so they fire in every repository you open. They run a
repository's `verify.sh` only if that repository's own local git config says
`harness.trusted = true`. Each project carries its own switch; a clone starts
without it. Anywhere else they run nothing and report that nothing was
verified. See
[ADR 0005](docs/adr/0005-keep-the-trust-switch-in-each-repository.md).

### Block where a claim becomes permanent

Blocking and reporting are not a preference setting. They follow from how
reversible the moment is.

A commit is a claim that outlives the session, and once it is pushed it cannot
be taken back. That is worth blocking. A half-finished edit is not — the agent
is still working, and a gate that blocks there is arguing with somebody
mid-sentence. The end of a turn is the subtle one: a **blocking** end-of-turn
hook can trap the agent in a loop, because the only way out of the loop is the
thing the block is preventing. So `stop-build.sh` reports and the operator
decides whether it is worth another turn.

`edit-gate.sh` blocks, because a formatting or static-analysis failure has a
fixed, known repair and the agent is the right one to make it. It does not
block on a failure that was already there, word for word, at the end of the
last turn: that one is reported, or every unrelated edit would be blocked by
it.

### A gate must never break the session

Every gate exits `0` itself, always, whatever it found. A gate's *decision*
travels in the JSON it prints, never in its own exit status. A guardrail that
crashes takes down the workflow it was guarding, and the operator's first
instinct will be to remove the guardrail.

This is why the gates are defensive about their own tools: if Python is not on
the path, `commit-gate.sh` says the command could not be inspected and asks for
confirmation, rather than dying or — much worse — waving the commit through.
The same holds when the commit-msg git hook is not installed: the message
would be checked by nothing, so the commit gate asks.

### Changed files come from the tree

Not from the event payload.

An earlier version of the edit gate matched the edit tools only. A careful,
surgical, multi-line change is easier to make through a shell script than
through an edit tool — so the most careful edits were exactly the ones
bypassing the gate. Anything that infers "what changed" from the shape of the
event will miss whatever it did not anticipate.

The gates hash every dirty file and compare against a snapshot: the edit gate
against the state it last checked, the end-of-turn gate against the state
`turn-start.sh` recorded when the prompt arrived. A deleted file is a change.
A file whose timestamp was kept by `cp -p` or `git checkout` is a change. A
command that changed nothing, such as `ls`, runs nothing.

### Gates are tested

Every gate has a test beside it. This is not thoroughness for its own sake.

A gate that has silently stopped matching produces no output, blocks nothing,
and looks exactly like approval. There is no error to notice. The test is the
only thing that can tell the difference.

```sh
sh hooks/edit-gate_test.sh
sh hooks/stop-build_test.sh
sh hooks/charter-check_test.sh
sh hooks/git/commit-msg_test.sh
python hooks/commit-gate_test.py
```

CI runs all five on every push. Each bug found by review has a case of its own,
written to fail against the old gate before the gate was fixed.
