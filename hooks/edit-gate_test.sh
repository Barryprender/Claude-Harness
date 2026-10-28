#!/bin/sh
# Checks edit-gate.sh decides correctly.
#
#     sh hooks/edit-gate_test.sh
#
# The failure this guards against is not a wrong decision, it is no decision:
# a gate that has stopped matching prints nothing, blocks nothing, and looks
# exactly like approval. Nothing in a normal session would ever tell you.
#
# Each case builds a throwaway git repository with a verify.sh that exits the
# way the case needs, touches a file so the gate sees a change, and feeds the
# gate an empty payload - which is the point of the gate reading git rather
# than the payload.

set -u

HOOKS=$(cd "$(dirname "$0")" && pwd)
GATE=$HOOKS/edit-gate.sh
pass=0
fail=0

ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

# A throwaway repository with one changed file and the given verify.sh body.
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

commit_all() { # $1 = directory
    git -C "$1" add . >/dev/null 2>&1
    git -C "$1" commit -qm seed >/dev/null 2>&1
}

decide() { # $1 = directory; prints block | report | silent
    out=$(cd "$1" && printf '{}' | sh "$GATE" 2>&1)
    case "$out" in
        *'"decision":"block"'*) printf 'block' ;;
        *systemMessage*)        printf 'report' ;;
        *)                      printf 'silent' ;;
    esac
}

case_is() { # $1 description, $2 verify.sh exit code, $3 expected
    d=$(scratch "#!/bin/sh
echo 'checking things'
echo 'FAILED: the check that this test says fails'
exit $2")
    got=$(decide "$d")
    out=$(cd "$d" && printf '{}' | sh "$GATE" 2>&1)
    rm -rf "$d"
    if [ "$got" = "$3" ]; then
        ok "$1: $got"
    else
        bad "$1: expected $3, got $got
      $out"
    fi
}

case_is "verify.sh fails (exit 1) after an edit" 1 block
case_is "verify.sh could not run (exit 2)"       2 report
case_is "verify.sh passes (exit 0)"              0 silent

# A clean tree is not this gate's business, whatever verify.sh would say.
d=$(scratch "#!/bin/sh
exit 1")
commit_all "$d"
got=$(decide "$d")
rm -rf "$d"
if [ "$got" = silent ]; then
    ok "clean tree, nothing changed: silent"
else
    bad "clean tree, nothing changed: expected silent, got $got"
fi

# The block has to carry the failing output back, or the agent is told only
# that something is wrong and not what.
d=$(scratch "#!/bin/sh
echo 'lots of passing noise'
echo 'FAILED: gofmt'
exit 1")
out=$(cd "$d" && printf '{}' | sh "$GATE" 2>&1)
rm -rf "$d"
case "$out" in
    *'FAILED: gofmt'*) ok "the reason carries the FAILED lines" ;;
    *)                 bad "the reason carries the FAILED lines: got $out" ;;
esac

# The output has to be valid JSON when the failing tool prints quotes,
# backslashes and tabs - which every compiler error message does. This case is
# the reason the escaping exists, and it caught the escaping being wrong.
#
# The failing script is written with a quoted heredoc and printf '%s', so what
# it prints is exactly the text below. An earlier version of this case built it
# with echo and escapes, the escapes were eaten before they reached the file,
# and the case passed against output that had no quotes in it at all. A test
# that passes for the wrong reason is worse than no test.
d=$(scratch "")
cat > "$d/verify.sh" <<'VERIFY'
#!/bin/sh
printf '%s\n' 'FAILED: go vet'
printf '%s\n' 'cannot use "x" (untyped string) as int value in argument'
printf '%s\n' 'see C:\path\to\thing	and a tab before this'
exit 1
VERIFY
out=$(cd "$d" && printf '{}' | sh "$GATE" 2>&1)
rm -rf "$d"
PY=""
for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then
        PY="$c"
        break
    fi
done

if [ -n "$PY" ]; then
    # Valid JSON, and the text survives it. Escaping that strips the quotes
    # instead of escaping them would also parse.
    if printf '%s' "$out" | "$PY" -c "
import json, sys
r = json.load(sys.stdin)['reason']
assert 'cannot use \"x\" (untyped string)' in r, r
assert 'C:' + chr(92) + 'path' + chr(92) + 'to' + chr(92) + 'thing' in r, r
" >/dev/null 2>&1; then
        ok "the decision is valid JSON and keeps quotes and backslashes intact"
    else
        bad "the decision is valid JSON and keeps quotes and backslashes intact:
      $out"
    fi
else
    printf 'SKIP  JSON validity: no working python (this is not a pass)\n'
fi

# The decision travels in the JSON. The gate's own exit status is always 0,
# because a guardrail that crashes takes down the workflow it was guarding.
d=$(scratch "#!/bin/sh
exit 1")
(cd "$d" && printf '{}' | sh "$GATE" >/dev/null 2>&1)
rc=$?
rm -rf "$d"
if [ "$rc" -eq 0 ]; then
    ok "the gate itself exits 0 while blocking"
else
    bad "the gate itself exits 0 while blocking: got $rc"
fi

# --- the review's cases: each of these used to be wrong -----------------------

# A deleted file is a change. The gate used to skip any path that was not a
# file, so deleting one was the one edit it could not see.
d=$(scratch '#!/bin/sh
[ -f keep.txt ] || { echo "FAILED: keep.txt is gone"; exit 1; }')
echo x > "$d/keep.txt"
commit_all "$d"
rm "$d/keep.txt"
got=$(decide "$d")
rm -rf "$d"
if [ "$got" = block ]; then ok "a deleted file is checked: $got"; else bad "a deleted file is checked: expected block, got $got"; fi

# A change that keeps an old timestamp - cp -p, tar, git checkout - is still a
# change. The gate used to look only at files modified in the last two minutes.
d=$(scratch "#!/bin/sh
echo 'FAILED: it'
exit 1")
touch -d '2001-01-01' "$d/changed.txt" "$d/verify.sh"
got=$(decide "$d")
rm -rf "$d"
if [ "$got" = block ]; then ok "a change with an old timestamp is checked: $got"; else bad "a change with an old timestamp is checked: expected block, got $got"; fi

# Nothing changed since the last check - an ls after an edit - runs nothing.
d=$(scratch "#!/bin/sh
echo 'FAILED: it'
exit 1")
first=$(decide "$d")
second=$(decide "$d")
rm -rf "$d"
if [ "$first/$second" = block/silent ]; then
    ok "a second run with nothing changed is silent"
else
    bad "a second run with nothing changed is silent: expected block/silent, got $first/$second"
fi

# A repository not marked as trusted: its verify.sh is not run, and that is
# said out loud.
d=$(scratch '#!/bin/sh
touch ran
exit 1')
git -C "$d" config --unset harness.trusted
got=$(decide "$d")
if [ -f "$d/ran" ]; then ran=yes; else ran=no; fi
rm -rf "$d"
if [ "$got/$ran" = report/no ]; then
    ok "an untrusted repository is reported and its verify.sh is not run"
else
    bad "an untrusted repository is reported and its verify.sh is not run: got $got, ran=$ran"
fi

# A yes in the global git config does not count. Trust is per repository, or
# one line in a global file would trust every clone at once.
d=$(scratch '#!/bin/sh
touch ran
exit 1')
git -C "$d" config --unset harness.trusted
home=$(mktemp -d)
HOME=$home git config --global harness.trusted true
out=$(cd "$d" && printf '{}' | HOME=$home sh "$GATE" 2>&1)
if [ -f "$d/ran" ]; then ran=yes; else ran=no; fi
rm -rf "$d" "$home"
case "$ran/$out" in
    no/*"not been marked as trusted"*) ok "a global harness.trusted does not trust a repository" ;;
    *) bad "a global harness.trusted does not trust a repository: ran=$ran, got $out" ;;
esac

# A failure that was already there at the end of the last turn does not block
# an unrelated edit. A different failure still does.
# shellcheck disable=SC2016 # the body is a script; it expands when it runs
d=$(scratch '#!/bin/sh
echo "FAILED: $(cat reason.txt)"
exit 1')
echo "old breakage" > "$d/reason.txt"
(cd "$d" && printf '{}' | sh "$HOOKS/stop-build.sh" >/dev/null 2>&1)
(cd "$d" && printf '{}' | sh "$HOOKS/turn-start.sh" >/dev/null 2>&1)
echo other > "$d/other.txt"
same=$(decide "$d")
echo "new breakage" > "$d/reason.txt"
different=$(decide "$d")
rm -rf "$d"
if [ "$same/$different" = report/block ]; then
    ok "a failure from before this turn is reported, a new one blocks"
else
    bad "a failure from before this turn is reported, a new one blocks: expected report/block, got $same/$different"
fi

# Nothing is cut off the bottom of the report.
# shellcheck disable=SC2016 # the body is a script; it expands when it runs
d=$(scratch '#!/bin/sh
i=1
while [ $i -le 40 ]; do echo "FAILED: check $i"; i=$((i + 1)); done
exit 1')
out=$(cd "$d" && printf '{}' | sh "$GATE" 2>&1)
rm -rf "$d"
case "$out" in
    *'FAILED: check 40'*) ok "a long failure report is not cut short" ;;
    *)                    bad "a long failure report is not cut short: got $out" ;;
esac

# The fallback, for a project with no verify.sh, reports and never writes.
if command -v gofmt >/dev/null 2>&1; then
    d=$(scratch "")
    printf 'package x\nfunc  f()  {}\n' > "$d/x.go"
    before=$(cat "$d/x.go")
    got=$(decide "$d")
    after=$(cat "$d/x.go")
    rm -rf "$d"
    if [ "$got" = block ] && [ "$before" = "$after" ]; then
        ok "the fallback reports unformatted Go and leaves the file alone"
    else
        bad "the fallback reports unformatted Go and leaves the file alone: got $got"
    fi
else
    printf 'SKIP  fallback gofmt: gofmt is not installed (this is not a pass)\n'
fi

# A verify.sh that was red at the end of the last turn and passes now, where the
# only change since is to a test file: the test may have moved to meet the code.
# Reported, never blocked - ADR 0001, and the gate cannot tell a corrected spec
# from a weakened one.
d=$(scratch '#!/bin/sh
grep -q GREEN foo_test.go 2>/dev/null && exit 0
echo "FAILED: not green yet"
exit 1')
printf 'package x\n// red\n' > "$d/foo_test.go"
(cd "$d" && printf '{}' | sh "$HOOKS/stop-build.sh" >/dev/null 2>&1)   # record the red baseline
(cd "$d" && printf '{}' | sh "$HOOKS/turn-start.sh" >/dev/null 2>&1)   # snapshot the turn's start
printf 'package x\n// GREEN\n' > "$d/foo_test.go"                      # only a test file changes
got=$(decide "$d")
rm -rf "$d"
if [ "$got" = report ]; then
    ok "a test-only change that turns a red verify.sh green is reported"
else
    bad "a test-only change that turns a red verify.sh green is reported: expected report, got $got"
fi

# The mirror: when the change that turned it green is to a non-test file, there
# is nothing to flag. That is just a fixed bug.
d=$(scratch '#!/bin/sh
grep -q GREEN foo.go 2>/dev/null && exit 0
echo "FAILED: not green yet"
exit 1')
printf 'package x\n// red\n' > "$d/foo.go"
(cd "$d" && printf '{}' | sh "$HOOKS/stop-build.sh" >/dev/null 2>&1)
(cd "$d" && printf '{}' | sh "$HOOKS/turn-start.sh" >/dev/null 2>&1)
printf 'package x\n// GREEN\n' > "$d/foo.go"
got=$(decide "$d")
rm -rf "$d"
if [ "$got" = silent ]; then
    ok "a code change that turns a red verify.sh green is not flagged"
else
    bad "a code change that turns a red verify.sh green is not flagged: expected silent, got $got"
fi

# The test-first note must never suppress a block from another verifier. Two
# projects: one flips green on a test-only change (a note), the other fails
# fresh (a block). The block has to win, whichever verifier runs first. This is
# the fail-open regression the pass path introduced, and the reason it collects
# the note and carries on instead of reporting from inside the loop.
d=$(mktemp -d)
git -C "$d" init -q .
git -C "$d" config user.email t@t.t
git -C "$d" config user.name t
git -C "$d" config harness.trusted true
mkdir -p "$d/a" "$d/b"
cat > "$d/a/verify.sh" <<'V'
#!/bin/sh
grep -q GREEN foo_test.go 2>/dev/null && exit 0
echo "FAILED: a is not green"
exit 1
V
printf 'red\n' > "$d/a/foo_test.go"
echo content > "$d/seed.txt"
(cd "$d" && printf '{}' | sh "$HOOKS/stop-build.sh" >/dev/null 2>&1)   # a's red baseline
(cd "$d" && printf '{}' | sh "$HOOKS/turn-start.sh" >/dev/null 2>&1)   # open a new turn
printf 'GREEN\n' > "$d/a/foo_test.go"                                 # a goes green on a test
cat > "$d/b/verify.sh" <<'V'
#!/bin/sh
echo "FAILED: b is broken"
exit 1
V
echo code > "$d/b/code.go"                                            # b fails fresh
got=$(decide "$d")
rm -rf "$d"
if [ "$got" = block ]; then
    ok "a test-only note does not suppress another verifier's block"
else
    bad "a test-only note does not suppress another verifier's block: expected block, got $got"
fi

# A soft outcome from one verifier must not drop the test-first note from
# another, and a note's baseline must not be consumed unless the note is really
# emitted. Project a goes green on a test-only change (a note); project b cannot
# run (exit 2). Both signals have to survive, in one report.
d=$(mktemp -d)
git -C "$d" init -q .
git -C "$d" config user.email t@t.t
git -C "$d" config user.name t
git -C "$d" config harness.trusted true
mkdir -p "$d/a" "$d/b"
cat > "$d/a/verify.sh" <<'V'
#!/bin/sh
grep -q GREEN foo_test.go 2>/dev/null && exit 0
echo "FAILED: a is not green"
exit 1
V
printf 'red\n' > "$d/a/foo_test.go"
echo content > "$d/seed.txt"
(cd "$d" && printf '{}' | sh "$HOOKS/stop-build.sh" >/dev/null 2>&1)   # a's red baseline
(cd "$d" && printf '{}' | sh "$HOOKS/turn-start.sh" >/dev/null 2>&1)   # open a new turn
printf 'GREEN\n' > "$d/a/foo_test.go"                                 # a goes green on a test
cat > "$d/b/verify.sh" <<'V'
#!/bin/sh
echo "FAILED: b cannot run"
exit 2
V
echo trigger > "$d/b/trigger.go"                                      # b cannot run
out=$(cd "$d" && printf '{}' | sh "$GATE" 2>&1)
rm -rf "$d"
case "$out" in *systemMessage*) got=report ;; *'"decision":"block"'*) got=block ;; *) got=silent ;; esac
case "$out" in *'is to a test file'*) hasnote=1 ;; *) hasnote=0 ;; esac
case "$out" in *'could not complete'*) hassoft=1 ;; *) hassoft=0 ;; esac
if [ "$got" = report ] && [ "$hasnote" = 1 ] && [ "$hassoft" = 1 ]; then
    ok "a soft outcome elsewhere keeps the test-first note, both in one report"
else
    bad "a soft outcome elsewhere keeps the test-first note: got $got note=$hasnote soft=$hassoft
      $out"
fi

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
