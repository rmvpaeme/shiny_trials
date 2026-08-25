#!/bin/bash
# Nothing that can authenticate may reach this repo. It is PUBLIC.
#
#   tests/no_secrets.sh
#
# Three separate questions, because passing one does not imply the others:
#   1. are credential-shaped PATHS ignored?
#   2. does any TRACKED FILE contain a credential?
#   3. does the tracked seed template contain a real hash rather than a
#      placeholder?
#
# Run before any push. The curation app introduces a database connection string,
# an argon2 admin hash and (optionally) a GitHub PAT — none of which existed in
# this repo before, so the pre-existing .gitignore had never been tested against
# them.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fails=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails+1)); }

echo "1. credential-shaped paths are ignored"
# Representative of each class, including ones that do not exist yet — the point
# is that they would be ignored IF someone created them.
for f in \
  ".Renviron" ".Renviron.local" ".env" ".env.local" "secrets.env" \
  ".Rhistory" ".RData" \
  "curation_app/sql/seed_admin.sql" \
  "curation_app/sql/reviewers_dump.sql" \
  "curation_app/secrets/db.txt" \
  "curation_app/auth/users.rds" \
  "curation_app/R/credentials.R" \
  "curation_app/db_password.txt" \
  "curation_app/gh_token.txt" \
  "curation_app/sessions/a.json" \
  "curation_app/reviewers.sqlite" \
  "rsconnect/shinyapps.io/acct/app.dcf" \
  "curation_app/rsconnect/acct/app.dcf" \
  "server.pem" "id_rsa.key" "cert.p12" ; do
    if git check-ignore -q "$f"; then ok "$f"; else bad "$f is NOT ignored"; fi
done

echo
echo "2. the files that MUST stay tracked are not caught by those rules"
# This script is in the list ON PURPOSE: its name matches the *_secrets* rule,
# so it excluded ITSELF from the repo the first time it was committed and the
# commit silently went in without it.
for f in "curation_app/sql/schema.sql" \
         "curation_app/sql/seed_admin.sql.example" \
         "curation_app/R/github.R" \
         "curation_app/R/field_spec.R" \
         "tests/no_secrets.sh" \
         "tests/with_scratch_v2.sh" \
         "tests/nightly_scripts_agree.sh" ; do
    if git check-ignore -q "$f"; then bad "$f is ignored but must be tracked"; else ok "$f"; fi
done

echo
echo "3. no tracked file contains a credential"
# Excludes the chemistry caches: drug synonyms like gsk-1120212 trip naive
# key-shaped patterns, and those files are 5.7 MB of known-safe reference data.
PATTERNS='\$argon2|\$7\$[A-Za-z0-9./]{16,}|\$2[aby]\$[0-9]{2}\$|postgres(ql)?://[^ "]*:[^ "@]{4,}@|mysql://[^ ]*:[^@]*@|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{25,}|BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}'
# *.example files hold placeholder-SHAPED values on purpose — the admin seed
# template shows an argon2 prefix so the operator knows what to paste. They are
# not skipped, they are checked properly by section 4 instead of by a pattern
# that cannot tell a placeholder from a hash.
HITS_RAW="$(git grep -nIE "$PATTERNS" -- . \
        ':(exclude)config/substance_norm_v2/chembl_cache.csv' \
        ':(exclude)config/substance_norm_v2/registry_aliases.csv' \
        ':(exclude)*.example' \
        ':(exclude)tests/no_secrets.sh' 2>/dev/null || true)"

# Documentation has to show the SHAPE of a connection string, and a test has to
# supply one that cannot connect. Neither is a credential, and muting the whole
# file would be worse than the false positive — a real leak in a README is
# exactly as public as one in source.
#
# Dropped only when the match is self-evidently not a secret:
#   <angle brackets>   a placeholder, never a password
#   loopback/example   a host that resolves to nothing real
# Anything else still fails, including a real string sitting in a .md.
HITS="$(printf '%s\n' "$HITS_RAW" \
        | grep -v '[<>]' \
        | grep -vE '@(127\.0\.0\.1|localhost|::1|example\.(com|org|net)|nowhere)' \
        | grep -v '^$' || true)"
DROPPED=$(( $(printf '%s' "$HITS_RAW" | grep -c . || true) - $(printf '%s' "$HITS" | grep -c . || true) ))
[ "$DROPPED" -gt 0 ] && ok "ignored $DROPPED placeholder/loopback match(es)"
if [ -z "$HITS" ]; then ok "no credential patterns in tracked files"
else bad "credential pattern found in a TRACKED file:"; echo "$HITS" | head -10; fi

echo
echo "4. the tracked seed template holds a placeholder, not a real hash"
TPL="curation_app/sql/seed_admin.sql.example"
if [ -f "$TPL" ]; then
    # A real argon2 hash ends in base64; the template must not.
    # sodium emits scrypt ("$7$..."). Match a real one, not the placeholder.
    if grep -qE '\$7\$[A-Za-z0-9./]{16,}' "$TPL"; then
        bad "$TPL contains what looks like a REAL password hash"
    else ok "$TPL hash field is a placeholder"; fi
    if grep -qE "^\s*INSERT.*VALUES\s*\('(?!CHANGEME)" "$TPL" 2>/dev/null; then
        bad "$TPL has a real username filled in"
    else ok "$TPL username is still CHANGEME"; fi
fi

echo
echo "5. no R source hardcodes a connection string"
RHITS="$(git grep -nIE "(postgres(ql)?|mysql)://" -- '*.R' 2>/dev/null \
         | grep -v '[<>]' \
         | grep -vE '@(127\.0\.0\.1|localhost|::1|example\.(com|org|net)|nowhere)' \
         || true)"
if [ -z "$RHITS" ]; then ok "no database URL literal in any .R file"
else bad "a database URL appears in R source:"; echo "$RHITS"; fi

echo
echo "6. the Posit deploy bundle carries no credentials"
# git is not the only way a secret escapes. rsconnect::deployApp() bundles the
# app DIRECTORY including dotfiles — verified with listBundleFiles() that a bare
# call would upload curation_app/.Renviron, putting the database password on
# Posit as an app file.
#
# Bundling it is ALLOWED: some targets (shinyapps.io) have no way to set an
# environment variable on a deployed app, and refusing there would just mean the
# app cannot connect. What must never happen is bundling it by ACCIDENT.
DEPLOY="curation_app/deploy.R"
if [ ! -f "$DEPLOY" ]; then
    bad "$DEPLOY is missing — a bare deployApp() would ship .Renviron"
else
    # Read the allowlist into a variable. NOT `grep <(sed ...)`: process
    # substitution needs /dev/fd, which is unreadable in some sandboxes, and
    # there grep fails, prints nothing, and the check passes without running.
    # That exact false pass shipped in this file once already.
    ALLOWLIST="$(sed -n '/^APP_FILES <- c(/,/^)/p' "$DEPLOY")"
    if [ -z "$ALLOWLIST" ]; then
        bad "could not read APP_FILES from $DEPLOY — the check did not run"
    else
        ok "read the deploy allowlist ($(printf '%s' "$ALLOWLIST" | wc -l | tr -d ' ') lines)"
        case "$ALLOWLIST" in
            *Renviron*) bad ".Renviron is in the DEFAULT allowlist — it must be opt-in only" ;;
            *)          ok ".Renviron is not in the default allowlist" ;;
        esac
    fi
    if grep -q "appFiles *= *APP_FILES" "$DEPLOY"; then
        ok "deployApp() is given an explicit allowlist, not the directory"
    else bad "the deploy does not pass an allowlist to deployApp()"; fi
    if grep -q -- '--include-env' "$DEPLOY"; then
        ok "bundling the env file requires an explicit --include-env"
    else bad "no explicit opt-in flag for bundling credentials"; fi
    if grep -q "app_role.sql" "$DEPLOY"; then
        ok "the opt-in points at the least-privilege role"
    else bad "the opt-in does not mention a least-privilege role"; fi
    if grep -q "REFUSING TO DEPLOY" "$DEPLOY"; then
        ok "a credential-shaped filename is still refused outright"
    else bad "no refusal for credential-shaped files"; fi

    # The allowlist fails CLOSED, which is safe but means a file app.R sources
    # and the list omits is simply missing at runtime — the app dies on startup
    # with "cannot open file". R/sample.R shipped in exactly that state.
    SOURCED="$(sed -n '/^for (f in c(/,/)) {/p' curation_app/app.R \
               | grep -oE '"[A-Za-z_]+\.R"' | tr -d '"' | sort -u)"
    if [ -z "$SOURCED" ]; then
        bad "could not read the source list from curation_app/app.R"
    else
        # Compare against the QUOTED FILENAMES only, never the raw block. The
        # block includes comments, and the comment explaining this very check
        # mentions "sample.R" — so a substring match against the block passed
        # while sample.R was genuinely missing from the list. The test was
        # green because of its own prose.
        ALLOW_FILES="$(printf '%s' "$ALLOWLIST" | grep -oE '"[A-Za-z_]+\.R"' | tr -d '"' | sort -u)"
        MISSING=""
        for f in $SOURCED; do
            echo "$ALLOW_FILES" | grep -qx "$f" || MISSING="$MISSING $f"
        done
        if [ -n "$MISSING" ]; then
            bad "app.R sources these but the deploy allowlist omits them:$MISSING"
        else
            ok "every file app.R sources is in the deploy allowlist"
        fi
    fi
fi

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed — DO NOT PUSH"; exit 1; fi
echo "all checks passed — safe to push"
