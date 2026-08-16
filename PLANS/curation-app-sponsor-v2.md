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

### Which ref — and why it is not `normalisation-v2`

[`nightly-sponsor-resolution-handover.md`](nightly-sponsor-resolution-handover.md)
changes the answer. `N_nightly_resolve.R` resolves sponsor strings the registry
has never seen, on every nightly run, and writes its state to `$SPONSOR_V2_DIR`
— which §5.3 there requires to be **outside the git work tree**, because
`nightly_deploy_posit.sh` runs `git reset --hard "$REMOTE/$SOURCE_BRANCH"` at the
start of every run and would otherwise discard it.

So `config/sponsor_norm_v2/E_review_queue.csv` on `normalisation-v2` is frozen at
the last hand-made commit. Point the app at it and the backlog silently stops
growing: every low-confidence string the nightly discovers is invisible to
reviewers, which is precisely the re-accumulation that handover §1 exists to
prevent.

The nightly already publishes generated artifacts — `nightly_deploy_posit.sh`
commits `GENERATED_FILES` to the **`deploy`** branch and pushes. Add the three
state files to that array and `deploy` becomes the branch that always carries the
current backlog. `SNAPSHOT_REF` therefore defaults to **`deploy`**, with
`SNAPSHOT_REPO` alongside it.

This also answers the first half of handover §6 gap 1 ("state promotion back into
git is deliberately undesigned"): promotion is the commit that already happens,
extended by three filenames.

**Only data is fetched, never code.** The app runs the R it was deployed with;
sourcing R from a branch at runtime is a code-execution path, not a refresh.

Fetch on startup and on the admin button. If GitHub is unreachable, keep the last
good snapshot (or the bundled copy at first start) and show a persistent banner
naming the SHA — a GitHub outage should make the backlog stale and say so, not
take the reviewer offline.

Every decision records the snapshot SHA in `config_sha`, which is what makes a
decision auditable when the branch moves under a long session.

## 3. Getting decisions into `rebuild_cache.R`

`rebuild_cache.R` now runs a four-step sponsor sequence — `1_export` →
`N_nightly_resolve` → `E_emit --diff-only --assert-no-regressions` (the gate) →
`E_emit` (the write). Curation slots in as a fifth step **after
`N_nightly_resolve` and before the gate**: the nightly assigns newly-seen strings
first, then human pins overwrite whatever it decided, then the gate sees the
final state.

`curation_app/export.R` — a plain Rscript, so it can `source()`
`helper_scripts/llm_norm/registry.R` directly and reuse `registry_add()`,
`registry_write()`, `assignments_write()` and `resolve_entity()` rather than
reimplementing them.

**It must honour `SPONSOR_V2_DIR`**, exactly as `B_mint`, `C_assign`,
`D_consolidate`, `E_emit` and `N_nightly_resolve` already do
(`Sys.getenv("SPONSOR_V2_DIR", unset = pp("config", "sponsor_norm_v2"))`).
Writing to `config/sponsor_norm_v2/` unconditionally would put human decisions in
a directory the nightly neither reads nor preserves — they would be discarded by
the next `git reset --hard` and never reach a label. With the override honoured
there is exactly **one live state directory** that both writers touch and
`E_emit` reads, so nothing diverges. That is the second half of handover §6
gap 1.

Reads the latest decision per `raw_sponsor` from Postgres:

| action | effect on `config/sponsor_norm_v2/` |
| --- | --- |
| `accept` | `assignments[raw]`: `decided_by = "human"`, `confidence = 1`, `channel = "review"`; `entity_id` resolved through any merge chain |
| `edit`, canonical exists | as accept, plus `entity_id` repointed to that canonical's live entity |
| `edit`, canonical is new | `registry_add(canonical, entity_type, decided_by = "human")`, then point the assignment at the new id |
| `reject` | `entity_id = NA`, `decided_by = "human"` — resolves to nothing |
| `skip` | ignored |

Canonical → `entity_id` is unambiguous: all 6,954 live canonicals are unique
(verified).

Then one `run_step()` in `rebuild_cache.R`, between `N_nightly_resolve` and the
`E_emit` gate, reusing the helper that block already uses:

```r
# Human curation outranks the model. Pins land in assignments.csv before the
# gate reads it. Exits 0 with a message when no connection string is set, so a
# rebuild without database access behaves exactly as it does today.
run_step(file.path("curation_app", "export.R"), "--write", label = "curation export")
```

Note it must **not** be allowed to abort the sequence: the governing rule in that
block is that a sponsor hiccup never costs the data refresh. Report through the
same sentinel the nightly uses rather than a non-zero exit.

### The regression gate must not treat a human reject as a regression

**This would otherwise freeze sponsor labels indefinitely, silently.** A `reject`
sets `entity_id = NA`, so `sponsor_clean` is NA and `match_status` becomes
`"unknown"` (`E_emit.R:92-96`) — which `E_emit.R:128-133` classifies as
`REGRESSION: -> unknown`, and `--assert-no-regressions` (`E_emit.R:152`) then
stops. `rebuild_cache.R` branches on that by **keeping the previous labels and
not writing new ones**. So one reviewer rejecting one string would stop sponsor
labels updating on every subsequent night, reported as "regression gate failed",
which reads as a pipeline fault rather than a curation decision.

The fix is in the classifier, not the app: a row whose assignment is
`decided_by = "human"` is not a regression when it goes to unknown — a human
saying "this is not a sponsor" is the intended outcome. Add that guard to the
`case_when` and report those rows on their own line (`human unassign`) so they
stay visible rather than merging into `unchanged`.

This is the same class of defect the v2 handover §3.0a records twice — a gate
that stops measuring, and a run that writes zero rows while printing success.
Worth fixing before the first reject exists, not after.

Once pinned, `route_for_review()` drops those rows from the queue on the next
`E_emit.R` (`registry.R:315`), so the backlog shrinks by construction and the
GitHub refresh picks it up as soon as the regenerated queue is pushed.

**Properties to hold:** `--write` is idempotent — a second run is a
byte-identical no-op. This is load-bearing, not hygiene: `export.R` now runs
unattended every night, and handover §2.1 records a bug where re-running
`C_assign` silently resurrected 284 merged-away entities and re-pointed 527
assignments, undoing every `D_consolidate --apply` with no error. Extend
`tests/sponsor_v2_idempotence.R` — which already exists as the fixture for
exactly that failure — rather than writing a new test.

It also backs both CSVs up to `<SPONSOR_V2_DIR>/backups/<utc>/` before writing:
they are the product of $10.31 of paid API calls, and once state lives outside
the work tree git is no longer an undo.

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
8. **The reject case, end to end.** Reject a string, then run
   `E_emit.R --diff-only --assert-no-regressions` — it must **exit 0**, with the
   rejected string's trials reported as `human unassign` rather than
   `REGRESSION: -> unknown`. Then a full `rebuild_cache.R` must actually write
   `data/trial_sponsor_labels.csv` rather than logging "SPONSOR LABELS NOT
   WRITTEN". Run this against a scratch `SPONSOR_V2_DIR`, the way the nightly
   handover §4 recommends for its own first live run.
9. **`SPONSOR_V2_DIR` is honoured.** With it pointed at a scratch copy,
   `export.R --write` must leave the real `config/sponsor_norm_v2/` byte-identical
   — the same check the nightly handover ran and recorded.
10. **The published queue is the live one.** After a nightly run that resolves a
    new string, confirm the queue on `deploy` contains it and the app shows it
    after a Refresh, with no redeploy.
11. `git log -p` over the branch shows no connection string or hash; `grep -ri
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
6. The `E_emit` classifier fix (human unassign). Independent of everything above
   and worth landing early — the gate is live in `rebuild_cache.R` today, so this
   is the one change that must precede the first reject.
7. `export.R` with `SPONSOR_V2_DIR`, the `run_step()` call in `rebuild_cache.R`,
   the three filenames in `GENERATED_FILES`. `README.md`.
8. Verification 1-11.

## Out of scope

- **Substances** — second stage. Only `curation_app`'s substance code goes; the
  substance config and pipeline are untouched, and git history holds the v1
  reviewer if a v2 substance version wants to start from it.
- **Reviewing pass D's merges** (`D_consolidate_merges.csv`, 764 rows including
  the one the mis-index guard held back, handover §3.7) and **the 18,105 changed
  labels** (§9a item 4). Neither is reachable from the queue, since both sit
  above the confidence threshold that routes rows into it. Worth a tier later;
  the queue screen generalises to them.
- **`N_new_entities.csv` — flagged, not designed.** The nightly deliberately never
  runs `D_consolidate` (a wrong merge is its most expensive error), so every new
  canonical it mints is parked in that file "for a periodic human run"
  (nightly handover §3). **Nothing else consumes it**, and the curation app is
  the only plausible reader. It is a different question from the queue's — *is
  this new canonical real, or a duplicate of an existing entity?* — so it wants
  its own small screen rather than a column on this one. Left out to keep this
  stage to the three bullets, but it should not stay unowned: without it, nightly
  registry growth accumulates unreviewed, which is the same drift in canonical
  form that motivated the v2 rewrite.
- **`normalisation-reviewer-multiuser.md` needs a revision pass** once this
  lands: its §2 fetch list is entirely v1 and substance files, and its §6
  pipeline diagram assumes v1's ~15-minute index rebuild, which v2 does not have
  — `E_emit.R` is offline and takes seconds, so that plan's argument for a
  weekly batched cadence no longer holds.
