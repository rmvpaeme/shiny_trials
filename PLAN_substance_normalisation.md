# Plan: Substance Normalisation — Next Steps

## Context

Phase 1 + Phase 2 of the substance normalisation pipeline are complete (commit `84c4563`). The core pipeline (`normalise_substances.R`, `build_substance_index.R`, all config files) is working. Queue is at ~3,584 rows, predominantly legitimate research codes where `review`/`unknown` is correct.

Four items remain:

1. **Blocking bug:** The `product_search` dropdown is disabled because `normalise_substances()` was being called inside an `observe`, hanging the R session.
2. **CLI test mismatch:** `export_raw_substances.R` doesn't split on ` / ` before writing, so CLI test output doesn't match what the app actually processes.
3. **No test fixture:** `tests/fixtures/substance_normalisation_gold.csv` doesn't exist, so there's no regression guard.
4. **No curation tool:** There's no interactive CLI to review `substance_review_queue.csv` and feed decisions back into config files (like the sponsor curation workflow).

---

## Task 1: Fix `export_raw_substances.R` (slash-separator split)

**File:** `helper_scripts/substance_norm_pipeline/export_raw_substances.R`

**Problem:** Raw values like `VINORELBINA TARTRATO / Cisplatin / Pemetrexed` are written as a single string. The normaliser receives the whole string, fuzzy-matches only the first token, and loses the rest. The app calls `separate_rows(..., sep = " / ")` before normalising; the CLI export does not.

**Fix:** Add `tidyr::separate_rows(raw_substance, sep = " \\/ ")` after creating `raw_substance` and before `count()`.

**No change needed** to `normalise_substances.R`.

**Result:** `tmp_raw_substances.csv` will contain individual substance strings matching what the app processes, so CLI queue numbers and app queue numbers will agree.

---

## Task 2: Fix `product_search` blocking observe

**Files:** `app.R`

**Problem (lines ~3151–3153):**
```r
observe({
  req(rv$data)
  # updateSelectizeInput(session, "product_search",
  #                      choices = extract_product_substance_choices(rv$data), server = TRUE)
```
`extract_product_substance_choices` calls `normalise_substances()` with fuzzy `stringdist` against 98k rows for every unique substance in the session. Blocks the R session.

**Proper fix:** Run substance normalisation once inside `prepare_trial_data()` and store the result as a `substance_label` column on `rv$data`. The observe then becomes a plain vector read.

**Steps:**

1. **In `prepare_trial_data()`** (around lines 1916–1938): after the existing substance processing block that builds `sub_log`, compute `substance_label` per trial row:
   - For each row: take `DIMP_inn_name` (fallback `DIMP_product_name`)
   - Split on ` / ` (multi-substance strings)
   - Normalise each component via `normalise_substances()` (already happens for `sub_log`)
   - Recombine normalised components with `|`
   - Store as `substance_label` column

   The `sub_log` computation already does the heavy work; deduplicate so normalisation only runs once per unique raw value (it already works on unique values internally).

2. **Update the observe** (around line 3151):
   ```r
   observe({
     req(rv$data)
     updateSelectizeInput(session, "product_search",
                          choices = sort(unique(rv$data$substance_label)),
                          server = TRUE)
   })
   ```

3. **Remove dead code** from `app.R`:
   - `resolve_substance_label()` wrapper function
   - `extract_product_substance_choices()` function
   - `is_exploratory_substance()` function (if it only served the old flow)

   Verify by grepping for all call sites before deleting.

**Key constraint:** `prepare_trial_data()` must not call `normalise_substances()` more than once per unique raw value. The function already deduplicates internally (`unique()` at batch entry) so this is safe.

---

## Task 3: Create gold-standard test fixture

**File:** `tests/fixtures/substance_normalisation_gold.csv`

**Purpose:** Regression guard. Any future change to `normalise_substances.R` that breaks these cases will be immediately visible.

**Schema:**
```csv
raw_substance,expected_substance,expected_status
```

**Minimum cases to include:**

| Category | Count | Examples |
|----------|-------|---------|
| Obvious brand names | 20 | Humira→adalimumab, Keytruda→pembrolizumab, Opdivo→nivolumab |
| INNs (already canonical) | 20 | Pembrolizumab, secukinumab, rituximab |
| Brands with strength/form | 10 | "Humira 40 mg solution for injection"→adalimumab |
| Combination products | 5 | Biktarvy→bictegravir\|emtricitabine\|tenofovir alafenamide |
| Placebo variants | 5 | Placebo, Placebo for Humira, Placebo excipient composition |
| Non-substances (reject) | 10 | LPA1 antagonist, Toothpaste (cosmetic product), Blinded to test product |
| Research codes (unknown) | 5 | AMG 386, AIN457, PF-04965842 |
| Malformed (dose glued) | 5 | Gemcitabine100 mg→gemcitabine |

Total: ~80 cases. Generate by running the pipeline against the known inputs and spot-checking accepted results.

---

## Task 4: Substance Curation CLI Tool

**New file:** `helper_scripts/substance_norm_pipeline/curate_substances.R`

**Pattern:** Modelled on `sponsor_curation/review_sponsor_aliases.R` — interactive, resumable, saves decisions immediately.

### What it does

Presents rows from `substance_review_queue.csv` one at a time (sorted by `n_occurrences` descending — highest-impact cases first). For each row the user decides what to do, and the decision is written back to the queue CSV immediately (no lost work on quit).

### Display per row

```
==========================================================================
Row 12 / 3584 | n_occurrences: 6
Raw substance:      AMG 386
Suggested clean:    trebananib
Match status:       review
Match score:        64
Match source:       chembl
Match reason:       alias match (trade_name): 'amg 386' → 'trebananib'
--------------------------------------------------------------------------
a = accept suggested   r = reject (add to negatives)   o = override
s = skip               q = quit and save
```

### Decisions

| Key | Action | Output |
|-----|--------|--------|
| `a` | Accept suggested `active_substance_clean` | Sets `decision=accepted`, `canonical_substance=active_substance_clean` in queue |
| `r` | Reject — this is not a substance | Prompts for reason, sets `decision=rejected`; row written to `negative_aliases.csv` |
| `o` | Override — use a different canonical name | Prompts for the correct canonical substance; sets `decision=accepted`, `canonical_substance=<override>` |
| `s` | Skip — defer to later | Sets `decision=skipped` in queue; will reappear with `--include-skipped` |
| `q` | Quit and save | All decisions written to queue CSV; exits cleanly |

### Resumption

On startup: load queue, skip rows where `decision` is already one of `accepted`, `rejected`, `override`. Report counts:
```
Substance review queue
  Total rows:       3584
  Already decided:   142
  Remaining:        3442
  Showing up to:      50 (sorted by n_occurrences desc)
```

### Post-session export

After quitting, optionally run `--export` to write decided rows back into config files:
- `decision=accepted` (with overridden canonical) → appended to `manual_substance_overrides.csv`
- `decision=rejected` → appended to `negative_aliases.csv`

Or export is handled by a separate script (like `apply_sponsor_aliases.R`) for safety.

### CLI usage

```bash
# Interactive review (up to 50 rows)
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R

# Review up to 100 rows
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R 100

# Include previously skipped rows
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --include-skipped

# Export decisions to config files
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --export
```

### Key implementation details (from sponsor curation pattern)

- Script finds its own path via `commandArgs(FALSE)` so it works regardless of working directory.
- All decisions written immediately (after each keypress), not buffered until quit.
- Decision log: updates the `decision` and `canonical_substance` and `comment` columns in `substance_review_queue.csv` in-place (no separate decisions CSV needed — the queue already has these columns).
- `--export` flag reads the queue, filters `decision %in% c("accepted", "rejected")`, and appends to the appropriate config CSVs, then reports counts.

---

## Execution Order

1. **Task 1** — `export_raw_substances.R` fix (trivial, ~5 min)
2. **Task 4** — Curation CLI tool (standalone new file, no app.R risk)
3. **Task 2** — `product_search` observe fix (largest; read app.R carefully around lines 1916–1938 and 3151 before touching)
4. **Task 3** — Gold-standard fixture (after Task 2, use post-fix pipeline output)

---

## Critical Files

| File | Task | Action |
|------|------|--------|
| `helper_scripts/substance_norm_pipeline/export_raw_substances.R` | Task 1 | Edit |
| `helper_scripts/substance_norm_pipeline/curate_substances.R` | Task 4 | Create new |
| `app.R` lines ~146–154, ~1916–1938, ~3151–3153 | Task 2 | Edit |
| `config/substance_norm_pipeline/substance_review_queue.csv` | Task 4 | Read/write decisions |
| `config/substance_norm_pipeline/manual_substance_overrides.csv` | Task 4 export | Append |
| `config/substance_norm_pipeline/negative_aliases.csv` | Task 4 export | Append |
| `tests/fixtures/substance_normalisation_gold.csv` | Task 3 | Create new |

## Verification

- **Task 1:** Re-run `export_raw_substances.R` + `normalise_substances.R --write-queue`. Confirm multi-substance strings (e.g. `Cisplatin / Pemetrexed`) no longer appear as single rows in `tmp_raw_substances.csv`.
- **Task 4:** Run `curate_substances.R`, make a few decisions, quit, re-run — confirm it resumes from the right row and skips decided rows. Run `--export`, confirm config files are updated correctly.
- **Task 2:** Launch app, confirm `product_search` dropdown populates without hanging. Check `rv$data$substance_label` has reasonable values.
- **Task 3:** Source `normalise_substances.R`, run against fixture rows, confirm all expected cases pass.
