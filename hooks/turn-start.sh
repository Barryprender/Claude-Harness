#!/bin/sh
# UserPromptSubmit: take the snapshot that "this turn" is measured against.
# It prints nothing: whatever this hook prints is added to the agent's context.
#
# The end-of-turn gate compares the tree against this snapshot, so a file left
# dirty an hour ago is not reported as this turn's work. The edit gate starts
# from it too, so the operator's own edits between turns are not attributed to
# the agent's first edit of the next one.
#
# Contract: reads the UserPromptSubmit payload on stdin, writes nothing.
# Never exits non-zero - a broken gate must not break the session.

set -u

cat > /dev/null   # drain the payload

# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0
sd=$(state_dir "$root") || exit 0

tmp=$(mktemp -d 2>/dev/null || echo "/tmp/turn-start.$$")
mkdir -p "$tmp" 2>/dev/null || exit 0
trap 'rm -rf "$tmp"' EXIT

tree_state "$root" "$tmp/s" > "$sd/start"
cp "$sd/start" "$sd/last"
exit 0
