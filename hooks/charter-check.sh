#!/bin/sh
# SessionStart: name the standing artifacts this repository does not have.
# This one reports, and only reports. It never blocks and it never writes.
#
# WHY IT EXISTS. A standard is only load-bearing if its absence is visible.
# Nothing tells you a repository has no SECURITY.md; it just quietly does not,
# for a year. This says it once per session, so a gap is something noticed
# rather than something forgotten.
#
# WHY IT IS QUIET ABOUT IT. The message is handed to the agent as context, not
# printed at the operator, and it says not to act on it. A hook that opens
# every session with a list of chores gets switched off in a week, and then it
# reports nothing at all. It is there for the moment the work happens to touch
# one of the gaps.
#
# WHAT IT DOES NOT DO. It does not judge content. Whether SECURITY.md says
# anything true is not a thing a probe can know, and pretending otherwise
# turns an honest existence check into a false assurance.
#
# Contract: reads the SessionStart payload on stdin, writes hook JSON on
# stdout. Never exits non-zero - a broken gate must not break the session.

set -u

cat > /dev/null   # drain the payload

# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"

# Only meaningful inside a project, and always about the whole of it. Asking
# git, not testing for a .git directory: in a worktree or a submodule .git is a
# file, and from a subfolder there is no .git here at all. Both used to make
# the check go silent.
root=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$root" ]; then
    cd "$root" || exit 0
else
    [ -f go.mod ] || [ -f package.json ] || exit 0
fi

missing=""
have=""

note() { # $1 = label, $2 = present(1)/absent(empty)
    if [ -n "$2" ]; then have="$have$1, "; else missing="$missing$1, "; fi
}

# Case-insensitive existence.
#
# A case-insensitive filesystem matched docs/TECHNICAL-DOCUMENTATION.md against
# a lower-case probe by accident; the same repository on Linux would have been
# reported as missing a file that was right there. A check that cries wolf gets
# ignored, and an ignored check is the same as no check.
#
# The comparison walks a glob rather than piping ls into grep. Parsing ls
# breaks on a filename containing a newline, and a probe that silently finds
# nothing is the failure this whole repository is about.
t() {
    [ -e "$1" ] && { echo 1; return; }
    _d=$(dirname "$1")
    _b=$(basename "$1" | tr '[:upper:]' '[:lower:]')
    [ -d "$_d" ] || return
    for _f in "$_d"/*; do
        [ -e "$_f" ] || continue
        _n=$(basename "$_f" | tr '[:upper:]' '[:lower:]')
        [ "$_n" = "$_b" ] && { echo 1; return; }
    done
}

note "CLAUDE.md"   "$(t CLAUDE.md)"
note "README.md"   "$(t README.md)"
note "SECURITY.md" "$(t SECURITY.md)"
note "docs/adr"    "$(t docs/adr)"

ci=""
[ -d .github/workflows ] && [ -n "$(ls .github/workflows 2>/dev/null)" ] && ci=1
note "CI workflow" "$ci"

verify=""
[ -f verify.sh ] && verify=1
note "verify.sh" "$verify"

# Two definitions of green drift, and then there is no definition. If both a
# verify.sh and a CI workflow exist, CI should be calling it rather than
# reimplementing the checks beside it.
if [ -n "$verify" ] && [ -n "$ci" ]; then
    grep -rq "verify\.sh" .github/workflows 2>/dev/null \
        || missing="${missing}CI calling verify.sh (it exists, but CI reimplements the checks), "
fi

# A workflow that warns instead of failing is a workflow that passes. It is
# invisible until somebody reads the YAML, which is why this reads it.
if [ -n "$ci" ] && grep -rq "continue-on-error: *true" .github/workflows 2>/dev/null; then
    missing="${missing}CI that fails rather than warns (continue-on-error is set), "
fi

# An SBOM is expected once there are declared dependencies to list. Existence
# is not the requirement - freshness is, and the way it goes stale is a
# dependency change landing without a regenerate.
#
# Compared by commit date, not by modification time: a clone, a checkout or a
# stray touch rewrites the mtime without changing a byte.
manifest=""
for m in go.mod package.json pyproject.toml Cargo.toml composer.json; do
    [ -f "$m" ] && { manifest="$m"; break; }
done
if [ -n "$manifest" ]; then
    sbom=""
    for s in sbom.json bom.json sbom.xml; do
        [ -f "$s" ] && { sbom="$s"; break; }
    done
    if [ -z "$sbom" ]; then
        missing="${missing}SBOM, "
    else
        m_at=$(git log -1 --format=%ct -- "$manifest" 2>/dev/null)
        s_at=$(git log -1 --format=%ct -- "$sbom" 2>/dev/null)
        if [ -n "$m_at" ] && [ -n "$s_at" ] && [ "$m_at" -gt "$s_at" ]; then
            missing="${missing}a regenerated SBOM ($manifest changed after $sbom did), "
        else
            have="${have}SBOM, "
        fi
    fi
fi

[ -z "$missing" ] && exit 0

missing=$(printf '%s' "$missing" | sed 's/, $//')
have=$(printf '%s' "$have" | sed 's/, $//')
[ -n "$have" ] || have="none"

ctx="Standing artifacts missing from this repository: $missing.
Present: $have.
Do not act on this. Mention it only if the work touches one of the gaps, or if the operator asks what this repository is missing."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"},"suppressOutput":true}\n' \
    "$(printf '%s' "$ctx" | esc)"
exit 0
