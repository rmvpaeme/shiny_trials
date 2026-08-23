# Curation / reviewer app v2

> **Branch:** `feature/curation-app-v2`, off `main` at `1705edf`. All 17 commits below land there; nothing touches `main` directly.

**Line numbers are against the working tree at branch time, which carried an uncommitted v0.21.1** ("substance and sponsor filters match the raw register strings" — `app.R` +175/−68, plus `CHANGELOG.md`, `README.md`, both `rmarkdown/*.Rmd`, and untracked `data/substance_rejected.csv` / `data/substance_residue.csv`). Every `app.R` offset in Phases B, C and H assumes those changes are **kept**. If v0.21.1 is dropped or reordered instead, re-derive the offsets before editing — the affected anchors are the config block (~`:255`), `attach_sponsor_labels()` (~`:885`), `prepare_trial_data()`'s drop list (~`:2023`), `cache_is_valid()` (~`:2049`) and the two duplicated modals (`:3859` / `:4167`).

## Context

The v1 reviewer app in `LEGACY/curation_app/` is retired and **was never actually run** — `config/review_ledger/` has never existed. Its entire input surface (v1's alias→canonical CSVs) was replaced by the v2 entity-registry model, so patching it is not an option.

The gap it leaves is concrete and expensive. `helper_scripts/llm_norm/registry.R` implements the whole `decided_by = "human"` pinning contract **on the read side with no writer**:

- `registry.R:271-278` — human assignments are kept verbatim and never overwritten by a re-run
- `registry.R:307-337` — merges of human-decided entities are refused, not silently applied
- `registry.R:377` — `route_for_review()` excludes human rows, so a pinned row leaves the queue by construction

`decided_by` is `"model"` on 100% of `config/sponsor_norm_v2/registry.csv` (7,238 rows) and `assignments.csv` (16,594 rows); the substance side has 23 human rows, all from a hand-maintained `manual_overrides.csv`. Without a writer, review is decorative: the queue re-proposes the same 2,128 sponsor + 4,717 substance rows forever, and nothing corrects the ~40 other recoded fields at all.

**Outcome:** a multi-user app where reviewers validate individual trials and clear the normalisation backlog, every decision is attributed and timestamped, and the results reach the dashboard through the existing nightly.

---

## Decisions (settled — do not re-litigate)

| | |
|---|---|
| Hosting | Posit Cloud, read-only filesystem, separate bundle from the dashboard |
| Decision store | Hosted Postgres (Supabase free tier) |
| Data in | Fetched at process start from the **public repo, `deploy` branch, by resolved SHA** |
| Data out | `curation_app/export.R`, invoked by `rebuild_cache.R` on the server |
| Tab 1 | Trial validation — full browsable/filterable table, click a trial, edit fields |
| Tab 2 | Normalisation review — sponsor + substance queues |
| Tab 3 | Changes & statistics — visible to every reviewer |
| Admin | Fourth section, admin-only, gated **server-side** |
| Correction routing | **Split**: sponsor/substance → the v2 registries as `decided_by = "human"` (generalises to every trial with that raw string); everything else → a new per-trial override file |

---

## Architecture

```
Posit Cloud                     GitHub (public)              Server (rstudio-rstudio-1)
┌──────────────────┐            ┌──────────────┐             ┌──────────────────────┐
│  curation_app/   │──fetch────▶│ deploy branch│◀──push──────│ nightly_deploy_*.sh  │
│  4 tabs + auth   │  by SHA    │ cache+queues │             │  └ rebuild_cache.R   │
└────────┬─────────┘            │  +registries │             │      └ export.R ─────┼──┐
         │ decisions            └──────────────┘             └──────────────────────┘  │
         ▼                                                                             │
   ┌───────────┐                                                                       │
   │ Supabase  │◀──────────────────────read────────────────────────────────────────────┘
   └───────────┘
```

The loop closes overnight. The app never writes to the registries directly — there is no shared filesystem, and a second writer racing `N_nightly_resolve.R` would recreate the read-modify-write race the whole design exists to avoid.

---

## Phase A — blocking fixes (land before any writer exists)

### A1. A human unassignment is not a regression

**This is the single most important item in the plan.** Today a `reject` sets `entity_id = NA` → `sponsor_clean` NA → `match_status == "unknown"` → classified `"REGRESSION: -> unknown"` → `--assert-no-regressions` exits 1 → [rebuild_cache.R:96-99](rebuild_cache.R#L96-L99) keeps yesterday's labels **forever**, reported as a pipeline fault. One reviewer rejecting one string permanently freezes sponsor labels.

[helper_scripts/sponsor_norm_pipeline/E_emit.R](helper_scripts/sponsor_norm_pipeline/E_emit.R) — make `match_status` a real three-way (the first branch at ~`:112` is currently redundant with the second):

```r
match_status = case_when(
  !is.na(sponsor_clean)   ~ "accepted",
  decided_by %in% "human" ~ "human_unassigned",
  TRUE                    ~ "unknown"
),
```

then in the diff `case_when` (~`:148-153`), **ordered before** the `unknown` test:

```r
match_status == "human_unassigned" ~ "human unassign (intended)",
```

[helper_scripts/substance_norm_pipeline_v2/E_emit.R](helper_scripts/substance_norm_pipeline_v2/E_emit.R) gets the same treatment at `:130-134` and `:191-209`. That file already has the right instinct — `"dropped: v1 raw fallback (intended)"` at `:206` is this exact pattern for a different intended drop; generalise its `fallback_ids` grouping to also yield `human_ids`.

**Make it loud, not silent.** Once the class is no longer asserted on, a mistaken reject of a 400-trial sponsor would otherwise pass in total silence — precisely the "gate stops measuring" failure this file's own comments warn about twice. Add a count line to the summary and print the top raw strings by trial count, modelled on the substance file's existing sample block.

### A2. Sponsor `E_emit.R` ignores `DATA_DIR` (verified)

`RAW_PATH`, `OUT_PATH`, `LOG_PATH` and `BASE_PATH` at [E_emit.R:47-58](helper_scripts/sponsor_norm_pipeline/E_emit.R#L47-L58) use `pp("data", …)` unconditionally, while the substance twin reads `Sys.getenv("DATA_DIR", …)` at [substance E_emit.R:53](helper_scripts/substance_norm_pipeline_v2/E_emit.R#L53). **Any scratch-dir test of the sponsor gate therefore overwrites the real `data/trial_sponsor_labels.csv`.** Four lines, mirroring the substance file. Land it in the same commit as A1 — it blocks the verification for A1.

### A3. The repo nightly never reported a substance failure

[nightly_update/nightly_deploy_posit.sh:111](nightly_update/nightly_deploy_posit.sh#L111) tests `$SUBSTANCE_SENTINEL`, which is never assigned and never `rm -f`'d. `[ -f "" ]` is silently false. The local copy is correct at `:109-111`; the two have drifted again despite the header comment added to stop exactly that. Fix, then add `tests/nightly_scripts_agree.sh` — a diff of the two ignoring comments and blank lines. Two lines, and it would have caught this.

---

## Phase B — shared field specification

### The problem it solves

[app.R:3859-3981](app.R#L3859-L3981) and [app.R:4167-4289](app.R#L4167-L4289) are 123 lines duplicated byte-for-byte, differing only in `filt()` → `recent_trials_src()` and `trials_table` → `recent_trials_table`. Both hand-write the same field list. A third hand-written copy in the curation app is where they permanently diverge.

### `curation_app/R/field_spec.R`

One declarative list, sourced by **both** apps. Base R + `dplyr::coalesce` only — no Shiny, no DT.

```r
FIELD_SPEC_VERSION <- "1"

TRIAL_FIELD_SPEC <- list(
  list(id = "sponsor", label = "Sponsor", group = "entities",
       raw_cols  = c("sponsor_name_raw", "b1_sponsor.b11_name_of_sponsor",
                     "authorizedApplication.authorizedPartI.sponsors.organisation.name"),
       norm_col  = "sponsor_label",
       extra_cols = c(pipeline = "sponsor_clean", source = "sponsor_label_source"),
       editable = TRUE, control = "entity", vocab = "sponsor_registry",
       route = "sponsor_registry", override_col = NA_character_,
       note = "Corrects every trial with this raw sponsor string."),
  list(id = "phase", label = "Phase", group = "design",
       raw_cols = "phase_raw", norm_col = "phase",
       editable = TRUE, control = "select",
       vocab = c("Phase I","Phase II","Phase III","Phase IV",
                 "Phase I / Phase II","Phase II / Phase III"),
       route = "trial_override", override_col = "phase",
       note = "Applies to this trial only."),
  ...
)
```

Load-bearing keys:

- **`id`** is a permanent decision key — it lands in `trial_decisions.field_id` and in `data/trial_overrides.csv`. Renaming one orphans every decision made against it.
- **`editable`** is `FALSE` for derived fields (`n_countries`, `analysis_year`, `trial_duration_days`, `days_to_decision`). An edit to `trial_duration_days` would silently contradict the two dates on the same screen.
- **`vocab`** is a literal vector *or* a symbolic name resolved server-side. 6,954 sponsor and 19,645 substance canonicals cannot ship as static choices — server-side `selectize`.
- **`route`** implements the split. **`override_col` must be `NA` whenever `route != "trial_override"`** — this is what keeps the routing decision enforced rather than conventional.
- **`note`** is the reviewer-facing one-liner. "Corrects every trial with this raw string" vs "This trial only" *is* the entire UX of the split.

Ships in the same file: `row_val()`, `show_val()`, `bool_label()`, `trial_link()` (lifted from [app.R:4170-4181](app.R#L4170-L4181) and `:4224-4234`), and `field_rows(row, spec)` — the whole extraction contract, pure and testable with a one-row tibble.

Use `app.R`'s link builder, **not** `LEGACY/curation_app/R/tiers.R:555-564` — the legacy one passes the full `_id` (`…-00`) to the CTIS URL; `app.R:4231-4233` correctly strips to the first `CT_number` token.

### The boundary that must not be crossed

**The spec describes; it must not compute.** Do not attempt to drive `prepare_trial_data()` ([app.R:960-2044](app.R#L960-L2044)) from it — ~1,000 lines of register-specific logic with no test harness, on the dashboard's only data path. Shared = data + pure extraction. Per-app = rendering.

### Why the file lives under `curation_app/`

A Posit bundle is rooted at a directory and cannot reference paths above it, so the curation app cannot reach up into the repo root — but the dashboard can reach down. Reads backwards; it is the only layout with zero copies and zero build steps. Loud header comment naming both consumers.

`manifest.json` is a 7-path allowlist and **its checksums are not enforced** (last written 2026-05-19; `app.R` has been rewritten many times since and deploys succeed) — so it functions purely as a path allowlist. Regenerate with an explicit `appFiles` list rather than hand-editing; do not run bare `rsconnect::writeManifest()`, which sweeps the tree. Note `pediatric_trials_cache.rds` is in the manifest but absent from the working tree — check `deploy` before regenerating.

In `app.R`, after the config block (~`:255`), `source()` it **hard** — no `if (file.exists())`. A silently-empty spec renders a modal with no rows and nothing says so.

Then both observers collapse to three lines each calling a file-scope `trial_detail_modal()`. **Net −170 lines.**

---

## Phase C — retain the registry's own words

On Posit Cloud there is no SQLite (`data/*.sqlite` is gitignored, never deployed), so raw-vs-normalised for phase, country, age group, orphan status and participant count is impossible today: those raws are dropped at [app.R:2023-2033](app.R#L2023-L2033) and country never had a `_raw` at all.

**Do not stop dropping the source columns.** Keeping `f13_elderly_65_years` and `authorizedApplication.authorizedPartI.products.orphanDrugDesigNumber` re-inflates the cache with names nobody can read. Instead materialise five compact `_raw` display columns from vectors **that already exist** — the pattern `sponsor_name_raw` and `MEDDRA_term_raw` already establish:

| new column | source (verified present) | edit site |
|---|---|---|
| `phase_raw` | `raw_phase_for_log` | [app.R:1942](app.R#L1942), assign before `:1990` |
| `Member_state_raw` | `raw_country_for_log` | [app.R:1159](app.R#L1159), assign after `:1164` |
| `is_orphan_raw` | `coalesce(euctr_orphan_raw, ctis_orphan_raw)` | [app.R:2011-2013](app.R#L2011-L2013) |
| `age_group_raw` | new: the TRUE EUCTR flags pasted, or CTIS `ageGroup` verbatim | inside the `age_group` mutate |
| `participants_n_raw` | `coalesce(f422…, totalNumberEnrolled, rowSubjectCount)` as character | inside the `participants_n` block |

`results_source_raw` already exists. Sponsor, product, INN, MedDRA term and organ class already have `_raw` pairs.

**Ordering trap:** `raw_country_for_log` is computed *before* the `unite("Member_state", …, remove = TRUE)`. Assigning a plain vector to `result$Member_state_raw` there is safe — `unite(remove=TRUE)` only drops its named inputs.

**Cost ≈ +0.45 MB on a 16.7 MB cache (+2.7%)**, estimated from the gzipped size of the comparable normalised columns. R's global string cache makes high-repetition columns nearly free.

Bump `DATA_PROCESSING_VERSION` at [app.R:253](app.R#L253) and add `phase_raw` + `Member_state_raw` to `required_cols` in `cache_is_valid()` ([app.R:2049-2063](app.R#L2049-L2063)). **The bump costs nothing on the server** — `cache_is_valid()` already returns `FALSE` every night because `update_data.R` touches the SQLite before `rebuild_cache.R` runs. The cost is one local full rebuild.

---

## Phase D — the store

### Two decision tables, not one

They differ in key and in lifetime. A registry decision is keyed on a **raw string**, applies to every trial carrying it, and outlives any trial. A trial override is keyed on **(`_id`, `field_id`)**, applies to one trial, and dies with it — and `_id` genuinely vanishes (substance `E_emit.R:168-179` documents 5,438 trials reappearing under a different country code between snapshots). One table forces a nullable `_id`, a nullable `raw_value`, a `field_id` meaning two things, and a `CASE` inside the `DISTINCT ON`. That is the shape v1's `TIERS` registry had, and why it needed 641 lines of dispatch.

```sql
CREATE TABLE reviewers (
  username TEXT PRIMARY KEY, display_name TEXT NOT NULL, email TEXT,
  password_hash TEXT NOT NULL,                       -- argon2, sodium::password_store
  role TEXT NOT NULL DEFAULT 'reviewer' CHECK (role IN ('reviewer','admin')),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  must_change_pw BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_login_at TIMESTAMPTZ
);

-- Tab 2. Keyed on the raw string.
CREATE TABLE norm_decisions (
  decision_id BIGSERIAL PRIMARY KEY,
  domain TEXT NOT NULL CHECK (domain IN ('sponsor','substance')),
  raw_value TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('accept','edit','reject','not_a_substance','skip')),
  entity_id_shown TEXT, proposed TEXT,               -- proposed = the BEFORE value
  final_canonical TEXT, final_entity_id TEXT,
  new_canonical BOOLEAN NOT NULL DEFAULT FALSE,
  entity_type TEXT, salt_form TEXT, brand TEXT, parent TEXT, legal_entity TEXT,
  n_trials_shown INTEGER, confidence_shown REAL, review_reason TEXT,
  comment TEXT,
  reviewer TEXT NOT NULL REFERENCES reviewers(username),
  decided_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  snapshot_sha TEXT NOT NULL,                        -- provenance, NOT a retrieval key
  decision_ms INTEGER, app_version TEXT
);
CREATE INDEX ON norm_decisions (domain, raw_value, decided_at_utc DESC, decision_id DESC);
CREATE INDEX ON norm_decisions (reviewer, decided_at_utc);

-- Tab 1. Keyed on (trial, field).
CREATE TABLE trial_decisions (
  decision_id BIGSERIAL PRIMARY KEY,
  trial_id TEXT NOT NULL, field_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('validate','override','clear')),
  raw_shown TEXT, norm_shown TEXT,                   -- norm_shown = the BEFORE value
  final_value TEXT,
  value_type TEXT,                                   -- character|numeric|integer|logical|date
  comment TEXT,
  reviewer TEXT NOT NULL REFERENCES reviewers(username),
  decided_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  snapshot_sha TEXT NOT NULL, decision_ms INTEGER, app_version TEXT
);
CREATE INDEX ON trial_decisions (trial_id, field_id, decided_at_utc DESC, decision_id DESC);
CREATE INDEX ON trial_decisions (field_id, action);

CREATE TABLE trial_reviews (      -- whole-trial sign-off → a completion metric
  review_id BIGSERIAL PRIMARY KEY, trial_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('validated','flagged','reopened')),
  comment TEXT, reviewer TEXT NOT NULL REFERENCES reviewers(username),
  decided_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(), snapshot_sha TEXT NOT NULL
);

CREATE TABLE export_runs (        -- closes the loop: "decided but not yet live"
  export_id BIGSERIAL PRIMARY KEY,
  started_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(), finished_at_utc TIMESTAMPTZ,
  host TEXT, domain TEXT, status TEXT NOT NULL CHECK (status IN ('running','ok','failed','skipped')),
  max_norm_decision_id BIGINT, max_trial_decision_id BIGINT,
  n_sponsor_pins INT, n_substance_pins INT, n_new_entities INT, n_trial_overrides INT,
  message TEXT
);

CREATE TABLE admin_audit (
  audit_id BIGSERIAL PRIMARY KEY, at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor TEXT NOT NULL REFERENCES reviewers(username),
  action TEXT NOT NULL, target TEXT, detail JSONB
);
```

Latest-wins is `SELECT DISTINCT ON (domain, raw_value) … ORDER BY domain, raw_value, decided_at_utc DESC, decision_id DESC`. **The `decision_id` tie-break is not cosmetic** — two reviewers in the same millisecond otherwise return a nondeterministic winner, and `export.R` must be deterministic or its idempotence is unprovable.

### Attribution the CSVs cannot carry

`assignments.csv` has `decided_by, decided_at_utc, model_id, prompt_version`. `decided_by = "human"` is a **class, not a person**. Missing: who, why, what it was before, what they were looking at.

**Do not add columns to the CSVs** — they are pipeline state rewritten by three scripts each. Postgres is the audit log; the bridge is a traceable token in fields that already exist:

- `assignments.csv` → `reason = sprintf("curation:%s:%d", reviewer, decision_id)`
- `registry.csv` → `note  = sprintf("curation:%s:%d", reviewer, decision_id)`

A pinned row is then traceable back to Postgres from the CSV alone, with zero schema change.

---

## Phase E — auth

**Hand-rolled, not `shinymanager`** — reversing `PLANS/curation-app-sponsor-v2.md`. `shinymanager` pulls four more packages (`openssl`, `R.utils`, `billboarder`, `scrypt`) against `AGENTS/AGENTS.md:11`'s no-new-dependencies rule, wants to own the top-level UI via `secure_app()` (giving two admin screens), and wants to own the store. Hand-rolled is ~120 lines: a `uiOutput` showing the login form until `session$userData$auth` is set, `sodium::password_verify()`, and a `require_role()` guard.

New dependencies, all four justified: `DBI`, `RPostgres`, `pool`, `sodium`. `pool` earns its place — several concurrent sessions each doing `dbConnect` against free-tier Supabase is exactly how this falls over. App uses Supabase's **transaction pooler (6543)** with `dbPool(minSize=1, maxSize=5, idleTimeout=300)`; `export.R` uses the **direct endpoint (5432)**, since it is one short-lived connection and the pooler's prepared-statement restrictions are an avoidable surprise in an unattended job.

Passwords: **argon2** via `sodium::password_store()`. The prior plans say bcrypt; `sodium` doesn't do bcrypt and argon2 is the better primitive. Accounts seeded by SQL — with a handful of known reviewers an account-creation screen is a privileged write path to secure for no benefit. Removing a reviewer is `active = FALSE`, never `DELETE`; their decisions must survive them.

60-minute idle timeout, enforced **server-side** in `require_role()` via a `last_seen` stamp bumped by an observer. `req(FALSE)` renders nothing rather than erroring. A client-side `setTimeout` sits on top purely so the user sees a login screen rather than blanks.

**Admin gating is three layers and only the second is access control:** (1) the `menuItem` is rendered only for admins — cosmetic; (2) **every** `renderX`, `downloadHandler` and `observeEvent` in `R/admin.R` opens with `require_role(session, "admin")`; (3) mutating handlers re-check, because `Shiny.setInputValue` is forgeable from the browser console. Every admin write appends to `admin_audit`.

**Reviewer identity comes only from `session$userData$auth$username`.** No free-text reviewer box exists anywhere — that was v1's attribution hole.

---

## Phase F — GitHub snapshot

Reuse `PLANS/curation-app-sponsor-v2.md` §2 **as specified**: ref = `deploy`, `resolve_sha()` via `GET api.github.com/repos/{repo}/commits/{ref}`, fetch **by resolved SHA never by ref**, fresh temp dir with an atomic pointer swap, `GITHUB_PAT` for rate-limit headroom only, degraded mode with a persistent SHA-naming banner, refresh at process start plus an admin button, **only data is fetched, never code** (sourcing R from a branch at runtime is a code-execution path).

**Fetch (≈27.6 MB):** `trials_cache.rds` (16.7 MB), both `E_review_queue.csv` (267 KB + 779 KB), both `registry.csv` (916 KB + 2.4 MB), `data/trial_sponsors_raw.csv` (2.7 MB), `data/trial_substances_raw.csv` (3.8 MB).

**Skip `assignments.csv` (7.4 MB combined).** Its only reviewer-facing job is the sibling panel, and there is a free substitute in data already fetched: `trials_cache.rds` carries both `sponsor_name_raw` and `sponsor_clean`, so "other raw strings on this canonical" is `filter(sponsor_clean == x) |> distinct(sponsor_name_raw)` — exact, in memory, zero bytes. Also skip `data/trial_sponsor_labels.csv` (4.6 MB): it is `_id → sponsor_clean` and the cache has both.

Fetch **synchronously at app scope**, before `shinyApp()` — Posit keeps the process warm and reviewers hit it once a day. Budget ≤30 s cold. Do not add `promises`/`future` for a cold start nobody sees twice.

**Two things the prior plan misses, both of which bite:**

1. **`deploy` is force-pushed nightly.** A SHA resolved yesterday can become unreachable and eventually GC'd, at which point `raw.githubusercontent.com/{repo}/{sha}/{path}` 404s. Re-resolve on every fetch; never persist a SHA expecting it to stay retrievable. `snapshot_sha` is a **provenance record, not a retrieval key** — say so in the schema comment, or someone will later build "show me what they saw" and it will 404 intermittently.
2. **Binary mode and post-download validation.** `download.file(..., mode = "wb")` for the `.rds`; text mode corrupts it. Validate before the pointer swap — non-zero size, and for the cache a successful `readRDS()` with `_id` present. A truncated download must not become the live snapshot.

**Overlay pending decisions on the fetched snapshot.** A raw string a reviewer has already decided must leave the tab-2 queue *now*, not after the next nightly. Anti-join the queue against `latest_norm_decisions()` in a reactive, plus a 60-second `reactivePoll` on `SELECT max(decision_id)` so two concurrent reviewers don't work the same row. Tab 1 shows the reviewer their own pending override immediately, labelled **"pending — live after tonight's rebuild."** Honest and cheap.

Do **not** build a claim/lock protocol. The conflict rule is last-write-wins made visible by the disagreement report.

---

## Phase G — write-back

`curation_app/export.R`, a plain Rscript. Reuse the prior plan as specified for `source()`ing [helper_scripts/llm_norm/registry.R](helper_scripts/llm_norm/registry.R) to get `registry_add()`, `registry_write()`, `assignments_write()`, `resolve_entity()`, `utc_now()`; honouring `SPONSOR_V2_DIR`/`SUBSTANCE_V2_DIR`; backups before writing; `--write` gating.

The working reference implementation to follow is `helper_scripts/substance_norm_pipeline_v2/A_resolve.R:160-180`, which already writes `decided_by="human", channel="manual", confidence=1.0` under `--apply-overrides`.

### Three insertion points in `rebuild_cache.R`

| after / before | call |
|---|---|
| after `:77`, before the gate at `:82` | `run_step("curation_app/export.R", c("--domain=sponsor","--write"))` |
| after `:136`, before the gate at `:140` | `run_step(..., c("--domain=substance","--write"))` |
| immediately before `:177` | `run_step(..., c("--domain=trial","--write"))` |

The nightly assigns newly-seen strings first (`N_nightly_resolve`), human pins then overwrite whatever it decided, and the gate sees the final state.

**Also fix [rebuild_cache.R:191-201](rebuild_cache.R#L191-L201)** while here: it re-implements sponsor precedence as `coalesce(sponsor_clean, sponsor_name)` — a second, lossier copy of the two lines at [app.R:873-883](app.R#L873-L883). The saved RDS therefore has no human overlay; `load_trial_data()` re-applies it, but `rmarkdown/preprocessing.Rmd` reads the cache directly and sees the wrong thing. Replace with `attach_sponsor_labels()` + `attach_trial_overrides()`.

### What it writes

| action | effect |
|---|---|
| `accept` | `assignments[raw]`: `decided_by="human"`, `confidence=1`, `channel="review"`, `entity_id=resolve_entity(...)`, `reason="curation:<user>:<id>"` |
| `edit` → existing | as accept, `entity_id` = that canonical's **live terminal** entity |
| `edit` → new | `registry_add(..., decided_by="human", note="curation:<user>:<id>")`, then point the assignment at it |
| `reject` | `entity_id = NA`, `decided_by = "human"` |
| `not_a_substance` | append to `<DATA_DIR>/substance_rejected.csv` **and** pin `entity_id=NA, decided_by="human"` |
| trial `override` | one row in `<DATA_DIR>/trial_overrides.csv` |

Two subtleties:

- **A raw string may have no assignment row at all** — `route_for_review()` queues `is.na(entity_id)` rows, and a string can be in the queue without an `assignments.csv` row. `export.R` must **insert**, not only update.
- **`not_a_substance` needs both writes.** The `substance_rejected.csv` row is what `E_emit.R:121` reads to classify it `rejected`; the `decided_by="human"` pin is what makes `route_for_review()` drop it from the queue. Without the pin it is re-queued forever.

### Idempotence — everything else rests on this

`--write` twice must be byte-identical. Three concrete threats:

1. **Timestamps** — use the Postgres `decided_at_utc`, never `utc_now()`, or every run rewrites every human row and the file churns nightly.
2. **`registry_add()` re-minting** — look the canonical up first, accent/case-folded, or a re-run allocates a second `entity_id`.
3. **Sort order** — `write_table_atomic()` already sorts; `substance_rejected.csv` is not written through it, so add an explicit `arrange()`.

Extend `tests/sponsor_v2_idempotence.R` and `tests/substance_v2_idempotence.R` rather than adding a third harness — they exist precisely as the fixture for this bug class (one careless re-materialisation once added 284 entities and re-pointed 527 assignments, with no error).

**Backups** to `<V2>/backups/<utc>/` before the first write of a run, **but only when something will actually change** — compare the would-be bytes to disk first. That makes idempotence *observable* (an unchanged night leaves no new backup directory) rather than merely asserted. Prune to 14.

### It must never abort the nightly

`rebuild_cache.R:62-65`'s governing rule is that a sponsor hiccup never costs the data refresh. `export.R` therefore `quit(status = 0)` in every path except argument errors:

| condition | behaviour |
|---|---|
| `CURATION_DB_URL` unset | message, exit 0 — **a laptop rebuild behaves exactly as today** |
| DB unreachable / any error | message, write `data/.curation_export_failed`, exit 0 |

The nightly tests the new sentinel alongside the two existing ones and folds it into the exit-3 condition **after** the push.

### Getting `RPostgres` where it actually runs

Two installs, and only the second is the one that matters tonight. The nightly runs `docker exec rstudio-rstudio-1 …` against a `rocker/rstudio` container **provisioned by hand on the server** — the repo `Dockerfile` is not that runtime (see `AGENTS/DEPLOY.md:36-44`, `:68-74`).

1. The running container: `apt-get install -y libpq-dev` then `install.packages(c("DBI","RPostgres"))`.
2. The repo `Dockerfile`, so the images don't drift — the same lesson as the nightly script.

`CURATION_DB_URL` goes in `/home/ruben/.config/shiny_trials/secrets.env`, the `env_file:` already carrying `ANTHROPIC_API_KEY`. **`docker exec` is called without `-e`**, so compose env is the only channel — `AGENTS/DEPLOY.md` documents that trap, including the `setwd()`-defeats-project-`.Renviron` variant.

---

## Phase H — per-trial overrides

**Path:** `data/trial_overrides.csv`, via `TRIAL_OVERRIDES_PATH` declared beside `REVIEW_LEDGER_PATH` at [app.R:245-248](app.R#L245-L248). Not `config/` — `config/*` is tracked on `main` and `git reset --hard origin/main` reverts it every night, the exact trap `AGENTS/DEPLOY.md` documents for `SPONSOR_V2_DIR`. It matches neither `data/*log*` nor `data/*labels*`, so add an explicit `.gitignore` line and force-add it via `GENERATED_FILES`.

**Schema:** `_id,field_id,column,value,value_type,reviewer,decided_at_utc,decision_id,comment`

- `column` is stored explicitly, not re-derived from `field_id`, so a later spec rename cannot silently mis-apply an old override.
- `value_type ∈ character|numeric|integer|logical|date`. The cache is typed (`participants_n` numeric, `has_results` logical, `start_date` Date); casting from a bare string with no declared type is how you get `"12"` in a numeric column.

**`attach_trial_overrides()`** goes immediately after `attach_sponsor_labels()` (~[app.R:886](app.R#L886)) and is called from three places: the end of `prepare_trial_data()` (a freshly built cache is consistent), inside `load_trial_data()` right after `attach_sponsor_labels()` (**the live path** — overrides go live on cache load, no rebuild needed), and in `rebuild_cache.R` before `saveRDS` (so `preprocessing.Rmd` sees what the app sees).

**Precedence, stated once:**

1. An override always wins for that `(trial, column)` — it is the most specific statement anyone has made about that cell.
2. It is never auto-retired. Tab 3 surfaces "override now equals the pipeline value" so stale ones can be cleared by hand.
3. **Overrides never touch `sponsor_*`, `substance_label`, or any `_raw` column.** The spec enforces this via `route`/`override_col = NA`; `attach_trial_overrides()` enforces it *again* via an `OVERRIDE_DENY` vector. **This is the single most important guard in the design** — without it a hand-edited CSV punches a per-trial sponsor label through and the routing split becomes unenforced convention.
4. Overrides run after `attach_sponsor_labels()`, so ordering can never matter — but rule 3 is what makes that true rather than accidental.
5. **Recompute the two cheap derived columns** when their inputs were overridden: `n_countries` from `Member_state`, `trial_duration_days` from the two dates. Six lines. Otherwise the modal shows a three-country list beside `# Countries = 5`.

Add an `override_fields` audit column recording what was overridden on each row. Even 5,000 overrides is ~400 KB.

---

## Phase I — nightly changes

### I1. Copy the live files into the work tree — the step that makes it all work

`git add -f <path>` stages the **work tree** copy. After `git reset --hard origin/main` that is `main`'s frozen version, not the live file in `$SPONSOR_V2_DIR`/`$SUBSTANCE_V2_DIR`. **This is already broken today**: `config/substance_norm_v2/E_review_queue.csv` is in `GENERATED_FILES` and publishes a stale file every night, silently.

Insert a `publish()` helper after the sentinel tests, before `git add`, copying `E_review_queue.csv` and `registry.csv` from the host paths (`/home/ruben/shiny_trials/{sponsor,substance}_norm_v2` — note these are **host** paths; `SPONSOR_V2_DIR` is the *container* path) into the work tree. **Log a WARNING when the source is absent** rather than skipping silently — a quiet `[ -f ]` skip is how this fails unnoticed for weeks.

### I2. `GENERATED_FILES` additions (4)

`config/sponsor_norm_v2/E_review_queue.csv` (missing entirely today), both `registry.csv`, and `data/trial_overrides.csv`. Broaden `GENERATED_PATHSPEC` to exclude both config dirs from the dirty check.

**Do not add `assignments.csv`** — 7.4 MB rewritten nightly, and the app doesn't need it.

### I3. Churn budget

On top of today's ~16 MB/night (`trials_cache.rds`, a full binary rewrite): steady state **≈ +0.35 MB/night**, worst case +1.3 MB when a registry mints. The script's current comment excludes these dirs for "megabytes of churn per night" — true of `assignments.csv`, not of `registry.csv`. Update the comment rather than leaving an inaccurate rationale in place. Note in the header that `git add -f` on the registries is safe **only because `deploy` is force-pushed**.

---

## The four screens

**Tab 1 — Trial validation.** `DT::datatable(filter = "top", server = TRUE)` over a ~20-column table plus three `selectizeInput`s. Click a row → the field spec rendered with inputs, grouped by `group`, each field showing raw / normalised / control / `note`. Save writes `trial_decisions` (and `trial_reviews` for whole-trial sign-off). **Do not extract `apply_trial_filters()`** ([app.R:3398-3453](app.R#L3398-L3453)) — it is pure, but its companion `make_filter_settings()` reads `input$*` and both live inside a 3,600-line `server` closure. Tab 1 does not need 14 filter dimensions; DT's own filters are 30 lines and no risk.

**Tab 2 — Normalisation review.** Both queues, one shape: raw / proposed / confidence / `n_trials` / `review_reason` / model `reason` verbatim. Actions accept / edit / reject / skip, plus **`not_a_substance`** on the substance side only (it has a third `match_status`; sponsor has no analogue). Server-side selectize over the live registry (`registry_live()`), with a visible warning when a new canonical is being minted — uncontrolled canonical creation is how near-duplicates accumulated in the first place. Sibling panel from the cache, not `assignments.csv`.

**Tab 3 — Changes & statistics.** Throughput by reviewer; **per-field change rate** (`n_reviewed`, `n_overridden`, `change_rate`, with a minimum-n filter so a 1-of-1 field cannot top the list) — this is the table that says which normalisation is untrustworthy; change rate by `review_reason` and confidence band, directly actionable against `route_for_review()`'s 0.75/0.90 thresholds; **disagreements** in two cuts (hard: same key, two reviewers, different final value; soft: one accepted where another overrode) **showing the losing decision too** — last-write-wins is only safe if the loser is visible; backlog burn-down; pipeline lag from `export_runs`; coverage. No leaderboard framing of disagreement.

**Admin.** Accounts, snapshot refresh, export status, decision CSV download, `admin_audit`.

The columns that exist *only* so tab 3 is possible — and that get forgotten: `norm_shown`/`proposed`/`raw_shown` (the **before** value; without it "what changed" is unanswerable once the pipeline moves on), `n_trials_shown`, `confidence_shown`, `review_reason`, `decision_ms` (median seconds/decision flags rubber-stamping).

---

## Build order

Each commit independently sound. Blocking fixes first, the writer last.

| # | commit |
|---|---|
| 1 | `fix: a human unassignment is not a regression` — A1 + A2, both `E_emit.R`, `tests/emit_human_unassign.R` |
| 2 | `fix: the repo nightly never reported a substance failure` — A3 |
| 3 | `refactor: one trial-detail modal, built from a field spec` — Phase B, net −170 lines. **Riskiest cosmetic change; do it while nothing else is in flight.** Verify by rendering both modals for 20 sampled trials before/after and diffing the HTML |
| 4 | `feat: keep the registry's own words for phase, age, orphan, participants and country` — Phase C. Improves the existing dashboard on its own |
| 5 | `feat: apply per-trial overrides on cache load` — Phase H, ships with **no writer**, a no-op until #15. Includes the `rebuild_cache.R:191-201` fix |
| 6 | `feat: publish the live registries and queues to deploy` — Phase I. Verifiable next morning |
| 7 | `docs: the curation database and its secrets` — Supabase provisioned, `sql/schema.sql` applied, one admin seeded, `AGENTS/DEPLOY.md` section |
| 8 | `feat(curation): snapshot fetch from deploy` — Phase F. Testable against the live repo with no database |
| 9 | `feat(curation): the store` — `R/store.R`, testable against a local Postgres |
| 10 | `feat(curation): login` — Phase E + the four-tab shell with server-side gating |
| 11 | `feat(curation): tab 1, trial validation` |
| 12 | `feat(curation): tab 2, normalisation review` |
| 13 | `feat(curation): tab 3, changes and statistics` |
| 14 | `feat(curation): admin panel` |
| 15 | `feat: export curation decisions into the nightly` — Phase G. **The first commit that can change production data.** Land only after #1 is live on the server |
| 16 | `test: curation round trip` |
| 17 | `chore: v0.22.0` — README, CHANGELOG, About-tab changelog |

### File layout

```
curation_app/
  app.R                shell: auth gate, 4 tabs, snapshot at app scope
  manifest.json        its OWN allowlist. Never merged into the root one.
  R/
    field_spec.R  ★    SHARED — also source()d by ../app.R. Base R + dplyr only.
    github.R           resolve_sha(), fetch_snapshot(), the snapshot pointer
    store.R            pool, append_*(), latest_*(), metrics_*()
    auth.R             login UI, password_verify, require_role(), idle timeout
    trials.R           tab 1     norm_review.R  tab 2
    stats.R            tab 3     admin.R        tab 4
    util.R
  export.R             Rscript: Postgres → registries + trial_overrides.csv
  sql/schema.sql, sql/seed_admin.sql.example
  README.md
```

---

## Verification

Every pipeline-touching test runs against scratch dirs via a `tests/with_scratch_v2.sh` wrapper that sets `SPONSOR_V2_DIR`/`SUBSTANCE_V2_DIR`/`DATA_DIR` and **ends with a `shasum` byte-identity check on the real directories** — that check is itself the test for env-var honouring. (This is why A2 must land first.)

1. **Reject does not freeze labels.** In scratch, set one high-traffic `raw_sponsor` to `entity_id=NA, decided_by=human`. `E_emit.R --diff-only --assert-no-regressions` must **exit 0**, show `human unassign (intended)` with the expected trial count, and 0 regressions. Then a full `rebuild_cache.R` against the small DB: `trial_sponsor_labels.csv` mtime advanced, log does **not** contain `SPONSOR LABELS NOT WRITTEN`. Both domains, both substance paths.
2. **The gate still fires.** Same fixture but `decided_by="model"` → **exit 1**. Without this, test 1 only proves the gate was disabled.
3. **`export.R` idempotence.** `--write` twice → identical shasums and **no second backup directory**.
4. **Never aborts the nightly.** `CURATION_DB_URL` unset → exit 0, no sentinel. Pointed at `postgres://nowhere` → exit 0, sentinel written.
5. **Round trip, all five actions** → 5 `decided_by="human"` rows with `reason` starting `curation:`, 1 new human registry row, 1 new `substance_rejected.csv` row, and the next `E_emit` queue 5 rows shorter.
6. **Trial override round trip including the negative case.** Override `phase`, export, confirm via `source("app.R")` that the value and `override_fields` are set. **Then hand-edit the CSV to override `sponsor_label` and assert `attach_trial_overrides()` refuses it.** That negative test is what keeps the routing split honest.
7. **Concurrency.** Two accounts, same row, within a second: both rows land, `DISTINCT ON` returns one, the tie-break is `decision_id`, the disagreement view shows both, `export.R` applies the higher id.
8. **Auth.** (a) unauthenticated gated output renders nothing; (b) a reviewer forging `Shiny.setInputValue('admin_create_user', …)` creates no row and no audit entry; (c) `grep -rn 'input\$.*reviewer' curation_app/` is empty; (d) after the idle timeout gated outputs stop rendering **server-side**.
9. **Snapshot atomicity + degraded mode.** Push to `deploy` mid-fetch → every file from the first SHA. Block `raw.githubusercontent.com` → login renders, banner names the last SHA, tabs say "no snapshot" rather than erroring.
10. **The published queue is the live one.** After a nightly that mints a new string, `git show origin/deploy:config/sponsor_norm_v2/E_review_queue.csv | grep <string>` succeeds and Refresh shows the row — **no redeploy**.
11. **Cache raw retention.** All five `_raw` columns present, each non-NA at ≥90% of its normalised counterpart's rate, `trials_cache.rds` grew **< 1 MB**.
12. **`tests/field_spec_matches_cache.R`** — every `norm_col`, `raw_cols` entry and non-NA `override_col` exists in `names(readRDS(CACHE_PATH))`; every `id` unique; every `trial_override` field has a non-NA `override_col` **and every registry-routed field has `override_col = NA`**. The guard against the spec drifting from `prepare_trial_data()`, and against a routing mistake.
13. **No secrets.** `git log -p` shows no connection string; `grep -rn 'postgres://' --include='*.R' .` empty; `git check-ignore -v data/trial_overrides.csv`.

---

## Explicitly not doing

1. **The app does not write to the registries directly.** No shared filesystem, and a second writer racing `N_nightly_resolve.R` recreates the read-modify-write race.
2. **No promise of same-day dashboard visibility for trial overrides.** Two separate deployments; `data/trial_overrides.csv` reaches Posit only via `deploy`. Promising same-day and delivering next-morning is worse than promising next-morning.
3. **Do not reuse `REVIEW_LEDGER_PATH` / `read_human_sponsor_decisions()`** ([app.R:814-841](app.R#L814-L841)) as transport. It is a CSV keyed on `row_key = raw sponsor` with a different action vocabulary; wiring it up gives two live mechanisms for sponsor overrides. Leave it exactly as-is — it returns `NULL` on a missing file, costs nothing, and is a working manual fallback. **Say this in the commit message or someone will connect it.**
4. No row-claim/lock protocol for tab 2 — a seventh table and a stale-claim problem, to replace a rule that already works.
5. No `shinymanager`, no one-table decision schema, no `assignments.csv` fetch, no extraction of `apply_trial_filters()`.
