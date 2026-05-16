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

Downloads external name sources and merges them with `manual_sponsor_aliases.csv` and accepted review-queue decisions to produce `sponsor_alias_index.csv`. Run after adding new manual aliases, after accepting review-queue decisions, or when the EPAR dataset is updated. The DB tiers require `data/trials.sqlite`; override the path with the `DB_PATH` environment variable.

**Sources (priority order):**

| Source | Flag to skip | Confidence | Coverage |
| ------ | ------------ | ---------- | -------- |
| `manual_sponsor_aliases.csv` | always included | 1.00 | seed |
| `sponsor_llm_reviewed.csv` | always included | 1.00 | accepted review-queue decisions |
| EMA EPAR MAH names | `--no-epar` | 0.85 | industry |
| ROR (academic/hospital variants) | `--no-ror` | 0.75 | EU institutions |
| CTIS `businessKey` EMA org IDs | `--no-businesskey` | 0.95 | CTIS only |
| EUCTR email domain | `--no-email` | 0.85 | EUCTR, 74% coverage |
| Postcode + country + JW ≥ 0.88 | `--no-location` | 0.70 | both registers |

Within accepted review-queue decisions, `llm_reviewed` overrides `bulk_reviewed`
for the same `alias_clean`.

After all source rows are merged, a final canonicalization pass applies
`final_sponsor_canonical_map.csv`, `final_sponsor_family_map.csv`, and
conservative automatic label-variant collapses. Borderline clusters are written
to `final_sponsor_canonical_review.csv` for manual review before being added to
one of the final maps.

Latest recommended rebuild (`--no-ror`, EPAR + full DB): 12,751 alias-index
rows, 12,564 unique aliases, 8,367 canonical sponsor labels, and 156 remaining
exact alias conflicts after final canonicalization.

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
- `config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv` — accepted `sponsor_review_queue.csv` rows; merged into the alias index without editing the manual seed file
- `config/sponsor_norm_pipeline/final_sponsor_canonical_map.csv` — final label-to-label canonical map applied after all sources are merged
- `config/sponsor_norm_pipeline/final_sponsor_family_map.csv` — entity-key family decisions applied to single-entity labels after explicit final maps
- `config/sponsor_norm_pipeline/final_sponsor_canonical_review.csv` — unresolved final label clusters for alphabetical manual review
- `config/sponsor_norm_pipeline/sponsor_ambiguous_aliases.csv` — aliases that map to more than one canonical sponsor
- `config/sponsor_norm_pipeline/new_sponsor_candidates.csv` — unmatched EPAR MAH names for manual review
- `config/sponsor_norm_pipeline/ctis_org_candidates.csv` — CTIS businessKey groups with no known canonical; one row per EMA organisation, with `suggested_canonical`, `other_names`, and `n_variants` for review

When `sponsor_alias_index.csv` does not yet exist, `normalise_sponsors.R` falls back to `manual_sponsor_aliases.csv` plus `sponsor_llm_reviewed.csv` automatically.

---

### Step 2b — Review final sponsor canonicals

```bash
# Inspect generated final-label clusters
open config/sponsor_norm_pipeline/final_sponsor_canonical_review.csv

# After adding accepted decisions to final_sponsor_canonical_map.csv
# or final_sponsor_family_map.csv:
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror
```

`final_sponsor_canonical_map.csv` has schema:

```csv
sponsor_clean_from,sponsor_clean_to,sponsor_parent_to,sponsor_group_to,sponsor_type_to,reason
```

`final_sponsor_family_map.csv` has schema:

```csv
entity_key,sponsor_clean_to,sponsor_parent_to,sponsor_group_to,sponsor_type_to,reason
```

Each family-map row is a curated canonical decision for one anchor entity key.
During index rebuild, the pipeline also derives related keys from the target
sponsor's existing high-confidence aliases and labels. That keeps family logic
generic: the code does not special-case individual organisations.

Current seeded decisions:

- `Fundacion Geltamo` → `GELTAMO`
- `GELA Group` → `GELA`
- entity key `radboud` → `Radboudumc`; related keys are generated from existing `Radboudumc` aliases

The final pass also auto-collapses safe label variants:

- accepted entity-family keys, excluding combined multi-entity labels,
- case/accent/punctuation-only variants,
- stripped legal/group/foundation-token variants,
- very-high Jaro-Winkler label similarity (`>= 0.985`) when sponsor types are compatible and acronym guards pass.

Risky clusters stay in `final_sponsor_canonical_review.csv`; accepted
label-to-label rows should be copied into `final_sponsor_canonical_map.csv`,
and accepted broader entity-family decisions should be copied into
`final_sponsor_family_map.csv`, rather than editing `sponsor_alias_index.csv`
directly.

---

### Step 3 — Normalise and build trial labels

```bash
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R --write-queue
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_labels.R --write-queue --allow-fuzzy
```

Reads `trial_sponsors_raw.csv`, runs `normalise_sponsors()`, writes:
- `data/trial_sponsor_labels.csv` — one row per trial with sponsor fields
- `data/sponsor_normalisation_log.csv` — full audit log (for preprocessing.Rmd)
- `config/sponsor_norm_pipeline/sponsor_review_queue.csv` — if `--write-queue` is passed

The label build is deterministic by default: exact alias matches and high-confidence
token containment can produce accepted labels, while the slower fuzzy stage is
opt-in via `--allow-fuzzy` and only emits review suggestions.

---

### Step 4 — Interactive curation

For the detailed manual/LLM-assisted curation protocol, see
`AGENTS/sponsor_manual_curation.md`. That handover note contains the review
rules, duplicate checks, comment conventions, manual alias row format, and
chunk-by-chunk curation progress. The short section below only documents the
CLI commands.

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

`--export` writes manual decisions to config files. Accepted queue rows are exported to `sponsor_llm_reviewed.csv` by Step 2 and included in the next `sponsor_alias_index.csv`. After exporting or accepting queue rows, re-run Step 2, then Step 3.

---

### Test the normaliser

```bash
Rscript helper_scripts/sponsor_norm_pipeline/normalise_sponsors.R \
  --input=tests/fixtures/sponsor_normalisation_gold.csv \
  --output=/tmp/out.csv \
  --config-dir=config/sponsor_norm_pipeline \
  --no-fuzzy
```

All 101 gold cases should pass.

---

## Materials And Methods Text

The following text summarizes the sponsor-normalisation workflow in a form suitable for adaptation into a manuscript methods section.

### Sponsor Name Normalisation

Sponsor names were harmonised using a reproducible normalisation pipeline implemented in R. The pipeline itself is deterministic when run from the saved configuration files, but part of the alias table was created through LLM-assisted human review of queued sponsor strings. Raw sponsor strings were extracted from the trial cache separately for EU Clinical Trials Register (EUCTR) and Clinical Trials Information System (CTIS) records and reduced to one primary sponsor string per trial. Each raw sponsor string was transliterated to Latin ASCII, converted to lower case, normalized for punctuation and whitespace, and expanded for common symbols such as ampersands. Candidate lookup keys were generated from the full cleaned string and from progressively simplified variants, including address-stripped, legal-suffix-stripped, research-and-development-token-stripped, prefix-token, first-word, first-two-word, and trailing-acronym forms.

The canonical sponsor index was built from multiple evidence sources in priority order. First, a manually curated alias table captured high-frequency pharmaceutical companies, cooperative groups, hospitals, universities, and known sponsor acronyms. Second, accepted review-queue decisions, including LLM-assisted decisions that were retained as explicit CSV rows, were exported to a separate reviewed-alias table and merged into the index without altering the manual seed table. Third, external and registry-derived evidence was added: European Medicines Agency marketing authorisation holder names from the EPAR medicines report, Research Organization Registry variants for academic and hospital organisations, CTIS organisation `businessKey` groups, EUCTR sponsor email-domain groups, and postcode-country groups shared across CTIS and EUCTR. The CTIS `businessKey` was treated as definitive evidence that names belonged to the same registered organisation. Email-domain and postcode-country sources were used only with additional safeguards, including shared-infrastructure domain exclusions, discriminative token-overlap requirements, and Jaro-Winkler similarity thresholds, to reduce false-positive merges.

The merged alias index was then passed through a final canonicalisation step that operated on sponsor labels and alias-derived entity keys. This step applied hand-maintained label-to-label and entity-family maps for known canonical choices, plus safe automatic collapses for case, accent, punctuation, legal suffix, group/foundation-token, and very-high-similarity label variants. Ambiguous, combined-sponsor, or higher-risk final-label clusters were written to a review table for manual assessment rather than applied automatically. The generated sponsor alias index was therefore treated as an output artifact; curation decisions were made in source configuration files and propagated by rebuilding the index.

For each trial sponsor, matching proceeded in a fixed order: exact manual override, negative placeholder alias, exact alias lookup, conservative fuzzy lookup, and finally an unmatched/unknown result. Exact alias matches were accepted when the confidence-adjusted score was at least 90; lower-confidence exact matches and all fuzzy matches were marked for review. Fuzzy matching used Jaro-Winkler similarity with a threshold of 0.92 and was blocked for generic standalone tokens such as “university”, “hospital”, or “centre”. Sponsor type was derived preferentially from the trial record’s commercial/non-commercial flag when available; otherwise, it fell back to a rule-based classifier that assigned industry, academic, hospital, cooperative group, foundation, public body, charity, or unknown categories from sponsor-name tokens.

Curation was supported by two review files. The sponsor review queue contained unmatched or review-status raw sponsor strings, ranked by the number of affected trials, and allowed accept, reject, override, or skip decisions; some accepted decisions were generated with LLM assistance and preserved with source labels in the reviewed-alias table. Accepted queue decisions were exported to the reviewed-alias table and included in subsequent index builds. A separate final-canonical review file captured unresolved canonical-label clusters after all source-specific evidence had been merged. All 1,076 rows in this file were reviewed line by line: 982 rows were accepted and written to the final canonical map (8 rows) or the entity-family map (971 rows); 61 rows were blocked as confirmed multi-entity clusters; and 33 rows were manually rejected because the suggested canonical conflated distinct legal entities (university vs. teaching hospital, cross-city hospital matches, or generic department names without an institutional anchor). Accepted final-label decisions were added to the final canonical map and then propagated through a rebuild.

The current recommended rebuild used EPAR and all local database-derived tiers while omitting the slower ROR query (`build_sponsor_index.R --no-ror`). This produced 12,751 alias-index rows, 12,564 unique aliases, 8,367 canonical sponsor labels, and 156 remaining exact alias conflicts after final canonicalisation. The final canonicalisation step reduced 8,883 intermediate sponsor labels to 8,367 final labels. As examples, `GELA`, `GELA Group`, and `GELA-Recherche Clinique` all resolve to `GELA`, while `Fundacion Geltamo` resolves to `GELTAMO`. The normaliser fixture now contains 101 manually specified examples covering major pharmaceutical companies, hospitals, cooperative groups, placeholder strings, final-canonicalisation cases, and Radboud entity-family cases.

---

## Config files (`config/sponsor_norm_pipeline/`)

| File | Purpose |
|------|---------|
| `manual_sponsor_aliases.csv` | Primary lookup table. Seeded with ~180 big pharma, cooperative group, and academic/hospital entries. Grows via curation. |
| `sponsor_llm_reviewed.csv` | Generated from accepted queue rows. Included in `sponsor_alias_index.csv` without bloating the manual seed file. |
| `final_sponsor_canonical_map.csv` | Final label-to-label canonical decisions applied after all source-specific alias evidence has been merged. |
| `final_sponsor_family_map.csv` | Final entity-key family decisions for app-facing canonical merges across aliases and labels. |
| `final_sponsor_canonical_review.csv` | Generated queue of final label/entity clusters, including `auto`, `review`, and `blocked` buckets. |
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
- **Final canonical labels are post-merge decisions**: use `final_sponsor_canonical_map.csv` for label-to-label cleanup such as `GELA Group` → `GELA`; keep upstream review/manual evidence untouched.
- **Fuzzy matching is conservative**: Jaro-Winkler threshold 0.92, blocked entirely for candidates that consist of generic standalone tokens (university, hospital, center, etc.).
- **When in doubt**: `match_status = "unknown"` or `"review"` — never invent a canonical sponsor.

---

## Normalisation matching order

1. Manual override (exact raw string) — always wins
2. Negative alias (placeholder check) → `rejected`
3. Exact alias match → `accepted` (score ≥ 90) or `review`
4. Conservative fuzzy (Jaro-Winkler ≥ 0.92) → `review`
5. Fallback → `unknown`
