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
HITS="$(git grep -nIE "$PATTERNS" -- . \
        ':(exclude)config/substance_norm_v2/chembl_cache.csv' \
        ':(exclude)config/substance_norm_v2/registry_aliases.csv' \
        ':(exclude)*.example' \
        ':(exclude)tests/no_secrets.sh' 2>/dev/null || true)"
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
RHITS="$(git grep -nIE "(postgres(ql)?|mysql)://" -- '*.R' 2>/dev/null || true)"
if [ -z "$RHITS" ]; then ok "no database URL literal in any .R file"
else bad "a database URL appears in R source:"; echo "$RHITS"; fi

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed — DO NOT PUSH"; exit 1; fi
echo "all checks passed — safe to push"
