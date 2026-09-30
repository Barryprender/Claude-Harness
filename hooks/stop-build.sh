#!/bin/sh
# Stop: never let a turn end on a tree that does not verify. This one reports.
#
# WHY IT REPORTS AND DOES NOT BLOCK. A blocking end-of-turn hook can trap the
# agent in a loop, because the only way out of the block is the work the block
# is preventing. Worse, the operator never gets a turn to look. So this states
# what it found and hands the decision back: block where a claim becomes
# permanent, report where it is still soft. See commit-gate.sh for the other
# half of that rule.
#
# WHY IT DELEGATES. An earlier version of this ended at "does it compile", with
# one project's private trap hardcoded into a hook that ran everywhere. Two
# problems. Compiling is not verifying - a service can compile for months while
# a security claim in its README is enforced by no test at all. And a global
# hook cannot know each project's silent-skip condition, because every project
# has a different one: a database that is not listening here, a code generator
# that has not run there.
#
# So it asks the project. verify.sh is the definition of green, it is the same
# script CI runs, and there is one of it rather than two that drift. It asks
# every verify.sh that owns a file changed this turn, found the same way the
# edit gate finds them, so a nested project is not missed.
#
# "This turn" is measured against the snapshot turn-start.sh takes when the
# operator sends a prompt. Without that snapshot, every dirty file counts:
# wider than intended, and the right way to be wrong.
#
# The contract is verify.sh --fast: the cheap tier, seconds not minutes. The
# expensive tier belongs in CI, not on the end of every turn.
#
# Contract: reads the Stop payload on stdin, writes hook JSON on stdout.
# Never exits non-zero - a broken gate must not break the session.

set -u

cat > /dev/null   # drain the payload

# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0
sd=$(state_dir "$root") || exit 0

tmp=$(mktemp -d 2>/dev/null || echo "/tmp/stop-build.$$")
mkdir -p "$tmp" 2>/dev/null || exit 0
trap 'rm -rf "$tmp"' EXIT

report() { # $1 = message
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$1" | esc)"
    exit 0
}

# --- what changed this turn ---------------------------------------------------

tree_state "$root" "$tmp/s" > "$tmp/now"
before="$sd/start"
[ -f "$before" ] || { : > "$tmp/empty"; before="$tmp/empty"; }
changed_paths "$before" "$tmp/now" > "$tmp/changed"

[ -s "$tmp/changed" ] || exit 0

trusted "$root" || report "$(untrusted_message)"

# --- the project's own definition of green ------------------------------------

verifiers_for "$root" < "$tmp/changed" > "$tmp/verifiers"

if [ -s "$tmp/verifiers" ]; then
    msg=""
    while IFS= read -r d; do
        out=$(cd "$d" && sh verify.sh --fast 2>&1)
        rc=$?
        bf=$(baseline_file "$sd" "$d")
        if [ "$rc" -eq 0 ]; then
            rm -f "$bf"
            continue
        fi

        # Report the collected failures, not the transcript of passes above them.
        detail=$(printf '%s' "$out" | failure_detail)
        rel="${d#"$root"}"
        rel="${rel#/}"
        name="./${rel:+$rel/}verify.sh"

        if [ "$rc" -eq 1 ]; then
            # The baseline the edit gate compares against next turn.
            printf '%s' "$detail" | normalise > "$bf"
            msg="$msg$name --fast FAILED with changes made this turn:

$detail

"
        else
            msg="$msg$name --fast could not complete (exit $rc). This is not a pass - a check did not run at all:

$detail

"
        fi
    done < "$tmp/verifiers"
    [ -n "$msg" ] && report "$msg"
    exit 0
fi

# --- fallback: no verify.sh here yet ------------------------------------------
#
# Deliberately thin. Give the project a verify.sh and this stops running.

[ -f "$root/go.mod" ] || exit 0
command -v go >/dev/null 2>&1 || exit 0
grep -q '\.go$' "$tmp/changed" || exit 0

if ! out=$(cd "$root" && go build ./... 2>&1); then
    report "go build ./... FAILED with Go changes made this turn (fallback check - this project has no verify.sh):

$out"
fi

exit 0
