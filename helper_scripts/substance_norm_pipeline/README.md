# Substance Normalisation Pipeline

Converts raw `raw_substance` strings from clinical trial registries into clean,
auditable `active_substance_clean` values.

## Architecture

The pipeline runs in three stages:

```
rebuild_cache.R
  │
  ├─ 1. Cache build  (source app.R → prepare_trial_data → trials_cache.rds)
  │
  ├─ 2. Substance export  (export_trial_substances.R)
  │        reads  trials_cache.rds
  │        writes data/trial_substances_raw.csv  (_id, raw_substance)
  │
  └─ 3. Normalisation  (build_substance_labels.R)
           reads  data/trial_substances_raw.csv
           writes data/trial_substance_labels.csv   (_id, substance_label)
                  data/substance_normalisation_log.csv
                  config/substance_norm_pipeline/substance_review_queue.csv

app.R startup
  └─ prepare_trial_data() reads data/trial_substance_labels.csv
     left-joins to trials data → rv$data$substance_label
     (falls back to inline normalisation if file is absent)
```

Substance normalisation runs once per cache rebuild, not on every session start.

## Quick start: run the full pipeline

```bash
# 1 — export raw substances from cache
Rscript helper_scripts/substance_norm_pipeline/export_trial_substances.R

# 2 — normalise and build labels (+ update review queue)
Rscript helper_scripts/substance_norm_pipeline/build_substance_labels.R --write-queue

# 3 — inspect results
head data/trial_substance_labels.csv
wc -l config/substance_norm_pipeline/substance_review_queue.csv
```

Or run everything via `rebuild_cache.R` which chains all three steps automatically.

## Quick start: use the normaliser in R

```r
source("helper_scripts/substance_norm_pipeline/normalise_substances.R")

cfg    <- load_substance_configs()
result <- normalise_substances(
  c("Humira 40 mg solution for injection", "Placebo", "LPA1 antagonist"),
  configs = cfg
)
```

Output:

| raw_substance | active_substance_clean | match_status | match_score |
|---|---|---|---|
| Humira 40 mg solution for injection | Adalimumab | accepted | 99 |
| Placebo | Placebo | accepted | 100 |
| LPA1 antagonist | NA | rejected | 100 |

## File layout

```text
helper_scripts/substance_norm_pipeline/
  normalise_substances.R       core pipeline — source and call normalise_substances()
  build_substance_index.R      fetches EPAR + ChEMBL, writes substance_alias_index.csv
  export_raw_substances.R      CLI test helper — extracts deduped substances for ad-hoc runs
  export_trial_substances.R    cache-build step — exports _id + raw_substance pairs
  build_substance_labels.R     normalises and writes trial_substance_labels.csv
  curate_substances.R          interactive CLI for manual queue review (save/resume)

config/substance_norm_pipeline/
  substance_alias_index.csv        generated — run build_substance_index.R to create
  canonical_substances.csv         hand-curated INN list + salt → parent mappings
  manual_brand_to_substance.csv    hand-curated brand/combination → substance mappings
  manual_substance_overrides.csv   per-raw-string corrections (and curation exports)
  negative_aliases.csv             strings that must never be normalised as substances
  ambiguous_substance_aliases.csv  generated — aliases that map to >1 substance
  substance_review_queue.csv       generated during cache rebuild — rows needing review

data/  (generated, not version-controlled)
  trial_substances_raw.csv         _id + raw_substance pairs from cache
  trial_substance_labels.csv       _id + substance_label — read by app.R at startup
  substance_normalisation_log.csv  full normalisation log for preprocessing.Rmd

tests/fixtures/
  substance_normalisation_gold.csv  79 gold-standard test cases (79/79 passing)
```

`substance_alias_index.csv` must be generated before the app runs. All other config
files are hand-maintained and version-controlled.

## Generating the alias index

```bash
# Full run (EPAR + ChEMBL, ~10 min due to ChEMBL pagination)
Rscript helper_scripts/substance_norm_pipeline/build_substance_index.R

# EPAR only (faster, ~1 min)
Rscript helper_scripts/substance_norm_pipeline/build_substance_index.R --no-chembl
```

Outputs:
- `config/substance_norm_pipeline/substance_alias_index.csv` — required at runtime
- `config/substance_norm_pipeline/ambiguous_substance_aliases.csv` — review these

## Pipeline steps (per raw string)

Every raw value passes through these steps in order. First match wins.

| Step | What it checks | Returns |
|---|---|---|
| 1 | Contains "placebo" | `active_substance_clean = "placebo"`, `accepted` |
| 2 | Matches `manual_substance_overrides.csv` | Override value, status from file |
| 3 | Matches `negative_aliases.csv` | `NA`, `rejected` |
| 4 | Hard-coded reject pattern (device, cosmetic, mechanism, strain) | `NA`, `rejected` |
| 5 | Candidate matches `canonical_substances.csv` | Canonical INN, `accepted` |
| 6 | Candidate matches `substance_alias_index.csv` | Mapped INN, `accepted` or `review` |
| 7 | Conservative fuzzy (Jaro-Winkler ≥ 0.80, length ≥ 6) | Fuzzy match, `review` |
| 8 | Nothing matched | `NA`, `unknown` |

**Candidate generation:** each raw string produces multiple candidates — raw
lowercased, dose-stripped, form-stripped, first token. All candidates are tried at
each step; the best match wins.

**Output invariant:** `active_substance_clean` is always free of dose amounts, units,
and formulation/route terms (`sanitise_substance_output()` on every exit path).

## Match statuses

| Status | Meaning |
|---|---|
| `accepted` | High-confidence match; safe to use downstream |
| `review` | Plausible but not auto-accepted (ambiguous alias, low fuzzy score) |
| `rejected` | Known non-substance: device, cosmetic, mechanism phrase, blinding text |
| `unknown` | No match found; `active_substance_clean` is `NA` |

## Output schema (`normalise_substances()`)

```r
tibble(
  raw_substance,            # original input
  active_substance_clean,   # normalised INN or "placebo"; NA if unknown/rejected
  active_substance_parent,  # parent moiety for salts (NA if not in canonical list)
  match_status,             # accepted | review | rejected | unknown
  match_score,              # 0-100 (100 = exact; lower = fuzzy/stripped candidate)
  match_source,             # canonical | alias_index | manual | fuzzy:* | ...
  match_reason              # human-readable explanation
)
```

## Reviewing the queue

After a cache rebuild, `substance_review_queue.csv` contains all `review`/`unknown`
rows sorted by frequency. Use the interactive curation tool:

```bash
# Review top 50 rows (default)
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R

# Review top 100 rows
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R 100

# Re-show previously skipped rows
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --include-skipped

# Write decisions to config files
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --export
```

Decisions (accept / reject / override / skip) are saved immediately to the queue CSV
and can be resumed across sessions.

`--export` writes:
- `decision=accepted` rows → `manual_substance_overrides.csv`
- `decision=rejected` rows → `negative_aliases.csv`

After exporting, re-run the full pipeline to apply the decisions.

## Maintaining config files

### Add a brand name

Edit `config/substance_norm_pipeline/manual_brand_to_substance.csv`:

```csv
alias_clean,substance_clean,alias_type,source,confidence_prior
kisqali femara,ribociclib|letrozole,combination_brand,manual,1.00
```

- `alias_clean`: lowercase, no ®/™
- `substance_clean`: INN; use `|` for combinations
- `alias_type`: `manual_brand` | `combination_brand`
- `confidence_prior`: 1.00 for hand-verified entries

### Add a hard reject

Edit `config/substance_norm_pipeline/negative_aliases.csv`:

```csv
alias_clean,reason
standard chemotherapy,non-specific treatment phrase
```

### Correct a specific raw string

Edit `config/substance_norm_pipeline/manual_substance_overrides.csv`:

```csv
raw_clean,substance_clean,match_status,reason
gemcitabine100 mg,gemcitabine,accepted,dose glued to INN
```

### Add a salt → parent mapping

Edit `config/substance_norm_pipeline/canonical_substances.csv`:

```csv
substance_clean,parent_substance,substance_type,source
acalabrutinib maleate,acalabrutinib,salt,manual
```

## Integration with app.R

`app.R` contains no substance cleaning logic. At startup `prepare_trial_data()`:

1. Checks for `data/trial_substance_labels.csv` (built by `build_substance_labels.R`)
2. If found: reads and left-joins to `rv$data` → populates `rv$data$substance_label`
3. If not found: runs inline normalisation as fallback (slower; warns to rebuild)

The `product_search` dropdown is populated directly from `rv$data$substance_label`
(a plain vector read, no runtime normalisation). Filtering uses
`matches_substance_label()` which checks the pre-computed column.

`resolve_substance_label()` is retained for the analytics tabs (PIP waiver,
active substances) which normalise on the filtered data view at render time.

## Running normalise_substances.R from the command line

```bash
# Normalise a CSV and write queue
Rscript helper_scripts/substance_norm_pipeline/normalise_substances.R \
  --input=tmp_raw_substances.csv \
  --output=tmp_normalised.csv \
  --write-queue

# Disable fuzzy matching
Rscript helper_scripts/substance_norm_pipeline/normalise_substances.R \
  --input=tmp_raw_substances.csv \
  --output=tmp_normalised.csv \
  --no-fuzzy
```

Input CSV must have a `raw_substance` column (and optionally `n_trials`).
