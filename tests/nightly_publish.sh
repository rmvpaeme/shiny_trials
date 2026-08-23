#!/bin/bash
# publish_live() copies the LIVE registry/queue over main's frozen copy, and
# says so loudly when it cannot.
#
#   tests/nightly_publish.sh
#
# Exercises the function text extracted from the real deploy script, not a copy
# of it — a copy would pass forever after the original changed.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/nightly_update/nightly_deploy_posit.sh"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/publishtest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

fails=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; fails=$((fails+1)); }

# Pull the real function out of the deploy script.
sed -n '/^publish_live() {/,/^}/p' "$SCRIPT" > "$TMPD/fn.sh"
if [ ! -s "$TMPD/fn.sh" ]; then
    echo "FAIL: could not extract publish_live() from $SCRIPT" >&2
    exit 1
fi

LOGGED="$TMPD/logged"
: > "$LOGGED"
log() { echo "$*" >> "$LOGGED"; }
# shellcheck disable=SC1090
. "$TMPD/fn.sh"

mkdir -p "$TMPD/live" "$TMPD/worktree"

# 1. The live file wins over the frozen one.
echo "raw_sponsor,proposed
LIVE MARKER,x" > "$TMPD/live/E_review_queue.csv"
echo "raw_sponsor,proposed
FROZEN,y"      > "$TMPD/worktree/E_review_queue.csv"

publish_live "$TMPD/live" "$TMPD/worktree" "E_review_queue.csv"

if grep -q "LIVE MARKER" "$TMPD/worktree/E_review_queue.csv"; then
    ok "the live queue replaces main's frozen copy"
else
    bad "the live queue did NOT reach the work tree"
fi
if grep -q "FROZEN" "$TMPD/worktree/E_review_queue.csv"; then
    bad "the frozen copy survived"
else
    ok "the frozen copy is gone"
fi
if [ -s "$LOGGED" ]; then bad "a successful publish logged a warning"; else ok "a successful publish is quiet"; fi

# 2. A missing live file must WARN, not skip silently, and must leave the
#    frozen copy in place so the deploy still ships something.
echo "raw_sponsor,proposed
FROZEN ONLY,z" > "$TMPD/worktree/registry.csv"
publish_live "$TMPD/live" "$TMPD/worktree" "registry.csv"

if grep -q "WARNING" "$LOGGED"; then
    ok "a missing live file logs a WARNING"
else
    bad "a missing live file was skipped SILENTLY"
fi
if grep -q "FROZEN ONLY" "$TMPD/worktree/registry.csv"; then
    ok "the frozen copy is left in place when there is no live one"
else
    bad "the frozen copy was destroyed"
fi

# 3. Every file the curation app fetches must be in GENERATED_FILES, or it
#    never reaches the deploy branch at all.
for want in "config/sponsor_norm_v2/E_review_queue.csv" \
            "config/sponsor_norm_v2/registry.csv" \
            "config/substance_norm_v2/E_review_queue.csv" \
            "config/substance_norm_v2/registry.csv" \
            "data/trial_overrides.csv"; do
    if grep -q "\"$want\"" "$SCRIPT"; then
        ok "GENERATED_FILES carries $want"
    else
        bad "GENERATED_FILES is MISSING $want"
    fi
done

# 4. assignments.csv must stay out — 7.4 MB rewritten nightly for data the app
#    does not use.
if grep -q '"config/.*assignments.csv"' "$SCRIPT"; then
    bad "assignments.csv was added to GENERATED_FILES"
else
    ok "assignments.csv is correctly absent"
fi

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
