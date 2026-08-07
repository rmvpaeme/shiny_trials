# Normalisation reviewer app + provenance correction

**Status: delivered.** 10 commits on `feature/normalisation-reviewer`. This file
was the plan; it has been updated to record what was actually built, where the
plan was wrong, and what was found on the way. Figures below are the corrected
ones — several early numbers in this plan were artefacts of my own bad join and
are called out where they mattered.

The multi-user deployment is a separate plan:
[`normalisation-reviewer-multiuser.md`](normalisation-reviewer-multiuser.md).

## Context

Sponsor and substance normalisation on `main` were curated almost entirely by
LLM agents working through review queues in chunks. Two problems followed:

1. **The provenance metadata lied.** `AGENTS/sponsor_manual_curation.md:79-93`
   instructed the curating agent to stamp its rows `source: manual`. Every alias
   the LLM added therefore looked hand-verified. No human review had happened,
   so ~3,100 config rows claimed a provenance they did not have — and `manual`
   outranks `llm_reviewed` in the index builder, so the mislabel actively won
   conflicts.
2. **There was no practical way for a human to do the review.** The only tools
   were `curate_sponsors.R` / `curate_substances.R`: single-key stdin loops, no
   evidence panel, no undo, no durable history. `curate_substances.R` did not
   run at all — see Part C.

Outcome: an honest provenance vocabulary reserving `manual` for real human
decisions, and a Shiny app where those decisions can be made.

## Scope note

"Low-confidence substance aliases" is **not** the ~74k rows carrying
`confidence_prior = 0.65`. That is a *tier prior* on the ChEMBL synonym table,
not a match confidence. The genuinely unconfident matches are the fuzzy ones:
**2,544** distinct raw strings, **zero auto-accepted** (JW ≥ 0.80 only ever
yields `review`/`unknown`). 665 already sit in the queue; **1,878** are
singletons dropped by the `n_occurrences >= 2` filter in
`build_substance_labels.R`. Sponsor fuzzy/containment matching is negligible:
104 rows, all scoring > 92.

---

## Part A — Provenance correction ✅

`manual` → `llm_curated`, ranked **1**, identical to where `manual` sat, so
output could not change. `manual` is now written in exactly one place:
`curation_app/apply.R`, when a human accepts a row.

| File | Field | Rows |
|---|---|---:|
| `manual_sponsor_aliases.csv` | `source` | 1,383 |
| `manual_brand_to_substance.csv` | `source` | 1,380 |
| `canonical_substances.csv` | `source` | 370 |
| `manual_substance_overrides.csv` | `reason` | 294 |

**The critical edit** was `llm_curated = 1` in `source_priority`
(`build_sponsor_index.R:191`). Without it the 1,383 relabelled rows fall to the
default priority of 99 — silently, with no error. `alias_type` now mirrors the
row's own source instead of a blanket `"manual"`, which also corrected the 131
`ctis_businesskey` seed rows caught by the same stamp (1504 = 1373 + 131).

Root cause fixed in `AGENTS/sponsor_manual_curation.md` and
`substance_manual_curation.md`, so the next curation pass writes `llm_curated`.

### Verified behaviour-neutral

- `trial_sponsor_labels.csv` **byte-identical** (47,665 rows)
- **0** of 16,594 raw sponsors changed resolution
- **0** canonical changes across 13,011 shared `(alias, source)` index rows
- gold fixtures identical before/after — sponsor 91/25, substance 107/4 —
  measured against a config tree rebuilt from `HEAD`, not against the figures in
  `normalisation_v2_handover.md`, which were produced by a different method

### Decisions taken

- **ROR tier stays off** (`--no-ror`), matching how the committed index was
  built. Enabling it adds 118 aliases and changes 33 canonicals — a real data
  decision, but not a provenance fix.
- **EPAR drift was kept.** The rebuild picked up newly authorised medicines
  (Bimervax, Opzelura, lerodalcibep) and an MAH rename (`abbvie ltd` →
  `abbvie limited`): +1 sponsor, +19 substance aliases. Upstream refresh, not a
  behaviour change.
- **`confidence_prior` stays at 1.** Lowering it would trip the `>= 0.95` gates
  in `normalise_sponsors.R:576,615`.
- **Filenames keep their `manual_` prefix** — renaming touches ~20 scripts for
  no functional gain.
- **The v2 worktree's 1,246 `reviewed_v1_snapshot:manual` rows** were left
  alone; their `catalog_id`/`decision_id` hashes derive from `source`.

---

## Part B — The reviewer app ✅

`curation_app/`, standalone from the 6,850-line dashboard `app.R`, using
`bslib` + `filelock` (approved) alongside existing dependencies.

```
curation_app/
  app.R              navbar, reviewer identity, progress + tail-audit panel
  R/tiers.R          tier registry, loaders, impact, canonical pools, detectors
  R/review_card.R    the review module used by every tier
  R/store.R          atomic writes, file locking, the append-only ledger
  apply.R            replays the ledger onto the config files
  README.md
```

### Tiers — 10, not the 5 originally planned

| Tier | In scope | Note |
|---|---:|---|
| Sponsor fragments | 194 groups | **added** — 2,428 trials split across duplicate canonicals |
| Substance conflicts | 42 | **added** — one raw string overridden to two substances |
| Sponsor LLM-reviewed | 2,344 of 11,899 | **added** — filtered to ≥3 trials (60% of impact) |
| Substance LLM-reviewed | 2,607 of 10,250 | **added** — filtered to ≥3 occurrences |
| Sponsor queue | 102 | |
| Substance queue | 1,320 | |
| Sponsor LLM aliases | 1,383 | |
| Substance LLM aliases | 1,380 | |
| Substance canonicals | 370 | **added** |
| Fuzzy singletons | 1,878 | |

### Review card — beyond the plan

- **Trial references.** Each row lists the EUCTR/CTIS trials the raw value came
  from, linked to the public registers, with a country summary. This is what
  settles an ambiguous name: `UCL` appears on four trials, all `-GB`, so it is
  University College London and not Université catholique de Louvain (`-BE`).
  URL shapes reuse `app.R:3721-3724`.
- **Editable siblings.** Aliases sharing the canonical are actionable —
  **Detach** records a rejection against the file that alias actually lives in.
  Rows from generated tiers (EPAR, CTIS businessKey, email domain, ChEMBL) are
  marked `generated` and left read-only, because a rebuild would undo any edit.
- **Constrained inputs.** The proposed value is a server-side selectize over the
  canonical pool (8,309 sponsors / 17,603 substances); creating a new canonical
  is allowed but warns and is recorded as `created_new_canonical`.
  `sponsor_type` / `alias_type` / `substance_type` are fixed-vocabulary
  dropdowns; `sponsor_parent` / `sponsor_group` use the canonical pool.
- **Impact threshold + tail audit.** The LLM-reviewed tiers default to ≥3 and
  expose a slider. The excluded tail is *sampled*: a fixed 200-row random sample
  seeded on the tier id, with a Wilson 95% interval reported on the Progress
  tab. Wilson rather than the normal approximation because the expected result
  is an error rate near zero — 0/200 bounds the tail at ≤1.9%, which is what
  makes skipping ~18,000 rows defensible rather than merely convenient.

### Persistence

Every decision appends to `config/review_ledger/review_decisions.csv` via
`filelock` + atomic rename. Queue tiers additionally get their decision columns
written in the format `curate_*.R --export` already reads. `apply.R` replays the
ledger idempotently and is the only writer of `source: manual`.

---

## Part C — Pipeline fixes ✅

1. **`build_substance_labels.R` dropped the queue's decision columns**, so
   `curate_substances.R` aborted with "Queue is missing columns" on every run.
   The substance CLI had never worked.
2. **`--keep-decided`** added to both queue writers, so a rebuilt queue can
   carry decisions forward instead of dropping them.
3. **`rebuild_cache.R`** now passes `--write-queue` to both pipelines.

---

## Bugs found that were not in the plan

| Bug | Effect |
|---|---|
| `empty_index_rows()` called but never defined (`build_sponsor_index.R:1598`) | the script aborted in the location tier — it had never run to completion |
| `build_substance_labels.R` queue schema | `curate_substances.R` unusable |
| Tier modules bound lazily in a `for` loop | all six panels showed the last tier's data (**reported from the running app**) |
| Impact keyed on `tolower(trimws(x))` instead of `clean_sponsor_alias()` | every sponsor with a comma, period or accent scored zero impact. `Incyte Corp.` (54 trials) and `Lilly S.A.` (37) were excluded from review scope; "37% of the tier resolves zero trials" was an artefact — the real figure is 4% |
| Alias index re-parsed per row change | 111k-row CSV parsed on every navigation; now cached |

---

## Data quality found by spot-checking `llm_reviewed`

The tiers are largely correct at the level of *which entity*, and wrong at the
level of *which spelling*:

- **Sponsor:** 0 duplicate rows, 0 contradictory aliases, entities correctly
  identified. But 194 fragmentation groups / 2,428 trials carry the same entity
  under several canonical spellings — casing, punctuation, `The`, `&` vs `and`,
  legal suffixes.
- **Substance:** 4,296 exact duplicate rows (removed — verified a no-op against
  byte-identical logs and labels). 42 aliases map to two different substances,
  mostly INN/USAN pairs but six are different drugs
  (`clobazam`/`clonazepam`, `gantenerumab`/`ganitumab`, `iopamidol`/`palmidrol`,
  `rifapentine`/`trientine`, `purified pertussis toxoid`/`tetanus toxoid`,
  `vitamina d3`/`vitamin k`).
- **Root cause:** the chunked curation *appended* its corrections instead of
  replacing the original rows, and first match wins. The file records both:
  `"purified pertussis toxoid","tetanus toxoid","chunk 3"` then
  `"...","pertussis toxoid","chunk 4"`.
- **Live impact: 6 trials.** `purified pertussis toxoid` → Tetanus toxoid (4)
  and `vitamina d3` → Vitamin k (2). The other four are masked because
  `manual_override` happens to resolve them correctly.
- **No mechanical fix exists**: "later chunk wins" repairs `vitamina d3` but
  breaks `clobazam`, whose correct value is the earlier row. Hence the tiers.

Detector caveat: two earlier fragmentation detectors were wrong in opposite
directions — Jaro-Winkler's prefix boost scored `University of Cologne` against
`University of Liverpool`, then stopwording `university`/`hospital` merged
`University of Leicester` with `University Hospitals of Leicester`. The shipped
version keeps entity-type words distinctive, but some groups still mix a real
duplicate with a real distinction, so the tier needs judgement, not rubber-stamping.

---

## Verification performed

1. Provenance edit behaviour-neutral — labels byte-identical, 0 resolution
   changes, 0 canonical changes.
2. Gold fixtures unchanged before/after, both domains.
3. No `manual` left in any `source`/`alias_type` field; `llm_curated` totals
   1,383 / 1,380 / 370.
4. App round-trip — accept/edit/reject into ledger and queue CSV, across tiers.
5. `apply.R --write` sets `source: manual` on accept, removes rejects into the
   negative-alias list, and is a **byte-identical no-op** on rerun.
6. Dedupe verified as a no-op: full rebuild produced byte-identical substance
   log and trial labels.
7. Audit sampling reproducible across calls and drawn only from below the
   threshold; Wilson bounds checked at 0, 3 and 30 errors in 200.

Test decisions were reverted rather than kept — a QA reviewer writing
`source: manual` would recreate the exact problem this branch fixed.

---

## Not done / open

- **`rebuild_cache.R` end-to-end has not been run.** Steps 1–7 above cover the
  normalisation pipeline; the full cache rebuild and `preprocessing.Rmd` knit
  were not exercised.
- **No version bump or CHANGELOG entry.** Per `AGENTS/AGENTS.md:3-11` a release
  needs `app.R` About tab, `README.md`, `CHANGELOG.md` and an `AGENTS.md`
  section. Deliberately left for whoever cuts the release.
- **The 6 live substance errors are still live.** They sit at the top of the
  Substance conflicts tier awaiting a human decision.
- **`config/` writes require `dangerouslyDisableSandbox`** in this environment.
  Four `allowWrite`/`Edit` settings entries were tried and had no effect; the
  denying rule was never located.
