# Normalisation reviewer app + provenance correction

## Context

Sponsor and substance normalisation on `main` were curated almost entirely by LLM agents working through review queues in chunks. Two problems follow from that:

1. **The provenance metadata lies.** `AGENTS/sponsor_manual_curation.md:79-93` instructs the curating agent to stamp its rows `source: manual, confidence_prior: 1, alias_type: NA`. Every alias the LLM added therefore looks hand-verified. No human review has actually happened, so ~1,383 sponsor and ~1,750 substance config rows claim a provenance they do not have — and `manual` outranks `llm_reviewed` in the index builder, so the mislabel actively wins conflicts.

2. **There is no practical way for a human to do the review.** The only tools are `curate_sponsors.R` / `curate_substances.R`, single-key stdin loops with no evidence panel, no undo, and no durable decision history (both queue writers `anti_join` decided rows *out* on rebuild, so the queue is a to-do list, not a record). `curate_substances.R` is in fact broken today — see Part C.

The outcome: an honest provenance vocabulary that reserves `manual` for real human decisions, and a local Shiny app where those human decisions can actually be made — raw vs proposed, accept / edit / reject, with an append-only ledger so the work survives pipeline rebuilds.

## Scope note (verified against the data)

"Low-confidence substance aliases" is **not** the ~74k rows carrying `confidence_prior = 0.65`. That value is a *tier prior* on the alias table (ChEMBL synonym), not a match confidence — an exact string hit on a ChEMBL synonym is generally sound. The genuinely unconfident matches are the fuzzy ones, and there are far fewer:

- **2,544** distinct fuzzy-matched raw substance strings total — `501` `review`, `2,043` `unknown`, **zero auto-accepted** (the pipeline is conservative: JW ≥ 0.80 only ever produces `review`/`unknown`).
- **665** of those already sit in `substance_review_queue.csv`.
- **1,879** are singletons excluded by the `n_occurrences >= 2` filter at `helper_scripts/substance_norm_pipeline/build_substance_labels.R:220-223`. Spot-checking these shows mostly garbage (`Menomune` → `Menbutone`, `Antigenum tegiminis hepatidis B` → `Platinum`), so they are worth surfacing as a low-priority tier — but as 1,879 rows, not 74,000.

Sponsor fuzzy/containment matching is negligible: 104 rows, all scoring > 92.

---

## Part A — Correct the provenance metadata

`manual` → `llm_curated`, a **new tier ranked 1** — exactly where `manual` sits today, so normalisation output is unchanged. `manual` becomes reserved for decisions made by a human in the new app.

### Critical dependency

`pick_final_canonical()` ranks on the **`source`** column:

```r
# helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R:190-192
source_priority <- c(
  manual = 1, llm_reviewed = 2, review_queue = 3, bulk_reviewed = 4,
  ctis_businesskey = 5, epar_mah = 6, ror = 7
)
```

Unmatched sources fall to `coalesce(..., 99)` at line 197. **Add `llm_curated = 1` here in the same commit as the data edit**, or all 1,383 relabelled rows silently lose their priority. Keep `manual = 1` for future human rows.

By contrast the substance side encodes priority by **row order** in `bind_rows` (`build_substance_index.R:270`), independent of the `source` string, so relabelling there is behaviourally inert.

### Data edits (tracked config, all verified counts)

| File | Field | Change | Rows |
|---|---|---|---|
| `config/sponsor_norm_pipeline/manual_sponsor_aliases.csv` | `source` | `manual` → `llm_curated` | 1,383 (leave `ctis_businesskey` 131) |
| `config/substance_norm_pipeline/manual_brand_to_substance.csv` | `source` | `manual` → `llm_curated` | 1,380 (all) |
| `config/substance_norm_pipeline/canonical_substances.csv` | `source` | `manual` → `llm_curated` | 370 (all) |
| `config/substance_norm_pipeline/manual_substance_overrides.csv` | `reason` | `"…during manual curation (chunk N)"` → `"…during llm curation (chunk N)"` | ~294 |

Do these with a one-off R script under the scratchpad (not committed) using `readr::read_csv`/`write_csv` — **not** `awk`/`sed`. Naive comma-splitting misparses these files: quoted commas in substance names shift fields, which is why an `awk` pass reports phantom `source` values like `" live attenuated"`.

### Code edits

- `build_sponsor_index.R:191` — add `llm_curated = 1` to `source_priority` (above).
- `build_sponsor_index.R:1604` — `dplyr::mutate(alias_type = "manual")` → `"llm_curated"`. Display-only (`alias_type` is never a ranking key; it surfaces at `normalise_substances.R:282`), but keeps the two fields consistent.
- `curate_sponsors.R:114` and `:139`, `curate_substances.R:~108` and `:~162` — default reason strings `"accepted during manual curation"` / `"rejected during manual curation"` → `"accepted during queue curation"` / `"rejected during queue curation"`, which is true regardless of who ran it.

### Doc edits (root cause — do not skip)

- `AGENTS/sponsor_manual_curation.md:79-93` — the instruction that caused this. Change the prescribed row format to `source: llm_curated`, and state that `manual` is written **only** by the reviewer app.
- `AGENTS/substance_manual_curation.md` — same note.

### Regenerates automatically, no manual edit

`sponsor_alias_index.csv`, `substance_alias_index.csv`, `final_sponsor_canonical_review.csv`, `sponsor_review_queue.csv`, `data/*_normalisation_log.csv`.

### Deliberately out of scope

- **Filenames** keep their `manual_` prefix (`manual_sponsor_aliases.csv` etc.). Renaming touches ~20 scripts, both READMEs, and the pipeline `.dot` diagram for zero functional gain.
- **`confidence_prior` stays at 1** for relabelled rows. Lowering it would trip the `>= 0.95` gates at `normalise_sponsors.R:576,615` and shift output. Flagging as a possible follow-up once human verification is underway.
- **The `feature/normalisation-v2` worktree** carries 1,246 `reviewed_v1_snapshot:manual` rows in `sponsor_resolution_catalog_v1.csv`. `migrate_reviewed_sponsor_decisions.R:129-131` folds `source` into a SHA-256, so relabelling would change every `catalog_id` and `decision_id`. That is a v2-branch migration decision — left alone here.

---

## Part B — The reviewer app

New standalone app at `curation_app/`, **not** touched into the 6,850-line `app.R`. Uses `bslib` + `filelock` (approved; both already installed) plus existing deps `shiny`, `DT`, `dplyr`, `readr`, `digest`.

```
curation_app/
  app.R              entry point; bslib::page_navbar, one nav panel per tier
  R/tiers.R          per-tier loaders → common {id, raw, proposed, fields, evidence} shape
  R/store.R          atomic write + filelock + append-only ledger
  R/review_card.R    Shiny module: the raw-vs-proposed review card (reused by every tier)
  R/apply.R          replay ledger → config files
  README.md
```

### Tiers

| Tier | Source | Rows | Raw | Proposed | Ordered by |
|---|---|---|---|---|---|
| Sponsor queue | `sponsor_review_queue.csv` | 102 | `raw_sponsor` | `candidate_sponsor` | `n_trials` desc |
| Substance queue | `substance_review_queue.csv` | 1,337 | `raw_substance` | `active_substance_clean` | `n_occurrences` desc |
| Sponsor LLM aliases | `manual_sponsor_aliases.csv` where `source == "llm_curated"` | 1,383 | `alias_clean` | `sponsor_clean` (+ parent, group, type) | trial impact |
| Substance LLM aliases | `manual_brand_to_substance.csv` + `canonical_substances.csv` | 1,750 | `alias_clean` | `substance_clean` | occurrence count |
| Fuzzy singletons | derived from `data/substance_normalisation_log.csv` | 1,879 | `raw_substance` | `active_substance_clean` | `match_score` asc |

Trial impact for the sponsor alias tier joins `data/sponsor_normalisation_log.csv` on `raw_sponsor` — 2,926 rows / 21,256 trials currently resolve through this tier, of which 568 carry ≥ 5 trials. Default the tier to `n_trials >= 2` (1,277 rows) so the highest-leverage rows come first; make the threshold a slider.

### Review card

Raw on the left, proposed on the right as an **editable** `textInput` (pre-filled with the proposal), plus the extra editable fields the tier carries (`sponsor_type`, `sponsor_parent`, `sponsor_group`). Below: an evidence panel showing `match_score`, `match_source`, `match_reason`, impact count, and — the piece the CLI lacks — **sibling aliases that resolve to the same canonical**, read from the alias index. That context is what makes a wrong canonical obvious.

Actions: **Accept** (proposal as-is) · **Accept edited** (enabled once the field is dirty) · **Reject** · **Skip**. Comment box optional; required on Reject. Keyboard shortcuts `a` / `e` / `r` / `s`, `←`/`→` to navigate. Header shows `n decided / n total` per tier and resumes at the first undecided row.

### Persistence — queue CSV + ledger

- **Queue tiers** — write `decision` / `canonical_*` / `comment` back into the queue CSV, exactly the columns `curate_*.R --export` already consumes, so the existing export path (`curate_sponsors.R:86-158`) keeps working untouched.
- **Alias tiers** — those CSVs have no decision columns; decisions live in the ledger only and are applied by `R/apply.R`.
- **Every** decision, both kinds, appends to `config/review_ledger/review_decisions.csv`:

  ```
  decision_id, decided_at_utc, reviewer, tier, source_file, row_key,
  raw_value, proposed_value, final_value, action, comment, input_hash
  ```

  `input_hash` is a `digest::digest` of the row as presented, so a decision made against since-changed data is detectable rather than silently stale. Append-only — a changed mind writes a new row, and the latest wins on replay.

All writes go through `store.R`: `filelock::lock` → write to `tempfile()` in the same directory → `file.rename`. This is the pattern already proven in `normalisation_reviewer/reviewer_store.R:37-49` on the v2 worktree; port those two helpers rather than reinventing them.

`R/apply.R` replays the ledger onto the config files: accepted alias-tier rows get `source: manual` (now honestly earned) with the reviewer and date in the ledger; rejected rows are removed from the alias table and added to `sponsor_negative_aliases.csv` / `negative_aliases.csv`; edited rows have their canonical rewritten. It is idempotent — re-running replays to the same end state.

### Deployment safety

`manifest.json` is an explicit 7-file allowlist (`app.R`, the two `.rds` caches, three `.Rmd`, `www/preprocessing.html`), so `curation_app/` will not reach Posit Cloud. Leave the manifest alone; do not regenerate it with `rsconnect::writeManifest`, which would sweep the new directory in.

---

## Part C — Pipeline fixes the app depends on

1. **`build_substance_labels.R:224-234` drops the decision columns.** `new_queue` selects 7 columns and `queue_out` never re-adds `decision` / `canonical_substance` / `comment`, so the written queue lacks them and `curate_substances.R:194-202` hard-stops with *"Queue is missing columns"*. The substance CLI is unusable today. Mirror the sponsor fix at `build_sponsor_labels.R:208-215`, which re-adds them in the `mutate()`.

2. **Decided rows vanish on rebuild.** Both writers `anti_join(existing_decisions, by = raw_*)` decided rows out of the rebuilt queue. The ledger makes this survivable, but also add a `--keep-decided` flag so a rebuilt queue can carry decisions forward for inspection.

3. **`rebuild_cache.R` is asymmetric** — the substance pipeline runs with `--write-queue`, the sponsor pipeline without, so the sponsor queue goes stale. Pass `--write-queue` to both.

---

## Verification

1. **Provenance edit is behaviour-neutral.** Snapshot `data/sponsor_normalisation_log.csv` and `data/trial_sponsor_labels.csv`, run `build_sponsor_index.R` then `build_sponsor_labels.R`, and diff. With `llm_curated = 1` added to `source_priority` the diff must be empty apart from the `match_source` string itself. A non-empty diff means the priority entry is missing or misspelled.
2. **Gold fixtures must not regress.** Run the sponsor and substance gold-fixture checks (`tests/fixtures/sponsor_normalisation_gold.csv`, 116 cases; `tests/fixtures/substance_normalisation_gold.csv`, 111 cases) before and after. Baselines are known-imperfect (93/23 and 14/97 per `AGENTS/normalisation_v2_handover.md`) — the bar is *unchanged*, not *passing*.
3. **No stray `manual` left.** `rg -c '\bmanual\b' config/` should show hits only in filenames and genuine `manual_override` tier values; every `source`/`alias_type` occurrence should be gone. Re-run the `readr`-based count from Part A and confirm `llm_curated` totals 1,383 / 1,380 / 370.
4. **App round-trip.** `Rscript -e 'shiny::runApp("curation_app")'`; on each of the five tiers accept one row, edit one, reject one. Confirm the queue CSV gained the decision columns, the ledger gained 15 rows, and a page reload resumes at the right position. Kill the app mid-decision and confirm no partial CSV (atomic rename).
5. **Apply is idempotent.** Run `R/apply.R` twice; the second run must be a no-op. Confirm accepted alias rows now read `source: manual` and rejected ones appear in the negative-alias files.
6. **End to end.** `Rscript rebuild_cache.R`, confirm it completes and the decisions made in step 4 are reflected in `data/trial_sponsor_labels.csv`.

## Repo conventions (`AGENTS/AGENTS.md:3-11`)

Version bump touching `app.R` (About tab), `README.md`, `CHANGELOG.md` (full entry), and a new section in `AGENTS/AGENTS.md`. Keep `trials_cache.rds` and `www/preprocessing.html` out of the commit. Note that `nightly_deploy_posit.sh:32-36` aborts on a dirty work tree, so the config CSV changes must be committed before the next nightly run.

## Suggested commit split

1. Part C pipeline fixes (independently testable, unblocks the substance CLI).
2. Part A provenance correction — data + `source_priority` + docs together, since splitting them breaks ranking.
3. Part B the app.
