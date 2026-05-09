# Substance Normalisation

Converts raw `raw_substance` strings from clinical trial registries into clean, auditable `active_substance_clean` values.

## Quick start

```r
source("helper_scripts/normalise_substances.R")

cfg <- load_substance_configs()

result <- normalise_substances(
  c("Humira 40 mg solution for injection", "Placebo", "LPA1 antagonist"),
  configs = cfg
)
```

Output:

| raw_substance | active_substance_clean | match_status | match_score | match_source | match_reason |
|---|---|---|---|---|---|
| Humira 40 mg solution for injection | Adalimumab | accepted | 99 | manual | alias match (manual_brand): 'humira' → 'adalimumab' |
| Placebo | Placebo | accepted | 100 | placebo_rule | placebo rule |
| LPA1 antagonist | NA | rejected | 100 | pattern_reject | matched pattern: ^.+\bantagonist$ |

## File layout

```
helper_scripts/
  normalise_substances.R      main pipeline — source this, call normalise_substances()
  build_substance_index.R     fetches EPAR + ChEMBL, writes substance_alias_index.csv

config/
  substance_alias_index.csv   generated — run build_substance_index.R to create
  canonical_substances.csv    hand-curated INN list + salt → parent mappings
  manual_brand_to_substance.csv  hand-curated brand/combination → substance mappings
  manual_substance_overrides.csv per-raw-string corrections
  negative_aliases.csv        strings that must never be normalised as substances
  ambiguous_substance_aliases.csv  generated — aliases that map to >1 substance
  substance_review_queue.csv  generated during cache rebuild — rows needing review
```

`substance_alias_index.csv` is the only file that must be generated before the app can run. All other config files are hand-maintained and version-controlled.

## Generating the alias index

```bash
# Full run (EPAR + ChEMBL, takes ~10 min due to ChEMBL pagination)
Rscript helper_scripts/build_substance_index.R

# EPAR only (faster, ~1 min)
Rscript helper_scripts/build_substance_index.R --no-chembl
```

Outputs:
- `config/substance_alias_index.csv` — required at runtime
- `config/ambiguous_substance_aliases.csv` — review these; they map to multiple substances

## Pipeline steps

Every raw value passes through these steps in order. The first step that matches wins.

| Step | What it checks | Returns |
|---|---|---|
| 1 | Contains the word "placebo" (any context) | `active_substance_clean = "placebo"`, `accepted` |
| 2 | Matches a row in `manual_substance_overrides.csv` | Override value, status from file |
| 3 | Matches a row in `negative_aliases.csv` | `NA`, `rejected` |
| 4 | Matches a hard-coded reject pattern (device, cosmetic, mechanism class, strain) | `NA`, `rejected` |
| 5 | Candidate matches a row in `canonical_substances.csv` | Canonical INN, `accepted` |
| 6 | Candidate matches a row in `substance_alias_index.csv` | Mapped INN, `accepted` or `review` |
| 7 | Conservative fuzzy match (Jaro-Winkler ≥ 0.80, candidate length ≥ 6) | Fuzzy match, `review` |
| 8 | Nothing matched | `NA`, `unknown` |

**Candidate generation:** before lookup, each raw string produces multiple candidates — raw lowercased, dose-stripped, form-stripped, first token. All candidates are tried at each step; the best match wins.

**Output invariant:** `active_substance_clean` is always free of dose amounts, units, and formulation/route terms. This is enforced by `sanitise_substance_output()` on every exit path, regardless of what the alias index contains.

## Match statuses

| Status | Meaning |
|---|---|
| `accepted` | High-confidence match; safe to use downstream |
| `review` | Plausible but not auto-accepted (e.g. ambiguous alias, low fuzzy score) |
| `rejected` | Known non-substance: device, cosmetic, mechanism phrase, blinding text |
| `unknown` | No match found; `active_substance_clean` is `NA` |

## Output schema

```r
tibble(
  raw_substance,            # original input
  active_substance_clean,   # normalised INN or "placebo"; NA if unknown/rejected
  active_substance_parent,  # parent moiety for salts (e.g. "imatinib" for "imatinib mesylate")
  match_status,             # accepted | review | rejected | unknown
  match_score,              # 0–100 (100 = exact; lower = fuzzy or stripped candidate)
  match_source,             # which source matched: canonical | alias_index | manual | fuzzy:* | placebo_rule | …
  match_reason              # human-readable explanation
)
```

## Maintaining the config files

### Adding a brand name

Edit `config/manual_brand_to_substance.csv`:

```csv
alias_clean,substance_clean,alias_type,source,confidence_prior
kisqali femara,ribociclib|letrozole,combination_brand,manual,1.00
```

- `alias_clean`: lowercase, no ®/™
- `substance_clean`: INN; use `|` for combinations
- `alias_type`: `manual_brand` | `combination_brand`
- `confidence_prior`: 1.00 for hand-verified entries

### Adding a hard reject

Edit `config/negative_aliases.csv`:

```csv
alias_clean,reason
standard chemotherapy,non-specific treatment phrase
```

### Correcting a specific raw string

Edit `config/manual_substance_overrides.csv`:

```csv
raw_clean,substance_clean,match_status,reason
gemcitabine100 mg,gemcitabine,accepted,dose glued to INN
```

`raw_clean` is matched against the cleaned candidates (lowercased, dose/form stripped), not the original raw string.

### Adding a salt → parent mapping

Edit `config/canonical_substances.csv`:

```csv
substance_clean,parent_substance,substance_type,source
acalabrutinib maleate,acalabrutinib,salt,manual
```

`parent_substance` populates `active_substance_parent` in the output. If the substance is its own parent (simple INN), set `parent_substance = substance_clean`.

## Handling the review queue

After a cache rebuild, `config/substance_review_queue.csv` contains all rows with `match_status` of `review` or `unknown`, sorted by frequency.

Workflow:
1. Open the queue CSV
2. For each row, decide: accept, reject, or add a manual mapping
3. Feed the decision into the appropriate config file
4. Re-run `build_substance_index.R` if you added brand mappings
5. Re-run the cache rebuild to verify the queue shrinks

## Integration with app.R

`app.R` contains no substance cleaning logic. At startup it does:

```r
source("helper_scripts/normalise_substances.R", local = FALSE)
.substance_cfg <- load_substance_configs()

resolve_substance_label <- function(x) {
  result <- normalise_substances(as.character(x), configs = .substance_cfg)
  stringr::str_to_sentence(result$active_substance_clean)
}
```

`resolve_substance_label()` is the only call site used elsewhere in `app.R`. Its signature is unchanged from the previous implementation — all other call sites require no modification.

## Running from the command line

```bash
Rscript helper_scripts/normalise_substances.R \
  --input=data/raw_substances.csv \
  --output=data/normalised.csv \
  --write-queue

# Disable fuzzy matching
Rscript helper_scripts/normalise_substances.R \
  --input=data/raw_substances.csv \
  --output=data/normalised.csv \
  --no-fuzzy
```

Input CSV must have a `raw_substance` column. With `--write-queue`, a `substance_review_queue.csv` is also written to the config directory.
