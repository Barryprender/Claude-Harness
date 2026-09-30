# shellcheck shell=sh
# Shared by the gates. Sourced, never run on its own.
#
# Everything here used to be copied into each gate, and the copies had already
# started to drift: one escaping bug was fixed in one place first. A helper
# that exists twice is two helpers, and only one of them gets the next fix.

# JSON string escaping, in awk rather than in an interpreter. Enough for tool
# output: backslash, quote, tab, and the control characters that would make the
# JSON invalid. Newlines become the two characters backslash-n.
#
# Keeping the gates free of python means they still work on a machine where
# python is missing or - see the note in commit-gate.sh - present but broken.
#
# It compares characters one at a time rather than calling gsub. The gsub
# version is shorter and it was wrong: a backslash in a gsub replacement is
# processed a second time, so the escape for a quote came out as two
# backslashes and a quote, which ends the JSON string early. Every compiler
# error message is full of quotes, so the first real failure the edit gate
# reported was unparseable. sprintf("%c", 92) has no such ambiguity.
esc() {
    tr -d '\000-\010\013-\037' | awk '
        BEGIN { bs = sprintf("%c", 92); q = sprintf("%c", 34) }
        {
            if (NR > 1) printf "%s", bs "n"
            out = ""
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == bs)        out = out bs bs
                else if (c == q)    out = out bs q
                else if (c == "\t") out = out "    "
                else                out = out c
            }
            printf "%s", out
        }'
}

# --- trust --------------------------------------------------------------------
#
# The gates run a repository's own verify.sh. In a repository somebody else
# wrote, that is running a stranger's code on every edit, just because the
# repository was opened. So verify.sh runs only where the operator has said
# yes, in that repository's own local git config. Each project carries its own
# switch. It lives in .git/config, which is never committed, so a clone cannot
# bring a yes with it. --local, so a global setting cannot say yes for every
# repository at once. A repository without the switch is reported, never run:
# a check that did not run has not passed.
trusted() { # $1 = repository root
    [ "$(git -C "$1" config --local --bool harness.trusted 2>/dev/null)" = true ]
}

untrusted_message() {
    printf '%s' "Nothing was verified: this repository has not been marked as trusted, so its verify.sh was not run. A repository you did not write can put anything in verify.sh. If you trust it, run this once inside it:

git config harness.trusted true"
}

# --- what changed -------------------------------------------------------------
#
# Where the gates keep their state: inside the git directory, so it is per
# worktree, never committed, and gone with the clone.
state_dir() { # $1 = repository root; prints an absolute directory
    _d=$(cd "$1" && git rev-parse --git-path claude-harness 2>/dev/null) || return 1
    case "$_d" in
        /*|[A-Za-z]:*) ;;
        *) _d="$1/$_d" ;;
    esac
    mkdir -p "$_d" 2>/dev/null || return 1
    printf '%s' "$_d"
}

# One line per dirty path: the hash of its content, a tab, the path. A path
# that is gone gets - for a hash, so a deletion is a change like any other.
#
# This replaced a two-minute modification-time window. Any tool that keeps the
# original timestamp - cp -p, tar, git checkout - made a changed file invisible
# to it, and a deleted file has no timestamp at all. Content cannot be fooled
# that way. The gates compare two of these: now, and a snapshot taken earlier.
tree_state() { # $1 = repository root, $2 = scratch file prefix
    (cd "$1" && git -c core.quotepath=off status --porcelain -uall 2>/dev/null) |
        sed -e 's/^...//' -e 's/^.* -> //' > "$2.p"
    : > "$2.e"
    while IFS= read -r _p; do
        [ -f "$1/$_p" ] && printf '%s\n' "$_p" >> "$2.e"
    done < "$2.p"
    (cd "$1" && git hash-object --stdin-paths < "$2.e" 2>/dev/null) > "$2.h"
    # FILENAME, not NR==FNR: that idiom breaks when the first file is empty.
    awk 'FILENAME == ARGV[1] { h[FNR] = $0; next }
         FILENAME == ARGV[2] { have[$0] = h[FNR]; next }
         { print (($0 in have) ? have[$0] : "-") "\t" $0 }' "$2.h" "$2.e" "$2.p"
}

# Paths whose line differs between two tree_state outputs, each once. A file
# that went from dirty to clean counts: reverting it is a change too.
changed_paths() { # $1 = before, $2 = after
    awk 'function out(k,  p) {
             p = substr(k, index(k, "\t") + 1)
             if (!(p in seen)) { seen[p] = 1; print p }
         }
         FILENAME == ARGV[1] { a[$0] = 1; next }
         { b[$0] = 1 }
         END {
             for (k in a) if (!(k in b)) out(k)
             for (k in b) if (!(k in a)) out(k)
         }' "$1" "$2"
}

# --- the project's own definition of green ------------------------------------
#
# verify.sh is looked for beside each changed file and upwards from there, so a
# repository holding several projects gets the right one for the file that
# changed rather than the one at the top. A deleted file still has a directory
# name, so it is looked up the same way. Both gates use this; they used to
# disagree, and the end-of-turn gate missed a nested project the edit gate saw.
verifiers_for() { # $1 = repository root; stdin = root-relative paths
    while IFS= read -r _p; do
        [ -n "$_p" ] || continue
        _d=$(dirname "$1/$_p")
        while :; do
            if [ -f "$_d/verify.sh" ]; then
                printf '%s\n' "$_d"
                break
            fi
            [ "$_d" = "$1" ] && break
            _up=$(dirname "$_d")
            [ "$_up" = "$_d" ] && break
            _d=$_up
        done
    done | awk '!seen[$0]++'
}

# Everything from the first FAILED: line down, or the whole output if there is
# none. Never cut short: a failure report that drops the bottom of the list
# hides failures, which is the thing all of this exists to stop.
failure_detail() {
    _o=$(cat)
    _f=$(printf '%s\n' "$_o" | sed -n '/FAILED:/,$p')
    if [ -n "$_f" ]; then printf '%s' "$_f"; else printf '%s' "$_o"; fi
}

# --- baseline -----------------------------------------------------------------
#
# The end-of-turn gate records how each verify.sh failed. When the edit gate
# then sees the same failure, word for word, it was already there before this
# turn's edits, and blocking every unrelated edit on it is the loop ADR 0001
# refuses at end of turn. Durations are stripped first, or a test that took
# 0.02s instead of 0.01s would look like a new failure.
#
# LAZY: exact text match after stripping durations. A failure whose message
# carries anything else that varies per run is treated as new and blocks,
# which is the safe direction. Upgrade path: have verify.sh name failing
# checks on FAILED: lines and compare those names only.
normalise() {
    sed -E 's/[0-9]+(\.[0-9]+)?(ns|us|ms|s)([^[:alpha:]]|$)/\3/g'
}

baseline_file() { # $1 = state dir, $2 = verifier dir
    printf '%s/baseline.%s' "$1" "$(printf '%s' "$2" | cksum | cut -d' ' -f1)"
}
