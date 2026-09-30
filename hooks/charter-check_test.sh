#!/bin/sh
# Checks charter-check.sh reports the right gaps.
#
#     sh hooks/charter-check_test.sh
#
# The case that matters most is the last one: a repository with everything in
# place must produce no output at all. A probe that always finds something to
# complain about is a probe nobody reads.

set -u

GATE=$(cd "$(dirname "$0")" && pwd)/charter-check.sh
pass=0
fail=0

ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

# A repository with every standing artifact present.
full_repo() {
    d=$(mktemp -d)
    git -C "$d" init -q .
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    for f in CLAUDE.md README.md SECURITY.md verify.sh; do
        echo x > "$d/$f"
    done
    mkdir -p "$d/docs/adr" "$d/.github/workflows"
    echo x > "$d/docs/adr/0001-example.md"
    printf 'jobs:\n  v:\n    steps:\n      - run: sh verify.sh\n' > "$d/.github/workflows/ci.yml"
    printf '%s' "$d"
}

run() { (cd "$1" && printf '{}' | sh "$GATE" 2>&1); }

# --- each artifact, removed one at a time -------------------------------------

for f in CLAUDE.md README.md SECURITY.md verify.sh; do
    d=$(full_repo)
    rm -f "$d/$f"
    out=$(run "$d")
    rm -rf "$d"
    case "$out" in
        *"$f"*) ok "a missing $f is named" ;;
        *)      bad "a missing $f is named: got $out" ;;
    esac
done

d=$(full_repo)
rm -rf "$d/docs/adr"
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *docs/adr*) ok "a missing docs/adr is named" ;;
    *)          bad "a missing docs/adr is named: got $out" ;;
esac

# --- a workflow that warns instead of failing ---------------------------------

d=$(full_repo)
printf 'jobs:\n  v:\n    continue-on-error: true\n    steps:\n      - run: sh verify.sh\n' \
    > "$d/.github/workflows/ci.yml"
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *continue-on-error*) ok "CI with continue-on-error is named" ;;
    *)                   bad "CI with continue-on-error is named: got $out" ;;
esac

# --- CI that reimplements the checks instead of calling verify.sh -------------

d=$(full_repo)
printf 'jobs:\n  v:\n    steps:\n      - run: go test ./...\n' > "$d/.github/workflows/ci.yml"
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *"CI calling verify.sh"*) ok "CI that reimplements the checks is named" ;;
    *)                        bad "CI that reimplements the checks is named: got $out" ;;
esac

# --- an SBOM older than the dependency manifest -------------------------------

d=$(full_repo)
printf 'module x\n\ngo 1.25\n' > "$d/go.mod"
echo '{}' > "$d/sbom.json"
git -C "$d" add . >/dev/null 2>&1
# Fixed dates, a year apart. Two commits made in the same second compare equal,
# and this case would then pass for the wrong reason on a fast machine.
GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
    git -C "$d" commit -qm seed >/dev/null 2>&1
printf 'module x\n\ngo 1.25\n\nrequire example.com/y v1.0.0\n' > "$d/go.mod"
git -C "$d" add go.mod >/dev/null 2>&1
GIT_AUTHOR_DATE="2021-01-01T00:00:00" GIT_COMMITTER_DATE="2021-01-01T00:00:00" \
    git -C "$d" commit -qm dep >/dev/null 2>&1
out=$(run "$d")
rm -rf "$d"
case "$out" in
    *"regenerated SBOM"*) ok "an SBOM older than go.mod is named" ;;
    *)                    bad "an SBOM older than go.mod is named: got $out" ;;
esac

# --- the case that keeps the check worth reading ------------------------------

d=$(full_repo)
out=$(run "$d")
rm -rf "$d"
if [ -z "$out" ]; then
    ok "a complete repository produces no output"
else
    bad "a complete repository produces no output: got $out"
fi

# --- run from a subfolder, and from a worktree --------------------------------
#
# Both used to be silent: the check tested for a .git directory in the current
# folder. A subfolder has none, and in a worktree .git is a file.

d=$(full_repo)
rm -f "$d/SECURITY.md"
out=$(run "$d/docs")
rm -rf "$d"
case "$out" in
    *SECURITY.md*) ok "run from a subfolder, the whole repository is checked" ;;
    *)             bad "run from a subfolder, the whole repository is checked: got $out" ;;
esac

d=$(full_repo)
rm -f "$d/SECURITY.md"
git -C "$d" add . >/dev/null 2>&1
git -C "$d" commit -qm seed >/dev/null 2>&1
wt=$(mktemp -d)
rmdir "$wt"
git -C "$d" worktree add "$wt" >/dev/null 2>&1
out=$(run "$wt")
rm -rf "$d" "$wt"
case "$out" in
    *SECURITY.md*) ok "a worktree is checked" ;;
    *)             bad "a worktree is checked: got $out" ;;
esac

# --- not a project at all -----------------------------------------------------

d=$(mktemp -d)
out=$(run "$d")
rm -rf "$d"
if [ -z "$out" ]; then
    ok "a directory that is not a project is ignored"
else
    bad "a directory that is not a project is ignored: got $out"
fi

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
