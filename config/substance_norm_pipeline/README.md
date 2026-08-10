# Substance pipeline config — field reference

Column-by-column reference for every CSV in this directory. For the *workflow*
that reads and writes them, see
[helper_scripts/substance_norm_pipeline/README.md](../../helper_scripts/substance_norm_pipeline/README.md).

**Hand-edit only the curated files.** Generated files are rewritten from scratch
on the next rebuild, so an edit there is silently discarded.

| File | Rows | Written by | Hand-edit? |
|---|---:|---|---|
| `canonical_substances.csv` | 370 | curation | ✅ curated |
| `substance_llm_brands.csv` | 1,380 | curation | ✅ curated |
| `substance_llm_reviewed.csv` | 10,275 | `4_curate_substances.R --export`, reviewer app | ✅ curated |
| `substance_llm_overrides.csv` | 636 | `4_curate_substances.R --export`, reviewer app | ✅ curated |
| `negative_aliases.csv` | 223 | curation | ✅ curated |
| `2_substance_alias_index.csv` | 110,992 | `2_build_substance_index.R` | ❌ generated |
| `2_chembl_cache.csv` | 120,416 | `2_build_substance_index.R --refresh-chembl` | ❌ generated (committed) |
| `2_ambiguous_substance_aliases.csv` | 1,984 | `2_build_substance_index.R` | ❌ generated |
| `2_ambiguous_needs_review.csv` | 23 | `2_build_substance_index.R` | ❌ generated (review queue) |
| `3_substance_review_queue.csv` | 1,340 | `3_build_substance_labels.R --write-queue` | ⚠️ decision columns only |

---

## Shared columns

| Column | Type | Meaning |
|---|---|---|
| `alias_clean` | string | **Lookup key.** The raw string after `clean_alias()` (`normalise_substances.R:12`): lowercased, `®`/`™` stripped, quotes and dashes unified, whitespace squished. Matching is on this value. |
| `substance_clean` | string | **Canonical INN**, lowercase. Combinations use `\|` as separator (`ribociclib\|letrozole`) — never `/` or `;`, which `clean_substance()` rewrites to `\|`. Always free of dose amounts, units, and formulation/route terms. |
| `alias_type` | enum | What kind of alias this is. See below. |
| `source` | enum | **Provenance.** See below. |
| `confidence_prior` | 0–1 | Tier confidence, multiplied into `match_score`. |
| `match_status` | enum | `accepted` (safe downstream), `review` (plausible, unverified), `rejected` (known non-substance), `unknown` (no match; `substance_clean` is `NA`). |
| `reason` | free text | Why the row exists. Not parsed. |

### `alias_type` values

| Value | Meaning |
|---|---|
| `llm_brand` | Brand name → INN, written by an LLM curation pass |
| `combination_brand` | Brand covering several INNs, e.g. `kisqali femara` |
| `epar_brand` | Brand name taken from the EMA EPAR medicines report |
| `inn` | The INN itself, listed as its own alias |
| `salt_hydrate_resolution` | Salt/hydrate form collapsed to its free base |
| `chembl_conflict_resolved` | A ChEMBL ambiguity settled by curation |
| `chembl_synonym` | Synonym straight from the ChEMBL API |
| `reviewed_queue` | Accepted review-queue decision |

### `source` values

| Value | Who wrote it | Verified by a human? |
|---|---|---|
| `llm_curated` | an LLM curation pass | **No** |
| `llm_reviewed` | an LLM decision on a review-queue row | **No** |
| `manual` | `curation_app/apply.R` only | **Yes** |
| `epar` | EMA EPAR medicines report | n/a — registry |
| `chembl` | ChEMBL REST API | n/a — registry |

`manual` is written in exactly one place — `curation_app/apply.R:198` — when a
person accepted or edited a row in the reviewer app. Do not hand-write it, and
do not use it as a synonym for `llm_curated`: the reviewer app's
change-rate-by-source report only means something if `manual` still means "a
human checked this".

---

## Curated files

### `canonical_substances.csv` — the INN list

`substance_clean, parent_substance, substance_type, source`

| Column | Meaning |
|---|---|
| `substance_clean` | The INN, including salt forms as their own rows. |
| `parent_substance` | Free-base moiety. Equals `substance_clean` for a base; points at the base for a salt (`acalabrutinib maleate` → `acalabrutinib`). |
| `substance_type` | `inn` or `salt`. |

Checked at step 5, before the alias index. A hit here is `accepted` outright.

### `substance_llm_brands.csv` — brand and combination mappings

`alias_clean, substance_clean, alias_type, source, confidence_prior`

Tier 1 of the index merge — beats EPAR and ChEMBL. Also where salt/hydrate
ambiguities get resolved: the pair is written here pointing at the free base, so
the next rebuild has no conflict to report.

### `substance_llm_reviewed.csv` — accepted queue decisions

Same columns. Tier 2, always overrides ChEMBL. Re-read from disk on every index
build, so adding rows here needs no other change.

### `substance_llm_overrides.csv` — exact raw-string corrections

`raw_clean, substance_clean, match_status, reason`

| Column | Meaning |
|---|---|
| `raw_clean` | The **whole cleaned raw string**, not an alias fragment. |
| `reason` | Curation provenance — `chunk 7`, `auto-accepted score=100`, or a specific note like `dose glued to INN`. |

Checked at step 2, before the negative list and before any alias lookup, so it
overrides everything. Use it for strings a general alias should not fix, e.g.
`gemcitabine100 mg`.

**Keep it small.** Because this tier outranks every other, a row here silently
shadows anything added below it. The file held 9,625 rows until 2026-08-10, of
which 8,989 were redundant — the alias index had learned to reproduce them on
its own, so they were doing nothing except sitting at the top of the priority
order. `helper_scripts/substance_norm_pipeline/prune_substance_overrides.R`
removed them, gated on `data/trial_substance_labels.csv` coming out
byte-identical. Re-run it after a curation pass appends more.

The 636 that remain are the rows that do work:

| | Rows | Why it stays |
|---|---:|---|
| Sole source | 368 | Nothing else resolves the string at all |
| Cross-string dependency | 104 | Its key is a *candidate* of some longer register string — `metformina`, `lidocain`, `valproate` — so removing it moves that string, not just its own |
| Real correction | 62 | The index resolves the string differently, and this row is the correction |
| Duplicate key | 102 | Feeds the reviewer's **Substance conflicts** tier; see below |

The last group is deliberate. `check_override()` takes `slice(1)`, so only the
first row per key is ever reachable — dropping a redundant first row would
*promote* the shadowed second one. Those same rows are what
`load_substance_conflicts()` (`curation_app/R/tiers.R`) surfaces for review, so
the prune leaves every duplicated key untouched.

### `negative_aliases.csv` — never a substance

`alias_clean, reason`

Devices, cosmetics, mechanism-of-action phrases, blinding text. Checked at step 3
so these can never reach fuzzy matching. Note `placebo` is handled by its own
rule at step 1, ahead of this file.

---

## Generated files

### `2_substance_alias_index.csv` — the merged index

`alias_clean, substance_clean, alias_type, source, confidence_prior`

All four tiers flattened, highest confidence winning per alias. Required at
runtime. **Never edit it** — fix the upstream curated file and rebuild.

### `2_chembl_cache.csv`

Same columns. A frozen copy of the ChEMBL fetch, **committed on purpose** so that
deployment and CI can run `2_build_substance_index.R --use-chembl-cache` with no
network access. Refresh quarterly with `--refresh-chembl`.

### `2_ambiguous_substance_aliases.csv` and `2_ambiguous_needs_review.csv`

`alias_clean, substances_all, n_substances, sources`

`substances_all` and `sources` are `|`-separated and aligned. The first file
records **every** alias resolving to more than one substance; the second is the
subset needing a human — genuine conflicts such as reused research codes, after
salt/hydrate pairs have been auto-resolved. Nothing is dropped in either case:
tier priority decides which mapping is used.

### `3_substance_review_queue.csv` — the curation backlog

`raw_substance, active_substance_clean, match_status, match_score, match_source, match_reason, n_occurrences, decision, canonical_substance, comment`

| Column | Meaning |
|---|---|
| `raw_substance` | Raw string as it appears in the register. The row key. |
| `active_substance_clean` | What the matcher proposed, if anything. |
| `match_status` | `review` or `unknown`. |
| `match_score` | 0–100 confidence for the proposal. |
| `match_source` | Which stage proposed it, e.g. `chembl`, `fuzzy:llm_reviewed`. |
| `match_reason` | Human-readable explanation. |
| `n_occurrences` | Trial-substance pairs affected — the sort key. |
| `decision` | **Written by the reviewer**: `accepted` or `rejected`. Blank = undecided. |
| `canonical_substance` | **Written by the reviewer**: the chosen INN when overriding. |
| `comment` | **Written by the reviewer**: free text. |

The last three are the only hand-editable columns. Inclusion rules: `review`
rows always enter the queue; `unknown` rows only at `n_occurrences >= 2`, since a
singleton with no candidate is not actionable. Strings shorter than 3 characters,
with no 3-character alphabetic run, or starting with a dose amount never reach
the queue at all.

Rebuilds drop decided rows by default, so the queue is **not** a durable record
of decisions — the reviewer ledger is.

---

## Generated outputs in `data/`

Gitignored (`data/*log*`, `data/*labels*`), so they are absent from `main`.

### `data/trial_substances_raw.csv` — pipeline input

`_id, raw_substance` — one row per trial-substance pair, after splitting
multi-substance strings on `" / "`. Written by `1_export_trial_substances.R`.

### `data/trial_substance_labels.csv` — what the app reads

`_id, substance_label` — one row per trial, substances sorted and `" / "`-joined.
`app.R` left-joins this at startup and populates the product-search dropdown
directly from it.

### `data/substance_normalisation_log.csv` — the audit log

`_id, raw_substance, active_substance_clean, match_status, match_score, match_source, match_reason`

Per-pair rather than per-distinct-string, unlike the sponsor log. Drives
`preprocessing.Rmd`, the reviewer's impact ordering, and its **Fuzzy singletons**
tier — the score-80–84 matches that the `n_occurrences >= 2` rule keeps out of the
queue.
