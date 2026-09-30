#!/bin/sh
# Checks the commit-msg git hook rejects attribution lines, however the commit
# was spelled.
#
#     sh hooks/git/commit-msg_test.sh
#
# Every case makes a real commit through git in a throwaway repository, so what
# is tested is what git does with the hook, not what the hook does when called
# by hand. The spellings below are the ones that got past the old
# command-line check.

set -u

HOOKS=$(cd "$(dirname "$0")" && pwd)
pass=0
fail=0

ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

# Assembled from pieces, like the commit gate's test.
T="Co-""Authored-By"
T_UPPER="CO-""AUTHORED-BY"
G="Generated ""with"

scratch() {
    d=$(mktemp -d)
    git -C "$d" init -q .
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    git -C "$d" config core.hooksPath "$HOOKS"
    echo x > "$d/a.txt"
    git -C "$d" add a.txt 2>/dev/null
    printf '%s' "$d"
}

commits() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }

expect() { # $1 description, $2 directory, $3 committed | rejected
    if [ "$(commits "$2")" -eq 1 ]; then got=committed; else got=rejected; fi
    rm -rf "$2"
    if [ "$got" = "$3" ]; then ok "$1: $got"; else bad "$1: expected $3, got $got"; fi
}

d=$(scratch)
git -C "$d" commit -qm "Add a" >/dev/null 2>&1
expect "a plain message" "$d" committed

d=$(scratch)
git -C "$d" commit -qm "Add a

$T: A <a@b.c>" >/dev/null 2>&1
expect "a trailer" "$d" rejected

d=$(scratch)
git -C "$d" commit -qm "Add a

$T_UPPER: A <a@b.c>" >/dev/null 2>&1
expect "a trailer in capitals" "$d" rejected

d=$(scratch)
printf 'Add a\n\n%s: A <a@b.c>\n' "$T" > "$d/msg"
git -C "$d" commit -q -F msg >/dev/null 2>&1
expect "a trailer in a -F message file" "$d" rejected

d=$(scratch)
(cd "$d" && sh -c "git commit -qm 'Add a

$T: A <a@b.c>'") >/dev/null 2>&1
expect "a commit inside sh -c" "$d" rejected

# The control for the case above: without it, a quoting mistake in the test
# would also read as rejected.
d=$(scratch)
(cd "$d" && sh -c "git commit -qm 'Add a'") >/dev/null 2>&1
expect "a plain commit inside sh -c" "$d" committed

d=$(scratch)
git -C "$d" commit -qm "Add a

$G [Claude Code](https://claude.com/claude-code)" >/dev/null 2>&1
expect "a generated-with line naming an AI tool" "$d" rejected

d=$(scratch)
git -C "$d" commit -qm "Regenerate the stubs

$G protoc 29.1 from api.proto." >/dev/null 2>&1
expect "a generated-with line naming a normal tool" "$d" committed

# With core.hooksPath set, git no longer runs the repository's own hooks. This
# hook runs the repository's commit-msg itself, or setting the path globally
# would quietly switch off every project's own message check.
d=$(scratch)
printf '#!/bin/sh\nexit 1\n' > "$(git -C "$d" rev-parse --absolute-git-dir)/hooks/commit-msg"
chmod +x "$(git -C "$d" rev-parse --absolute-git-dir)/hooks/commit-msg"
git -C "$d" commit -qm "Add a" >/dev/null 2>&1
expect "the repository's own commit-msg still runs" "$d" rejected

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
