# Sponsor pipeline config — field reference

Column-by-column reference for every CSV in this directory. For the *workflow*
that reads and writes them, see
[helper_scripts/sponsor_norm_pipeline/README.md](../../helper_scripts/sponsor_norm_pipeline/README.md).

**Hand-edit only the curated files.** Generated files are rewritten from scratch
on the next rebuild, so an edit there is silently discarded.

| File | Rows | Written by | Hand-edit? |
|---|---:|---|---|
| `sponsor_llm_aliases.csv` | 1,514 + self-aliases | curation + `audit_sponsor_canonicals.R --fix-self-aliases` | ✅ curated seed |
| `sponsor_llm_reviewed.csv` | 11,899 | curation, **rewritten by `2_build_sponsor_index.R`** | ⚠️ curated content, regenerated file |
| `sponsor_llm_overrides.csv` | 0 | `4_curate_sponsors.R --export` | ✅ curated |
| `sponsor_negative_aliases.csv` | 264 | curation | ✅ curated |
| `final_sponsor_canonical_map.csv` | 3,181 | curation | ✅ curated |
| `final_sponsor_family_map.csv` | 972 | curation | ✅ curated |
| `2_sponsor_alias_index.csv` | 13,013 | `2_build_sponsor_index.R` | ❌ generated |
| `2_final_sponsor_canonical_review.csv` | 1,225 | `2_build_sponsor_index.R` | ❌ generated (review queue) |
| `2_sponsor_ambiguous_aliases.csv` | 3 | `2_build_sponsor_index.R` | ❌ generated |
| `2_new_sponsor_candidates.csv` | 340 | `2_build_sponsor_index.R` | ❌ generated (review queue) |
| `2_ctis_org_candidates.csv` | 131 | `2_build_sponsor_index.R` | ❌ generated (review queue) |
| `2_postcode_sponsor_candidates.csv` | 1,484 | `2_build_sponsor_index.R --no-location` off | ❌ generated (review queue) |
| `2_self_alias_conflicts.csv` | ~250 | `audit_sponsor_canonicals.R` | ❌ generated (review queue) |
| `3_sponsor_review_queue.csv` | 102 | `3_build_sponsor_labels.R --write-queue` | ⚠️ decision columns only |
| `5_llm_proposals.csv` | — | `5_llm_resolve.R` | ❌ generated (frozen API fetch, committed) |
| `6_llm_verifications.csv` | — | `6_llm_verify.R` | ❌ generated (frozen API fetch, committed) |

---

## Shared columns

These mean the same thing everywhere they appear.

| Column | Type | Meaning |
|---|---|---|
| `alias_clean` | string | **Lookup key.** The raw sponsor string after `clean_sponsor_alias()` (`normalise_sponsors.R:14`): transliterated to Latin-ASCII, lowercased, quotes/dashes unified, `&` → ` and `, punctuation → space, whitespace squished. Never contains uppercase or punctuation. Matching is on this value, so it must be produced by that function — not by `tolower(trimws(x))`, which misses every name with an accent or a period. |
| `sponsor_clean` | string | **Canonical output label**, as shown in the app. Title-cased, no legal suffix (`Inc.`, `GmbH`, `B.V.`, …). One per organisation. |
| `sponsor_parent` | string \| `NA` | Parent company or university system, e.g. `Radboudumc`. `NA` when the sponsor has no parent or it is unknown. |
| `sponsor_group` | string \| `NA` | Broader analytical grouping used for charts, e.g. `MSD / Merck & Co.`. Coarser than `sponsor_parent`. |
| `sponsor_type` | enum \| `NA` | `industry`, `academic`, `hospital`, `cooperative_group`, `foundation`, `public_body`, `charity`, `person`, `unknown`. `NA` means "derive it at label-build time from the trial's commercial flag", which is preferred over guessing here. |
| `source` | enum | **Provenance — the field the reviewer app's metrics are cut by.** See the table below. |
| `confidence_prior` | 0–1 | Tier confidence, multiplied into `match_score`. A score ≥ 90 after weighting auto-accepts; anything lower goes to `review`. |
| `alias_type` | string \| `NA` | Sub-classification within a source. Mostly `NA` on the sponsor side. |
| `reason` | free text | Why the row exists. Not parsed — but it is what a human reads when auditing, so keep it specific. |

### `source` values

The distinction that matters most in this repo:

| Value | Who wrote it | Verified by a human? |
|---|---|---|
| `llm_curated` | an LLM curation pass | **No** |
| `llm_reviewed` | an LLM decision on a review-queue row | **No** |
| `self_alias` | `audit_sponsor_canonicals.R --fix-self-aliases` — a canonical's own cleaned label mapped to itself | n/a — derived |
| `manual` | `curation_app/apply.R` only | **Yes** |
| `ctis_businesskey` | EMA organisation registry (ground truth) | n/a — registry |
| `epar_mah` | EMA EPAR marketing-authorisation-holder names | n/a — registry |
| `ror` | Research Organization Registry | n/a — registry |
| `email_domain` | shared EUCTR corporate email domain | n/a — derived |
| `location_postcode` | shared postcode + country + name similarity | n/a — derived |

`manual` is written in exactly one place — `curation_app/apply.R:198` — when a
person accepted or edited a row in the reviewer app. Do not hand-write it, and
do not use it as a synonym for `llm_curated`: conflating the two once already
cost ~3,100 rows their real provenance, and the admin panel's change-rate-by-source
report is meaningless if `manual` stops meaning "a human checked this".

---

## Curated files

### `sponsor_llm_aliases.csv` — the seed alias table

`alias_clean, sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, source, confidence_prior, alias_type`

The primary lookup table: 1,383 rows `llm_curated`, 131 `ctis_businesskey`, plus
`self_alias` rows. Highest priority in the index merge. Add a row here when an
alias should apply everywhere, not just to one raw string.

**Self-aliases, and why they are the weakest tier.** `check_alias()` matches
`alias_clean %in% candidates`, so a canonical that never appears as an
`alias_clean` cannot match on the alias tier even when a raw sponsor arrives
spelled exactly like the label — it falls through to containment or fuzzy, or
misses. `audit_sponsor_canonicals.R --fix-self-aliases` closes that gap, at
`confidence_prior` **0.94, not 1.00**, because `check_alias()` ranks by
`confidence_prior * 100 - candidate_rank`: at 1.00 a self-alias matching the full
raw string (rank 1) outranks a curated alias that only matches a stripped
candidate, silently overriding deliberate consolidations. At 0.94 a self-alias
scores ~93 — still auto-accepted when it is the only match, but it loses to any
curated confidence-1.0 alias and sits below the 0.95 floor for containment and
fuzzy targets, so it adds no surface on those tiers.

Confidence alone is not sufficient, though. `make_sponsor_candidates()` generates
stripped forms of each raw string, so a **short** self-alias hijacks longer
strings: the one-token label `medac` is the first-word candidate of
`Medac Gesellschaft fuer klinische Spezialprapaerate mbH`. The audit therefore
also refuses any self-alias whose key is a generated candidate of an
already-matched raw string, and reports those in `2_self_alias_conflicts.csv`.

### `sponsor_llm_reviewed.csv` — accepted queue decisions

Same columns as above. Populated from accepted `3_sponsor_review_queue.csv` rows so
those decisions reach the index without bloating the seed file. Where both files
carry the same `alias_clean`, `llm_reviewed` wins over `bulk_reviewed`.

**This file is both read and rewritten** by `2_build_sponsor_index.R`
(`export_llm_reviewed()`, line ~1003): each rebuild merges the existing rows with
newly-accepted queue rows, dedupes on `(alias_clean, sponsor_clean)` and re-sorts.
Hand edits survive — the merge keeps existing rows — but formatting and row order
will not. Note the asymmetry: the substance pipeline only *reads* its
`substance_llm_reviewed.csv`.

### `sponsor_llm_overrides.csv` — exact raw-string corrections

`raw_clean, sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, match_status, reason`

| Column | Meaning |
|---|---|
| `raw_clean` | The **whole cleaned raw string**, not an alias fragment. Matched before anything else. |
| `match_status` | Status to force: `accepted`, `review`, `rejected`, `unknown`. |

Highest priority in the whole matcher — step 1 of the matching order. Use it to
fix one specific trial's sponsor string without changing how that alias behaves
elsewhere. Currently empty.

### `sponsor_negative_aliases.csv` — never a sponsor

`alias_clean, reason`

Placeholders that must resolve to `rejected` rather than to a name: `unknown`,
`n/a`, `multiple sponsors`, and similar. Checked at step 2, before alias lookup,
so a placeholder can never fuzzy-match a real organisation.

### `final_sponsor_canonical_map.csv` — label-to-label merges

`sponsor_clean_from, sponsor_clean_to, sponsor_parent_to, sponsor_group_to, sponsor_type_to, reason`

Applied **after** every alias source has been merged, so it operates on output
labels rather than on aliases. `GELA Group` → `GELA`. The `*_to` columns
overwrite the corresponding fields on every row that resolved to
`sponsor_clean_from`.

**Where its 3,181 rows came from.** The pipeline only ever *reads* this file —
`apply_explicit_final_map()` in `2_build_sponsor_index.R` opens it with
`read_csv()` and never writes it. Despite the `OUT_FINAL_MAP` variable name at
`2_build_sponsor_index.R:89`, which is a misnomer, nothing generates it. Rows
arrive two ways:

1. **Copied out of `2_final_sponsor_canonical_review.csv`** — the generated
   review queue. Accepted label-to-label clusters are moved here by hand;
   broader entity-family decisions go to `final_sponsor_family_map.csv` instead.
   Per the handover, a 1,076-row review pass sent 8 rows here and 971 to the
   family map.
2. **Historically appended** by the retired `clean_llm_reviewed.py`
   (now in `LEGACY/`), which wrote canonical-convergence and legal-suffix-stripping
   decisions here in bulk. That accounts for most of the row count and is why the
   file is far larger than hand-review alone would produce.

So: curated, but with a bulk-scripted history. Because nothing regenerates it,
a deleted row is gone for good — take a diff before editing.

### `final_sponsor_family_map.csv` — entity-family merges

`entity_key, sponsor_clean_to, sponsor_parent_to, sponsor_group_to, sponsor_type_to, reason`

| Column | Meaning |
|---|---|
| `entity_key` | An **anchor token** derived from the alias, e.g. `radboud` — deliberately coarser than a label. |

Broader than the canonical map: one row catches every label sharing that anchor,
including ones not yet seen. The rebuild also derives *related* keys from the
target's existing high-confidence aliases, which is what keeps the family logic
generic instead of special-casing organisations in code.

---

## Generated files

### `2_sponsor_alias_index.csv` — the merged index

`alias_clean, sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, alias_type, source, confidence_prior`

Every source flattened into one lookup table and passed through final
canonicalisation. This is what `normalise_sponsors()` reads at match time.
**Never edit it** — fix the upstream curated file and rebuild, or the change is
gone on the next `2_build_sponsor_index.R` run.

### `2_final_sponsor_canonical_review.csv` — the canonicalisation review queue

| Column | Meaning |
|---|---|
| `cluster_key` | Identifier for the proposed merge, e.g. `entity-final:graz university`. |
| `entity_key`, `entity_anchor_key`, `entity_class_key`, `department_parent_key` | Decomposition of the label into anchor (`graz`), class (`university`) and parent, used to judge whether a merge is safe. |
| `suggested_canonical` | The label the cluster would collapse to. |
| `sponsor_labels`, `aliases_sample` | `\|`-separated members of the cluster and example aliases. |
| `sources`, `sponsor_types` | `\|`-separated provenance and types across the cluster. Mixed types are a red flag: `academic\|hospital` usually means a university is being merged with its teaching hospital. |
| `score` | 0–100 similarity/confidence for the proposed merge. |
| `evidence` | Human-readable justification. |
| `confidence_bucket` | `auto` (applied), `review` (needs a decision), `blocked` (refused). |
| `blocked_reason` | Why it was blocked, e.g. `sponsor types differ`. |
| `review_bucket` | Alphabetical batch, e.g. `A-F`, for splitting review sessions. |
| `applied` | `TRUE`/`FALSE` — whether the merge was applied this run. |

Accepted rows are copied into `final_sponsor_canonical_map.csv` (label-to-label)
or `final_sponsor_family_map.csv` (entity-family). The file itself is
regenerated, so decisions recorded only here are lost.

### `2_sponsor_ambiguous_aliases.csv`

`alias_clean, sponsors_all, n_sponsors, sources` — one alias resolving to more
than one canonical. `sponsors_all` and `sources` are `|`-separated and aligned.
Priority order decides which wins; this file just records that a conflict exists.

### `2_new_sponsor_candidates.csv`

`raw_name, source, suggested_canonical, other_names` — EPAR MAH names that
matched nothing. Review fodder for growing `sponsor_llm_aliases.csv`.

### `2_ctis_org_candidates.csv`

`businesskey, suggested_canonical, alias_clean, n_variants, other_names` — one
row per EMA organisation whose `businessKey` group has no known canonical.
`n_variants` is how many name spellings EMA lists for it; `businesskey` is EMA's
own organisation ID (`ORG-…`) and is ground truth for identity.

### `2_postcode_sponsor_candidates.csv`

`alias_clean, suggested_canonical, sponsor_parent, sponsor_group, sponsor_type, source, confidence_prior`

Same-postcode evidence, `confidence_prior` 0.7. **Never merged into the index** —
too weak for app-facing labels, since unrelated organisations share buildings.
Only produced when the `--no-location` flag is omitted.

### `3_sponsor_review_queue.csv` — the curation backlog

`raw_sponsor, candidate_sponsor, sponsor_type, match_status, match_score, match_source, match_reason, n_trials, decision, canonical_sponsor, comment`

| Column | Meaning |
|---|---|
| `raw_sponsor` | Raw string as it appears in the register. The row key. |
| `candidate_sponsor` | What the matcher proposed, if anything. |
| `match_status` | `review` or `unknown` — accepted rows do not enter the queue. |
| `match_score` | 0–100 confidence for the proposal. |
| `match_source` | Which stage proposed it, e.g. `llm_curated`, `fuzzy:llm_reviewed`. |
| `match_reason` | Human-readable explanation of the match. |
| `n_trials` | Trials affected — the sort key, so the queue is worked highest-impact first. |
| `decision` | **Written by the reviewer**: `accepted` or `rejected`. Blank = undecided. |
| `canonical_sponsor` | **Written by the reviewer**: the chosen canonical, when overriding `candidate_sponsor`. |
| `comment` | **Written by the reviewer**: free text. |

The last three are the only hand-editable columns; everything else is
regenerated. `3_build_sponsor_labels.R --write-queue` drops decided rows by
default so the file reads as a to-do list — pass `--keep-decided` to retain them.
Because rebuilds drop rows, the queue is **not** a durable record of decisions;
the reviewer ledger is.

### `2_self_alias_conflicts.csv` — labels that already resolve elsewhere

`alias_clean, sponsor_clean, resolves_to, resolves_source, resolves_status, triage, conflict`

Canonicals that `--fix-self-aliases` deliberately did **not** emit. `triage`
splits them into kinds that need opposite responses:

| `triage` | What it means |
|---|---|
| `would hijack an already-matched raw string` | The key is a generated candidate of a raw string that already resolves elsewhere — emitting it would rewrite existing labels. |
| `deliberate mapping — self-alias would override` | The label resolves via the alias/containment/family tiers, i.e. someone curated it that way. Leave alone unless the curation is wrong. |
| `fuzzy false positive — self-alias would fix` | The label resolves via Jaro-Winkler to a *different* organisation — `Abalos Therapeutics` → `Alba Therapeutics`, `Adienne` → `Advicenne`. These are live matcher bugs. |
| `alias key taken by another canonical` | Two labels clean to one key, e.g. `Fundació Sant Joan de Déu` vs `Hospital Sant Joan de Deu`. Genuine identity questions. |

The fuzzy false positives are the interesting group: each is a canonical the
matcher would mis-resolve today if a raw string arrived spelled exactly like it.
Fixing one means adding the self-alias *and* accepting that already-matched
trials change — a human decision, so they are reported rather than applied.

### `5_llm_proposals.csv` — the resolver decision cache

`cache_key, raw_sponsor, model_id, prompt_version, candidates_sha256, chosen, confidence, reason, abstained, decided_at_utc, batch_id`

Written by `5_llm_resolve.R`. **Committed on purpose**, following the precedent
`2_chembl_cache.csv` sets: a frozen API fetch in the repo means deployment and CI
need no network and no credentials.

| Column | Meaning |
|---|---|
| `cache_key` | `sha256(raw_clean, prompt_version, model_id, candidates_sha256)`. Presence here is what makes a re-run free. **Not unique** — raw strings differing only in punctuation clean to the same value, so they share a key and one API call answers all of them. |
| `raw_sponsor` | The unresolved raw string, and the file's real row key — one row per raw string, so the reviewer's join resolves every punctuation variant. |
| `model_id` / `prompt_version` | Pinned provenance. Bumping either changes every `cache_key`, so a re-resolve is visible as a full-file diff rather than a silent change. |
| `candidates_sha256` | Hash of the candidate list the model chose from. A canonical merged later changes this and correctly invalidates the row — which is why the vocabulary is settled first. |
| `chosen` | An existing canonical, or `NA` when the model abstained or the call failed. Never a new name. |
| `confidence` | `high`/`medium`/`low` — the model's opinion, not evidence. |
| `abstained` | `TRUE` when the model returned `NONE_OF_THESE`; `NA` when the call failed (`reason` carries the error). |

**This file changes no labels.** It is a proposal store: a row becomes a label
only when a human accepts it in the reviewer app, the one path that writes
`source: manual`.

### `6_llm_verifications.csv` — re-review of the frozen alias decisions

`cache_key, alias_clean, sponsor_clean, model_id, prompt_version, verdict, problem, confidence, reason, n_trials, decided_at_utc, batch_id`

Written by `6_llm_verify.R`. Also committed, same reasoning as
`5_llm_proposals.csv`. Judges *existing* `alias_clean → sponsor_clean` decisions
rather than picking a canonical for an unresolved string, because ~11,900 rows
in `sponsor_llm_reviewed.csv` sit at `confidence_prior` 1 with `source:
llm_reviewed` — which per the table above means **no human checked them**.

| Column | Meaning |
|---|---|
| `cache_key` | `sha256(alias_clean, sponsor_clean, prompt_version, model_id)`. No candidate hash — there is no candidate set, so the key is stable across index rebuilds. |
| `verdict` | `correct` / `incorrect` / `unsure`. `NA` when the call failed (`reason` carries the error), which keeps the row retry-eligible. |
| `problem` | `none`, `department_should_resolve_to_parent`, `different_organisation`, `variant_of_another_canonical`, `too_generic_to_be_a_sponsor`, `other`. An unrecognised value degrades to `other` rather than discarding the verdict. |
| `confidence` | The model's opinion, not evidence. |
| `n_trials` | Trials the alias affects — the sort key, so the highest-impact wrong decisions surface first. |

**No replacement is proposed, deliberately.** The verifier does triage, not
repair: it never writes an organisation name. That preserves the same
never-invent property as the resolver *and* keeps the JSON schema byte-identical
across every request, so the grammar compiles once instead of once per row —
which is what makes 12,495 rows affordable at all.

A row flagged `incorrect` is a finding. Act on it by adding a label-to-label row
to `final_sponsor_canonical_map.csv` — the `department_should_resolve_to_parent`
case is exactly what that file exists for — then rebuild and re-run the label
gate.

---

## Generated outputs in `data/`

Gitignored (`data/*log*`, `data/*labels*`), so they are absent from `main` and
must be rebuilt locally or shipped in a deploy bundle.

### `data/trial_sponsors_raw.csv` — pipeline input

`_id, raw_sponsor, is_commercial` — one row per trial, written by
`1_export_trial_sponsors.R`. `is_commercial` is the register's own
commercial/non-commercial flag and takes precedence over the rule-based
`sponsor_type` classifier when present.

### `data/trial_sponsor_labels.csv` — what the app reads

`_id, sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, match_status`

One row per trial. `app.R` left-joins this at startup; no normalisation happens
at runtime.

### `data/sponsor_normalisation_log.csv` — the audit log

`raw_sponsor, sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, match_status, match_score, match_source, match_reason, suggested_clean, n_trials`

Every distinct raw string with its outcome — the input to `preprocessing.Rmd`
and to the reviewer app's impact ordering. `suggested_clean` is what fuzzy
matching proposed even where it was not accepted.
