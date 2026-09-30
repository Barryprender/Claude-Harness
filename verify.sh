#!/bin/sh
# This repository's own definition of green.
#
# It is here because charter-check.sh said it was missing, which is the check
# doing its job. A harness that does not govern itself is a slide deck.
#
# Contract, the same one HARNESS.md asks of any project:
#   exit 0   everything ran and passed
#   exit 1   something ran and failed
#   exit 2   something could not run at all
#   --fast   the cheap tier, seconds not minutes

set -u

fast=0
[ "${1:-}" = "--fast" ] && fast=1

cd "$(dirname "$0")" || exit 2

notes=$(mktemp 2>/dev/null || echo "./.verify.$$")
trap 'rm -f "$notes"' EXIT
: > "$notes"

failed=0
unrun=0

fail() {
    failed=1
    printf 'FAILED: %s\n' "$1" >> "$notes"
    [ -n "${2:-}" ] && printf '%s\n\n' "$2" >> "$notes"
}

cannot_run() {
    unrun=1
    printf 'FAILED: %s could not run - %s\n' "$1" "$2" >> "$notes"
}

finish() {
    if [ -s "$notes" ]; then
        echo
        cat "$notes"
    fi
    [ "$failed" -eq 1 ] && exit 1
    [ "$unrun" -eq 1 ] && exit 2
    echo "OK"
    exit 0
}

# --- the fast tier: every hook still parses ----------------------------------
#
# The edit gate runs this after every edit here, so it has to cost seconds.
# A syntax error in a hook is the one break that takes every gate down at
# once, and sh -n finds it without running anything.

echo "sh -n hooks"
for f in hooks/*.sh hooks/git/commit-msg hooks/git/*.sh verify.sh; do
    if ! out=$(sh -n "$f" 2>&1); then
        fail "sh -n $f" "$out"
    fi
done

[ "$fast" -eq 1 ] && finish

# --- the gates ----------------------------------------------------------------
#
# These are the whole product, and a gate that has stopped matching is silent.
# They are not in the fast tier: each case builds real git repositories, and
# on Windows the suite takes minutes, which is too long to wait after every
# edit. CI runs them on every push, and there is no version of this repository
# where skipping them there is acceptable.

for t in hooks/edit-gate_test.sh hooks/stop-build_test.sh hooks/charter-check_test.sh hooks/git/commit-msg_test.sh; do
    echo "$t"
    if ! out=$(sh "$t" 2>&1); then
        fail "$t" "$(printf '%s' "$out" | grep '^FAIL')"
    fi
done

# The commit gate is the one hook that needs python, so its test does too.
# Probed by running it: on Windows, python3 is often an alias that exists,
# resolves, and then refuses to run.
PY=""
for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then
        PY="$c"
        break
    fi
done

echo "hooks/commit-gate_test.py"
if [ -n "$PY" ]; then
    if ! out=$("$PY" hooks/commit-gate_test.py 2>&1); then
        fail "hooks/commit-gate_test.py" "$(printf '%s' "$out" | grep '^FAIL')"
    fi
else
    cannot_run "hooks/commit-gate_test.py" "no working python interpreter on PATH"
fi

# --- the full tier ------------------------------------------------------------

# The shell scripts are the product, so they get a linter when one is here. Not
# installed is exit 2 and never exit 0: we did not look is a different answer
# from we looked and it is clean.
# The version is part of what green means, so it is pinned in one file that
# both this script and CI read. 0.11.0 dropped SC3013; the runner's
# preinstalled shellcheck had not. The same file passed here and failed there,
# and neither report was wrong - they were answering different questions. A
# version this script did not expect is therefore a check that did not run,
# not a check that passed.
echo "shellcheck"
want=$(cat .shellcheck-version 2>/dev/null)
have=$(shellcheck --version 2>/dev/null | sed -n 's/^version: *//p')

if [ -z "$have" ]; then
    cannot_run "shellcheck" "not installed - https://www.shellcheck.net"
elif [ -z "$want" ]; then
    cannot_run "shellcheck" ".shellcheck-version is missing - nothing to pin against"
elif [ "$have" != "$want" ]; then
    cannot_run "shellcheck" "version $have, but .shellcheck-version pins $want - a different version is a different set of rules"
elif ! out=$(shellcheck -x -s sh hooks/*.sh hooks/git/commit-msg hooks/git/*.sh templates/go/verify.sh example/verify.sh verify.sh 2>&1); then
    # Not truncated, on purpose. This was head -40, and the first CI run
    # that failed had fifteen findings - so five of them were cut off the
    # bottom of the report and looked like they did not exist. A failure
    # report that hides failures is the thing this script exists to stop.
    fail "shellcheck" "$out"
fi

# The example, through its own verify.sh rather than through a second copy of
# its checks written here.
echo "example/verify.sh"
out=$(cd example && sh verify.sh 2>&1)
case $? in
    0) ;;
    1) fail "example/verify.sh" "$(printf '%s' "$out" | sed -n '/FAILED:/,$p')" ;;
    *) cannot_run "example/verify.sh" "$(printf '%s' "$out" | sed -n '/FAILED:/,$p')" ;;
esac

finish
