# Sponsor normalisation v2 — handover

**Branch:** `normalisation-v2` (cut from `feature/normalisation-reviewer`, which is
where `curation_app/` lives — it is NOT on `main`).
**Status: THE PIPELINE IS COMPLETE AND THE REGRESSION GATE PASSES.** Every pass —
A, B (including singletons), C, D (including the translation channel) and E — has
run against the real corpus, and `E_emit --diff-only` reports **zero
`accepted -> unknown` regressions** against the restored old-pipeline baseline.
`data/trial_sponsor_labels.csv` is written and current.
**Last worked:** 2026-08-15.

| | |
|---|---|
| distinct raw strings assigned | **16,594 / 16,594 (100%)** |
| trial rows labelled | **50,359 / 50,359**, 0 unknown |
| canonical sponsors | **6,954** |
| regressions (`accepted -> unknown`) | **0** |
| improvements (`unknown -> accepted`) | 234 |
| labels changed vs old pipeline | 18,105 (the brand-granularity change — expected) |
| review queue | 2,130 rows / 3,579 trial rows |
| **spend** | **$10.31 of the $60 cap** |

Top of the sponsor chart, which is what the rewrite was for: Novartis 1662,
GlaxoSmithKline 1036, Roche 880, AstraZeneca 810, MSD 732, Pfizer 717, Janssen 606
— one canonical each, against 28 for Novartis under the v1 entity-level mint.

### THE NEXT STEP: COMMIT. Nothing is committed.

~11 untracked paths plus the modified `5_llm_proposals.csv`. Per §9 a commit here
also bumps the version everywhere and adds an `AGENTS.md` section. Current state,
already checked:

| file | current | note |
|---|---|---|
| `CHANGELOG.md` | `## v0.12.4 — 2026-05-31` | format is `## vX.Y.Z — DATE` then `### Section` |
| `app.R:2` | `# app.R  (v0.12.1 — …)` | |
| `app.R:244` | `DATA_PROCESSING_VERSION <- "2026-05-v0.12.1-…"` | **bump this or the cache will not rebuild** |
| `app.R:2899` | About-tab changelog `tags$li` list | says v0.12.0 — already out of step with line 2 |
| `app.R:2924` | footer `v0.12.0 — Sys.Date()` | |
| `AGENTS/AGENTS.md` | `### vX.Y.Z - Title - shipped DATE` | append a section |

This is a rewrite of sponsor normalisation, so **v0.13.0**. Note `app.R` is already
internally inconsistent (v0.12.1 in the header, v0.12.0 in the About tab and
footer) — worth making them agree while bumping.

Do NOT commit `data/trial_sponsor_labels.csv`, `data/trial_sponsor_labels_baseline.csv`,
`trials_cache.rds` or `www/preprocessing.html`.

### Read this before running anything

1. **`export ANTHROPIC_API_KEY` in the shell you run from.** When it is unset,
   `llm_auth()` shells out to `ant auth print-credentials`, and that call sits
   *before* the poll branch in `B_mint.R`. If it stalls you get hours of silence
   with no status lines and no credit movement — which is exactly what happened.
   `llm_dry_run()` also calls `llm_auth()` (it counts tokens over the API), so
   **even `--dry-run` needs credentials.**
2. **The sandbox does not allowlist `api.anthropic.com`, and blocks writes under
   `config/`.** Adjust `/sandbox` or disable it for live runs.
3. **`Rscript helper_scripts/llm_norm/batch_status.R`** answers "is it my
   credentials, the network, or the batch?" in seconds, with no block table and no
   work list. Use it before debugging anything else.
4. Gold adjudication is **not** a blocker — see §7.

Read §3 "Do not undo these" before changing anything in `helper_scripts/llm_norm/`.
Several of those decisions look like over-engineering and are each load-bearing for
a reason that was measured, usually by getting it wrong first.

---

## 1. What this is

Replaces the deterministic sponsor matcher (~4,200 lines of R plus 16,545 committed
alias rows) with a model-built canonical registry. The job is unchanged: map each of
**16,594 distinct raw sponsor strings** (over 50,359 trial rows) to a canonical
organisation name that `app.R` can display.

Two measurements motivated the rewrite:

1. **The old "curated" asset was never curated.** `2_sponsor_alias_index.csv` is
   11,122 `llm_reviewed` + 1,373 `llm_curated` + 3,495 mechanical `self_alias` +
   ~540 rows from EPAR/CTIS/email lookups. **Zero `manual` rows.** The rule layer
   existed to protect what was itself older LLM output.
2. **The corpus is small for an LLM.** Whole-corpus resolution costs ~$35 via the
   Batches API.

### Decisions the user made (do not revisit without asking)

| Decision | Choice |
|---|---|
| Old config | **Regression set only.** Greenfield build; `config/sponsor_norm_pipeline/` is a frozen baseline, never an input. |
| Human review | Reviewer app confirms **low-confidence rows only**, not everything. |
| Models | Sonnet 5 bulk, Opus 5 for minting head + consolidation. |
| Scope | Sponsors now; `llm_norm/` factored so substances can adopt it later. |
| Jaro-Winkler | **Removed entirely.** User's experience, corroborated by 87 recorded false positives. |
| Budget | **Hard cap USD 60 for the whole project.** Enforced in code, not by intention. |
| Retrieval channels | exact + IDF token + structured. n-gram and acronym written, measured, dropped. |
| Gold standard | Built and frozen, but **adjudication is NOT a prerequisite** — see §7. |

---

## 2. Architecture

```
1_export_trial_sponsors.R        (UNCHANGED, still used)
        v  data/trial_sponsors_raw.csv        50,359 rows / 16,594 distinct strings

A_block.R          deterministic, offline, NO decisions
        v  data/sponsor_blocks.csv            2,438 multi-member blocks + 3,877 singletons

B_mint.R           Opus 5 (top 500 blocks) / Sonnet 5 (rest)   cluster-at-a-time
B_mint.R --singletons   Sonnet 5   the 3,837 one-member blocks  (§3.6, REQUIRED)
        v  config/sponsor_norm_v2/B_mint_clusters.csv

C_assign.R         Sonnet 5   pick-from-list, index only
        v  config/sponsor_norm_v2/{registry,assignments}.csv

D_consolidate.R    Opus 5     partition each group into organisations  (--apply to write)
E_emit.R                      labels + reviewer queue + regression diff
        v  data/trial_sponsor_labels.csv      <- the only file app.R reads
```

`app.R` needs **no change**: it selects `_id` + `sponsor_clean` at `app.R:1919-1934`
and `app.R:1985-2000`, and `E_emit.R` writes exactly that shape.

### Why blocking exists when the model does the labelling

This question was asked and is worth keeping answered. Pass B's premise is that a
cluster is named **once, with every variant visible in one request** — that is what
stops `UZ Gent` / `Ghent University Hospital` / `Universitair Ziekenhuis Gent`
becoming three canonicals. You cannot get that by handing a model 16,594 strings and
asking for a clustering: the response would be 16k assignments, past `max_tokens`,
unverifiable. Something must group candidate-same strings first.

For *assignment* (pass C) retrieval is not strictly necessary — a full-registry
prefix would work. It is a cost decision, priced in §6.

---

## 3. Do not undo these

Each of these was measured. Reverting any of them reintroduces a specific, verified failure.

### 3.0 canonical is the BRAND, not the legal entity (mint prompt v2)

**Learned by spending $2.31 and looking at the output.** Mint prompt v1 asked for
the legal entity and set `parent` on subsidiaries. 499 blocks produced **1,563
entities** — 28 canonicals for Novartis, 21 for Sanofi, 14 each for Pfizer, Roche
and Janssen. The old pipeline collapsed all 87 Novartis strings to **2**.

Cause: cluster-at-a-time prevents drift *within* a block, and a company spread over
ten blocks gets named ten times. AstraZeneca came out as **1** canonical purely
because all its variants landed in one block. `D_consolidate` could not repair it —
its prompt correctly refuses to merge a parent with a subsidiary, so the split
survived by design. The two prompts contradicted each other.

`app.R` displays `sponsor_clean` in the Top Sponsors chart and the sponsor filter, so
28 Novartis rows there is worse than what shipped. v2 asks for the brand
(`Novartis`) and keeps the entity in a new `legal_entity` column — strictly more
information than the old pipeline retained. Academic and public bodies are exempt:
an institution IS its own canonical, and hospitals never roll up. Brands with their
own identity (Genentech, Genzyme, MedImmune, Sandoz) keep separate canonicals with
`parent` set, and `D_consolidate` is told not to merge those.

**Do not "simplify" this back to entity-level without changing `app.R` too.**

Confirmed working: `blk_00001` under v2 put all 40 Novartis variants into ONE
cluster at confidence 0.95 — absorbing `NOVARTIS FARMA S.P.A.`,
`Novartis Consumer Health`, `Novartis Sverige AB`, `Novartis Finland Oy` and
`Novartis Vaccines and Diagnostics GmbH & Co. KG`. v1 gave `Novartis Pharma` at
0.80 and split the rest.

**`legal_entity` is populated on 1,535 of 3,509 entities (44%)** — corrected
2026-08-13 against the materialised `registry.csv`. An earlier version of this
document said it "comes back empty / is always NA"; that was measured on the v1
mint and is wrong for v2. `parent` is set on 128. Treat it as present-but-partial:
usable as a hint, not as a column you can join on. Nothing is lost where it is
absent — `raw_sponsor` on every assignment row preserves the exact original string.

### 3.0a Operational bugs already fixed — do not reintroduce

Both were found by running, and both killed a run *after* the API had been paid for.

- **`llm_cache_merge` type mismatch.** `llm_cache_read()` reads every column as
  character (it must: a column can be entirely NA on the first run and readr would
  guess `logical`), while fresh rows carry declared `integer`/`numeric`/`logical`.
  `bind_rows()` refuses to combine them. The merge now coerces the cached side to
  the fresh rows' types. Symptom if reverted: `Can't combine <character> and
  <integer>` at the end of a successful batch.
- **`fallbacks` is not universally supported.** `llm_body()` attached
  `fallbacks: "default"` to every sync request; `claude-sonnet-5` returns
  400 `does not support the \`fallbacks\` parameter`. Opus 5 does support it,
  which is why the Opus head mint never hit this and the Sonnet tail would have
  failed all 1,939 requests. Now gated by `model_supports_fallbacks()` — an
  allowlist, because a missing fallback costs a refusal retry while a wrong
  guess costs the run. Caught by `--sync --limit=3`, which is the entire
  argument for running it.
- **Spend was double-counted per batch.** `llm_batch_usage()` reports the usage of
  the WHOLE batch, so running `--batch` and then `--poll=<same id>` for stragglers
  logged the same tokens twice — one Sonnet batch recorded $1.70 twice, inflating
  the running total by 26%. `llm_spend_record()` is now idempotent on `batch_id`.
  This matters because the budget guard reads that total: an inflated ledger
  refuses runs you can afford.
- **A `--poll` MUST repeat the flags of the submission.** The poll branch rebuilds
  the work list from the command line, and `llm_batch_results` matches results to
  it by `custom_id`. Poll with different flags and *nothing* matches, so every
  result is dropped. Cost 2026-08-13: a 3,857-request singleton batch polled as
  `--poll=<id>` without `--singletons` rebuilt the default 83-block work list and
  reported `wrote 0 rows (0 assigned, 0 failed)` plus a recorded spend — which
  reads exactly like success. Recovered by re-polling with `--singletons`; batch
  results are retained 29 days, so this is never fatal if spotted.
  `llm_batch_results` now **stops** when a non-empty batch matches no work item,
  and names the flags to check. Do not soften that back into a warning.
- **`n_requests` was recorded as `nrow(work)`, not the batch size.** Same incident:
  the ledger got 83 against 3,857 real requests. `n_requests` feeds the dry-run
  calibration (`output_tokens / n_requests`), so a too-small value inflates every
  later estimate — the same failure mode as double-counted spend, where an
  inflated ledger refuses runs you can afford. `llm_batch_usage()` now returns `n`
  and every caller records that. The one bad row was corrected by hand.
- **`E_emit`'s regression baseline defaulted to the file `E_emit` writes.** The
  gate compared `data/trial_sponsor_labels.csv` against itself, so the first full
  `E_emit` overwrote the old pipeline's labels and every later `--diff-only`
  measured the new labels against the previous NEW labels — while still printing a
  healthy table (50,208 unchanged, no regression row). **A gate that silently
  stops measuring is worse than no gate.** The baseline is now a frozen snapshot
  at `data/trial_sponsor_labels_baseline.csv`, taken once and never moved;
  `--baseline=` still overrides. If it is ever lost, regenerate it — the old
  pipeline is intact and needs no DB and no API:

  ```sh
  cp data/trial_sponsor_labels.csv /tmp/v2_labels.csv
  Rscript LEGACY/sponsor_norm_pipeline/3_build_sponsor_labels.R
  mv data/trial_sponsor_labels.csv data/trial_sponsor_labels_baseline.csv
  cp /tmp/v2_labels.csv data/trial_sponsor_labels.csv
  ```

  Both label files are gitignored (`data/*labels*`), so neither is recoverable
  from git — only by the four lines above. **And the script that regenerates the
  baseline now lives in `LEGACY/`, which is also gitignored** — it is in git
  history, so recover it with
  `git show <commit>:helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R`
  if a fresh clone ever needs to rebuild the baseline.
- **`llm_batch_wait` died on a DNS timeout.** A batch may run for up to 24 hours,
  so a transient network failure over that window is close to certain, and the
  work is server-side — losing the poll must not lose the batch. It now tolerates
  failures, gives up only after 20 consecutive ones, and prints `--poll=<id>` on
  the way out. `llm_batch_results` and `llm_batch_usage` are hardened the same way.

### 3.1 The output schema must be constant per pass

`5_llm_resolve.R:303-315` records the original failure: a per-row `enum` made every
request a distinct grammar, the org limit is **20 grammar compilations per minute**,
and a 222-request batch lost **190 requests**. 159 NA rows from that run are still in
`config/sponsor_norm_pipeline/5_llm_proposals.csv`.

`llm_spec()` takes exactly one schema and **rejects a function** with an explanatory
error. Constrain answers with an **integer index** into a per-row candidate list plus
a bounds check in R — same guarantee (the model cannot invent a name), one grammar.
`llm_dry_run()` prints the schema sha256 as evidence.

### 3.2 Dual fold — EUCTR deletes diacritics, it does not transliterate

`Abteilung für Anästhesie` is stored as `Abteilung fr Ansthesie`. All 14,285 distinct
EUCTR strings are pure ASCII; CTIS keeps its diacritics.

Verified: the *deleted* form appears verbatim in the corpus, the transliterated form
(`Abteilung fur Anasthesie`) does not. Cross-register collisions for the 48 diacritic
CTIS strings: raw 0 → transliterate 1 → **deletion 3**.

**This means `clean_sponsor_alias()` (Latin-ASCII transliteration) is the wrong fold
for this corpus and has never joined these pairs.** It maps CTIS
`Universitätsklinikum` → `universitatsklinikum` and EUCTR `Universittsklinikum` →
`universittsklinikum`, still unequal.

`fold_forms()` indexes **both**. Needs no detector — every string gets both forms.
The stoplist is also expanded through both folds, because `universitt` (the mangled
form) was the 6th largest posting list in the corpus and sailed past a stoplist
containing only `universitat`.

**There is a THIRD form the fold does not cover: expansion** (`ä`→`ae`, `ö`→`oe`,
`ü`→`ue`), found 2026-08-13 in live singleton mint output. The same organisation
appears both ways — `Klinikum der Universitaet Muenchen AöR` beside
`Klinikum Der Universitat Munchen AöR`, `Technische Universitaet Dresden` beside
`Technische Universitat Dresden`, `Vaestra Goetalandsregionen` beside
`Vastra Gotalandsregionen`. Measured: **20 strings in 10 pairs, all true
positives, zero false collisions** on this corpus. `universitaet` and `universitat`
are different tokens, so these never join and land as separate blocks.

**Verified after the singleton batch: 7 of 9 pairs self-healed**, exactly as
predicted — the mint prompt restores the correct spelling, both members produce
one canonical, and `registry_from_clusters` absorbs them. `Universitaet Muenchen`
and `Universitat Munchen` both became `Klinikum der Universität München`.

The 2 that did NOT converge are `Västra Götalandsregionen` vs
`Vastra Gotalandsregionen` — the model restored diacritics on one member and not
the other. **`fold_forms()` cannot join those either**, and this is where §3.2's
conclusion stops applying: transliteration is the wrong fold for RAW strings
(EUCTR deletes, it does not transliterate) but it is the RIGHT fold for minted
CANONICALS, because the model restores diacritics rather than deleting them. The
registry is a different population from the corpus. If pass D leaves diacritic
duplicates behind, add a transliteration fold **to the D graph only** — not to
`fold_forms()`, which would undo §3.2. Residual today is 2 entities; not worth a
re-mint.

### 3.3 Canopy blocking, not connected components

Tried components first: transitive closure put **11,838 of 16,594 strings in one
component**, and chunking it produced blocks like
`Novartis / AstraZeneca / Novo Nordisk / Roche / AP-HP` — the highest-impact strings
with nothing in common.

`canopy_blocks()` seeds a block from one string and admits only strings similar **to
the seed**, so membership is a statement about the seed rather than a path through
the graph. Seeds are taken in descending trial impact.

`components_of()` is retained and **is** correct in `D_consolidate.R`: that graph is
a few thousand canonicals at threshold 0.70, where closure gives tight groups and
"A=B and B=C implies A=C" is what you want.

### 3.4 The postings cap must stay high, with generics stoplisted

`MAX_POSTINGS` was 60. That excluded any token in more than 60 strings — which is
exactly the tokens naming the **largest** sponsors, because they have the most
variants: pfizer 159, sanofi 119, roche 97, novartis 87, janssen 65, bayer 62. Result:
87 Novartis strings across 48 blocks, 36 as singletons.

Measured: even with **no cap** the corpus generates only 1.84M pairs — there is no
explosion to protect against. The largest posting lists are generic words
(`pharmaceuticals` 746, `therapeutics` 698, `pharma` 657, `nhs` 546), which belong in
the stoplist, not behind a cap.

Now: `MAX_POSTINGS = 500` plus a measured generic list. Novartis → 10 blocks / 1
singleton; pfizer and bayer → 0 singletons.

### 3.5 Concatenated bigrams match but must not count toward IDF mass

`Astra Zeneca AB` and `AstraZeneca AB` share no token, scored 0.48, and sat as
singletons beside a 40-member AstraZeneca block. `tokens_of(concat_adjacent = TRUE)`
emits adjacent pairs concatenated.

**But** including bigrams in a string's own IDF mass inflates the score denominator
and penalises every pair that does not share one — measured, singletons went
3,980 → **4,836**. They are indexed with `is_concat = TRUE` and excluded from `mass`
in `scored_token_pairs()`. Correct version: **3,877**.

---

### 3.6 Singletons MUST be minted, and a lower re-block threshold will not do it

**This is what the C gate found, and it is the thing to fix first.**

`B_mint.R` mints multi-member blocks only. A singleton therefore never gets a
canonical, so no registry entry exists for it, so pass C has nothing to match it
against and can only abstain — permanently. Measured on the first live 200-request
gate:

| | |
|---|---|
| assigned straight from the mint | 12,457 strings |
| left for pass C | 4,084 |
| ...of those, in **singleton** blocks | **3,837 (94%)** |
| gate result | 53 matched, **147 abstained**, 0 failed |
| abstainers that are singleton-block strings | 120 of 147 |
| trial rows still unassigned | 5,944 of 50,359 (11.8%) |

**The abstentions are correct, not a retrieval failure.** The model's own reasons
say so — "Sutro Biopharma is not listed among the candidates", "Athera
Biotechnologies AB is not listed". One statistic settles it: **abstentions were
offered a median of 10 candidates, matches a median of 2.** A full slate of 10 is
retrieval scraping the barrel; one or two strong hits is retrieval working.

**The designed round-2 fix does not reach these.** Re-blocking abstainers at 0.30
only helps a string that has a lexical neighbour to block *with*. A string with no
neighbour at 0.50 has none at 0.30 either — lowering the threshold just groups it
with noise, and minting a noise cluster is *worse* than minting nothing, because a
wrong canonical then attracts other strings through pass C.

Fixed by `B_mint.R --singletons` (plus `--only=<csv>` to target
`C_abstained.csv`). Deliberately a separate run, not a widened default: it routes
entirely to Sonnet, and mixing it into the main run would split the prompt cache.

**It reuses `PROMPT_VERSION`, `MINT_SCHEMA` and the whole parse path unchanged** —
one grammar, verified identical schema sha256 across both runs. Only the user-turn
framing differs, because "group these 1 sponsor strings" invites a split that
cannot exist.

**Why this also rescues strings retrieval can never reach.** The mint prompt's
rule 3 already resolves a department to its PARENT institution. So
`1. Frauenklinik der LMU-Innenstadt` — which shares no token with
`Klinikum der Universitat Munchen` and is therefore invisible to blocking at 0.50,
to retrieval at 0.15 *and* to pass D — mints as the parent's name from the model's
own knowledge. And `registry_from_clusters` (`registry.R:179-195`) assigns a raw
string to an **existing** entity whenever the canonical matches exactly: no new
entity, no merge request, no cost. The model's world knowledge becomes the join key
the text channels cannot supply.

Residual risk, measured: of 2,389 abstainers only **138 (6%)** carry a sub-unit
marker at all, covering **303 of 50,359 trial rows (0.6%)** — and most of those 138
are standalone institutions (`ISTITUTO SUPERIORE DI SANITA`, `INSERM`,
`Instituto Catalán de Oncología`) that are correctly their own canonical. The
collapse is exact-string, so case and diacritic near-misses still make two entities;
that is pass D's job.

### 3.7 Pass D partitions the group — a boolean over the whole group cannot work

**Found by checking D against the real 3,509-entity registry before spending on it.**

D's v1 schema was `same_organisation: boolean` — one verdict for the whole
component. That question is unanswerable for most components, because **a component
is a lexical neighbourhood, not a duplicate set.** The Leuven component holds five
spellings of UZ Leuven *and* two of KU Leuven. A university and its university
hospital are correctly different organisations, so the only honest answer was "no"
— and all five hospital duplicates survived. The right answer produced the wrong
outcome.

Not a Leuven quirk: **134 of the 287 askable groups mixed entity types.** One held
`AM-Pharma`, `Lek Pharmaceuticals`, `Q-Med` and four unrelated German
`Verein zur Förderung…` foundations.

**Splitting the group by `entity_type` in R was tried and rejected.** It strands
211 entities whose only neighbour is typed differently, and it does not work anyway
— single-type groups are just as mixed (one held `Hospital Universitari de
Bellvitge` and `Hospital Universitario de Bellvitge`, a genuine duplicate pair,
beside four unrelated Catalan hospitals). `entity_type` is also model output, so
making it a hard barrier lets one mistyped entry veto a correct merge. It is now
shown to the model as **evidence**, not enforced as a rule.

v2 returns `merge_into`: one index per member, naming the entry whose name
survives, or itself to stand alone. Leuven answers `[1,1,1,4,4,6]`. `confidence` is
a parallel array, so `--apply` gates **per fold** at 0.80 instead of letting one
shaky member veto the confident merges beside it.

**This does not violate §3.1.** An array of integers is ONE grammar however long it
gets — the schema does not vary with group size. What caused the grammar-compilation
rate limit was a per-row *enum*, whose members changed with every request. Bounds
are checked in R exactly as `C_assign` does, and `components_of` resolves chains
(`3→2→1`) and cycles (`1↔2`) without special-casing either.

**VERIFIED LIVE 2026-08-13, and it found a second failure.** The partition works:
the Vienna group returned three families in one request (`Medizinische Universität
Wien` ← `Medizinische Universitat Wien` at 0.97, `Allgemeines Krankenhaus der Stadt
Wien` ← `Allgemeines Krankenhaus Wien`, `Wilhelminenspital` ←
`Wilhelminenspital der Stadt Wien`), and Aarhus returned three while keeping the
hospital and university families apart. The boolean could not have expressed either.

**But 1 of 8 proposed merges contradicted the model's own stated reasoning.** For
the Sanofi/Lille group it wrote *"Institut Pasteur, Institut Pasteur de Lille, and
the Lille hospitals are distinct entities"* — and then pointed `Centre Hospitalier
Universitaire de Lille` (hospital, 17 raw strings) at `Sanofi Pasteur MSD`
(industry) at **0.90 confidence, which `--apply` would have executed**. The prose
was right and the index was wrong.

**Confidence does not separate these** — the bad merge scored 0.90, the same as
the good ones. Raising the 0.80 apply threshold would not have caught it.

`--apply` holds back a merge only when **BOTH** signals fire: the entity types
differ AND the two canonicals are dissimilar (character bigrams over an
accent-folded string, < 0.30). Each signal ALONE is worse than useless, measured
over all 267 proposed merges from the full batch:

| rule | blocked | of which correct |
|---|---|---|
| entity_type mismatch alone | 21 | ~20 |
| name dissimilarity alone | 14 | ~13 |
| **both together** | **1** | **0** |

Type alone fails because the type is model output and disagrees with itself across
mints of one organisation — `Charité – Universitätsmedizin Berlin` (hospital) and
`Charité - Universitätsmedizin Berlin` (academic) differ by a dash. Dissimilarity
alone fails because it fires hardest on the pass's BEST merges: acronym expansions
(`UZ Leuven` ← `Universitair Ziekenhuis Leuven`, `HUS` ← `Helsingin ja Uudenmaan
sairaanhoitopiiri`) and diacritic pairs (`Grünenthal` ← `Grunenthal`). Two entries
that are genuinely one organisation almost always share a type or a name; sharing
neither is the tell.

**A backstop, not a proof.** It cannot catch a mis-index between two same-type
entities with similar names. The merges file is written before `--apply` precisely
so it can be read first.

**Oversized components are re-split, not skipped.** `MAX_GROUP = 12` was dropping 5
components covering **723 entities — 46% of every entity with a duplicate
neighbour** — the largest with 529 members, to an "inspect by hand" message. The
earlier claim here that closure "gives tight groups" over canonicals was simply
false at this scale. They are now re-split by canopy (seeded on trial impact, the
same instrument A_block uses and for the same reason):

| | groups | entities askable | stranded |
|---|---|---|---|
| before | 287 | 841 | **723** |
| after | **457** | **1,391** | **0** |

### 3.8 The translation channel — one institution, two languages

**Found by looking at the emitted labels, which is the only place it shows.** An
institution recorded in two languages produces two canonicals sharing no token, so
the pair graph never proposes them and the model is never asked:

| institution | split across | trial rows |
|---|---|---|
| Med Uni Vienna | `Medizinische Universität Wien` (469) + `Medical University of Vienna` (26) | **495** |
| Ghent Univ Hospital | `Ghent University Hospital` (128) + `Universitair Ziekenhuis Gent` (32) + `UZ Gent` (4) | **164** |
| UZ Brussel | `UZ Brussel` (57) + `Universitair Ziekenhuis Brussel` (25) | **82** |
| Milano-Bicocca | `Università degli Studi di Milano-Bicocca` (9) + `University of Milano-Bicocca` (2) | 11 |

From ten hand-picked city patterns, so a floor, not a total. The Vienna split is
the **rank-12 sponsor in the app**. None appear in the review queue: all are 0.90+
confidence, and confidence is right — each name is a correct name.

**No lexical channel reaches this, all three measured, not assumed:**

- Token overlap: `University Hospital Gent` and `University Hospital Ghent` share
  only `university` and `hospital`, both **stoplisted generics**. The only
  discriminating tokens are the ones that differ. This is the stoplist that makes
  blocking work (§3.4) removing the only thing these strings have in common.
- Character n-grams (`extra_channels = TRUE`): adds no Ghent pair, and returns NA
  scores. Consistent with n-gram having been measured and dropped for blocking.
- Indexing surface forms rather than canonicals (what `C_assign` does): does not
  bridge it either, for the same stoplist reason.

Translation is semantic knowledge. `--translate` asks the model for each entity's
established English name and uses that as a **blocking key** — no gazetteer, no
city table, no rule layer. It is the same move that lets a sub-unit find its parent
in `B_mint`: put the model's world knowledge where retrieval cannot go.

```sh
Rscript .../D_consolidate.R --translate --sync --limit=20   # gate: most must ECHO
Rscript .../D_consolidate.R --translate --batch
Rscript .../D_consolidate.R --batch                          # picks the cache up
```

Scoped by `--min-trials` (default 20) — 401 entities carrying **64% of all trial
rows**; the tail below that is 1–2 trials each. Sonnet, ~$0.50.

**Matching English names only PROPOSE a group.** The partition prompt still
decides and the mis-index guard still applies, so a wrong English name costs one
request and a "leave it alone", never a wrong merge. Entities answering below 0.6
confidence are dropped before edges are built.

**What to check on the gate: most answers must ECHO the input.** `Novartis` →
`Novartis`, `Hospices Civils de Lyon` → itself. A model that renames everything
manufactures false groups — that is the failure mode, not a bad translation.

Verified on the real registry with a synthetic cache: Ghent 3 components → 1,
Vienna 2 → 1, Brussels 2 → 1.

**EVERY live entity is keyed, not just the translated ones** — English name where
there is one, own canonical otherwise. Keying only the translated rows was the
first version and it is a silent no-op: the channel could then connect two
TRANSLATED entities and nothing else, and the English-side counterpart is usually
the small one `--min-trials` excluded. `Medizinische Universität Wien` (469 trial
rows) has to reach `Medical University of Vienna` (26), which was never asked.
Symptom if reverted: the `+N pair(s) from matching English names` line never
prints even with a populated cache.

**Unplanned bonus, and it is most of the yield.** Because the key is an
accent-folded sorted word bag over every canonical, it catches variants the token
graph cannot see — measured on the first 40 translations, 8 groups / 17 entities,
zero false pairs, and only ONE of them came from a translation:

| pair caught | variation |
|---|---|
| `Linköping University` / `Linkoping University` | diacritic — the case §3.2 said needed transliteration |
| `St James's Hospital` / `St. James's Hospital` | punctuation |
| `Geiser Pharma` / `GeiserPHARMA`, `PARI Pharma` / `PARIPharma` | spacing |
| `Research & Development Department` ×3 | `&` vs `and`, and case |
| `GETNE - Grupo Español…` / `Grupo Español… (GETNE)` | acronym position |

**English is a PIVOT, so every language pair is covered without enumerating any.**
French↔Dutch, Finnish↔Swedish and German↔Italian all meet on the same key; N
languages collapse to one key rather than N² mappings. Nothing needs adding per
language.

**The key is a SORTED BAG OF WORDS, not the string.** Two language variants get
translated independently, so they arrive in different word orders — `Ghent
University Hospital` vs `University Hospital Ghent` is one answer twice, and an
exact key calls them different. The key lowercases, folds accents, drops
connectives (`of the and de du di der la le …`), sorts and dedupes. Verified it
matches all four word-order variants tested and still separates `Ghent University
Hospital` from `Ghent University`, `University of Milan` from `Milano-Bicocca`,
and `University Hospital Zurich` from `Basel`.

**THE TRAP, and it is in this corpus.** Universities that split along language
lines translate to the SAME English name and would be merged:

| | trials | |
|---|---|---|
| `KU Leuven` | 86 | Dutch |
| `Universite Catholique de Louvain` + `UCLouvain` | 11 | French — split 1968 |
| `Vrije Universiteit Brussel` | 7 | Dutch |
| `Universite Libre de Bruxelles` | 6 | French — split 1969 |
| `Free University of Brussels` | 1 | ambiguous between the last two |

The translate prompt names both cases explicitly and tells the model to echo the
native form when English sources use it (`KU Leuven`, `Charité`, `INSERM`).
Independently, `--min-trials=20` puts UCLouvain (4), ULB (6) and VUB (7) out of
scope entirely, so the default is safe by construction — **the guard matters only
if you lower `--min-trials`.** Do not lower it without re-reading this.

## 3.9 What pass B actually produced (verified 2026-08-13)

| | v1 (entity) | v2 (brand) |
|---|---|---|
| blocks minted | 499 | **2,438 (all)** |
| canonicals | 1,563 | 3,509 |
| canonicals per block | 3.13 | **1.44** |
| Novartis / Pfizer / Glaxo / AstraZeneca / Lilly / Amgen / Bayer | 28 / 14 / 11 / 1 / — / — / 9 | **1 each** |
| Roche, Janssen | 14, 14 | 2, 2 (Roche+Genentech, Janssen+Ortho-McNeil) |
| Sanofi | 21 | 3 (Sanofi, Genzyme, Sanofi Pasteur) |
| Merck | 10 | 7 — **correct, see below** |

**Merck at 7 is right, not residual splitting.** MSD (61 strings), Merck Sharp &
Dohme (14) and Merck & Co. (12) are three names for one US company and are
`D_consolidate`'s job to merge. What matters is that **Merck KGaA (38) and Merck
Serono (3) stayed separate from MSD** — the rule held. Sanofi Pasteur MSD (a joint
venture), Merck Generics and Merckle are genuinely different organisations.

Canonicals-per-block is 1.44 rather than 1.0 because blocking is deliberately
recall-oriented: a block legitimately contains more than one organisation and the
model splits it. That is correct behaviour, not leftover drift.

**84 blocks failed, and they turned out to be the ONLY thing left broken.** The
model returned a `member_index` beyond the block size — it invented a cluster
member — so R rejected the response rather than storing a wrong cluster.

An earlier version of this section called them "not worth fixing". That was wrong,
and measuring the E_emit gate is what showed it. After the singleton mint,
**every** remaining unassigned string traced to these blocks: 165 strings, 256
trial rows, and **all 177 `accepted -> unknown` regressions** — the one thing
standing between this rewrite and a clean gate. Zero singletons and zero genuine
pass-C abstentions were involved.

**It is a model-capability failure, not a prompt failure.** Measured: Sonnet failed
83 of ~2,431 blocks (3.4%), Opus 1 of ~500 (0.2%) — 17x. Forty of the 84 were
TWO-member blocks answered with an index above 2. Retrying Sonnet on a prompt
Sonnet already mishandled mostly reproduces the failure, so the retry changes the
model instead of the prompt (which would need a version bump and a full re-mint):

```sh
Rscript .../B_mint.R --batch --retry-failed --model=claude-opus-5
```

`--retry-failed` selects only blocks cached with `canonical = NA`. `--model` is
**refused unless combined with a restricting flag** — it is part of the cache key,
so an unrestricted `--model` would invalidate all ~2,900 cached blocks and re-mint
the corpus at the new price.

## 4. File inventory

### New, untracked

Plus, generated during the run and not in the table below:
`config/sponsor_norm_v2/{registry,assignments,C_assign_decisions,C_abstained,D_consolidate_merges,D_translate,E_review_queue}.csv`
and `data/trial_sponsor_labels{,_baseline}.csv` (both gitignored — see §3.0a for
how to regenerate the baseline, which git cannot restore).

| Path | Lines | Tested |
|---|---|---|
| `helper_scripts/llm_norm/client.R` | ~430 | offline: schema constancy, fallbacks placement, pricing, budget guard, cache merge, duplicate custom_id |
| `helper_scripts/llm_norm/retrieve.R` | ~430 | offline: dual fold, JW-trap avoidance, IDF ranking, structured channel, union-find |
| `helper_scripts/llm_norm/registry.R` | ~330 | offline: merge chains, cycles, human pinning, routing, no-silent-drop |
| `helper_scripts/llm_norm/batch_status.R` | ~110 | **run this first when anything looks stuck** — isolates credentials / network / batch state, and carries `--cancel` |
| `helper_scripts/sponsor_norm_pipeline/A_block.R` | ~200 | **runs clean on the real corpus, 42s** |
| `helper_scripts/sponsor_norm_pipeline/B_mint.R` | ~350 | offline: 7 malformed-response shapes. **LIVE: 2,931 requests.** `--singletons` path built and gated offline, not yet run live |
| `helper_scripts/sponsor_norm_pipeline/C_assign.R` | ~300 | offline: index bounds, registry materialisation. **LIVE: 200 requests, 0 failures** |
| `helper_scripts/sponsor_norm_pipeline/D_consolidate.R` | ~330 | offline: 8 response shapes incl. partition, chains, cycles, bad arrays; canopy re-split verified on the real registry. **No live response yet** |
| `helper_scripts/sponsor_norm_pipeline/E_emit.R` | ~180 | parses; not yet run (needs a registry) |
| `tests/gold/` | — | `verify_fixtures.R` drift detection tested both directions |
| `data/sponsor_blocks.csv` | 16,594 rows | generated output, regenerate freely |
| `config/sponsor_norm_v2/B_mint_clusters.csv` | live | mint cache; may hold BOTH v1 and v2 rows, `C_assign` keeps the newest version only |
| `config/sponsor_norm_v2/archive/B_mint_clusters_v1.csv` | 6,923 rows | the v1 (entity-level) mint, kept for before/after comparison. Paid-for Opus 5 output — do not delete |
| `config/sponsor_norm_v2/llm_spend.csv` | live | actual spend from returned usage |

Test scripts live in the session scratchpad, **not** in the repo. If you want them
kept, move them into `tests/`.

### Also modified

`config/sponsor_norm_pipeline/5_llm_proposals.csv` — an **uncommitted** re-run that
resolved 156 of the 159 grammar-rate-limit failures (159 NA → 3 NA). Real work. Do
not discard; it improves the regression baseline.

---

## 5. How to run

```sh
# ALWAYS export this in the shell you run from. Unset, llm_auth() shells out to
# `ant auth print-credentials`, which sits BEFORE the poll branch in B_mint.R —
# a stall there looks exactly like a hung batch.
export ANTHROPIC_API_KEY='sk-ant-...'      # or: ant auth login

# When anything looks stuck, run this BEFORE debugging anything else.
Rscript helper_scripts/llm_norm/batch_status.R                 # recent batches
Rscript helper_scripts/llm_norm/batch_status.R msgbatch_01...  # one batch
Rscript helper_scripts/llm_norm/batch_status.R --cancel msgbatch_01...
```

**The sandbox does not allowlist `api.anthropic.com`.** Live runs need `/sandbox`
adjusted or the sandbox disabled.

```sh
# 1. blocking — deterministic, offline, re-runnable
Rscript helper_scripts/sponsor_norm_pipeline/A_block.R

# 2. mint — START HERE for the first live test, ~3 requests, a few cents
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --dry-run
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --sync --limit=3
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --batch

# 2b. SINGLETONS — pass C cannot work without them (§3.6). 3,877 minted.
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --sync --singletons --limit=20
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --batch --singletons
#     or, to mint only what a previous C pass could not place:
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --batch --singletons \
  --only=config/sponsor_norm_v2/C_abstained.csv

# 3. assign — --sync --limit=200 IS THE SCALE GATE. Check for
#    "grammar compilation rate limit" in the output. There should be none.
#    If any appear, DO NOT submit the batch — the schema has become per-row.
#    RUN THIS AFTER 2b, NOT BEFORE: minting changes every candidate list, and
#    the cache key includes cands_sha, so answers bought now are thrown away.
Rscript helper_scripts/sponsor_norm_pipeline/C_assign.R --sync --limit=200
Rscript helper_scripts/sponsor_norm_pipeline/C_assign.R --batch

# 4. round 2: whatever still abstains after singletons are minted. The 0.30
#    re-block only helps strings that HAVE a neighbour — see §3.6 before
#    assuming this step will clear the remainder.
Rscript helper_scripts/sponsor_norm_pipeline/A_block.R \
  --threshold=0.30 --only=config/sponsor_norm_v2/C_abstained.csv
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --batch
Rscript helper_scripts/sponsor_norm_pipeline/C_assign.R --batch --round=2

# 5. consolidate.
#    --translate FIRST: it is a grouping channel the merge pass reads, and
#    without it cross-language splits are never even proposed (§3.8).
Rscript helper_scripts/sponsor_norm_pipeline/D_consolidate.R --translate --sync --limit=20
Rscript helper_scripts/sponsor_norm_pipeline/D_consolidate.R --translate --batch
Rscript helper_scripts/sponsor_norm_pipeline/D_consolidate.R --sync --limit=5
Rscript helper_scripts/sponsor_norm_pipeline/D_consolidate.R --batch
Rscript helper_scripts/sponsor_norm_pipeline/D_consolidate.R --apply
#    re-mint any blocks that failed, on the better model (§3.9)
Rscript helper_scripts/sponsor_norm_pipeline/B_mint.R --batch --retry-failed --model=claude-opus-5

# 6. emit + the decisive gate
Rscript helper_scripts/sponsor_norm_pipeline/E_emit.R --diff-only
Rscript helper_scripts/sponsor_norm_pipeline/E_emit.R
```

Every pass resolves only absent cache keys, so re-running costs nothing.

---

## 6. Budget

**Hard cap USD 60**, enforced by `llm_budget_guard()`. Spend is recorded from the
usage actually returned by each batch (`llm_batch_usage()`), not from estimates, and
accumulates in `config/sponsor_norm_v2/llm_spend.csv`.

| Pass | Model | Requests | Estimate | Actual |
|---|---|---|---|---|
| B mint (head) v1 | Opus 5 | 499 | ~$6 | **$2.31** (superseded — wrong granularity) |
| B mint (head) v2 | Opus 5 | 497 | ~$15 | **$2.40** |
| B mint (tail) v2 | Sonnet 5 | 1,935 | ~$24 | **$1.70** |
| B mint singletons | Sonnet 5 | 3,857 | ~$3 | **$2.50** |
| B mint retry (failed blocks) | Opus 5 | 83 | — | **$0.18** |
| C assign | Sonnet 5 | 373 (sync only) | — | **not recorded** — see below |
| D consolidate | Opus 5 | 585 + 102 | ~$7 | **$1.12** |
| D translate | Sonnet 5 | 361 | ~$0.50 | **$0.09** |
| **Ledger total** | | | | **$10.31 of the $60 cap** |

Pass C never needed a batch. After the singletons were minted, the registry
materialisation assigned nearly everything directly and only 373 strings were ever
worth asking about — all of them handled by `--sync` gates.

**`--sync` spend is not recorded anywhere.** `llm_spend_record()` is only called on
the batch and poll paths, so every `--sync` gate is invisible to the ledger and to
`llm_budget_guard()`. The amounts are small (a 200-request gate is cents), but the
ledger is a floor, not a total. Worth closing if sync is used more heavily.

Every actual came in at a fraction of estimate, because the dry run assumed the
response fills a quarter of `max_tokens` (2,048 tokens) when minting actually used
**264**. `llm_dry_run()` now calibrates from `llm_spend.csv` history for the same
pass and model, falling back to the old heuristic only when there is no history —
and it says which basis it used, so an unexplained number never reaches the guard.

Prompt caching works well inside a batch: the v2 head recorded 980,392 cache-read
tokens against 217,535 fresh input, the tail 3,863,307 against 191,518. Cache reads
bill at ~0.1x, which is most of why actuals undershoot.

The v1 head batch came in at **a third of the estimate** ($2.31 vs ~$6), so the
dry-run costing is conservative — it assumes the response fills a quarter of
`max_tokens`, which minting does not. Treat estimates as a ceiling.

A Sonnet 5 tail batch of 1,938 was submitted on the v1 prompt and **cancelled**
(`msgbatch_01H8nULyR5zQHpfLxrp9Nf4f`) once the granularity problem was found.

Notes that will otherwise be re-derived:

- **Sonnet 5 introductory pricing ($2/$10) ends 2026-08-31.** After that pass C
  roughly doubles. Encoded with its date in `client.R`, so the estimate self-corrects.
- **Opus 4.8 is not cheaper than Opus 5** — same $5/$25, same tokenizer. Sonnet 4.6 is
  a ±$10 swing that flips direction on 2026-08-31. This was asked and priced.
- `--full-registry` on pass C (all canonicals in the cached prefix, no retrieval) costs
  ~$86 with perfect cache hits and ~$860 without; **batch requests cannot read a cache
  entry another is still writing**, so the hit rate is unpredictable. The guard
  permits it on `--gold-only` (~$2) and refuses it on the corpus. That is the intended
  use: settle the design empirically, not by argument.
- Thinking is ON by default on Opus 5 and bills as output — the dominant cost
  variance. `effort = "low"` throughout. **Do not set `thinking: disabled` on Opus 5**:
  it can leak `<thinking>` tags and is rejected above `high` effort.

---

## 7. The gold standard — built, frozen, NOT a prerequisite

`tests/gold/fixtures/` holds 995 stratified cases (433 round 1, 562 sealed held-out,
71 flagged for blind re-adjudication), blinded, with a sha256 manifest and a working
drift-detecting verifier.

**It is unadjudicated, and the user should not be blocked on adjudicating it.** That
conclusion was reached explicitly:

- 433 cases at ~30–60s each is **4–7 hours** of judgement, on a project whose premise
  was that too much time had already gone into this.
- **The regression diff needs no adjudication.** `E_emit.R --diff-only` classifies all
  47,665 trial rows against the current baseline; `accepted → unknown` must be zero.
  That is the real safety net and it is free.
- **The reviewer app accumulates ground truth as a by-product.** Every row in
  `config/review_ledger/review_decisions.csv` is human truth, and in a month it is a
  bigger, more representative benchmark than 433 cases frozen today.
- `tests/fixtures/sponsor_normalisation_gold.csv` already has 116 human-authored cases.

The blinding, sealed predictions and inter-rater apparatus are **validation-study
ceremony**, imported from a benchmark harness found on the old `feature/normalisation-v2`
branch. Retained because they are already built and cost nothing idle.

**If drift detection is later wanted, ~50 adjudicated cases is enough** — sufficient to
catch a regression, not sufficient to publish.

**The code no longer references the gold set as a tuning target** (done 2026-08-12).
`A_block.R` now documents tuning the blocking threshold from its own printed output —
score distribution, block-size distribution, and the three largest blocks in full —
with a rising singleton count and, one pass later, a rising abstention rate in
`C_assign` as the signal that it is too high.

`--gold-only` in `C_assign.R` survives, deliberately, but reframed: the frozen sample
is a **stratified subset** (across trial-count band, register, text form and the
adversarial families), which makes it the right cheap population for the
retrieval-vs-`--full-registry` A/B. That comparison diffs two candidate sources
against **each other**, so it needs no adjudication at all.

Current thresholds are all judgement, not measurement — state this plainly rather
than implying they are validated:

| Threshold | Value | Where |
|---|---|---|
| blocking pair score | 0.50 | `A_block.R --threshold` |
| retrieval min score | 0.15 (round 1), 0.05 (round 2+) | `C_assign.R` |
| review routing | conf < 0.75, or n_trials>=20 and conf < 0.90 | `registry.R::route_for_review` |
| merge apply | conf >= 0.80 | `D_consolidate.R --apply` |
| max block | 40 | `A_block.R --max-block` |

---

## 8. Known gaps

1. **`A0_extract_evidence.R` does not exist.** The structured channel (CTIS
   `businessKey`, EUCTR email domain, postcode) is therefore inert — `A_block.R` says
   so on every run. It is the **only channel that reaches strings sharing no text with
   their match** (`1. Frauenklinik der LMU-Innenstadt` → `Klinikum Der Universitat
   Munchen AoR`), so it is the highest-value remaining addition. Extraction logic
   exists to copy from `2_build_sponsor_index.R:1249-1600`. Output shape:
   `raw_sponsor, evidence_key` at `data/sponsor_structured_evidence.csv`.

2. ~~**~316 mutual-singleton strings.**~~ **WRONG — the real number is 3,837, and
   the designed fix does not work.** Measured on the live C gate, not estimated. See
   §3.6: singletons are never minted at all, so pass C abstains on all of them, and
   the round-2 re-block at 0.30 cannot reach a string that has no neighbour at any
   threshold. Fixed by `B_mint --singletons`, **not yet run against the API.**

3. **Blocks cap at 40 members**, so a sponsor with more variants spills into a second
   block. Pass D is what reunites them. Roche is currently spread over 27 blocks —
   partly correct (`F. Hoffmann-La Roche`, `Roche Registration` and `Roche Products`
   are different legal entities), partly the cap.

4. **`curation_app` wiring for gold adjudication is deferred** at the user's request.
   Note when picking it up: `review_card.R` is built around accept/edit/reject of a
   *proposal*, while adjudication is *authoring blind* with four extra fields, and it
   must **not** write into `config/review_ledger/review_decisions.csv` — mixing gold
   truth with pipeline review decisions destroys the independence the benchmark rests
   on. Reuse the app shell, give it its own panel and store.

5. **`C_assign` has now run live (200 requests, clean). `D_consolidate` and
   `E_emit` still have not.** D's new partition parser is unit-tested against eight
   response shapes — the Leuven partition, chains, cycles, wrong-length arrays,
   out-of-range and zero indices, scalar confidence, and an API-level refusal — and
   the whole script runs offline to the point of the first API call. Its behaviour
   on live responses is still unverified. Gate it: `D_consolidate --sync --limit=5`.

   `registry.csv` (3,509 entities) and `assignments.csv` (12,510 rows) now exist.
   They are derived from the mint cache, not authored — regenerate freely.

5a. **83 mint blocks failed** (0.78% of trial rows) with an out-of-range
   `member_index`. They retry automatically on any `B_mint` re-run. See §3.9.

6. **The mint cache holds two prompt generations.** `C_assign` keeps only the
   newest, and `registry_from_clusters` tolerates the older rows' missing columns —
   but if a third generation appears, check that filter still does what you want.

7. **`legal_entity` is partial, not empty** — populated on 1,535 of 3,509 entities
   (44%), `parent` on 128. An earlier note here claimed it was always NA; that was
   true of the v1 mint only. Do not join on it; treat it as a hint.

8. Nothing is committed. ~10 untracked paths plus the modified `5_llm_proposals.csv`
   (which is real work: 156 recovered grammar-rate-limit failures).

---

## 9. Conventions

- `AGENTS/AGENTS.md` is the project convention file (there is no root `CLAUDE.md`).
- **Do not add package dependencies without permission.** Union-find is hand-written
  for this reason.
- On commit: bump the version everywhere — `README.md`, the About-tab changelog in
  `app.R`, `CHANGELOG.md` — and add an `AGENTS.md` section describing what was built.
- Never commit `trials_cache.rds` or `www/preprocessing.html`.
- The DB is MessagePack; use `ctrdata::dbGetFieldsIntoDf`, never `rawToChar` +
  `jsonlite`.
- `data/*labels*` and `data/*log*` are gitignored — rebuilt, not committed.

## 9a. What is left, in priority order

Everything below is optional — the gate passes without any of it.

1. **Commit.** See the header. Nothing is committed.
2. **4 D groups failed** with an off-by-one `merge_into` length (the model
   returned one element more than the group had). Rejected cleanly, never
   mis-parsed. They retry on any `D_consolidate --batch` re-run.
3. **1 merge held back** by the mis-index guard — `Sanofi Pasteur MSD` ←
   `Centre Hospitalier Universitaire de Lille`, sitting in
   `D_consolidate_merges.csv`. The model's own prose says they are distinct, so
   the right resolution is to leave them unmerged; nothing to do unless you want
   the row gone.
4. **18,105 changed labels are unaudited.** They are the intended brand-granularity
   change (`Janssen-Cilag International NV` → `Janssen`), and `E_emit --diff-only`
   prints the top ones by trial count. Worth reading that list once — it is what a
   user of the app actually sees.
5. **Cross-language splits below `--min-trials=20` are untouched.** The translate
   channel covered the 401 entities carrying 64% of trial rows. The tail is 1-2
   trials each; lower `--min-trials` to reach it, but read §3.8's trap warning
   first — UCLouvain, ULB and VUB all sit in that tail.
6. **`A0_extract_evidence.R` still does not exist** (§8.1). It is now the only
   remaining channel that could reach a string sharing no text with its match.

Deliberately NOT done, with reasons:

- **754 `individual` entities (person names) were left in.** Measured: 861 trial
  rows (1.71%), and the highest-ranked person name is **rank 574** — none appears
  in the top 500 sponsors, so the Top Sponsors chart never shows one. They are
  real investigator-initiated sponsors and useful in the filter.
- **Native-language names were left in.** `Medizinische Universität Wien` is rank
  12, but rank 10 is `Assistance Publique - Hôpitaux de Paris`, which nobody would
  want anglicised. Switching to English exonyms would make the chart *less*
  consistent and costs a re-mint.

## 10. Suggested first move

**Every pass has run. The gate passes. The work left is the commit** — see the
header for the exact version-bump inventory.

If you are picking this up cold and want to re-verify before trusting it, the
whole chain is re-runnable and costs nothing, because every pass answers only
absent cache keys:

```sh
Rscript helper_scripts/sponsor_norm_pipeline/E_emit.R --diff-only
```

That is the decisive check on its own: 50,359 trial rows classified against the
frozen old-pipeline baseline, and `accepted -> unknown` must be **0**. If the
baseline is missing, the script now says so and prints the four lines that
regenerate it (§3.0a) instead of silently comparing the file with itself.

**The one habit worth carrying forward: run `--sync --limit=N` before every
batch.** It caught five problems that would each have cost a full batch:

| caught by the sync gate | would have cost |
|---|---|
| v1 entity-vs-brand granularity | $2.31 plus a cancelled tail |
| `fallbacks` 400 on Sonnet 5 | all 1,939 tail requests |
| singleton coverage hole | a C batch answering 73% abstentions |
| D's boolean schema being unable to partition | the whole D batch |
| translate edges built only among translated rows | a silent no-op channel |

Two of those five were found by reading output that *looked* successful. The
pipeline's failures are mostly quiet ones — a batch that writes 0 rows, a gate
that stops measuring, a schema that answers the wrong question confidently — so
prefer checking a number over checking for an error.
