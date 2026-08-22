# Substance normalisation v2

## Context

Sponsor normalisation was rewritten as v2 (`PLANS/normalisation-v2-handover.md`): a
model-built canonical registry replacing ~4,200 lines of deterministic matcher, built on a
reusable library at `helper_scripts/llm_norm/`. It shipped with zero `accepted -> unknown`
regressions for $10.31. §"Decisions the user made" of that handover records the scope note:
*"Sponsors now; `llm_norm/` factored so substances can adopt it later."* This is that adoption.

The v1 substance pipeline (`helper_scripts/substance_norm_pipeline/`, 7 scripts) has the same
disease sponsors had, and I confirmed it: **zero `manual` rows in any config file.**
`canonical_substances.csv` is 370 `llm_curated`, `substance_llm_reviewed.csv` is 10,275
`llm_reviewed` — all from undocumented sessions with no recorded model, prompt or date, and
20 of the current gold fixtures are known wrong (`PLANS/normalisation-llm-resolver.md:23-28`).
The rule layer protects what was itself older LLM output.

**The one big difference from sponsors, and the reason this plan is not a copy-paste:**
substances have a real external registry. ChEMBL and EPAR worked well in v1 and go *first*,
before any model is involved. Sponsors had to mint canonicals because no vocabulary existed;
substances already have one, so the pass order inverts — **resolve, then assign, then mint**,
not block, mint, assign.

### Measured on the real corpus (all numbers below are mine, run today)

`data/trial_substances_raw.csv`: 99,385 rows, **98,842 trial-substance pairs**,
**33,530 distinct raw strings**, 45,998 trials.

ChEMBL + EPAR alone — no curated tiers, no fuzzy, using v1's `generate_candidates()` ladder:

| class | distinct strings | trial pairs |
|---|---:|---:|
| registry hit, one substance | **16,541** | **67,801 (68.6%)** |
| placebo rule | 1,826 | 2,347 |
| registry hit, ambiguous (>1 substance) | 724 | 2,251 |
| no hit | 14,439 | 26,443 |

Of the 14,439 no-hit strings, a deterministic junk filter removes 3,249 (9,518 pairs), leaving
**11,189 strings / 16,843 pairs as the real LLM work list** — comparable to sponsors' 16,594,
so the sponsor cost profile ($10.31 of a $60 cap) should carry over.

### Decisions taken (confirmed with the user, do not revisit)

| Decision | Choice |
|---|---|
| Canonical granularity | **INN base.** `Methotrexate` absorbs `methotrexate sodium`, `Metoject`, `Methotrexat 10mg Tabletten`. Salt/ester in `salt_form`, brand in `brand`. Direct analogue of §3.0 "canonical is the BRAND, not the legal entity". |
| Combination products | Keep v1's single pipe-joined canonical (`amoxicillin\|clavulanic acid`). Not split. |
| v1 curated CSVs | **Regression baseline only, never an input.** Greenfield, same as sponsors. ChEMBL + EPAR stay as the deterministic tier. |
| Non-substances | Deterministic filter for obvious unit/dose fragments, then an explicit `not_a_substance` model answer for the rest. **v1's raw-string fallback is dropped.** |
| Budget | **Hard cap USD 60**, own ledger at `config/substance_norm_v2/llm_spend.csv`. |
| Jaro-Winkler | Removed, as for sponsors — see the `metotrexate` evidence below. |

---

## Architecture

```
1_export_trial_substances.R              (UNCHANGED, reused as-is)
        v  data/trial_substances_raw.csv         99,385 rows / 33,530 distinct

A_resolve.R      deterministic, offline, NO model            <- NEW, no sponsor analogue
        v  config/substance_norm_v2/{registry,assignments}.csv   68.6% of pairs done
        v  data/substance_residue.csv            11,189 strings for the model
        v  data/substance_rejected.csv            3,249 junk strings

B_assign.R       Sonnet 5   pick-from-list, index only       ~= sponsor C_assign.R
        v  assignments.csv + config/substance_norm_v2/B_abstained.csv

C_mint.R         Opus 5 head / Sonnet 5 tail, cluster-at-a-time  ~= sponsor A_block + B_mint
        v  config/substance_norm_v2/C_mint_clusters.csv

D_consolidate.R  Opus 5     partition each group into substances  (--apply to write)
E_emit.R                    labels + review queue + regression diff
        v  data/trial_substance_labels.csv       <- the only file app.R reads
```

**`app.R` needs no change.** It reads `_id` + `substance_label` at
[app.R:1811-1839](app.R#L1811-L1839) and re-joins on the cache-hit path at
[app.R:2069-2082](app.R#L2069-L2082); `E_emit.R` writes exactly that shape.

### Why the order inverts vs sponsors

Sponsor pass B minted first because no canonical vocabulary existed and a cluster had to be
named once with every variant visible. Here ChEMBL supplies **17,272 canonicals / 89,017
surface forms** before a single API call, so the cheap pick-from-list pass runs first and mint
only sees what it cannot place. That is what makes the residue 11,189 instead of 33,530.

---

## Evidence that shaped the design

These are measurements, not assumptions. Each one changes an implementation choice.

### 1. Index surface forms, not canonicals — and use `ngram_n = 3`

Indexing the 17,272 ChEMBL `pref_name` values alone misses `BNT162b2`. Indexing all **89,017
surface forms** (canonicals *plus* their registry aliases, exactly what sponsor
`registry_surface_forms()` does at `registry.R:308`) hits it at 1.00, because `bnt-162b2` is a
ChEMBL synonym. Same for `SODIO ASCORBATO` → `ascorbato de sodio` at 0.62.

`ngram_n = 3` beats 4 on this vocabulary (`metotrexate` → `methotrexate` scores 0.58 vs 0.42;
`Botox` and `Etomedac 20 mg` return nothing at all at n=4). Threshold **0.30**, not
`ch_ngram`'s 0.45 default — `SODIO ASCORBATO` → `sodium ascorbate` scores 0.35.

### 2. The n-gram channel is the PRIMARY channel here, and it is not broken

§3.8 of the sponsor handover records n-gram as "adds no Ghent pair, and returns NA scores".
I ran it over the substance vocabulary: **0 NA of 20 rows.** That note is about the sponsor
corpus, not a defect. Drug names are single tokens, so `ch_token_idf` — the sponsor workhorse —
has nothing to work with, and `ch_ngram` ([retrieve.R:260](helper_scripts/llm_norm/retrieve.R#L260))
carries the pass. Turn it on via `extra_channels = TRUE`; `CHANNEL_RANK` already ranks it
below exact and token_idf, which stays correct.

### 3. Token IDF actively poisons substance slates without a units stoplist

Measured, and it is ugly. With the sponsor `GENERIC_TOKENS` in place:

```
Etomedac 20 mg                    -> token: mg-s-2525[1.00]
Olopatadin Micro Labs 1 mg        -> token: mg-s-2525[1.00]
Natriumklorid Fresenius Kabi 9 mg -> token: mg-s-2525[1.00]
```

The token `mg` matched a ChEMBL molecule literally named `mg-s-2525`, and it outranked the
correct `olopatadine`. A substance generic list (units, dose words, dosage forms, routes) is
load-bearing, not cosmetic.

### 4. Retrieval must propose, the model must decide — the `metotrexate` trap

```
metotrexate -> ketotrexate[0.80] | metotrexato[0.80] | ketotrexato[0.64] | methotrexate[0.58]
```

**Any auto-accept-top-score rule picks `ketotrexate`, a different drug.** The correct answer is
rank 4. This is the substance version of the 87 recorded Jaro-Winkler false positives, and it
is the whole argument for pick-from-list over fuzzy matching. Name it in the B_assign prompt.

### 5. Greenfield gives something up, and it is bounded

`Botox` is in the v1 index but not in ChEMBL+EPAR; `Etomedac` is in neither. Strings like these
are what the model must re-derive. They land in B_assign's abstain set and then C_mint, which
is the designed path — not a hole.

---

## Implementation

### Phase 0 — freeze the baseline FIRST (blocking; §3.0a is the trap)

`E_emit`'s regression gate compared the labels file with itself for sponsors, and *"a gate that
silently stops measuring is worse than no gate."* `data/trial_substance_labels.csv` is
gitignored (`data/*labels*`), so once overwritten it is unrecoverable from git.

```sh
Rscript helper_scripts/substance_norm_pipeline/1_export_trial_substances.R
Rscript helper_scripts/substance_norm_pipeline/3_build_substance_labels.R
cp data/trial_substance_labels.csv data/trial_substance_labels_baseline.csv
```

Then move `helper_scripts/substance_norm_pipeline/` (except `1_export_trial_substances.R`) and
`config/substance_norm_pipeline/` to `LEGACY/`, mirroring what was done for sponsors.

### Phase 1 — library changes in `helper_scripts/llm_norm/`

Every change is backward-compatible by defaulting to today's sponsor behaviour. **Re-run
`tests/sponsor_v2_idempotence.R` after this phase** — the sponsor pipeline must not move.

**`retrieve.R`**
- `tokens_of()` reads the global `GENERIC_TOKENS` at
  [retrieve.R:137](helper_scripts/llm_norm/retrieve.R#L137). Add a `generic = GENERIC_TOKENS`
  argument and thread it through `build_index()` ([:165](helper_scripts/llm_norm/retrieve.R#L165)),
  `ch_token_idf()` ([:240](helper_scripts/llm_norm/retrieve.R#L240)) and
  `scored_token_pairs()` ([:350](helper_scripts/llm_norm/retrieve.R#L350)).
- Add `SUBSTANCE_GENERIC_TOKENS` beside `.GENERIC_BASE`
  ([:59-99](helper_scripts/llm_norm/retrieve.R#L59-L99)): units (`mg ml mcg g iu ui mbq gbq
  mmol`), dose/form words, routes. Seed it from v1's `.dose_pattern` and `.form_pattern`
  ([normalise_substances.R:32-60](helper_scripts/substance_norm_pipeline/normalise_substances.R#L32-L60)),
  then **verify by posting-list size the way §3.4 did** — print the largest posting lists over
  the substance vocabulary and stoplist what is generic, rather than guessing.
- `fold_forms()` ([:120](helper_scripts/llm_norm/retrieve.R#L120)) is unchanged — the EUCTR
  diacritic-deletion fold of §3.2 applies identically, same registers, same corruption.

**`registry.R`**
- `raw_sponsor` is a literal in 9 places: [:37](helper_scripts/llm_norm/registry.R#L37),
  [:56](helper_scripts/llm_norm/registry.R#L56), [:91](helper_scripts/llm_norm/registry.R#L91),
  [:147](helper_scripts/llm_norm/registry.R#L147), [:221](helper_scripts/llm_norm/registry.R#L221),
  [:231](helper_scripts/llm_norm/registry.R#L231), [:236-237](helper_scripts/llm_norm/registry.R#L236-L237),
  [:313](helper_scripts/llm_norm/registry.R#L313), [:332](helper_scripts/llm_norm/registry.R#L332).
  Thread a `raw_col = "raw_sponsor"` parameter.
- `registry_resolve_labels()` ([:354-363](helper_scripts/llm_norm/registry.R#L354-L363)) hardcodes
  the three output names. Give it a caller-supplied name map.
- Add `salt_form` and `brand` to `REGISTRY_COLS` ([:31](helper_scripts/llm_norm/registry.R#L31)).
  Sponsors leave them `NA`; `write_table_atomic()` already back-fills missing columns
  ([:79-80](helper_scripts/llm_norm/registry.R#L79-L80)), so no sponsor file changes.
- While there: `REGISTRY_COLS` lists `legal_entity` but `registry_empty()`
  ([:45-52](helper_scripts/llm_norm/registry.R#L45-L52)) does not create it. Fix.

**`client.R`** — one change. [:466](helper_scripts/llm_norm/client.R#L466) names
`SPONSOR_NIGHTLY_CAP_USD` in an error string; make the var name an argument.
`llm_budget_guard()` already accepts `cap=`, so the $60 substance cap needs no code change.
**`batch_status.R` — no change**, it is already domain-free.

### Phase 2 — `A_resolve.R` (deterministic, offline, free, re-runnable)

Reads `data/trial_substances_raw.csv`. Writes the registry, assignments, the residue and the
rejected list. Order matters: placebo → junk filter → candidate ladder → registry.

- **Registry cache.** Reuse `config/substance_norm_pipeline/2_chembl_cache.csv` (120,416 rows,
  already committed). Refresh it once at the start with the v1 fetch logic
  ([2_build_substance_index.R:196-266](helper_scripts/substance_norm_pipeline/2_build_substance_index.R#L196-L266))
  since its vintage is unrecorded. **Also add the EPAR cache v1 never had** —
  [2_build_substance_index.R:128-173](helper_scripts/substance_norm_pipeline/2_build_substance_index.R#L128-L173)
  downloads the EMA XLSX unconditionally on every run, including `--no-chembl`, so the pipeline
  cannot run offline today. Write `config/substance_norm_v2/epar_cache.csv`, refreshed by
  `--refresh-epar`.
- **Candidate ladder.** Port `generate_candidates()`
  ([normalise_substances.R:104-125](helper_scripts/substance_norm_pipeline/normalise_substances.R#L104-L125))
  and `clean_alias`/`clean_substance` ([:12-30](helper_scripts/substance_norm_pipeline/normalise_substances.R#L12-L30))
  verbatim. This is the "worked pretty good in v1" part and my 68.6% number is measured with it.
- **Junk filter.** Port the pre-filter at
  [3_build_substance_labels.R:108-117](helper_scripts/substance_norm_pipeline/3_build_substance_labels.R#L108-L117)
  and `is_exploratory_substance()` ([:67-82](helper_scripts/substance_norm_pipeline/3_build_substance_labels.R#L67-L82)).
  Rejected strings are **written out, not dropped silently** — a filter you cannot audit is the
  same failure class as a gate that stops measuring.
- The 724 **ambiguous** registry hits are not resolved here. They go to `B_assign` with their
  competing substances as the candidate slate — the model's pick-from-list is exactly the right
  instrument, and this is strictly better than v1's `check_alias()` ambiguity handling
  ([:251-270](helper_scripts/substance_norm_pipeline/normalise_substances.R#L251-L270)).
- Build the registry with `registry_add()` / `registry_from_clusters()`, `decided_by =
  "registry"`, `confidence = 1.0` for exact hits.

**Gate:** re-derive the four-row table in Context above from A_resolve's own output. Any large
deviation means the port broke something.

### Phase 3 — `B_assign.R` (Sonnet 5, pick-from-list)

Structurally a fork of `C_assign.R`; the parse path, bounds check, cache-key composition and
four-mode block (`--dry-run/--sync/--batch/--poll`) transfer nearly unchanged.

- Index `registry_surface_forms()` output with `build_index(..., ngram_n = 3L)`, retrieve with
  `extra_channels = TRUE`, `ch_ngram` threshold 0.30.
- **Schema unchanged from `ASSIGN_SCHEMA`** ([C_assign.R:101-110](helper_scripts/sponsor_norm_pipeline/C_assign.R#L101-L110)):
  `{chosen_index:int, confidence:number, reason:string}`. One grammar, per §3.1. Sentinels:
  `0` = none of the candidates, `-1` = **not a substance at all**. Bounds checked in R.
- Prompt must state: canonical is the **INN base**; brand → INN; salt → INN base with the salt
  recorded; **do not pick on spelling similarity alone**, and give the `metotrexate` /
  `ketotrexate` / `metotrexato` slate as the worked example; `-1` for dose fragments,
  placeholders (`Not yet assigned`), influenza strain names (`California`, `Wisconsin`,
  `Brisbane` — all real, all in the corpus), excipients and devices.
- Run `--sync --limit=200` as the scale gate before any batch, and check for
  "grammar compilation rate limit" in the output.

### Phase 4 — `C_mint.R` (Opus 5 head / Sonnet 5 tail)

Fork of `B_mint.R`, with `A_block.R`'s canopy blocking folded in — the abstain set is small
enough (low thousands) that a separate blocking script is not worth it. Expose `--threshold`
and `--max-block` and print A_block's tuning report.

- Blocking uses `build_pair_graph()` + `canopy_blocks()`
  ([retrieve.R:404](helper_scripts/llm_norm/retrieve.R#L404), [:460](helper_scripts/llm_norm/retrieve.R#L460))
  with the substance stoplist. **`canopy_blocks`, not `components_of`** — §3.3.
- `--singletons` path is **required**, not optional. §3.6 was the single biggest hole in the
  sponsor run, and here the abstain set will be even more singleton-heavy (8,986 of the 11,189
  work-list strings occur in exactly one trial). Budget for it from the start.
- `MINT_SCHEMA` ([B_mint.R:121-146](helper_scripts/sponsor_norm_pipeline/B_mint.R#L121-L146)) with
  `legal_entity` → `salt_form`, plus `brand`, and `entity_type` → `substance_type` enum:
  `small_molecule, biologic, vaccine, cell_or_gene_therapy, radiopharmaceutical, blood_product,
  diagnostic_agent, supplement_or_excipient, not_a_substance, unknown`.
- Prompt rules: INN base is the canonical; a code name (`BNT162b2`, `AZD1222`) stays a code name
  when no INN exists; vaccine antigen components (`Pertactin`, `Pneumococcal polysaccharide
  serotype 6B`) roll up to the vaccine where one is identifiable, else `not_a_substance`.
- Retry failed blocks on Opus per §3.9 (`--retry-failed --model=claude-opus-5`); the
  out-of-range `member_index` failure was 17x more frequent on Sonnet.

### Phase 5 — `D_consolidate.R` (Opus 5)

Fork with three changes.

- **`MERGE_SCHEMA` unchanged** ([D_consolidate.R:517-535](helper_scripts/sponsor_norm_pipeline/D_consolidate.R#L517-L535)):
  `merge_into` integer array + parallel `confidence`. §3.7 applies verbatim — a boolean over the
  group cannot work, and a substance group is a lexical neighbourhood, not a duplicate set.
- **Drop `--translate` entirely.** INNs are already an international standard; there is no
  "one institution, two languages" analogue. **But keep the sorted-word-bag key** from
  [D_consolidate.R:413-415](helper_scripts/sponsor_norm_pipeline/D_consolidate.R#L413-L415) with
  *no* API call: §3.8 records that the fold-key bonus (punctuation, spacing, diacritics, `&` vs
  `and`) was most of that channel's yield and only one of eight groups came from an actual
  translation. Free, and it catches `ascorbato de sodio` / `sodio ascorbato`.
- **Add a second mis-index guard, and it is the important one.** The sponsor guard
  ([:127-186](helper_scripts/sponsor_norm_pipeline/D_consolidate.R#L127-L186)) blocks a merge when
  type differs AND names are dissimilar. The dangerous substance error is the *opposite*:
  similar names, different drugs — `vinblastine`/`vincristine`, `cisplatin`/`carboplatin`,
  `daunorubicin`/`doxorubicin`. Add: **refuse any merge between two canonicals that both appear
  as distinct ChEMBL `pref_name` values.** That is an external fact, not a model opinion, and it
  has no sponsor equivalent. State these pairs in the prompt as keep-separate examples too.
- Salt rollup (`methotrexate sodium` → `Methotrexate`, `salt_form = sodium`) is a merge with
  `salt_form` carried onto the assignment, decided by this pass.

### Phase 6 — `E_emit.R`

Fork of the sponsor version. Writes `data/trial_substance_labels.csv` (`_id`,
`substance_label`), `data/substance_normalisation_log_v2.csv`, and
`config/substance_norm_v2/E_review_queue.csv`.

- Label shape must match today exactly: `str_to_sentence()` then sorted-unique per trial joined
  with `" / "` ([3_build_substance_labels.R:130](helper_scripts/substance_norm_pipeline/3_build_substance_labels.R#L130),
  [:154-165](helper_scripts/substance_norm_pipeline/3_build_substance_labels.R#L154-L165)).
- **Drop the raw fallback** at [:169-181](helper_scripts/substance_norm_pipeline/3_build_substance_labels.R#L169-L181)
  per the decision above. Expect this to show as `accepted -> unknown` in the diff for trials whose
  only substance was junk; that is the intended change and must be read, not just counted.
- Keep the sponsor exit-code contract: 0 clean, 1 measured a regression, 2 could not measure.
- `--freeze-baseline` must refuse to overwrite an existing baseline.
- Update the substance section of `rmarkdown/preprocessing.Rmd:1178-1320` to read the v2 log.

### Phase 7 — tests

Clone `tests/sponsor_v2_idempotence.R` → `tests/substance_v2_idempotence.R`; only the path block
at [:41-44](tests/sponsor_v2_idempotence.R#L41-L44) is domain-specific. Add the four probe
strings from Evidence §4 as a retrieval fixture — `metotrexate` must offer `methotrexate` in the
slate, and the test asserts the slate, not the top hit.

`tests/fixtures/substance_normalisation_gold.csv` (111 cases) becomes a **regression set, not a
tuning target**, exactly as §7 reframed the sponsor gold set.

---

## Environment and operational notes

- `SUBSTANCE_V2_DIR` (default `config/substance_norm_v2`), mirroring `SPONSOR_V2_DIR`. Honour
  `DATA_DIR` in **all five** new scripts — the sponsor A–E scripts hardcode `pp("data", ...)`
  and only the export script reads `DATA_DIR`; do not inherit that asymmetry.
- **`export ANTHROPIC_API_KEY` in the shell you run from.** Unset, `llm_auth()` shells out to
  `ant auth print-credentials` before the poll branch and stalls silently. `--dry-run` needs it too.
- **The sandbox does not allowlist `www.ebi.ac.uk` or `www.ema.europa.eu`.** Refreshing either
  cache needs `/sandbox` adjusted. `api.anthropic.com` *is* allowlisted now.
- `Rscript helper_scripts/llm_norm/batch_status.R` first whenever anything looks stuck.
- Run `--sync --limit=N` before **every** batch. It caught five run-costing problems on the
  sponsor side, two of them in output that looked successful.
- Do not add package dependencies without asking.

---

## Verification

**Free, offline, decisive — in order:**

1. `Rscript tests/sponsor_v2_idempotence.R` after Phase 1. The library changes are
   backward-compatible or they are wrong.
2. `Rscript helper_scripts/substance_norm_pipeline_v2/A_resolve.R` reproduces the Context table:
   ~16,541 strings / ~67,801 pairs resolved, ~11,189-string residue. Runs offline from the two
   caches, costs nothing, re-runnable.
3. `Rscript tests/substance_v2_idempotence.R` — re-materialising the registry must not resurrect
   merged entities.

**Costs a few cents each, and each one gates a batch:**

4. `B_assign.R --sync --limit=200` — check for "grammar compilation rate limit" (there must be
   none), and check the abstain rate. Sponsors' equivalent gate found the singleton hole.
   Read the slates: if abstentions are being offered 10 candidates and matches 2, retrieval is
   working (§3.6's statistic).
5. `C_mint.R --sync --limit=20` and `--sync --singletons --limit=20`.
6. `D_consolidate.R --sync --limit=5` — confirm the partition returns families, not one verdict,
   and that the ChEMBL-distinct-pref_name guard fires on a planted `vincristine`/`vinblastine`
   pair.

**The decisive gate:**

7. `Rscript .../E_emit.R --diff-only` against `data/trial_substance_labels_baseline.csv`.
   **`accepted -> unknown` must be 0**, excepting trials whose only label came from the dropped
   raw fallback — count those separately and read the list rather than accepting a number.
8. Read the top changed labels by trial count. The intended change is granularity
   (`Methotrexate sodium` → `Methotrexate`); anything else needs explaining.
9. `Rscript rebuild_cache.R` then launch the app and check the **Active Substance** chart and the
   `product_search` dropdown. That is what the rewrite is for — the sponsor equivalent
   (28 Novartis canonicals) was only visible there.

## On commit

Per §9: bump the version in `README.md`, `CHANGELOG.md`, `app.R` line 2, `DATA_PROCESSING_VERSION`
at `app.R:244` (**or the cache will not rebuild**), the About-tab changelog and the footer; add an
`AGENTS/AGENTS.md` section. This is a rewrite, so a minor bump. Never commit `trials_cache.rds`,
`www/preprocessing.html`, or anything matching `data/*labels*`.

**`AGENTS/AGENTS.md:267-293` documents a "Normalisation v2 substance resolution (v0.12.10)" as
completed and verified 2026-08-04, citing `helper_scripts/normalisation_v2/substance_resolution.R`
and four other paths. None of them exist and `git log --all` finds nothing.** Delete or correct
that section as part of this work — it will mislead the next person into thinking this is done.
