# Sponsor Normalisation Pipeline

Mirrors the substance normalisation pipeline. Converts raw sponsor name strings from the trial cache into auditable, structured sponsor labels stored in `data/trial_sponsor_labels.csv`. The Shiny app reads this file at startup — no normalisation happens at runtime.

---

## Workflow (run in order)

### Step 1 — Export raw sponsors from cache

```bash
Rscript helper_scripts/sponsor_norm_pipeline/1_export_trial_sponsors.R
```

Reads `trials_cache.rds`, extracts the primary sponsor name for each trial (EUCTR and CTIS fields), writes `data/trial_sponsors_raw.csv`.

---

### Step 2 — Build alias index from external databases

```bash
# Recommended: EPAR + strong DB tiers, skip slow ROR and weak postcode evidence
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-ror --no-location

# Full run (adds ~43 ROR aliases, takes several extra minutes):
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-location

# DB tiers only (fastest, no network):
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-epar --no-ror

# Skip DB tiers (e.g. no local database available):
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-db
```

Downloads external name sources and merges them with `sponsor_llm_aliases.csv` and accepted review-queue decisions to produce `2_sponsor_alias_index.csv`. Run after adding new LLM-curated aliases, after accepting review-queue decisions, or when the EPAR dataset is updated. The DB tiers require `data/trials.sqlite`; override the path with the `DB_PATH` environment variable.

**Sources (priority order):**

| Source | Flag to skip | Confidence | Coverage |
| ------ | ------------ | ---------- | -------- |
| `sponsor_llm_aliases.csv` | always included | 1.00 | seed |
| `sponsor_llm_reviewed.csv` | always included | 1.00 | accepted review-queue decisions |
| EMA EPAR MAH names | `--no-epar` | 0.85 | industry |
| ROR (academic/hospital variants) | `--no-ror` | 0.75 | EU institutions |
| CTIS `businessKey` EMA org IDs | `--no-businesskey` | 0.95 | CTIS only |
| EUCTR email domain | `--no-email` | 0.85 | EUCTR, 74% coverage |
| Postcode + country + JW ≥ 0.88 | `--no-location` | review-only | both registers |

Within accepted review-queue decisions, `llm_reviewed` overrides `bulk_reviewed`
for the same `alias_clean`.

After all source rows are merged, a final canonicalization pass applies
`final_sponsor_canonical_map.csv`, `final_sponsor_family_map.csv`, and
conservative automatic label-variant collapses. Borderline clusters are written
to `2_final_sponsor_canonical_review.csv` for manual review before being added to
one of the final maps.

Latest recommended rebuild (`--no-ror --no-location`, EPAR + strong DB tiers):
~12,000 alias-index rows after Phase 9 alias curation (see below), 0 duplicate
alias_clean entries in `sponsor_llm_reviewed.csv`, and 54 undecided rows in
the review queue.

**CTIS businessKey** is ground truth: EMA's own organisation registry links name variants
that are definitively the same entity (e.g. "AstraZeneca AB" / "Astrazeneca AB",
"Princess Maxima Center" / "Prinses Maxima Centrum").

**EUCTR email domain** groups sponsors sharing a corporate email domain (e.g. `novartis.com`).
CRO domains and generic providers are blocked. Requires a discriminative token overlap
between the unresolved name and the canonical to prevent investigator-email false positives.

**Postcode + country** groups sponsors at the same registered address, but is
too weak for automatic app-facing labels. If enabled, candidates are written to
`2_postcode_sponsor_candidates.csv` for review and are not merged into
`2_sponsor_alias_index.csv`.

**Outputs:**
- `config/sponsor_norm_pipeline/2_sponsor_alias_index.csv` — merged alias table used by `normalise_sponsors.R`
- `config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv` — accepted `3_sponsor_review_queue.csv` rows; merged into the alias index without editing the LLM-curated seed file
- `config/sponsor_norm_pipeline/final_sponsor_canonical_map.csv` — final label-to-label canonical map applied after all sources are merged
- `config/sponsor_norm_pipeline/final_sponsor_family_map.csv` — entity-key family decisions applied to single-entity labels after explicit final maps
- `config/sponsor_norm_pipeline/2_final_sponsor_canonical_review.csv` — unresolved final label clusters for alphabetical manual review
- `config/sponsor_norm_pipeline/2_postcode_sponsor_candidates.csv` — optional postcode evidence for manual review only
- `config/sponsor_norm_pipeline/2_sponsor_ambiguous_aliases.csv` — aliases that map to more than one canonical sponsor
- `config/sponsor_norm_pipeline/2_new_sponsor_candidates.csv` — unmatched EPAR MAH names for manual review
- `config/sponsor_norm_pipeline/2_ctis_org_candidates.csv` — CTIS businessKey groups with no known canonical; one row per EMA organisation, with `suggested_canonical`, `other_names`, and `n_variants` for review

When `2_sponsor_alias_index.csv` does not yet exist, `normalise_sponsors.R` falls back to `sponsor_llm_aliases.csv` plus `sponsor_llm_reviewed.csv` automatically.

---

### Step 2b — Review final sponsor canonicals

```bash
# Inspect generated final-label clusters
open config/sponsor_norm_pipeline/2_final_sponsor_canonical_review.csv

# After adding accepted decisions to final_sponsor_canonical_map.csv
# or final_sponsor_family_map.csv:
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-ror --no-location
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

**Sizing the queue before working it.** `2_final_sponsor_canonical_review.csv`
has ~937 unapplied rows, but that count badly overstates the work. 861 are
`blocked`, and **836 of those contain only one distinct label** — a "merge
proposal" with nothing to merge, produced when a department-level alias key
(`aalborg orthopedics hospital`) resolves to the single correct canonical.
Unblocking them changes nothing. The genuine judgment calls are the **25 blocked
clusters with more than one label** plus the **76 `review` rows** — around 100
decisions, not 937. Filter before reading:

```r
b <- readr::read_csv("config/sponsor_norm_pipeline/2_final_sponsor_canonical_review.csv")
b[!b$applied & lengths(strsplit(b$sponsor_labels, "|", fixed = TRUE)) > 1, ]
```

---

### Step 2c — Audit the canonical vocabulary

```bash
# Report; writes 2_self_alias_conflicts.csv
Rscript helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R

# Append the safe self-alias subset to sponsor_llm_aliases.csv
Rscript helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R --fix-self-aliases
```

Reports five checks over the canonical list: labels that collide under
`clean_sponsor_alias()`, labels differing only by a trailing legal suffix,
labels backed by a single alias, labels with **no self-alias**, and the unapplied
merge queue. Run it before Step 5 — the resolver picks from the canonical list,
and its cache key hashes the candidate set, so a canonical merged afterwards
silently invalidates cached proposals.

`--fix-self-aliases` closes the self-alias gap at `confidence_prior` **0.94**, so
the emitted rows are the weakest tier rather than the strongest — see the
`sponsor_llm_aliases.csv` section of the config README for why 1.00 is actively
harmful here. Three guards keep it from rewriting existing labels: it skips a
label that already resolves elsewhere, a key that is a generated candidate of an
already-matched raw string, and the handful in `SELF_ALIAS_EXCLUDE` that only the
trial-level gate can catch. All are reported in `2_self_alias_conflicts.csv`.

**Always re-run the gate after `--fix-self-aliases`:**

```bash
cp data/trial_sponsor_labels.csv /tmp/labels_before.csv
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-ror --no-location
Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R
# Expect: unknown -> accepted only. Any already-matched trial that CHANGES
# label is a regression, not an improvement.
```

Current seeded decisions:

- `Fundacion Geltamo` → `GELTAMO`
- `GELA Group` → `GELA`
- entity key `radboud` → `Radboudumc`; related keys are generated from existing `Radboudumc` aliases

The final pass also auto-collapses safe label variants:

- accepted entity-family keys, excluding combined multi-entity labels,
- case/accent/punctuation-only variants,
- stripped legal/group/foundation-token variants,
- very-high Jaro-Winkler label similarity (`>= 0.985`) when sponsor types are compatible and acronym guards pass.

Risky clusters stay in `2_final_sponsor_canonical_review.csv`; accepted
label-to-label rows should be copied into `final_sponsor_canonical_map.csv`,
and accepted broader entity-family decisions should be copied into
`final_sponsor_family_map.csv`, rather than editing `2_sponsor_alias_index.csv`
directly.

---

### Step 3 — Normalise and build trial labels

```bash
Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R
Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R --write-queue
Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R --write-queue --allow-fuzzy
```

Reads `trial_sponsors_raw.csv`, runs `normalise_sponsors()`, writes:
- `data/trial_sponsor_labels.csv` — one row per trial with sponsor fields
- `data/sponsor_normalisation_log.csv` — full audit log (for preprocessing.Rmd)
- `config/sponsor_norm_pipeline/3_sponsor_review_queue.csv` — if `--write-queue` is passed

The label build is deterministic by default: exact alias matches and high-confidence
token containment can produce accepted labels, while the slower fuzzy stage is
opt-in via `--allow-fuzzy` and only emits review suggestions.

---

### Step 4 — Interactive curation

For the detailed LLM-assisted curation protocol, see
`AGENTS/sponsor_llm_curation.md`. That note contains the review rules,
duplicate checks, comment conventions, alias row format, and chunk-by-chunk
curation progress. The short section below only documents the CLI commands.

For anything beyond a quick CLI pass, prefer the reviewer app in
`curation_app/` — it shows sibling aliases and trial references alongside each
row, and records an auditable decision. It is also the only thing that writes
`source: manual`, which marks a row a human actually verified.

```bash
Rscript helper_scripts/sponsor_norm_pipeline/4_curate_sponsors.R [N]
Rscript helper_scripts/sponsor_norm_pipeline/4_curate_sponsors.R --include-skipped
Rscript helper_scripts/sponsor_norm_pipeline/4_curate_sponsors.R --export
```

Reviews `3_sponsor_review_queue.csv` sorted by `n_trials` descending.

| Key | Action |
|-----|--------|
| `a` | Accept suggested canonical sponsor |
| `r` | Reject (adds to `sponsor_negative_aliases.csv` on `--export`) |
| `o` | Override with a different canonical sponsor |
| `s` | Skip (deferred; re-shown with `--include-skipped`) |
| `q` | Quit and save progress |

`--export` writes curation decisions to config files. Accepted queue rows are exported to `sponsor_llm_reviewed.csv` by Step 2 and included in the next `2_sponsor_alias_index.csv`. After exporting or accepting queue rows, re-run Step 2, then Step 3.

---

### Step 5 — Resolve the residue with a pinned LLM

```bash
Rscript helper_scripts/sponsor_norm_pipeline/5_llm_resolve.R --dry-run        # assemble + count tokens, no calls
Rscript helper_scripts/sponsor_norm_pipeline/5_llm_resolve.R --sync --limit=5 # prompt iteration
Rscript helper_scripts/sponsor_norm_pipeline/5_llm_resolve.R --batch          # full run (50% cheaper)
Rscript helper_scripts/sponsor_norm_pipeline/5_llm_resolve.R --batch --poll=<batch_id>
```

A few hundred raw strings survive Steps 1–4 at `match_status: unknown`. They are
entity resolution, not string editing — `1. Frauenklinik der LMU-Innenstadt` →
`Klinikum Der Universitat Munchen AöR` shares no material with its input — so no
rule derived from the frozen decisions closes them. This step asks a model.

**Run Step 2c first.** The resolver picks from the canonical list and its cache
key hashes the candidate set, so a canonical merged after proposals are cached
invalidates them, paying twice and discarding the review work.

What makes it safe to hand to a model:

- **The model picks from a list; it never writes a name.** Candidates come from
  the matcher's own indexes (entity-family, containment-token, Jaro-Winkler).
  The answer is constrained twice — by `output_config.format` with an `enum` of
  the supplied labels, and by a post-response check rejecting anything off-list.
  A model that can only choose cannot introduce a spelling or invent an org.
- **If retrieval yields nothing, the string is skipped.** There is nothing to
  choose from, and asking anyway invites invention.
- **Nothing auto-applies.** Decisions land in `config/sponsor_norm_pipeline/5_llm_proposals.csv`
  and surface in the reviewer app as `llm_proposal` / `llm_confidence` evidence,
  alongside — not replacing — the matcher's own `proposed` candidate. A proposal
  becomes a label only when a human accepts it.
- **Pinned and cached.** `model_id` and `prompt_version` are constants echoed
  into every row; `cache_key` is
  `sha256(raw_clean, prompt_version, model_id, candidates_sha256)`. A run
  resolves only absent keys, so re-running costs nothing and only genuinely new
  strings reach the API. Bumping either constant invalidates deliberately and
  visibly, in the diff.
- **One call per question, not per string.** Because the key hashes
  `raw_clean`, raw strings that differ only in punctuation collapse to the same
  key — `Dainippon Sumitomo Pharma America, Inc` and `...America Inc.` are one
  question. The run asks once per distinct key (227 strings → 222 questions at
  last measurement) and writes the answer to a cache row for *each* raw string,
  so the reviewer's join on `raw_sponsor` still resolves every variant. The
  Batches API rejects duplicate `custom_id`s, so this is enforced, not optional.

Cost is roughly $1–2 for the sponsor residue, about half that batched. Verify
with `--dry-run`, which reports real `count_tokens` figures and checks whether
the cached system prefix clears Opus 5's 512-token minimum.

**Credentials and network.** Uses `ANTHROPIC_API_KEY` if set, otherwise the
OAuth profile from `ant auth login` (`ant auth status` to check). The agent
sandbox allowlist does **not** include `api.anthropic.com`, so `--sync` and
`--batch` need the allowlist widened or must run outside the sandbox. `--dry-run`
and every gate below run offline.

Verification gates:

```bash
# every non-abstained choice is an existing canonical
Rscript -e '
  p <- readr::read_csv("config/sponsor_norm_pipeline/5_llm_proposals.csv", show_col_types=FALSE)
  idx <- readr::read_csv("config/sponsor_norm_pipeline/2_sponsor_alias_index.csv", show_col_types=FALSE)
  bad <- setdiff(na.omit(p$chosen), idx$sponsor_clean)
  stopifnot(length(bad) == 0); cat("all choices are existing canonicals\n")'

# the resolver is inert — it writes proposals, not labels
cp data/trial_sponsor_labels.csv /tmp/labels_before.csv
Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R
diff /tmp/labels_before.csv data/trial_sponsor_labels.csv && echo "labels unchanged"
```

Then **read the proposals**. At this size that is the real acceptance test, and
the last point at which a bad prompt is cheap to fix. Spot-check the abstentions
too — a resolver that abstains on everything passes every mechanical check above.

---

### Step 6 — Re-review the frozen alias decisions

```bash
Rscript helper_scripts/sponsor_norm_pipeline/6_llm_verify.R --dry-run
Rscript helper_scripts/sponsor_norm_pipeline/6_llm_verify.R --target=defects --batch
Rscript helper_scripts/sponsor_norm_pipeline/6_llm_verify.R --batch --poll=<batch_id>
```

`sponsor_llm_reviewed.csv` holds ~11,900 alias → canonical decisions at
`confidence_prior` 1 that **no human ever checked** (`source: llm_reviewed`).
Some are wrong. The measured example:

```text
center for clinical metabolic research at herlev gentofte hospital
  -> Herlev og Gentofte Hospital                    correct: department -> parent
center for clinical metabolic research at herlev-gentofte hospital
  -> Center for Clinical Metabolic Research at ...  wrong: department kept as canonical
```

Two aliases differing by one hyphen, disagreeing on the answer.
`clean_sponsor_alias()` normalises dash *characters* but does not remove them, so
these stay distinct keys and never trip the exact-collision check in
`2_sponsor_ambiguous_aliases.csv`.

**This asks a different question from step 5.** The resolver picks a canonical
for an unresolved string; this judges an *existing* decision — correct /
incorrect / unsure, with a `problem` category. It deliberately proposes **no
replacement**: triage, not repair. That keeps the "never writes a name" property
and, critically, keeps the schema constant.

| `--target` | Rows | Batched cost | What it covers |
|---|---:|---:|---|
| `defects` (default) | 137 | ~$0.39 | Department-label canonicals + separator-variant aliases that disagree |
| `single-alias` | 3,036 | ~$8.73 | Canonicals backed by exactly one alias — no corroboration |
| `all` | 12,495 | ~$35.93 | Every `llm_reviewed` / `llm_curated` row |

Start with `defects`. It is the concentrated defect population, so it measures
the base error rate before you commit to a wider sweep: a high hit rate justifies
it, a clean result says the known-bad examples were unlucky rather than typical.

**Why this batches when step 5 could not.** Step 5's schema embeds an `enum` of
that row's candidates, so every request is a distinct grammar — 222 requests hit
the 20-compilations-per-minute org limit and 190 failed. Here all four fields are
fixed and the enums never vary, so the grammar compiles **once** and is cached.
`--dry-run` prints the schema hash to prove it. Do not add a per-row enum of
suggested replacements; that would reintroduce the limit at 12,495 rows.

Results land in `config/sponsor_norm_pipeline/6_llm_verifications.csv`, sorted by
trials affected. **Nothing is changed** — a row flagged `incorrect` is a finding.
Act on it by adding a label-to-label row to `final_sponsor_canonical_map.csv`
(the department case is exactly what that file is for), then rebuild and re-run
the gate.

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

The canonical sponsor index was built from multiple evidence sources in priority order. First, an LLM-curated alias table captured high-frequency pharmaceutical companies, cooperative groups, hospitals, universities, and known sponsor acronyms. Second, accepted review-queue decisions, including LLM-assisted decisions that were retained as explicit CSV rows, were exported to a separate reviewed-alias table and merged into the index without altering the seed table. Third, external and registry-derived evidence was added: European Medicines Agency marketing authorisation holder names from the EPAR medicines report, Research Organization Registry variants for academic and hospital organisations, CTIS organisation `businessKey` groups, EUCTR sponsor email-domain groups, and postcode-country groups shared across CTIS and EUCTR. The CTIS `businessKey` was treated as definitive evidence that names belonged to the same registered organisation. Email-domain and postcode-country sources were used only with additional safeguards, including shared-infrastructure domain exclusions, discriminative token-overlap requirements, and Jaro-Winkler similarity thresholds, to reduce false-positive merges.

The merged alias index was then passed through a final canonicalisation step that operated on sponsor labels and alias-derived entity keys. This step applied hand-maintained label-to-label and entity-family maps for known canonical choices, plus safe automatic collapses for case, accent, punctuation, legal suffix, group/foundation-token, and very-high-similarity label variants. Ambiguous, combined-sponsor, or higher-risk final-label clusters were written to a review table for manual assessment rather than applied automatically. The generated sponsor alias index was therefore treated as an output artifact; curation decisions were made in source configuration files and propagated by rebuilding the index.

For each trial sponsor, matching proceeded in a fixed order: exact manual override, negative placeholder alias, exact alias lookup, conservative fuzzy lookup, and finally an unmatched/unknown result. Exact alias matches were accepted when the confidence-adjusted score was at least 90; lower-confidence exact matches and all fuzzy matches were marked for review. Fuzzy matching used Jaro-Winkler similarity with a threshold of 0.92 and was blocked for generic standalone tokens such as “university”, “hospital”, or “centre”. Sponsor type was derived preferentially from the trial record’s commercial/non-commercial flag when available; otherwise, it fell back to a rule-based classifier that assigned industry, academic, hospital, cooperative group, foundation, public body, charity, or unknown categories from sponsor-name tokens.

Curation was supported by two review files. The sponsor review queue contained unmatched or review-status raw sponsor strings, ranked by the number of affected trials, and allowed accept, reject, override, or skip decisions; some accepted decisions were generated with LLM assistance and preserved with source labels in the reviewed-alias table. Accepted queue decisions were exported to the reviewed-alias table and included in subsequent index builds. A separate final-canonical review file captured unresolved canonical-label clusters after all source-specific evidence had been merged. All 1,076 rows in this file were reviewed line by line: 982 rows were accepted and written to the final canonical map (8 rows) or the entity-family map (971 rows); 61 rows were blocked as confirmed multi-entity clusters; and 33 rows were manually rejected because the suggested canonical conflated distinct legal entities (university vs. teaching hospital, cross-city hospital matches, or generic department names without an institutional anchor). Accepted final-label decisions were added to the final canonical map and then propagated through a rebuild.

The current recommended rebuild used EPAR and all local database-derived tiers while omitting the slower ROR query (`2_build_sponsor_index.R --no-ror --no-location`). This produced 12,751 alias-index rows, 12,564 unique aliases, 8,367 canonical sponsor labels, and 156 remaining exact alias conflicts after final canonicalisation. The final canonicalisation step reduced 8,883 intermediate sponsor labels to 8,367 final labels. As examples, `GELA`, `GELA Group`, and `GELA-Recherche Clinique` all resolve to `GELA`, while `Fundacion Geltamo` resolves to `GELTAMO`. The normaliser fixture now contains 101 manually specified examples covering major pharmaceutical companies, hospitals, cooperative groups, placeholder strings, final-canonicalisation cases, and Radboud entity-family cases.

---

## Config files (`config/sponsor_norm_pipeline/`)

Column-by-column reference:
[config/sponsor_norm_pipeline/README.md](../../config/sponsor_norm_pipeline/README.md).

| File | Purpose |
|------|---------|
| `sponsor_llm_aliases.csv` | Primary lookup table. Seeded with ~180 big pharma, cooperative group, and academic/hospital entries; now ~1,500 rows, almost all `source: llm_curated`. Grows via curation. |
| `sponsor_llm_reviewed.csv` | Generated from accepted queue rows. Included in `2_sponsor_alias_index.csv` without bloating the seed file. |
| `final_sponsor_canonical_map.csv` | Final label-to-label canonical decisions applied after all source-specific alias evidence has been merged. |
| `final_sponsor_family_map.csv` | Final entity-key family decisions for app-facing canonical merges across aliases and labels. |
| `2_final_sponsor_canonical_review.csv` | Generated queue of final label/entity clusters, including `auto`, `review`, and `blocked` buckets. |
| `sponsor_llm_overrides.csv` | Exact raw-string corrections. Populated by `4_curate_sponsors.R --export`. Takes priority over aliases. |
| `sponsor_negative_aliases.csv` | Placeholders that must never resolve to a sponsor (unknown, N/A, etc.). |
| `3_sponsor_review_queue.csv` | Generated at build time. Contains all `review` and `unknown` rows sorted by `n_trials`. |

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
- **University ≠ University Hospital**: "University of Bonn" ≠ "Universitätsklinikum Bonn"; "University of Aarhus" ≠ "Aarhus University Hospital". These are distinct legal entities and must have separate aliases.
- **No legal suffixes in canonicals**: `sponsor_clean` should not include Inc., Ltd., GmbH, B.V., S.A., A/S, AG, AB, etc. Strip them when curating. Exception: institutional abbreviations like AöR (Anstalt des öffentlichen Rechts) may be kept.
- **No department labels as canonicals**: aliases mapping a dept description to itself (e.g. `Klinisk Farmakologisk Afdeling` → `Klinisk Farmakologisk Afdeling`) are useless and should be moved to `2_sponsor_ambiguous_aliases.csv`.
- **No person-name canonicals**: individual investigators listed as sponsors should be left undecided in the review queue, not accepted with the person's name as canonical.
- **Academic/hospital names are not auto-shortened**: "University Hospital Tübingen" stays as-is unless there is an explicit alias.
- **Acronyms only when explicitly curated**: GSK, BMS, MSD, EORTC, HOVON etc. are in the alias table. Unknown short strings are not auto-mapped.
- **Final canonical labels are post-merge decisions**: use `final_sponsor_canonical_map.csv` for label-to-label cleanup such as `GELA Group` → `GELA`; keep upstream review/manual evidence untouched.
- **Fuzzy matching is conservative**: Jaro-Winkler threshold 0.92, blocked entirely for candidates that consist of generic standalone tokens (university, hospital, center, etc.).
- **When in doubt**: `match_status = "unknown"` or `"review"` — never invent a canonical sponsor.

---

## Normalisation matching order

1. Override (exact raw string, `sponsor_llm_overrides.csv`) — always wins
2. Negative alias (placeholder check) → `rejected`
3. Exact alias match → `accepted` (score ≥ 90) or `review`
4. Conservative fuzzy (Jaro-Winkler ≥ 0.92) → `review`
5. Fallback → `unknown`
