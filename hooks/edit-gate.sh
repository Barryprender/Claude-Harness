#!/bin/sh
# PostToolUse gate for edits, however they were made. Forced feedback.
#
# WHAT IT DOES. After an edit, it finds the project's own verify.sh and runs
# the cheap tier of it. A failure comes back to the agent as a block, with the
# failing output, so fixing it is the next thing the agent does.
#
# WHAT "BLOCK" MEANS HERE. PostToolUse runs after the tool. The edit has
# already happened and it stays. A block cannot undo it or prevent it; it puts
# the failure in front of the agent before it builds anything else on top.
# That is forced feedback, not prevention, and nothing here should claim more.
#
# WHY IT DELEGATES. The harness has no opinion about what green means. A
# formatter, a linter, a test runner, a code generator that has to run first -
# all of that is the project's business and it changes per project. What the
# harness owns is the moment: after every edit, before anything is built on
# top of it. See HARNESS.md for the contract verify.sh has to meet.
#
# WHERE CHANGED FILES COME FROM. The tree, never the tool payload. An earlier
# version of this gate matched the edit tools only. A careful, surgical,
# multi-line change is easier to make through a shell script than through an
# edit tool, so the most careful edits were exactly the ones bypassing the
# gate. Anything that infers what changed from the shape of the event will
# miss whatever it did not anticipate.
#
# The tree is compared against the state this gate last checked, which
# turn-start.sh resets at the start of each turn. Nothing changed since the
# last check - an ls, a git log - means nothing runs.
#
# WHAT ELSE IT REPORTS. If verify.sh was failing at the end of the last turn
# and passes now because the only files changed since are tests, it says so and
# hands the decision back. That is the one case where a green run is worth a
# second look: the test may have moved to meet the code. It is reported, never
# blocked - a gate cannot tell a corrected spec from a weakened one.
#
# Contract: reads the PostToolUse payload on stdin, writes hook JSON on stdout.
# Never exits non-zero - a broken gate must not break the session.

set -u

cat > /dev/null   # drain the payload; this gate deliberately does not read it

# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0
sd=$(state_dir "$root") || exit 0

tmp=$(mktemp -d 2>/dev/null || echo "/tmp/edit-gate.$$")
mkdir -p "$tmp" 2>/dev/null || exit 0
trap 'rm -rf "$tmp"' EXIT

# Both of these are called directly, never on the right of a pipe: the right
# side of a pipe is a subshell, and exiting there would let the caller carry on
# and print a second decision after the first.
block() { # $1 = one-line summary, $2 = detail
    printf '{"decision":"block","reason":"%s\\n\\n%s","systemMessage":"%s"}\n' \
        "$(printf '%s' "$1" | esc)" "$(printf '%s' "$2" | esc)" "$(printf '%s' "$1" | esc)"
    exit 0
}

report() { # $1 = message
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$1" | esc)"
    exit 0
}

# --- what changed since the last check ----------------------------------------

tree_state "$root" "$tmp/s" > "$tmp/now"
[ -f "$sd/last" ] || : > "$sd/last"
changed_paths "$sd/last" "$tmp/now" > "$tmp/changed"
cp "$tmp/now" "$sd/last"

# What changed since this turn began, for the test-first report below. The
# baseline that report keys on is written at the end of the previous turn, and
# turn-start.sh snapshots the tree into start at that same moment.
if [ -f "$sd/start" ]; then
    changed_paths "$sd/start" "$tmp/now" > "$tmp/turnchanged"
else
    : > "$tmp/turnchanged"
fi

[ -s "$tmp/changed" ] || exit 0

trusted "$root" || report "$(untrusted_message)"

# --- the project's own definition of green ------------------------------------

verifiers_for "$root" < "$tmp/changed" > "$tmp/verifiers"

if [ -s "$tmp/verifiers" ]; then
    # Every soft outcome is collected, never reported from inside the loop: a
    # block is the strongest result and must win, so a later verifier always
    # gets its turn to block before anything soft is said. Only block exits the
    # loop. Whatever is collected is emitted together after it - which is
    # reached only when nothing blocked - so no signal is dropped and none is
    # cut short. $tmp/clear holds the baselines a test-first note describes;
    # they are removed only once that note is actually emitted, never before.
    note=""
    : > "$tmp/clear"
    while IFS= read -r d; do
        out=$(cd "$d" && sh verify.sh --fast 2>&1)
        rc=$?

        # It passes now. If it was failing at the end of the last turn, and the
        # only thing changed since then is a test file, the test moved to meet
        # the code rather than the code to meet the test. Collect that, never
        # block: ADR 0001, and a gate cannot tell a corrected spec from a
        # weakened one. The baseline is cleared when the note is emitted, so the
        # note fires once; stop-build.sh clears it next turn on a clean pass too.
        if [ "$rc" -eq 0 ]; then
            bf=$(baseline_file "$sd" "$d")
            if [ -f "$bf" ]; then
                rel="${d#"$root"}"; rel="${rel#/}"
                if dir_paths "$rel" < "$tmp/turnchanged" | only_tests; then
                    printf '%s\n' "$bf" >> "$tmp/clear"
                    note="${note}verify.sh --fast in $d passes now, but every change since it failed at the end of the last turn is to a test file. Check the test was changed because the spec was wrong, not to turn a red test green.

"
                fi
            fi
            continue
        fi

        detail=$(printf '%s' "$out" | failure_detail)

        # Exit 1 is a real failure with a known repair: block, unless it is
        # word for word the failure this verify.sh already had at the end of
        # the last turn. Then this edit did not cause it, so it is collected
        # like any other soft outcome rather than blocking an unrelated edit.
        #
        # Exit 2 is a check that could not run at all - a missing tool, a
        # service that is down. Blocking on that would trap the session in a
        # loop it cannot edit its way out of, so it is collected instead. It is
        # still never silent. Not blocking is not the same as passing.
        if [ "$rc" -eq 1 ]; then
            bf=$(baseline_file "$sd" "$d")
            if [ -f "$bf" ] && [ "$(printf '%s' "$detail" | normalise)" = "$(cat "$bf")" ]; then
                note="${note}verify.sh --fast in $d still fails exactly as it did at the end of the last turn. This edit did not cause it, so it is reported, not blocked. It has not passed:

$detail

"
                continue
            fi
            block "verify.sh --fast failed after an edit. Fix this before continuing." "$detail"
        fi
        note="${note}verify.sh --fast in $d could not complete (exit $rc). Nothing here has passed - a check did not run:

$detail

"
    done < "$tmp/verifiers"
    # Reached only when nothing blocked. Clear the baselines whose test-first
    # note we are about to emit - only now, so a block that exited the loop
    # above never consumed a warning that was never printed - then report
    # everything collected, in one message.
    if [ -n "$note" ]; then
        while IFS= read -r bf; do [ -n "$bf" ] && rm -f "$bf"; done < "$tmp/clear"
        report "$note"
    fi
    exit 0
fi

# --- fallback -----------------------------------------------------------------
#
# ONLY for a project that has no verify.sh yet. It is deliberately thin: the
# harness guessing at a project's checks is how two definitions of green come
# to exist, and two definitions of green drift until there is none. Give the
# project a verify.sh and this code stops running.
#
# It reads and never writes. It used to run gofmt -w, which changed the file
# under the agent without telling it, and made "the hooks only read" untrue.

command -v go >/dev/null 2>&1 || exit 0
: > "$tmp/go"
while IFS= read -r p; do
    case "$p" in
        *.go) ;;
        *) continue ;;
    esac
    # Generated files are rewritten by their generator; reporting on them names
    # problems nobody is going to fix in place.
    case "$p" in
        *_templ.go|*.pb.go|*_generated.go|vendor/*|*/vendor/*|*/node_modules/*) continue ;;
    esac
    [ -f "$root/$p" ] && printf '%s\n' "$root/$p" >> "$tmp/go"
done < "$tmp/changed"

[ -s "$tmp/go" ] || exit 0

unformatted=$(while IFS= read -r f; do gofmt -l "$f" 2>/dev/null; done < "$tmp/go")
[ -n "$unformatted" ] && block "gofmt: files you just edited are not formatted (fallback check - this project has no verify.sh). Run gofmt -w on them." "$unformatted"

while IFS= read -r f; do dirname "$f"; done < "$tmp/go" | awk '!seen[$0]++' > "$tmp/pkgs"
while IFS= read -r d; do
    if ! out=$(cd "$d" && go vet . 2>&1); then
        block "go vet failed on a package you just edited (fallback check - this project has no verify.sh)." "$out"
    fi
done < "$tmp/pkgs"

exit 0
