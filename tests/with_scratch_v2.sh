#!/bin/bash
# Run a command against COPIES of the v2 pipeline state, then prove the real
# state was not touched.
#
# Usage: tests/with_scratch_v2.sh Rscript tests/emit_human_unassign.R
#
# Every pipeline script honours SPONSOR_V2_DIR / SUBSTANCE_V2_DIR / DATA_DIR, so
# pointing all three at a scratch copy is enough to make a test harmless. That is
# the theory. The check at the bottom is what makes it true: it hashes the real
# directories before and after and fails if anything moved.
#
# This is not belt-and-braces. helper_scripts/sponsor_norm_pipeline/E_emit.R
# hardcoded pp("data", ...) until 2026-08-23, so every "scratch" run of the
# sponsor regression gate silently overwrote the production labels. A test that
# can damage what it is testing is worse than no test, and nothing in the run
# output said so — only a hash comparison catches it.
#
# Exit 0 = the command succeeded AND the real state is byte-identical.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ $# -eq 0 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

# Hash BEFORE anything is copied — the copy itself must not be able to hide a
# mutation, and `find` output is sorted so the comparison is stable.
REAL_PATHS=(config/sponsor_norm_v2 config/substance_norm_v2 data)
snapshot() {
    find "${REAL_PATHS[@]}" -type f ! -name '.DS_Store' 2>/dev/null \
        | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null
}
BEFORE="$(snapshot)"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/v2scratch.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH"/sponsor "$SCRATCH"/substance "$SCRATCH"/data
cp -a config/sponsor_norm_v2/.   "$SCRATCH/sponsor/"   2>/dev/null || true
cp -a config/substance_norm_v2/. "$SCRATCH/substance/" 2>/dev/null || true
# Only the inputs the emit steps read. Copying all of data/ would drag in the
# SQLite databases and the 16 MB cache for no reason.
for f in trial_sponsors_raw.csv trial_substances_raw.csv \
         trial_sponsor_labels.csv trial_substance_labels.csv \
         trial_sponsor_labels_baseline.csv trial_substance_labels_baseline.csv \
         substance_rejected.csv; do
    [ -f "data/$f" ] && cp -a "data/$f" "$SCRATCH/data/"
done

export SPONSOR_V2_DIR="$SCRATCH/sponsor"
export SUBSTANCE_V2_DIR="$SCRATCH/substance"
export DATA_DIR="$SCRATCH/data"
export SCRATCH_ROOT="$SCRATCH"

"$@"
STATUS=$?

AFTER="$(snapshot)"
if [ "$BEFORE" != "$AFTER" ]; then
    echo "" >&2
    echo "FAIL: the run mutated real pipeline state despite the scratch dirs." >&2
    echo "Differing paths:" >&2
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") >&2
    exit 1
fi

if [ $STATUS -ne 0 ]; then
    echo "command exited $STATUS (real state is intact)" >&2
fi
exit $STATUS
