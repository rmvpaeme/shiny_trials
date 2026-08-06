# Reviewer app — multi-user deployment on Posit Cloud

## Context

The reviewer app built in `curation_app/` assumes a single reviewer on a laptop:
it reads the config CSVs directly and appends decisions to a CSV ledger guarded
by `filelock`. The app is now to be deployed to Posit Cloud for several users,
with a login screen, an admin view of what each user changed, and metrics.

That breaks three assumptions at once, and the storage one is not a detail:

1. **The deployed bundle is read-only.** Posit Cloud serves the app from a
   deployed image. `config/review_ledger/review_decisions.csv` cannot be written
   there, and even if it could, the write would be discarded on redeploy.
2. **`filelock` does not span containers.** It coordinates processes on one
   filesystem. Concurrent reviewers in separate sessions would silently
   overwrite each other's ledger — the classic read-modify-write race, and the
   atomic rename makes it *worse*, because each writer cleanly replaces the
   whole file with its own stale copy.
3. **There is no identity.** `reviewer` is a free-text box seeded from the OS
   user. That is fine for attribution on one machine and worthless as an access
   control or an audit trail once the app is on the internet.

So the deployment is not "add a login screen to the existing app". It is
**move the decision store off the filesystem**, then add identity and an admin
view on top. The tier loaders, review card, and `apply.R` replay logic survive
unchanged; only `R/store.R` is substantially rewritten.

## Decision needed before starting

**Where does the decision store live?** This is the one thing I cannot pick for
you, because it depends on infrastructure you have rather than on the code.

| Option | Fit | Cost | Notes |
|---|---|---|---|
| **Hosted Postgres** (Supabase / Neon free tier) | Recommended | Free tier is ample — the whole backlog is 6,431 rows | Real concurrency, real transactions, `DBI` + `RPostgres`. Connection string via `.Renviron`, already gitignored |
| Google Sheets (`googlesheets4`) | Workable | Free | Simplest to inspect by hand, but rate-limited and has no locking — needs an append-only discipline and still races on read-modify-write |
| Posit Cloud persistent storage | Depends | — | Only if your plan gives the app a writable persistent volume shared across sessions. Worth checking before ruling in |

Everything below assumes Postgres; the Sheets variant changes only `store.R`.

---

## 1. Storage — rewrite `R/store.R`

Same public surface, so `review_card.R` and `apply.R` do not change:
`append_decision()`, `read_ledger()`, `latest_decisions()`.

Two tables:

```sql
CREATE TABLE reviewers (
  username      TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  password_hash TEXT NOT NULL,      -- bcrypt, never plaintext
  role          TEXT NOT NULL DEFAULT 'reviewer',  -- 'reviewer' | 'admin'
  active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE review_decisions (
  decision_id           BIGSERIAL PRIMARY KEY,
  decided_at_utc        TIMESTAMPTZ NOT NULL DEFAULT now(),
  reviewer              TEXT NOT NULL REFERENCES reviewers(username),
  tier                  TEXT NOT NULL,
  domain                TEXT NOT NULL,
  source_file           TEXT NOT NULL,
  row_key               TEXT NOT NULL,
  raw_value             TEXT,
  proposed_value        TEXT,
  final_value           TEXT,
  action                TEXT NOT NULL CHECK (action IN ('accept','edit','reject','skip')),
  created_new_canonical BOOLEAN NOT NULL DEFAULT FALSE,
  extra_fields          JSONB,
  comment               TEXT,
  input_hash            TEXT,
  decision_ms           INTEGER          -- time on the card, for throughput metrics
);

CREATE INDEX ON review_decisions (tier, row_key);
CREATE INDEX ON review_decisions (reviewer);
```

Still append-only — `latest_decisions()` becomes a window function rather than
`slice_tail`, so the semantics carry over exactly:

```sql
SELECT DISTINCT ON (tier, row_key) *
FROM review_decisions
ORDER BY tier, row_key, decided_at_utc DESC;
```

The `BIGSERIAL` primary key replaces the client-generated `decision_id` hash,
which removes the collision risk when two reviewers decide the same row in the
same second.

Keep a `--export-ledger` path that dumps the table to the same CSV shape
`apply.R` already reads, so the local apply workflow is unchanged.

## 2. Login

Recommended: **`shinymanager`** — purpose-built, handles the session cookie,
timeout, and password change flow. It stores credentials in an encrypted SQLite
file by default; point it at the Postgres `reviewers` table instead.

A hand-rolled alternative is ~150 lines (`bcrypt` via the `sodium` package, a
session token in `session$userData`, and a `req(authenticated())` guard on every
output). It avoids a dependency but puts you in the business of writing auth,
which is the wrong place to save a dependency.

Either way:

- Passwords hashed with bcrypt. Never stored, logged, or emailed in plaintext.
- The reviewer identity comes **only** from the authenticated session. Delete the
  free-text `reviewer` input from the header — with several users it is an
  attribution hole, since anyone can type anyone else's name.
- Gate the admin panel on `role == 'admin'` **server-side**. Hiding the nav
  panel client-side is not access control; the outputs must refuse to render.
- Set a session timeout. Reviewers leave tabs open.

New dependencies: `shinymanager`, `DBI`, `RPostgres`, `sodium`. Per
`AGENTS/AGENTS.md:11` these need your explicit approval — flagging rather than
assuming.

## 3. Admin panel

A `nav_panel` visible only to admins, server-side gated.

**Per-reviewer metrics** — the counts you asked for:

| Metric | Definition |
|---|---|
| Decided | rows with a latest action in (accept, edit, reject) |
| Accepted | proposal taken unchanged — the LLM was right |
| Changed | `action = 'edit'` — the LLM was wrong and was corrected |
| Rejected | alias removed / not a valid entity |
| Skipped | deferred |
| New canonicals | `created_new_canonical = TRUE` — the number to watch |
| Median seconds/decision | from `decision_ms`; flags rubber-stamping |

**By source** — the discriminating cut, since it answers "which provenance tier
is actually trustworthy". Join decisions to the source row's `source` /
`match_source` and report the **change rate per source**:

```
source            decided   accepted   changed   rejected   change_rate
llm_curated          420        367        41         12          12.6%
chembl               180        170         6          4           5.6%
fuzzy:llm_reviewed    95         31        48         16          67.4%
```

A tier where reviewers change two thirds of the rows is a tier whose confidence
prior is wrong, and that table is the evidence for re-tuning it.

**Cross-reviewer disagreement** — rows where two reviewers reached different
`final_value`s. With several users this is the highest-value view in the panel:
it finds both genuinely ambiguous entities and reviewers who need calibration.
There is no such thing as a disagreement report with one user, which is why it
belongs in this plan and not the last one.

**Downloads** — full ledger CSV, per-reviewer CSV, and the metrics tables, via
`downloadHandler`.

## 4. Deployment

- **Separate Posit Cloud app** from the public dashboard. Different bundle,
  different URL, different access list. Do not add `curation_app/` to the
  dashboard's `manifest.json` — that file is a deliberate 7-file allowlist.
- The app reads config CSVs from its own bundle (read-only, fine) and writes
  only to Postgres.
- Connection string and any keys come from environment variables set in the
  Posit Cloud UI, never from a file in the repo. `.Renviron`, `*.env`, `*.key`,
  `*.pem`, `curation_app/auth/`, `curation_app/secrets/` and the session/sqlite
  patterns are already gitignored (`.gitignore`, reviewer app block).
- Redeploy refreshes the backlog: the config CSVs are baked into the bundle, so
  a rebuilt index needs a redeploy to be seen. Decisions are unaffected — they
  live in the database.

## 5. Workflow with several reviewers

```
reviewers decide in the deployed app   →   Postgres
                                            │
                          admin exports ledger CSV
                                            │
                             locally: Rscript curation_app/apply.R --write
                                            │
                             rebuild indexes, commit, redeploy
```

`apply.R` stays local and unchanged. Applying decisions edits tracked config
files and must go through review and a commit — that should not happen from a
web form.

Decide the conflict rule before going live: with several reviewers, the current
"latest decision wins" silently lets a later reviewer overwrite an earlier one.
Options are last-write-wins (current), first-write-wins, or route disagreements
to an admin queue. The disagreement report makes whichever you pick auditable.

## Verification

1. **Concurrency** — two browser sessions, two accounts, decide the same row
   simultaneously; both rows land, `latest_decisions()` returns one, the
   disagreement report shows both.
2. **Auth** — unauthenticated request to an output returns nothing; a
   `reviewer`-role session cannot reach admin outputs even with a forged input
   value; session expires on timeout.
3. **Attribution** — decisions carry the authenticated username, and no UI path
   lets a reviewer write a different name.
4. **Export/apply round-trip** — export from Postgres, run `apply.R --write`
   locally, confirm the alias tables gain `source: manual` on accepted rows and
   that a second run is a no-op.
5. **No secrets in git** — `git log -p` over the branch shows no connection
   string, hash, or key; `git check-ignore -v` confirms the reviewer-auth paths.

## Sequencing

1. Postgres schema + `store.R` rewrite, with the CSV export path (unblocks
   everything, testable locally against a local Postgres).
2. Auth + remove the free-text reviewer input.
3. Admin panel and metrics.
4. Deploy, then the concurrency and auth tests above.
