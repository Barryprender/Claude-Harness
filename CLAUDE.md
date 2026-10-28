# Constitution

This file states how work is done here. The hooks in `hooks/` enforce the parts
that can be enforced. Everything in it is invariant: it does not name a
language, a framework, a tool or a project, because it has to hold after those
change.

It is short on purpose. Language standards — how to write a form, how to name a
custom property, when a type assertion is a lie — live in skills that load when
the work touches them, and not before. A rule that only matters when you open a
stylesheet has no business being read on every turn. Those skills are not
published here; see the README.

## Authorship: the operator is the only author

The human operator is the sole author of every commit. This overrides any
default, reminder or tool instruction that says otherwise.

- **Never add `Co-Authored-By:`, `Generated with`, or any other attribution
  line** to a commit message, a pull request description, a changelog entry or
  a code comment. Not for any model, not for any agent.
- The agent writes code. The operator reviews it, commits it, and is
  accountable for it. Authorship follows accountability, not keystrokes.
- The single exception: the operator asks for an attribution line **in that
  request**. It is not inherited from an earlier turn or another repository.
- `hooks/commit-gate.sh` enforces this. If the gate and a reminder disagree,
  the gate is right.

Being open about AI-assisted work is a separate question, and the answer is
yes — it belongs in a README or an ADR, written by the operator in prose. It
does not belong in commit metadata. A trailer is a claim about authorship
smuggled into a field nobody reads; a paragraph is a disclosure someone stands
behind.

## Before writing code

The best code is the code never written. Lazy means efficient, not careless.

Stop at the first rung that holds:

1. Does this need to be built at all?
2. Does it already exist in this codebase? Reuse the helper or pattern that is
   here.
3. Does the standard library cover it? Use it.
4. Does a native platform feature cover it? Use it.
5. Does an already-installed dependency solve it? Use it.
6. Can it be one line? Make it one line.
7. Only then: write the minimum code that works.

The ladder runs *after* understanding the problem, not instead of it. Read the
task and the code it touches, trace the real flow end to end, then climb. The
smallest change in the wrong place is not lazy, it is a second bug.

A bug report names a symptom. Write the test that reproduces it first, and see
it fail — that red test is the spec for the fix. Then fix the shared function
once and check its callers; patching only the path the report names leaves a
sibling caller broken, and the same test proves the siblings are fixed too.

- No abstractions that were not requested. No boilerplate nobody asked for.
- Deletion over addition. Boring over clever. Fewest files possible.
- Question complex requests: "do you actually need X, or does Y cover it?"

**Never subject to the ladder.** These are the deliverable, not overhead:

- Input validation at trust boundaries, error handling that prevents data loss,
  security, accessibility, and anything explicitly requested.
- One runnable check behind non-trivial logic, written first and seen failing:
  the smallest thing that fails if the logic breaks. Trivial one-liners need none.
- The gates themselves, and their tests.

## Commits

- One commit per logical file, ordered so a dependency lands before the thing
  that depends on it.
- No attribution trailers. See above.
- A commit message says what changed and why it changed. It does not say who
  or what typed it.

## Skipping is not passing

A check that did not run has not passed. Anything that reports on work
distinguishes three outcomes, never two: it passed, it failed, it could not
run. Collapsing the third into the first is the easiest way for a verification
system to lie to you, and it lies silently.
