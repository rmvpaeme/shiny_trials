# Reviewer app — multi-user deployment on Posit Cloud

## Context

The reviewer app built in `curation_app/` assumes a single reviewer on a laptop:
it reads the config CSVs directly and appends decisions to a CSV ledger guarded
by `filelock`. The app is now to be deployed to Posit Cloud for several users,
with a login screen, an admin view of what each user changed, and metrics.

That breaks four assumptions at once, and the storage one is not a detail:

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
4. **The backlog is baked into the bundle too.** The tier loaders read the config
   CSVs shipped inside the deployed image, so the app cannot see a decision that
   has already been applied until someone redeploys it. The same read-only
   filesystem also kills `write_queue_decision()` (`R/store.R:118`), which stamps
   queue decisions into the queue CSV — and that CSV is exactly what
   `curate_*.R --export` reads. Left alone, the queue tiers have no path to
   production at all.

So the deployment is not "add a login screen to the existing app". It is
**move the decision store off the filesystem and the backlog off the bundle**,
then add identity and an admin view on top. The tier loaders and the `apply.R`
replay logic survive unchanged; `R/store.R` is substantially rewritten,
`R/review_card.R` takes its root as a reactive rather than a constant, and a new
`R/snapshot.R` fetches the config from `main`.

## Decisions taken

Nothing below is left open. Each of these was a genuine fork, and the reasoning
is in the section named.

| Decision | Choice | Where |
|---|---|---|
| Decision store | **Supabase** (hosted Postgres, free tier) | §1 |
| Queue source | Fetched from `main` on GitHub at runtime | §2 |
| Queue refresh | Process start, plus an admin button | §2, §4 |
| Config provenance | Always `main` HEAD; each decision records the SHA | §1, §2 |
| The two gitignored `*_normalisation_log.csv` | Stay in the deploy bundle | §2 |
| Login | **`shinymanager`**, 60-minute idle timeout | §3 |
| Reviewer accounts | Seeded by SQL; one admin (you) | §3 |
| New packages | `shinymanager`, `DBI`, `RPostgres`, `sodium` — approved | §3 |
| Queue-tier decisions | Stamped into the queue CSVs by `export_decisions.R` | §6 |
| Conflicting decisions | Last-write-wins, surfaced by the disagreement report | §6 |
| Apply cadence | Weekly, on a fixed slot | §6 |

Two rejected options are worth recording, because they will come up again.
**Google Sheets** as the store is free and hand-inspectable but has no locking and
still races on read-modify-write — it would need an append-only discipline that
nothing enforces. **Posit Cloud persistent storage** was ruled out rather than
investigated; if it turns out a writable shared volume exists, §1 gets
considerably smaller, so it is worth a look before building.

The store choice touches `store.R` and where the `app_state` marker lives. It does
**not** touch §2 — the queue source is independent of the decision store.

---

## 1. Storage — rewrite `R/store.R`

**Supabase**, free tier — ample for a 6,431-row backlog, and its table browser
matters more than it sounds: auditing reviewer decisions means reading the ledger
by hand, and a store you cannot inspect without writing a query is a store nobody
audits. Connection string via `.Renviron`, already gitignored.

Same public surface — `append_decision()`, `read_ledger()`,
`latest_decisions()` — so `apply.R` does not change at all, and `review_card.R`
changes only for the reasons §2 gives, not because the store moved.

Two tables, plus a one-row marker added at the end of this section:

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
  config_sha            TEXT,            -- main commit the row was reviewed against
  decision_ms           INTEGER          -- time on the card, for throughput metrics
);

CREATE INDEX ON review_decisions (tier, row_key);
CREATE INDEX ON review_decisions (reviewer);
```

`config_sha` complements `input_hash` rather than duplicating it. `input_hash`
says *this row's content changed since the decision*; `config_sha` says *which
published state the reviewer was looking at*. With `main` moving underneath a
long-lived session (§2), that is the difference between an auditable decision and
a guess.

A third, one-row table carries the refresh signal between app processes. The
rationale is in §4 — a refresh button that only reaches the process serving the
admin is a button that appears not to work.

```sql
CREATE TABLE app_state (
  id                   BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  refresh_requested_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
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

## 2. Queue source — reading config from `main`

The decisions move to Postgres; the **backlog** moves to GitHub. The app fetches
its config from the `main` branch at runtime instead of reading the copies baked
into its bundle.

`main` is already the gate — §6 step ④ is where applied decisions are committed —
so this makes "what the reviewer shows" and "what has been applied" the same thing
by construction. It also deletes an entire step from that pipeline: there is no
longer a redeploy whose only job is to refresh the backlog.

The repo is public (`https://github.com/rmvpaeme/shiny_trials`), so this needs no
credentials. `GITHUB_PAT` is honoured if set, purely for rate-limit headroom.

### The snapshot

A *snapshot* is a directory under `tempdir()` that looks exactly like the project
root to the tier loaders: `<dir>/config/…` fetched from `main`, `<dir>/data/…` a
mix of fetched and bundled files. That shape is the whole trick — `cfg_path()` and
`data_path()` (`R/tiers.R:32-33`) already take `root` as their first argument, so
the loaders need no changes and no new path plumbing.

New file `R/snapshot.R`:

- `resolve_head_sha()` — `GET https://api.github.com/repos/{repo}/commits/main`,
  take `.sha`. Unauthenticated is 60 requests/hour per IP, ample for one call at
  start plus an occasional button press.
- `build_snapshot(bundle_root, sha)` — fetch each file below from
  `https://raw.githubusercontent.com/{repo}/{sha}/{path}`, copy the bundled ones,
  assemble in a fresh directory, and swap the active pointer only once every file
  has arrived. Returns `list(root=, sha=, fetched_at=, degraded=)`.

Fetch by **resolved SHA, never by `main`**. A push landing mid-fetch would
otherwise produce a snapshot that is half one commit and half another — the kind
of inconsistency that surfaces as an alias index disagreeing with the queue it is
supposed to describe.

### What is fetched, and what is not

Only the files a tier loader, `canonical_pool()`, `alias_index()` or `raw_pairs()`
actually opens — about 15 MB, not the whole repo:

| From `main` | Size |
|---|---:|
| `config/sponsor_norm_pipeline/sponsor_review_queue.csv` | 14 K |
| `config/sponsor_norm_pipeline/manual_sponsor_aliases.csv` | 157 K |
| `config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv` | 1.2 M |
| `config/sponsor_norm_pipeline/sponsor_alias_index.csv` | 1.4 M |
| `config/substance_norm_pipeline/substance_review_queue.csv` | 121 K |
| `config/substance_norm_pipeline/manual_brand_to_substance.csv` | 94 K |
| `config/substance_norm_pipeline/canonical_substances.csv` | 16 K |
| `config/substance_norm_pipeline/substance_alias_index.csv` | 6.0 M |
| `data/trial_sponsors_raw.csv` | 2.6 M |
| `data/trial_substances_raw.csv` | 3.7 M |

Two files **cannot** come from `main`: `data/sponsor_normalisation_log.csv` and
`data/substance_normalisation_log.csv` match `data/*log*` in `.gitignore` and are
untracked. They ship in the bundle and are copied into each snapshot.

That is the one asymmetry this design leaves behind, and it is not cosmetic: those
logs drive the entire **Fuzzy singletons** tier (1,879 rows, the largest) and the
impact ordering of both alias tiers. Queue and alias *contents* track `main`
continuously; fuzzy singletons and impact ranking still refresh only on redeploy.

### Refresh

On process start, and on demand from the admin panel (§4). Not per session — 15 MB
per login is wasteful, and two reviewers logging in minutes apart would see
different backlogs.

`ROOT` and `POOLS` (`app.R:33-38`) stop being file-scope constants. The snapshot
becomes a `reactiveVal` at app scope, shared by every session in the process, and
the canonical pools derive from it. `review_card_server()` takes `snapshot` in
place of `root`, and its one-shot `observeEvent(TRUE, once = TRUE, …)`
(`R/review_card.R:92`) becomes `observeEvent(snapshot(), …)` so a refresh reaches
open sessions. Reset the cursor on refresh — the old position indexes a list that
no longer exists.

**Clear the tier caches.** `.alias_index_cache` and `.raw_pairs_cache`
(`R/tiers.R:233`, `R/tiers.R:264`) are keyed on domain alone and never expire, so
a refresh that ignores them serves siblings and trial references from the previous
snapshot. Add `clear_tier_caches()` to `tiers.R` and call it from
`build_snapshot()`, rather than reaching into those environments from another file.

### Provenance

Every decision records the snapshot's SHA in `config_sha` (§1) — on the main
decision path (`R/review_card.R:363-379`) and on the sibling-detach path
(`R/review_card.R:266`), which is easy to miss because it builds its ledger row
separately. `LEDGER_FIELDS` (`R/store.R:11`) gains the field.

### Degrading, not failing

If GitHub is unreachable, fall back to the bundled config with `degraded = TRUE`
and a persistent banner naming the bundle's commit. A GitHub outage must not take
the reviewer offline; it should only make the backlog stale and say so.

### Consequence for queue tiers

`write_queue_decision()` is deleted, both its call site
(`R/review_card.R:385-396`) and the function in `R/store.R`. The snapshot is a
temp directory, so a write there would be discarded on the next refresh. §6 step ①
gives those decisions their real path, at the point where the file is writable.

## 3. Login

**`shinymanager`** — purpose-built, and it handles the session cookie, the
timeout, and the password-change flow rather than leaving them to be written
here. It stores credentials in an encrypted SQLite file by default; point it at
the Postgres `reviewers` table instead.

The hand-rolled alternative (~150 lines: `bcrypt` via `sodium`, a session token in
`session$userData`, `req(authenticated())` on every output) was considered and
rejected. It saves one dependency and costs you ownership of an auth
implementation, which is the wrong trade.

- Passwords hashed with bcrypt. Never stored, logged, or emailed in plaintext.
- The reviewer identity comes **only** from the authenticated session. Delete the
  free-text `reviewer` input from the header — with several users it is an
  attribution hole, since anyone can type anyone else's name.
- Gate the admin panel on `role == 'admin'` **server-side**. Hiding the nav
  panel client-side is not access control; the outputs must refuse to render.
- **60-minute idle timeout**, extended by activity. Long enough that nobody is
  logged out mid-card while reading the trial-reference panel on a hard row —
  which is exactly when they should be taking their time — and short enough that
  a forgotten tab expires within the working day.

### Accounts

Seeded by SQL, not by a UI. A short local script inserts each reviewer into
`reviewers` with a bcrypt hash and a role; you are the only `admin`. With a
handful of known reviewers an account-management screen is dead weight, and it
would be a privileged write path to secure for no benefit.

Two consequences to keep in view: password resets are a manual `UPDATE`, and
removing a reviewer means `active = FALSE` rather than a `DELETE`, since
`review_decisions.reviewer` references the row and their decisions must survive
them.

### Dependencies

`shinymanager`, `DBI`, `RPostgres`, `sodium` — approved under
`AGENTS/AGENTS.md:11`. §2 adds none: `utils::download.file()` and `jsonlite`
(already a dependency) cover the whole snapshot path.

## 4. Admin panel

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

**Config snapshot** — the short SHA the app is currently serving, its commit date,
the degraded banner if §2's fallback is active, and a **Refresh from `main`**
button.

The button writes `app_state.refresh_requested_at` rather than re-snapshotting in
place. Posit Cloud may run several R processes behind one URL, so a button that
refreshes only the process serving the admin is a button that appears not to work.
Each process compares its snapshot's `fetched_at` against that timestamp on every
new session and on a slow `reactiveTimer` (~2 min), re-snapshotting when it is
behind — one scalar read on a connection that is already open.

## 5. Deployment

- **Separate Posit Cloud app** from the public dashboard. Different bundle,
  different URL, different access list. Do not add `curation_app/` to the
  dashboard's `manifest.json` — that file is a deliberate 7-file allowlist.
- The app reads its config from `main` at runtime (§2) and writes only to
  Postgres. The bundle ships the app code plus the two untracked
  `data/*_normalisation_log.csv` files, and nothing else needs to be in it.
- Connection string and any keys come from environment variables set in the
  Posit Cloud UI, never from a file in the repo. `.Renviron`, `*.env`, `*.key`,
  `*.pem`, `curation_app/auth/`, `curation_app/secrets/` and the session/sqlite
  patterns are already gitignored (`.gitignore`, reviewer app block).
- **Outbound access to `api.github.com` and `raw.githubusercontent.com`** is a
  deployment requirement. Confirm it before going live. If either is blocked the
  app still starts, on bundled config and with the degraded banner up (§2), which
  is a stale reviewer rather than a broken one — but it is stale silently unless
  someone reads the banner.
- Redeploy is now only for **app code** and the two log files. A rebuilt index
  reaches reviewers as soon as it is on `main`; decisions are unaffected either
  way, since they live in the database.

## 6. From reviewer decisions to production

This is the part that has to be designed rather than assumed, because the
reviewer app and the dashboard are two separate deployments that share no
filesystem. Decisions live in Postgres; the dashboard reads `trials_cache.rds`
built from the config CSVs in git. Nothing connects those two automatically, and
nothing should — applying decisions rewrites tracked config files and changes
what every downstream number means.

### The pipeline

```
  Posit Cloud: reviewer app          (several users, writes only to Postgres)
        │
        │  decisions accumulate
        ▼
  Postgres review_decisions
        │
        │  ① export_decisions.R              (pull ledger → CSV, local)
        │     export_decisions.R --stamp-queues   (ledger → queue CSV columns)
        ▼
  config/review_ledger/review_decisions.csv
  config/*/*_review_queue.csv    (decision / canonical_* / comment filled)
        │
        │  ② curation_app/apply.R --write        alias tiers
        │     curate_sponsors.R --export         queue tiers
        │     curate_substances.R --export
        ▼
  config/*.csv   (manual_sponsor_aliases, negative_aliases, overrides …)
        │
        │  ③ build_sponsor_index.R --no-ror
        │     build_substance_index.R --use-chembl-cache
        ▼
  config/*_alias_index.csv
        │
        │  ④ git commit + review the diff
        ▼
  main branch
        │
        ├───────────────────────────►  reviewer app pulls on start, or on
        │                              admin refresh (§2) — decided rows
        │                              leave the backlog, no redeploy
        │
        │  ⑤ nightly_deploy_posit.sh  →  rebuild_cache.R  →  trials_cache.rds
        ▼
  Posit Cloud: dashboard app
```

The loop closes at `main`, which is the point. The reviewer's backlog is a
function of the branch, so nothing has to remember to refresh it.

### Step by step

**① Export** — new `helper_scripts/review/export_decisions.R`: connect to
Postgres, pull `latest_decisions()`, write `config/review_ledger/review_decisions.csv`
in exactly the shape `apply.R` already reads. Runs locally, needs the connection
string in `.Renviron`. Records the max `decision_id` exported so the next run
can report what is new.

Two more jobs, both consequences of §2:

- `--stamp-queues` — for each queue tier, read the **local working-copy** queue
  CSV and set `decision` (`accepted` / `rejected`), `canonical_sponsor` /
  `canonical_substance` and `comment` from the latest ledger row per `row_key`.
  Write back with the existing `write_csv_atomic()` + `detect_eol()`
  (`R/store.R:36`, `R/store.R:56`). This is exactly what the deleted
  `write_queue_decision()` used to do, moved to the one place where the file is
  actually writable. The two `curate_*.R --export` commands then run unchanged.
- Report the distinct `config_sha` values in the batch, and flag any that is not
  an ancestor of the current `HEAD` (`git merge-base --is-ancestor`). Those
  decisions were taken against config that has since been rewritten, and belong in
  front of a human at step ④ rather than in a silent replay.

**② Apply** — unchanged from the single-user design. `apply.R --write` for the
alias tiers, the two `curate_*.R --export` scripts for the queue tiers. Both are
idempotent, so a re-export that includes already-applied decisions is harmless.

**③ Rebuild indexes** — `--no-ror` on the sponsor side to match the committed
baseline; `--use-chembl-cache` on the substance side to avoid a network fetch.
~15 minutes, dominated by the sponsor DB tiers.

**④ Commit and review the diff** — the gate. Run the gold fixtures and diff
`data/trial_sponsor_labels.csv` before/after, the same checks used for the
provenance correction. A reviewer decision that moves 4,000 trials between
sponsors should be seen by a human before it ships, and this is where that
happens. Nothing here is automated.

**⑤ Dashboard** — no new machinery. `nightly_deploy_posit.sh` already resets
`deploy` to `main`, runs `rebuild_cache.R`, and pushes to trigger Posit Cloud.
Once step ④ is on `main`, the next nightly run carries the decisions into
`trials_cache.rds`. Note the script aborts on a dirty work tree, so step ④ must
be committed, not left in the working directory.

**The reviewer needs no step of its own.** It pulls from `main`, so step ④ is
what refreshes its backlog. An admin can press **Refresh from `main`** (§4) to
make that immediate rather than waiting for the next process start.

### Cadence

**Weekly, on a fixed slot.** Every cycle costs a ~15-minute index rebuild and a
human diff review whether it carries one decision or two hundred, so batching a
week costs the same as applying a single row. A fixed slot beats "when there is
enough to apply", because the rebuild is always something that can be done later
and a ledger left to accumulate is a ledger nobody replays. It also lets reviewers
know when their work lands.

Between cycles reviewers keep working, and re-deciding a row that was already
applied is harmless, because the ledger keys on `row_key` and the replay is
idempotent.

What *is* stale between cycles is narrower than before: queue and alias contents
track `main` continuously, so only the fuzzy-singletons tier and the impact
ordering lag, and those lag until a redeploy rather than until the next cycle.

### What deliberately stays manual

- **Applying decisions** — rewrites tracked config, must go through a commit.
- **Enabling the ROR tier** — a separate data decision, not a review outcome.
- **Creating canonicals** — allowed in the app but flagged
  (`created_new_canonical`); worth scanning in the admin panel each cycle before
  applying, since that is the field most able to fragment the canonical set.
- **Refreshing the fuzzy-singletons tier and the impact ordering** — they read
  `data/*_normalisation_log.csv`, which is gitignored and therefore not on `main`
  (§2). Those two shipped in the bundle and change only on redeploy. This is the
  one place where "the app tracks `main`" is not the whole truth, so it is written
  down here rather than left to be discovered.

### Conflict rule

**Last-write-wins**, unchanged from the single-user semantics: the latest decision
per `(tier, row_key)` wins on replay. Nothing blocks.

What makes that safe rather than merely cheap is that it is not silent. The
disagreement report (§4) lists every row where two reviewers reached different
`final_value`s, and step ④'s diff review is where an unresolved one stops the
cycle. The alternative rules — first-write-wins, or an admin queue that blocks
`export_decisions.R` until every conflict is resolved — buy a stronger guarantee
at the cost of stalling a weekly cycle on one disputed row, and neither is
reversible-in-place later the way this is.

The one property to preserve when implementing: a conflict must be *visible before
export*, not discovered afterwards in a diff. If the disagreement report is ever
dropped or left unread, this rule silently becomes "whoever clicked last was
right".

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
6. **Round trip from `main`** — commit a change to `sponsor_review_queue.csv` on
   `main`, press Refresh, confirm the row appears with no redeploy and the header
   SHA matches `git rev-parse --short main`.
7. **Snapshot atomicity** — resolve a SHA, push to `main` mid-fetch, confirm every
   fetched file came from the first SHA rather than a mixture.
8. **Cache invalidation** — change a canonical's siblings on `main`, refresh, and
   confirm the sibling panel and the trial references both update. This is the
   case most likely to fail silently, since a stale `.alias_index_cache` looks
   exactly like a correct one.
9. **Degraded mode** — block `raw.githubusercontent.com`, restart, confirm the app
   serves bundled config with the banner up rather than erroring.
10. **Cross-process refresh** — with ≥2 processes, press Refresh as an admin and
    confirm a session on the *other* process picks the new SHA up within the poll
    interval.
11. **Queue export** — decide a sponsor-queue row in the deployed app, run
    `export_decisions.R --stamp-queues`, confirm the queue CSV gains
    `decision=accepted` and `canonical_sponsor`, then that
    `curate_sponsors.R --export` writes the override and a second run is a no-op.
12. **Provenance** — `config_sha` is populated on every decision including the
    sibling-detach path, and the stale-SHA warning fires for a decision made
    against a since-rewritten commit.

## Sequencing

1. `R/snapshot.R` + the `app.R` wiring + `clear_tier_caches()`. First because it
   is independent of the store rewrite and testable today against the current
   CSV-backed store, so it de-risks the rest without waiting on Postgres.
2. Provision the Supabase project; connection string into `.Renviron`. Apply the
   schema (including `config_sha` and `app_state`), then rewrite `store.R` with
   the CSV export path. Testable against a local Postgres first — nothing here
   needs the hosted instance until deploy.
3. `review_card.R`: reactive root, `config_sha` on both decision paths, delete the
   `write_queue_decision()` call.
4. Auth: `shinymanager` against the `reviewers` table, 60-minute idle timeout,
   remove the free-text reviewer input. Seed the accounts by SQL.
5. Admin panel, metrics, the disagreement report, and the refresh control. The
   disagreement report is not optional — §6's conflict rule depends on it.
6. `export_decisions.R`, including `--stamp-queues`.
7. Deploy, then the tests above.
