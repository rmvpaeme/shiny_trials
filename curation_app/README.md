# Curation app

A multi-user reviewer app for the EU Paediatric Trial Monitor. Reviewers check
how trials were recoded, clear the sponsor and substance normalisation queues,
and every decision is attributed, timestamped and fed back into the nightly.

It is a **separate deployment** from the dashboard and shares one file with it,
`R/field_spec.R`.

---

## What it is for

The pipeline has honoured `decided_by = "human"` since v0.20 — pinned
assignments survive a re-run, merges of human entities are refused, and
`route_for_review()` drops human rows so a decided string leaves the queue by
construction. Nothing wrote it. 2,128 sponsor and 4,717 substance rows were
re-proposed every night to nobody, and the ~40 other recoded fields had no
correction path at all.

This app is the writer.

---

## The four screens

| Tab | What it does |
|---|---|
| **Trial validation** | Two columns — what the register said, what the app shows — with the differing rows highlighted. Click any row to correct it. Defaults to *your assigned round*, not all 51,311 trials. |
| **Normalisation review** | The sponsor and substance queues. Accept / edit / reject, plus *not a substance* on the substance side. |
| **Changes & statistics** | Per-field change rate, disagreements, throughput, pipeline lag. Visible to everyone. |
| **Admin** | Accounts, passwords, the review sample, snapshot refresh, export status, downloads. Admin only. |

### Where a correction goes

This is the one thing to understand before using it.

- **Sponsor and substance** corrections are keyed on the **raw string** and go
  to the v2 registries. They fix *every* trial carrying that string. Correcting
  "Novartis Pharma AG" on one trial and leaving the other 400 wrong is not a fix.
- **Everything else** — phase, status, MedDRA, country, age group, dates —
  has no registry to generalise through and becomes a **per-trial override**.

The editor says which, every time, before you save. A registry edit shows a
warning; a per-trial edit says "This trial only".

Nothing enforces this by convention alone: `field_spec.R` gives registry-routed
fields `override_col = NA`, `attach_trial_overrides()` refuses those columns
independently, and `tests/field_spec_matches_cache.R` fails if the two ever
disagree.

---

## Data in, decisions out

```
GitHub `deploy` branch ──fetch by SHA──▶ curation app ──decisions──▶ Postgres
                                                                        │
  data/trial_sponsor_labels.csv ◀── E_emit ◀── registries ◀── export.R ◀─┘
                                                    (inside the nightly)
```

**In.** At process start the app resolves `deploy` to a commit and fetches seven
files at that SHA: the trials cache, both review queues, both registries, and
both raw-string exports. By SHA and never by ref, so a nightly push landing
mid-fetch cannot produce a half-and-half snapshot. Only data is fetched, never
code.

**Out.** `export.R` runs inside the nightly on the server and is the *single
writer*. The app never touches the pipeline's files: there is no shared
filesystem, and a second writer racing `N_nightly_resolve.R` is the collision
that retired the v1 reviewer app.

A decision is therefore **live the next morning**, not immediately. The app says
so — an edited field shows a "pending" badge until the rebuild.

---

## The review sample

51,311 trials will never all be validated. An admin draws a stratified sample
and it is split across the reviewers.

- **Stratified by register × era**, allocated proportionally. Measured at N=300:
  every stratum within 0.31 percentage points of its true share.
- **~10% double-assigned**, always to a different reviewer. Without overlap no
  two people ever see the same trial, so inter-rater agreement is unmeasurable
  and the disagreement report can never populate.
- **Reproducible** — seeded from the sample id, so the same id always yields
  the same draw.

**Rounds are named.** A validation gets redone, so several draws coexist:
Admin → Review sample → name it ("Round 1 — Aug 2026"), set N and the
double-assigned share → Draw. Reviewers pick which round they are working
through from a dropdown in Trial validation, newest first.

The representativeness table appears after each draw, so the claim is checked
rather than asserted. A round nobody has reviewed can be retired; one with
sign-offs behind it is refused, because retiring it would orphan that work and
discard the overlap the agreement figures come from.

---

## Running it locally

```bash
# 1. The connection string, in curation_app/.Renviron (NOT the repo root —
#    R reads .Renviron from the STARTUP directory and this app starts here).
echo 'CURATION_DB_URL=postgresql://postgres.<ref>:<pw>@aws-0-<region>.pooler.supabase.com:5432/postgres' \
  > curation_app/.Renviron

# 2. Schema (idempotent)
psql "$CURATION_DB_URL" -f curation_app/sql/schema.sql

# 3. The first admin — copy the template, fill it in, run it, delete your copy
cp curation_app/sql/seed_admin.sql.example /tmp/seed.sql

# 4. Run
R -e 'shiny::runApp("curation_app", port = 7913)'
```

Use the **session pooler** (port 5432). The direct endpoint
`db.<ref>.supabase.co` is IPv6-only and will not resolve on a network without
IPv6 — it fails as "no route to host", which reads like an outage.

**Through the pooler the username carries the project ref**: `postgres.<ref>`,
or `curation_app.<ref>` for the app role. A bare role name gets
`(ENOIDENTIFIER) no tenant identifier provided`, because the pooler cannot tell
which project the connection is for. `apply_app_role.R` builds this correctly.

The pooler allows **15 clients for the whole project**, shared with `export.R`,
any `psql`, and any second copy of the app. Exhausting it surfaces at the login
screen and looks exactly like bad credentials; the app now says otherwise.

---

## Deploying

To **Posit Cloud, by hand** — not through the nightly like the dashboard. Its
data changes nightly; its code does not.

Target is **Connect Cloud**, because it has a Vars pane: `CURATION_DB_URL` is
set on the deployed app and never enters the bundle.

```bash
Rscript curation_app/deploy.R                      # dry run: shows what uploads
Rscript curation_app/deploy.R --deploy
```

First time only, authorise the account:

```r
# connect.posit.cloud -> avatar -> API Keys -> New key
rsconnect::connectApiUser(account = "<username>",
                          server  = "connect.posit.cloud",
                          apiKey  = "<key>")
```

After deploying, set the variable — the app cannot sign anyone in without it:

> Connect Cloud → the app → **Vars** → `CURATION_DB_URL` = the session pooler URL

To use shinyapps.io instead: `--server=shinyapps.io --deploy --include-env`.
It has no Vars pane, so the string must be bundled; apply `sql/app_role.sql`
first so what ships is the least-privilege role.

`deploy.R` uses an **allowlist**, not an exclusion list. A bare
`rsconnect::deployApp()` bundles the directory including dotfiles — verified
that it would upload `curation_app/.Renviron`, putting the database password in
the bundle.

Set `CURATION_DB_URL` on the deployed app instead (Connect / Connect Cloud have
a Vars pane). If the target has none — shinyapps.io does not — use
`--deploy --include-env`, which bundles it deliberately and says what that costs.

**Either way, do not deploy with the `postgres` superuser.** Run

```bash
Rscript curation_app/apply_app_role.R           # creates the role, prints the URL once
Rscript curation_app/apply_app_role.R --rotate  # new password, same grants
```

No `psql` needed — it runs over DBI, generates the password, applies the grants
and verifies every table and view before printing the connection string. Paste
that into Connect Cloud → Vars; it is not written to disk.

The `curation_app` role has: SELECT and INSERT on
decisions, a column-scoped UPDATE on `reviewers`, and no DELETE or TRUNCATE
anywhere. A leaked app credential is then a much smaller event than a leaked
superuser, which can read every password hash and disable the audit trail.

---

## Files

```
app.R              shell: auth gate, four tabs, snapshot + pool at startup
export.R           THE WRITER. Postgres -> registries + trial_overrides.csv
deploy.R           allowlisted deploy to Posit
R/field_spec.R  ★  the recoded-field catalogue — SHARED with ../app.R
R/github.R         snapshot fetch: resolve by SHA, atomic swap, degraded mode
R/store.R          the decision store; every write parameterised
R/auth.R           login, roles, idle expiry
R/sample.R         stratified draw and assignment
R/norm_review.R    tab 2      R/trials.R  tab 1
R/stats.R          tab 3      R/admin.R   tab 4
sql/schema.sql     tables, latest-wins views, disagreement views
sql/app_role.sql   least-privilege role for the deployed app
```

★ `field_spec.R` is sourced by **both** apps. It lives here because a Posit
bundle is rooted at a directory and cannot reference paths above it — the
curation app cannot reach up into the repo, but the dashboard can reach down.
`manifest.json` carries the path.

---

## Tests

```bash
tests/no_secrets.sh                                    # before every push
Rscript tests/curation_snapshot.R                      # needs network
Rscript tests/curation_store.R                         # needs the database
Rscript tests/curation_auth.R
Rscript tests/curation_norm_review.R
Rscript tests/curation_trials.R
Rscript tests/curation_stats.R
Rscript tests/curation_admin.R
Rscript tests/curation_sample.R
tests/with_scratch_v2.sh Rscript tests/curation_round_trip.R   # the whole loop
```

Every database test namespaces its rows `__test__` and deletes them in a
`finally` block. `with_scratch_v2.sh` copies the pipeline state, points the env
vars at the copy, and **hashes the real directories before and after** — a test
that can damage what it is testing is worse than no test.

A test that cannot judge exits **2**, not 1, following `E_emit.R`: exit 1 means
a problem was measured, exit 2 means the check did not run.
