# Curation app → sponsor-only, multi-user, wired to normalisation v2

## Context

`curation_app/` was built for the **v1** pipelines: ten tiers across two domains,
each reading a different file shape out of `config/sponsor_norm_pipeline/` and
`config/substance_norm_pipeline/`. That is where its complexity comes from — the
`TIERS` registry, the per-tier loaders, the `evidence`/`extra_fields`/`queue`
specs, the `alias_home()` source→file map.

Sponsor normalisation has since been rewritten
([`normalisation-v2-handover.md`](normalisation-v2-handover.md)) and **v2 has one
shape**: a raw string, a proposed canonical, a confidence. Substances are a
second stage and are simply removed here.

So `curation_app/` is **deleted and rebuilt from scratch**, not patched. Nine of
the ten tiers would go and the tenth is a different data model; keeping the
abstraction would mean 641 lines of `tiers.R` dispatching to a single loader.

Nothing constrains the new design, because **the app has never been run**:
`config/review_ledger/` has never existed and nothing in git history has ever
touched it. There is no ledger to migrate, no schema to stay compatible with, and
no decision to preserve. The old code is committed, so git history keeps it if
the substance reviewer later wants to start from it.

### Decision: decisions reach the dashboard on the nightly rebuild

The dashboard has a second, older path for the same data — a display overlay
(`app.R:786-881`) that reads the CSV ledger on every load, so a decision shows up
without waiting for a cache rebuild. With decisions in Postgres that ledger never
appears, and **the nightly rebuild is the agreed path** (§3). Same-day visibility
is not wanted.

**`app.R` is not touched.** `read_human_sponsor_decisions()` returns `NULL` on a
missing file (`app.R:811`), so the overlay is already a no-op and costs nothing.
Ripping it out is not free: `sponsor_label` is read at ~60 call sites and the
overlay is welded into `attach_sponsor_labels()`, which produces it. Editing that
function for a cosmetic cleanup risks the sponsor filter, the Top Sponsors chart
and every export, for no behavioural gain. Left in place it is also a working
fallback if a ledger CSV is ever dropped in by hand.

There is also a hole to fill: **`registry.R` has the whole `decided_by = "human"`
pinning contract on the read side and no writer.** Verified — `decided_by` is
`"model"` on 100% of both `registry.csv` (7,238 rows) and `assignments.csv`
(16,594 rows). Without a writer, review is decorative: the queue re-proposes the
same 2,130 rows forever.

Three things are wanted, and the plan is organised around them:

1. a multi-user app with an admin panel,
2. a way to pull the current to-curate list from GitHub,
3. a way to get decisions back into `rebuild_cache.R`.

---

## The shape

```text
curation_app/
  app.R        login, the review screen, the admin panel
  R/github.R   fetch the queue + registry from GitHub by SHA
  R/store.R    Postgres: append_decision / latest_decisions / metrics
  R/review.R   the review screen module
  R/admin.R    the admin panel
  export.R     decisions → config/sponsor_norm_v2/{assignments,registry}.csv
```

`git rm -r curation_app/` first: `app.R` (236), `apply.R` (242), `R/tiers.R`
(641), `R/review_card.R` (476), `R/store.R` (134), `README.md` — 1,895 lines out,
and with them the tier registry, every substance loader,
`load_sponsor_fragments`, `impact_table`/`load_normaliser`, `alias_index`,
`alias_home`, `sibling_aliases`, the sibling-detach path, `write_queue_decision`,
and the audit-sampling/Wilson-CI machinery. That last one was v1's defence for
skipping ~18,000 rows; the v2 queue is 2,130 rows and reviewable in full, so
there is no tail to put an error bar on.

Three ideas are worth carrying across from the old app, and are the only things
worth reading it for:

- **the trial-references panel** — what actually settles an ambiguous name, since
  `UCL` on four `-GB` trials is University College London and not the Belgian
  one. `trial_url()` / `is_ctis_id()` (old `tiers.R:554-564`) are ~10 lines and
  can be lifted verbatim from git history;
- **a server-side selectize** over the canonicals — 6,954 names cannot ship to
  the browser as static choices;
- **append-only decisions**, latest-per-row winning, so changing your mind writes
  a second row rather than editing history.

---

## 1. Multi-user app + admin panel

**Supabase** (hosted Postgres, free tier), `shinymanager` for login. New
dependencies `shinymanager`, `DBI`, `RPostgres`, `sodium` — approved under
`AGENTS/AGENTS.md:11`. Connection string from `.Renviron` / Posit Cloud env vars,
never a file in the repo (`.Renviron` and `curation_app/secrets/` are already
gitignored).

Two tables. No `app_state` table — the multiuser plan wanted one to broadcast a
refresh across processes, but a re-press of the admin button costs nothing and
saves a table plus a polling timer.

```sql
CREATE TABLE reviewers (
  username      TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  password_hash TEXT NOT NULL,          -- bcrypt
  role          TEXT NOT NULL DEFAULT 'reviewer',   -- 'reviewer' | 'admin'
  active        BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE decisions (
  decision_id     BIGSERIAL PRIMARY KEY,
  decided_at_utc  TIMESTAMPTZ NOT NULL DEFAULT now(),
  reviewer        TEXT NOT NULL REFERENCES reviewers(username),
  raw_sponsor     TEXT NOT NULL,        -- the key; = assignments.raw_sponsor
  entity_id       TEXT,                 -- entity shown at decision time
  proposed        TEXT,
  final_value     TEXT,
  action          TEXT NOT NULL CHECK (action IN ('accept','edit','reject','skip')),
  entity_type     TEXT,                 -- only when a new canonical is created
  comment         TEXT,
  config_sha      TEXT                  -- snapshot the reviewer was looking at
);
CREATE INDEX ON decisions (raw_sponsor);
```

Append-only; latest per `raw_sponsor` wins:

```sql
SELECT DISTINCT ON (raw_sponsor) * FROM decisions
ORDER BY raw_sponsor, decided_at_utc DESC;
```

Identity comes **only** from the authenticated session — the free-text
`reviewer` box (`app.R:67`) is deleted, since with several users it is an
attribution hole. Accounts are seeded by SQL; one admin. 60-minute idle timeout.

**Admin panel**, gated on `role == 'admin'` **server-side** (hiding the nav panel
is not access control):

- per-reviewer counts — decided / accepted / edited / rejected / new canonicals;
- **disagreement list** — rows where two reviewers reached different
  `final_value`. This is the whole safety net for last-write-wins, so it is not
  optional;
- download the decisions table as CSV;
- the snapshot's ref + short SHA + fetch time, and a **Refresh from GitHub**
  button.

## 2. Pulling the to-curate list from GitHub

The v2 pipeline is committed (`2892596`, `a00c6b2`) and pushed to
**`origin/normalisation-v2`** — not `main`, which still carries the v1
`sponsor_curation/` tree. Verified end to end against the public repo
`rmvpaeme/shiny_trials`: the API resolves the ref to a SHA and every file returns
HTTP 200 at the local byte size, unauthenticated.

| fetched | size | why |
| --- | ---: | --- |
| `config/sponsor_norm_v2/E_review_queue.csv` | 274 K | the to-curate list |
| `config/sponsor_norm_v2/registry.csv` | 938 K | canonical dropdown (6,954 live) |
| `config/sponsor_norm_v2/assignments.csv` | 2.4 M | siblings on the same entity |
| `data/trial_sponsors_raw.csv` | 2.8 M | trial-reference links |

~6.4 MB, and that is the whole dependency list. Nothing the reviewer shows is
gitignored — v1's impact numbers came from the gitignored
`data/sponsor_normalisation_log.csv`, whereas v2's `n_trials` is a column of the
queue itself.

`R/github.R`:

- `resolve_sha(repo, ref)` — `GET https://api.github.com/repos/{repo}/commits/{ref}`,
  take `.sha`. `GITHUB_PAT` honoured if set, purely for rate-limit headroom
  (unauthenticated is 60/hour, ample).
- `fetch_snapshot(sha)` — download the four files **by resolved SHA, never by
  ref**, into a fresh temp dir, and swap the pointer only once every file has
  landed. A push mid-fetch would otherwise give a snapshot that is half one
  commit and half another. Returns `list(dir, sha, fetched_at, degraded)`.

Ref from `SNAPSHOT_REF`, defaulting to `normalisation-v2` — one env var to change
when it merges to `main`. Repo from `SNAPSHOT_REPO`.

**Only data is fetched, never code.** The app runs the R it was deployed with;
sourcing R from a branch at runtime is a code-execution path, not a refresh.

Fetch on startup and on the admin button. If GitHub is unreachable, keep the last
good snapshot (or the bundled copy at first start) and show a persistent banner
naming the SHA — a GitHub outage should make the backlog stale and say so, not
take the reviewer offline.

Every decision records the snapshot SHA in `config_sha`, which is what makes a
decision auditable when the branch moves under a long session.

## 3. Getting decisions into `rebuild_cache.R`

`rebuild_cache.R:46-52` already runs `E_emit.R`, and `rebuild_cache.R:79-86`
already joins `data/trial_sponsor_labels.csv` into the cache. So the only missing
link is turning decisions into pins *before* that runs.

`curation_app/export.R` — a plain Rscript, so it can `source()`
`helper_scripts/llm_norm/registry.R` directly and reuse `registry_add()`,
`registry_write()`, `assignments_write()` and `resolve_entity()` rather than
reimplementing them. Reads the latest decision per `raw_sponsor` from Postgres:

| action | effect on `config/sponsor_norm_v2/` |
| --- | --- |
| `accept` | `assignments[raw]`: `decided_by = "human"`, `confidence = 1`, `channel = "review"`; `entity_id` resolved through any merge chain |
| `edit`, canonical exists | as accept, plus `entity_id` repointed to that canonical's live entity |
| `edit`, canonical is new | `registry_add(canonical, entity_type, decided_by = "human")`, then point the assignment at the new id |
| `reject` | `entity_id = NA`, `decided_by = "human"` — resolves to nothing |
| `skip` | ignored |

Canonical → `entity_id` is unambiguous: all 6,954 live canonicals are unique
(verified).

Then one line in `rebuild_cache.R`, immediately before the sponsor block:

```r
# Human curation outranks the model. Pins land in assignments.csv before
# E_emit.R reads it; without a database connection this is a no-op.
system2(rscript_bin(), c(file.path("curation_app", "export.R"), "--write"))
```

`export.R` exits 0 with a message when the connection string is unset, so a
rebuild on a machine without database access behaves exactly as it does today.

Once pinned, `route_for_review()` drops those rows from the queue on the next
`E_emit.R` (`registry.R:315`), so the backlog shrinks by construction and the
GitHub refresh picks it up as soon as the regenerated queue is pushed.

**Properties to hold:** `--write` is idempotent (a second run is a byte-identical
no-op), and it backs both CSVs up to `config/sponsor_norm_v2/backups/<utc>/`
first — they are the product of $10.31 of paid API calls and this is the first
thing that has ever mutated them.

---

## Verification

1. Two browser sessions, two accounts, decide the same row — both rows land,
   latest-per-`raw_sponsor` returns one, the disagreement list shows both.
2. A `reviewer`-role session cannot reach admin outputs even with a forged input
   value; the session expires on timeout; no UI path writes a different username.
3. Refresh: push a change to `E_review_queue.csv` on the ref, press Refresh,
   confirm the row appears and the header SHA matches `git rev-parse --short`.
4. Snapshot atomicity: resolve a SHA, push mid-fetch, confirm every file came
   from the first SHA.
5. Degraded mode: block `raw.githubusercontent.com`, restart, confirm the app
   serves the last snapshot with the banner up rather than erroring.
6. Round trip: accept / edit-to-existing / edit-to-new / reject one row each,
   run `export.R --write`, confirm four `decided_by = "human"` rows in
   `assignments.csv`, one new human entity in `registry.csv`, and that a second
   `--write` is byte-identical.
7. `Rscript rebuild_cache.R` — the labels reflect all four decisions and the
   regenerated queue is 2,126 rows.
8. **`E_emit.R --diff-only` after a reject.** A human reject yields
   `match_status = "unknown"` (`E_emit.R:92-96`), so it registers as
   `REGRESSION: -> unknown` for every trial carrying that string. Confirm the
   count equals exactly the rejected strings' `n_trials`. The gate now means
   "zero regressions not attributable to a human reject" — worth recording in the
   handover, because a gate whose meaning has silently shifted is the failure
   mode that document keeps warning about.
9. `git log -p` over the branch shows no connection string or hash; `grep -ri
   substance curation_app/` returns nothing.

## Sequencing

1. `git rm -r curation_app/` — one commit, so the diff for everything after it
   reads as new code rather than a 1,900-line rewrite.
2. `R/github.R` + the snapshot. Independent of the database and testable
   immediately against the live repo, so it de-risks the rest.
3. Provision Supabase, apply the schema, seed accounts. `R/store.R`.
4. `R/review.R` + `app.R` — the review screen against the snapshot, still
   unauthenticated. Reviewable end to end at this point.
5. `shinymanager` login, then `R/admin.R`.
6. `export.R`, then the one line in `rebuild_cache.R`. `README.md`.
7. Verification 1-9.

## Out of scope

- **Substances** — second stage. Only `curation_app`'s substance code goes; the
  substance config and pipeline are untouched, and git history holds the v1
  reviewer if a v2 substance version wants to start from it.
- **Reviewing pass D's merges** (`D_consolidate_merges.csv`, 764 rows including
  the one the mis-index guard held back, handover §3.7) and **the 18,105 changed
  labels** (§9a item 4). Neither is reachable from the queue, since both sit
  above the confidence threshold that routes rows into it. Worth a tier later;
  the queue screen generalises to them.
- **`normalisation-reviewer-multiuser.md` needs a revision pass** once this
  lands: its §2 fetch list is entirely v1 and substance files, and its §6
  pipeline diagram assumes v1's ~15-minute index rebuild, which v2 does not have
  — `E_emit.R` is offline and takes seconds, so that plan's argument for a
  weekly batched cadence no longer holds.
