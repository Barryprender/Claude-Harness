#!/bin/sh
# Checks stop-build.sh reports correctly - and, just as important, that it
# never blocks.
#
#     sh hooks/stop-build_test.sh
#
# The decision this test pins down is the one that is easy to get wrong later:
# an end-of-turn hook that starts blocking can trap the agent in a loop, and
# the change that would do that is a one-word edit.

set -u

HOOKS=$(cd "$(dirname "$0")" && pwd)
GATE=$HOOKS/stop-build.sh
pass=0
fail=0

ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

scratch() { # $1 = verify.sh body, or empty for no verify.sh
    d=$(mktemp -d)
    git -C "$d" init -q .
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    [ -n "$1" ] && printf '%s\n' "$1" > "$d/verify.sh"
    echo content > "$d/changed.txt"
    git -C "$d" config harness.trusted true   # the gates only run verify.sh in a trusted repository
    printf '%s' "$d"
}

run() { # $1 = directory
    (cd "$1" && printf '{}' | sh "$GATE" 2>&1)
}

body() { # $1 = exit code
    printf '#!/bin/sh\necho "noise that passed"\necho "FAILED: the failing check"\nexit %s\n' "$1"
}

# --- a failing verify.sh is reported, never blocked ---------------------------

d=$(scratch "$(body 1)")
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *'"decision":"block"'*) bad "a failing verify.sh must not block at end of turn: $out" ;;
    *systemMessage*FAILED*) ok "a failing verify.sh is reported with its FAILED lines" ;;
    *)                      bad "a failing verify.sh is reported: got $out" ;;
esac

# --- exit 2 is reported too, and says so --------------------------------------
#
# The wording matters here. "Could not run" reported as if it were a failure is
# survivable; reported as nothing at all is the bug this harness exists about.

d=$(scratch "$(body 2)")
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *"not a pass"*) ok "exit 2 is reported as not-a-pass" ;;
    *)              bad "exit 2 is reported as not-a-pass: got $out" ;;
esac

# --- a passing verify.sh says nothing -----------------------------------------

d=$(scratch "$(body 0)")
out=$(run "$d")
rm -rf "$d"
if [ -z "$out" ]; then
    ok "a passing verify.sh is silent"
else
    bad "a passing verify.sh is silent: got $out"
fi

# --- a clean tree is not this hook's business ---------------------------------

d=$(scratch "$(body 1)")
git -C "$d" add . >/dev/null 2>&1
git -C "$d" commit -qm seed >/dev/null 2>&1
out=$(run "$d")
rm -rf "$d"
if [ -z "$out" ]; then
    ok "a clean tree is silent even when verify.sh would fail"
else
    bad "a clean tree is silent: got $out"
fi

# --- the hook's own exit status is always 0 -----------------------------------

d=$(scratch "$(body 1)")
(cd "$d" && printf '{}' | sh "$GATE" >/dev/null 2>&1)
rc=$?
rm -rf "$d"
if [ "$rc" -eq 0 ]; then
    ok "the hook itself exits 0 while reporting a failure"
else
    bad "the hook itself exits 0 while reporting a failure: got $rc"
fi

# --- the review's cases: each of these used to be wrong -----------------------

# A nested project. The root verify.sh passes and does not cover sub/; the
# change is in sub/, so sub/verify.sh is the one that has to run. This gate
# used to ask only the root, and said nothing.
d=$(scratch "$(body 0)")
mkdir "$d/sub"
body 1 > "$d/sub/verify.sh"
git -C "$d" add . >/dev/null 2>&1
git -C "$d" commit -qm seed >/dev/null 2>&1
echo change > "$d/sub/x.txt"
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *sub/verify.sh*FAILED*) ok "a failing nested verify.sh is reported" ;;
    *)                      bad "a failing nested verify.sh is reported: got $out" ;;
esac

# Only this turn's changes. A file left dirty before the turn started, and not
# touched since, is not this turn's work.
d=$(scratch "$(body 1)")
(cd "$d" && printf '{}' | sh "$HOOKS/turn-start.sh" >/dev/null 2>&1)
out=$(run "$d")
rm -rf "$d"
if [ -z "$out" ]; then
    ok "a tree left dirty before the turn is silent"
else
    bad "a tree left dirty before the turn is silent: got $out"
fi

# The same tree, with one change made during the turn, is reported.
d=$(scratch "$(body 1)")
(cd "$d" && printf '{}' | sh "$HOOKS/turn-start.sh" >/dev/null 2>&1)
echo more >> "$d/changed.txt"
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *FAILED*) ok "a change made during the turn is reported" ;;
    *)        bad "a change made during the turn is reported: got $out" ;;
esac

# A repository not marked as trusted: its verify.sh is not run, and that is
# said out loud.
d=$(scratch '#!/bin/sh
touch ran
exit 1')
git -C "$d" config --unset harness.trusted
out=$(run "$d")
if [ -f "$d/ran" ]; then ran=yes; else ran=no; fi
rm -rf "$d"
case "$ran/$out" in
    no/*"not been marked as trusted"*) ok "an untrusted repository is reported and its verify.sh is not run" ;;
    *) bad "an untrusted repository is reported and its verify.sh is not run: ran=$ran, got $out" ;;
esac

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
