#!/bin/bash
# The two nightly deploy scripts must not drift apart in BEHAVIOUR.
#
# Usage: tests/nightly_scripts_agree.sh
#
# There are two copies for a real reason: the server's runs from the repo root
# (every git path relative to $SCRIPT_DIR), the repo's runs from nightly_update/
# (paths relative to $PROJECT_DIR). Only the location and three identifiers may
# differ. Anything else is drift, and drift here is expensive and silent:
#
#   * 2026-08-16 the repo copy staged 2 generated files where the server staged
#     16, so a deploy from it would have shipped a cache with no label CSVs
#     beside it and nothing would have said so.
#   * It drifted again immediately: the repo copy tested $SUBSTANCE_SENTINEL
#     without ever assigning it. Under `set -e` an unset variable expands to ""
#     and `[ -f "" ]` is false, so substance failures were never reported at
#     all — a silent no-op sitting in the middle of the alerting path.
#
# A comment saying "keep these in sync" did not work twice. This does.
#
# Exit 0 = the two agree once location and naming are normalised.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_COPY="$ROOT/nightly_update/nightly_deploy_posit.sh"
SERVER_COPY="$ROOT/nightly_update/nightly_deploy_posit_local.sh"

for f in "$REPO_COPY" "$SERVER_COPY"; do
    [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/nightlydrift.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

# Strip what is allowed to differ, keep everything that changes behaviour:
#   - comments and blank lines (prose, not code)
#   - $PROJECT_DIR / $SCRIPT_DIR      -> $ROOT   (where the script lives)
#   - $INSTANCE_NAME / $instanceName  -> $INST   (naming only)
#   - the assignment lines for those, which legitimately differ
# Leading whitespace is normalised so indentation is not treated as drift.
normalise() {
    sed -e 's/#.*$//' \
        -e 's/[[:space:]]*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/\$PROJECT_DIR/$ROOT/g' \
        -e 's/"\${PROJECT_DIR}"/"${ROOT}"/g' \
        -e 's/\$SCRIPT_DIR/$ROOT/g' \
        -e 's/\$INSTANCE_NAME/$INST/g' \
        -e 's/\$instanceName/$INST/g' \
        "$1" \
    | grep -v '^$' \
    | grep -Ev '^(INSTANCE_NAME|instanceName|PROJECT_DIR|SCRIPT_DIR|LOG_FILE)=' \
    | grep -Ev '^cd "\$ROOT"$'
}

# Compare as STRINGS, not via `diff <(...) <(...)`. Process substitution needs
# /dev/fd, which is not always readable (a sandbox, a restricted CI container),
# and there `diff` fails, prints nothing, and a `|| true` turns that into a
# silent pass — a test that reports success precisely when it could not run.
# That is the same failure shape as the unset $SUBSTANCE_SENTINEL this test
# exists to catch, so it is worth avoiding rather than tolerating.
A="$(normalise "$REPO_COPY")"
B="$(normalise "$SERVER_COPY")"

if [ -z "$A" ] || [ -z "$B" ]; then
    echo "FAIL: normalisation produced nothing — the test could not run." >&2
    exit 1
fi

if [ "$A" = "$B" ]; then
    echo "ok: the two nightly scripts agree"
    exit 0
fi

DRIFT="$(printf '%s\n' "$A" > "$TMPD/repo" && printf '%s\n' "$B" > "$TMPD/server" &&
         diff -u "$TMPD/repo" "$TMPD/server")"

echo "FAIL: nightly_deploy_posit.sh and nightly_deploy_posit_local.sh have drifted." >&2
echo "      < repo copy   nightly_update/nightly_deploy_posit.sh" >&2
echo "      > server copy nightly_update/nightly_deploy_posit_local.sh" >&2
echo "" >&2
printf '%s\n' "$DRIFT" >&2
exit 1
