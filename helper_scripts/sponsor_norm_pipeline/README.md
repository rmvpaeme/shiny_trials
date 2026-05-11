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
# Recommended: EPAR + all DB tiers, skip slow ROR API
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror

# Full run (adds ~43 ROR aliases, takes several extra minutes):
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R

# DB tiers only (fastest, no network):
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-epar --no-ror

# Skip DB tiers (e.g. no local database available):
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-db
```

Downloads external name sources and merges them with `manual_sponsor_aliases.csv` to produce `sponsor_alias_index.csv`. Run after adding new manual aliases or when the EPAR dataset is updated. The DB tiers require `data/trials.sqlite`; override the path with the `DB_PATH` environment variable.

**Sources (priority order):**

| Source | Flag to skip | Confidence | Coverage |
| ------ | ------------ | ---------- | -------- |
| `manual_sponsor_aliases.csv` | always included | 1.00 | seed |
| EMA EPAR MAH names | `--no-epar` | 0.85 | industry |
| ROR (academic/hospital variants) | `--no-ror` | 0.75 | EU institutions |
| CTIS `businessKey` EMA org IDs | `--no-businesskey` | 0.95 | CTIS only |
| EUCTR email domain | `--no-email` | 0.85 | EUCTR, 74% coverage |
| Postcode + country + JW ≥ 0.88 | `--no-location` | 0.70 | both registers |

**CTIS businessKey** is ground truth: EMA's own organisation registry links name variants
that are definitively the same entity (e.g. "AstraZeneca AB" / "Astrazeneca AB",
"Princess Maxima Center" / "Prinses Maxima Centrum").

**EUCTR email domain** groups sponsors sharing a corporate email domain (e.g. `novartis.com`).
CRO domains and generic providers are blocked. Requires a discriminative token overlap
between the unresolved name and the canonical to prevent investigator-email false positives.

**Postcode + country** groups sponsors at the same registered address; only proposes an alias
when at least one name in the group already resolves to a known canonical.

**Outputs:**
- `config/sponsor_norm_pipeline/sponsor_alias_index.csv` — merged alias table used by `normalise_sponsors.R`
- `config/sponsor_norm_pipeline/sponsor_ambiguous_aliases.csv` — aliases that map to more than one canonical sponsor
- `config/sponsor_norm_pipeline/new_sponsor_candidates.csv` — unmatched EPAR MAH names for manual review
- `config/sponsor_norm_pipeline/ctis_org_candidates.csv` — CTIS businessKey groups with no known canonical; one row per EMA organisation, with `suggested_canonical`, `other_names`, and `n_variants` for review

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
