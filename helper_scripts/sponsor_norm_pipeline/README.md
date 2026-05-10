# Sponsor Normalisation Pipeline

Mirrors the substance normalisation pipeline. Converts raw sponsor name strings from the trial cache into auditable, structured sponsor labels stored in `data/trial_sponsor_labels.csv`. The Shiny app reads this file at startup — no normalisation happens at runtime.

---

## Workflow (run in order)

### Step 1 — Export raw sponsors from cache

```bash
Rscript helper_scripts/sponsor_norm_pipeline/export_trial_sponsors.R
```

Reads `trials_cache.rds`, extracts the primary sponsor name for each trial (EUCTR and CTIS fields), writes `data/trial_sponsors_raw.csv`.

---

### Step 2 — Build alias index from external databases

```bash
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R          # manual + EPAR + ROR
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror  # manual + EPAR only
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-epar # manual + ROR only
```

Downloads external name sources and merges them with `manual_sponsor_aliases.csv` to produce `sponsor_alias_index.csv`. Run after adding new manual aliases or when the EPAR dataset is updated.

**Sources:**
- `manual_sponsor_aliases.csv` — always included (confidence 1.00, highest priority)
- EMA EPAR Marketing Authorisation Holders — MAH name variants for sponsors already in the manual table (confidence 0.85)
- ROR (Research Organization Registry) — academic/hospital name variants for EU institutions already in the manual table (confidence 0.75)

**Outputs:**
- `config/sponsor_norm_pipeline/sponsor_alias_index.csv` — merged alias table used by `normalise_sponsors.R`
- `config/sponsor_norm_pipeline/sponsor_ambiguous_aliases.csv` — aliases that map to more than one canonical sponsor
- `config/sponsor_norm_pipeline/new_sponsor_candidates.csv` — unmatched external names for manual review

When `sponsor_alias_index.csv` does not yet exist, `normalise_sponsors.R` falls back to `manual_sponsor_aliases.csv` automatically.

---

### Step 3 — Normalise and build trial labels

```bash
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R --write-queue
```

Reads `trial_sponsors_raw.csv`, runs `normalise_sponsors()`, writes:
- `data/trial_sponsor_labels.csv` — one row per trial with sponsor fields
- `data/sponsor_normalisation_log.csv` — full audit log (for preprocessing.Rmd)
- `config/sponsor_norm_pipeline/sponsor_review_queue.csv` — if `--write-queue` is passed

---

### Step 4 — Interactive curation

```bash
Rscript helper_scripts/sponsor_norm_pipeline/curate_sponsors.R [N]
Rscript helper_scripts/sponsor_norm_pipeline/curate_sponsors.R --include-skipped
Rscript helper_scripts/sponsor_norm_pipeline/curate_sponsors.R --export
```

Reviews `sponsor_review_queue.csv` sorted by `n_trials` descending.

| Key | Action |
|-----|--------|
| `a` | Accept suggested canonical sponsor |
| `r` | Reject (adds to `sponsor_negative_aliases.csv` on `--export`) |
| `o` | Override with a different canonical sponsor |
| `s` | Skip (deferred; re-shown with `--include-skipped`) |
| `q` | Quit and save progress |

`--export` writes decisions to config files. After exporting, re-run Step 3.

---

### Test the normaliser

```bash
Rscript helper_scripts/sponsor_norm_pipeline/normalise_sponsors.R \
  --input=tests/fixtures/sponsor_normalisation_gold.csv \
  --output=/tmp/out.csv \
  --config-dir=config/sponsor_norm_pipeline \
  --no-fuzzy
```

All 89 gold cases should pass.

---

## Config files (`config/sponsor_norm_pipeline/`)

| File | Purpose |
|------|---------|
| `manual_sponsor_aliases.csv` | Primary lookup table. Seeded with ~180 big pharma, cooperative group, and academic/hospital entries. Grows via curation. |
| `manual_sponsor_overrides.csv` | Exact raw-string corrections. Populated by `curate_sponsors.R --export`. Takes priority over aliases. |
| `sponsor_negative_aliases.csv` | Placeholders that must never resolve to a sponsor (unknown, N/A, etc.). |
| `sponsor_review_queue.csv` | Generated at build time. Contains all `review` and `unknown` rows sorted by `n_trials`. |

---

## Output schema (`data/trial_sponsor_labels.csv`)

| Column | Description |
|--------|-------------|
| `_id` | Trial identifier |
| `sponsor_clean` | Canonical sponsor name (e.g. `MSD`, `Roche`, `Amsterdam UMC`) |
| `sponsor_parent` | Parent company or university system |
| `sponsor_group` | Broader analytical grouping (e.g. `MSD / Merck & Co.`) |
| `sponsor_type` | `industry`, `academic`, `hospital`, `cooperative_group`, `foundation`, `public_body`, `charity`, or `unknown` |
| `match_status` | `accepted` or `review` |

---

## Key rules

- **MSD ≠ Merck KGaA**: "Merck Sharp & Dohme" and "MSD" → `MSD / Merck & Co.`; "Merck KGaA" and "Merck Serono" → `Merck KGaA / EMD Serono`. Never collapsed.
- **Academic/hospital names are not auto-shortened**: "University Hospital Tübingen" stays as-is unless there is an explicit alias.
- **Acronyms only when manually curated**: GSK, BMS, MSD, EORTC, HOVON etc. are in the alias table. Unknown short strings are not auto-mapped.
- **Fuzzy matching is conservative**: Jaro-Winkler threshold 0.92, blocked entirely for candidates that consist of generic standalone tokens (university, hospital, center, etc.).
- **When in doubt**: `match_status = "unknown"` or `"review"` — never invent a canonical sponsor.

---

## Normalisation matching order

1. Manual override (exact raw string) — always wins
2. Negative alias (placeholder check) → `rejected`
3. Exact alias match → `accepted` (score ≥ 90) or `review`
4. Conservative fuzzy (Jaro-Winkler ≥ 0.92) → `review`
5. Fallback → `unknown`
