# Substance normalisation v2 — handover

**Branch:** `substance-normalisation-v2`, cut from `main` (where sponsor v2 lives, v0.20.0).
**Status: COMPLETE AND LIVE IN THE CACHE. The regression gate is clean and
`--assert-no-regressions` exits 0. The nightly is wired.**
**Last worked:** 2026-08-22. **Nothing is committed.**

| | |
|---|---|
| distinct raw strings | **33,529** over **98,760** trial-substance pairs, 45,584 trials |
| A: resolved by ChEMBL+EPAR alone, no model | **16,627 strings / 68,222 pairs (69.1%)** |
| A: placebo rule | 1,826 / 2,347 |
| A: rejected as not-a-substance (deterministic) | 871 / 6,339 |
| B: matched by the model | 4,084 |
| B: judged not-a-substance | 817 |
| B: permanently refused by the bio classifier | 196 strings / 257 pairs (0.26%) |
| C: blocks minted | 5,219 (1,218 multi-member + 4,001 singletons) |
| D: salt rollups applied | 1,602 |
| D: model merges applied | ~678 |
| **live registry entities** | **19,556** |
| **assignments** | **31,483** |
| **trial-substance pairs accepted** | **89,688 of 97,620 (91.9%)** |
| **pairs still unknown** | **44** |
| **trials with a label in the cache** | **44,029 of 50,485** |
| **regressions (`accepted -> unknown`)** | **0** |
| **total spend** | **$23.16 of the $60 cap** |

The corpus figures moved once mid-project because `1_export` re-ran against a
refreshed cache (§4.7c). These are the current ones.

For contrast, v1 on this same corpus leaves **7,003 unique strings unknown** and puts
**4,350 trials on a raw-string fallback**.

### What is left: THE COMMIT

Everything else is done. `rebuild_cache.R` has run end to end, the cache carries
v2 labels for 44,029 trials, `preprocessing.Rmd` reports v2, and both test suites
pass with sponsor blocking still byte-identical.

The Active Substance chart, as the app now shows it:

```
Placebo 1941 | Paclitaxel 746 | Cisplatin 706 | Sodium chloride 701
Dexamethasone 637 | Carboplatin 632 | Pembrolizumab 626 | Rituximab 624
Cyclophosphamide 610 | Fluorouracil 603 | Bevacizumab 593 | Gemcitabine 567
```

Clean INN names, no salt forms, no duplicates, no dosage language.

Remaining:
1. Move `helper_scripts/substance_norm_pipeline/` and
   `config/substance_norm_pipeline/` to `LEGACY/`. Safe now — the export script
   has been copied into the v2 directory. Keep v1 until you are sure you will not
   need to regenerate the baseline.
2. Bump the version in `README.md`, `CHANGELOG.md`, `app.R:2`,
   **`DATA_PROCESSING_VERSION` at `app.R:244`** (or the cache will not rebuild),
   the About-tab changelog and the footer.
3. Add an `AGENTS.md` section, and **DELETE `AGENTS/AGENTS.md:267-293`** — it
   claims substance v2 was completed and verified on 2026-08-04, citing five
   paths that do not exist.

### Two commands that are destructive or wasteful — read before running

- **`A_resolve.R` with no flags now REFUSES** once B and C have run, because a full
  rebuild writes `registry.csv` and `assignments.csv` from the reference tables alone
  and discards every model-minted entity and assignment (13,021 of them when the guard
  was added). Use `--apply-overrides` to pin `manual_overrides.csv` / `inn_names.csv`
  onto the existing registry, or `--force` to rebuild and lose the work deliberately.
- **Do not run `B_assign --rebuild-lists` between C_mint runs.** C_mint's cache key is
  `sha256(block members)` and its blocks come from `B_abstained.csv`; rebuilding that
  list after `--materialise` shrinks it, changing every block's membership and every
  cache key, forcing a full paid re-mint.

### The one thing to know before touching anything

**The pass order is inverted relative to sponsors, and that is the whole design.**
Sponsors had no canonical vocabulary, so B_mint invented one and C_assign matched
against it. Substances already have one — ChEMBL `pref_name` plus the EMA medicines
report, 17,272 canonicals and 89,046 aliases — so:

```
sponsors:   block -> mint -> assign -> consolidate -> emit
substances: RESOLVE -> assign -> mint -> consolidate -> emit
```

That inversion is what makes the model's work list 14,205 strings instead of 33,529.
Do not "align" the letters with the sponsor pipeline.

---

## 1. Architecture

```
1_export_trial_substances.R          (v1 script, UNCHANGED, still used)
        v  data/trial_substances_raw.csv        33,529 distinct / 98,760 pairs

A_resolve.R      deterministic, offline, free, ~90s. NO model.
        v  config/substance_norm_v2/{registry,assignments,registry_aliases}.csv
        v  data/substance_residue.csv    14,205 strings for the model
        v  data/substance_rejected.csv      871 strings, audited not discarded

B_assign.R       Sonnet 5   pick-from-list, index only        (~= sponsor C_assign)
        v  assignments.csv + B_abstained.csv + B_not_substance.csv

C_mint.R         Opus 5 head / Sonnet 5 tail, cluster-at-a-time
                 (blocking folded in; ~= sponsor A_block + B_mint)
        v  C_mint_clusters.csv   --materialise folds them into the registry

D_consolidate.R  --rollup is DETERMINISTIC (no model); --batch is Opus 5
E_emit.R                      labels + reviewer queue + regression diff
        v  data/trial_substance_labels.csv    <- the only file app.R reads
```

**`app.R` needs no change.** It reads `_id` + `substance_label` at `app.R:1811-1839`
and re-joins on the cache-hit path at `app.R:2069-2082`; `E_emit.R` writes that shape,
with the same `str_to_sentence()` casing and `" / "` join v1 used.

---

## 2. How to run

EVERY step below has been run against the real corpus. Re-running is free — each pass
resolves only absent cache keys, and B_assign skips on the STRING rather than the cache
key (§4.7b) so a re-run does not re-ask what it has already answered.

```sh
export ANTHROPIC_API_KEY='sk-ant-...'    # unset, llm_auth() shells out to
                                         # `ant auth print-credentials` and STALLS
                                         # before the poll branch. --dry-run needs
                                         # it too: it counts tokens over the API.
```

**The sandbox blocks writes under `config/` and does not allowlist `api.anthropic.com`,
`www.ebi.ac.uk` or `www.ema.europa.eu`.** Adjust `/sandbox` or run outside it.

```sh
# ---- OFFLINE, already done, free to repeat ----
Rscript helper_scripts/substance_norm_pipeline_v2/A_resolve.R
Rscript helper_scripts/substance_norm_pipeline_v2/B_assign.R --candidates-only
Rscript helper_scripts/substance_norm_pipeline_v2/C_mint.R  --blocks-only
Rscript helper_scripts/substance_norm_pipeline_v2/D_consolidate.R --rollup
Rscript tests/substance_v2_idempotence.R
Rscript tests/sponsor_v2_idempotence.R          # must stay green — shared library

# ---- NEEDS THE API ----
# 1. assign. THE SCALE GATE. Check for "grammar compilation rate limit" (none),
#    and read the -1 answers — those are the ones no filter could have caught.
Rscript .../B_assign.R --sync --limit=200
Rscript .../B_assign.R --batch

# 2. mint whatever B abstained on. --singletons is REQUIRED, not optional (§4.3).
Rscript .../C_mint.R --sync --limit=20
Rscript .../C_mint.R --batch
Rscript .../C_mint.R --batch --singletons
Rscript .../C_mint.R --batch --retry-failed --model=claude-opus-5
Rscript .../C_mint.R --materialise

# 3. consolidate. --rollup FIRST and it costs nothing.
Rscript .../D_consolidate.R --rollup --apply
Rscript .../D_consolidate.R --sync --limit=5
Rscript .../D_consolidate.R --batch
Rscript .../D_consolidate.R --apply

# 3b. pin the hand-mapped strings and the INN names (free, no model)
Rscript .../A_resolve.R --apply-overrides

# 4. emit + the decisive gate
Rscript .../E_emit.R --diff-only
Rscript .../E_emit.R
```

Every pass resolves only absent cache keys, so re-running costs nothing.

---

## 3. Decisions the user made (do not revisit without asking)

| Decision | Choice |
|---|---|
| Canonical granularity | **INN base.** `Methotrexate` absorbs the salt, the brand and the German pack label. `salt_form` and `brand` are separate registry columns. |
| Combination products | Keep v1's single pipe-joined canonical (`amoxicillin\|clavulanic acid`). Not split. |
| v1 curated CSVs | **Regression baseline only, never an input.** Greenfield, as for sponsors. |
| Non-substances | Cheap deterministic filter, then an explicit `not_a_substance` model answer for the rest. **v1's raw-string fallback is dropped.** |
| Budget | USD 60 cap, own ledger at `config/substance_norm_v2/llm_spend.csv`. |
| `confidence_prior` | **Dropped.** See §5.1. |
| Unvalidated thresholds | **Omit them rather than invent them.** See §5.2 — this cost one retracted claim already. |

Greenfield was justified by measurement, not analogy: **zero `manual` rows in any
`config/substance_norm_pipeline/` file.** `canonical_substances.csv` is 370
`llm_curated`, `substance_llm_reviewed.csv` is 10,275 `llm_reviewed`, all from
sessions whose model, prompt and date nobody recorded.

---

## 4. Do not undo these

### 4.1 The junk filter must not reject a string for MENTIONING a dosage form

Two separate defects, both found by reading output.

**v1's filter (`3_build_substance_labels.R:67-82`) rejects any string containing a
dosage-form word.** Measured against real corpus strings:

```
Pembrolizumab concentrate for solution for infusion  -> REJECTED by v1
Humira 40 mg solution for injection                  -> REJECTED by v1
Methotrexat 10mg Tabletten                           -> REJECTED by v1
Rx Abemaciclib Ramiven 50 mg film coated tablets     -> REJECTED by v1
Not yet assigned                                     -> KEPT by v1
California                                           -> KEPT by v1
```

Four real drugs discarded; a placeholder and an influenza strain kept.

**Then my replacement had its own version of it.** It demanded a run of three
letters, which discarded every investigational compound code in the corpus:
`PF-06480605`, `MK-3475A` (pembrolizumab), `TL-895`, `K201`, `18F-RO948`,
`11C-SB207145`, `EO2463`, `GS030-DP`. **532 strings / 786 trial pairs**, silently.

The correct question is not "does this mention a dosage form" but "is anything left
once the dosage language is removed", **and digits count as content** — for a code
name the digits ARE the name. `junk_reason()` now strips dose/form/unit language and
accepts either a 3+ letter word or any letter-plus-digit combination.

**Anything the filter cannot confidently call junk goes to the model**, which has an
explicit `-1` answer. A string wrongly kept costs one cheap request; a string wrongly
rejected is gone and nothing downstream will ever ask about it again.

Accents are folded **before** matching, not after. Matching first left
`ml Konzentrat zur Herstellung einer Infusionslösung` (100 trials, pure packaging)
looking like a substance.

### 4.2 The identity tie-break, and why it is not confidence 1.0 by accident

An alias mapping to several substances normally goes to the model. Not when one of
those substances IS the alias: `tacrolimus` -> {tacrolimus, tacrolimus anhydrous}, and
the bare INN is both correct and what the INN-base decision asks for. Measured: settles
**86 strings / 421 trial pairs** — TACROLIMUS (126 trials), Fingolimod, Cefuroxime,
Bicalutamide — leaving 627 genuinely ambiguous.

`canon_lut` sorts identity rows first, or the tie-break would fire and still pick the
wrong side of it.

These rows carry `channel = "registry_identity"`, distinct from `"registry"`. That is a
FACT, not a score — a rule applied to an ambiguity is worth being able to find later,
and inventing a lower confidence for it would be the move §5.1 exists to prevent.

### 4.3 Singletons must be minted

Not yet demonstrated here, but it was the single largest hole in the sponsor rewrite
(3,837 strings) and the arithmetic is worse here: **8,986 of the residue strings occur
in exactly one trial**. A string with no lexical neighbour is never in a multi-member
block, so it is never minted, so nothing ever assigns it. `C_mint.R --singletons` is
required, and it routes entirely to Sonnet so it does not split the Opus prompt cache.

### 4.4 The salt rollup is deterministic, and the elemental guard is load-bearing

ChEMBL `pref_name`s are frequently salt-specific, so pass A resolves
`ATORVASTATIN CALCIUM` to a canonical of that name. `D_consolidate --rollup` proposes
**1,596 rollups** over the registry (605 of them on canonicals the corpus actually
reaches, covering 6,039 trial pairs): `fluticasone propionate -> fluticasone`,
`doxorubicin hydrochloride -> doxorubicin`.

**`ELEMENTAL_BASE` is what stops `sodium chloride -> sodium` and
`calcium carbonate -> calcium`.** Both bare elements are real ChEMBL pref_names, so the
registry check alone does not catch it. Verified: 0 rollups into a bare element.

`salt_form` moves onto the winner only when every entry rolling into it carries the
same one, or the registry would claim "Metoprolol is the succinate".

### 4.4a Salt words are generic in pass D, and NOT in pass A

The two passes index different populations and need different stoplists.

`SUBSTANCE_GENERIC_TOKENS` deliberately keeps chemical words, because "sodium" and
"chloride" are parts of INNs and dropping them would delete the only discriminating
token some raw strings have. But **pass D indexes CANONICALS**, where 501 end in
"hydrochloride" and 230 in "sodium" — there the salt word says nothing about which
drug it is.

Measured, before `D_GENERIC` added `SALT_SUFFIX`:

```
group 3  (12 members, 65 assignments)
   47  Insulin human
   17  Irinotecan hydrochloride
    1  Iptacopan hydrochloride
    0  Irbesartan hydrochloride
    0  Inupadenant hydrochloride     ... five unrelated drugs, one shared token
```

After: groups go 1,403 -> **2,324** (more, smaller) covering 6,375 entities, and the
top groups are clean families — Dexamethasone with its five esters, Methylprednisolone
with its six, Metformin with its combinations. Same failure §3.4 fixed for sponsors by
stoplisting "pharmaceuticals"; same fix.

### 4.5 The merge guard is inverted relative to sponsors

The sponsor guard blocks a merge when types differ AND names are dissimilar. The
dangerous substance error is the opposite — **similar names, different drugs**:
vinblastine/vincristine, cisplatin/carboplatin, daunorubicin/doxorubicin.

So the primary guard is an EXTERNAL FACT: two canonicals that are both ChEMBL/EPAR
pref_names are different substances — **unless one is a salt form of the other, or
they fold to the same word bag.** Without that exception the guard would block exactly
the merges pass D exists to make (`methotrexate` and `methotrexate sodium` are both
pref_names). The sponsor conjunction is kept as a backstop for entries the registry
does not cover.

### 4.6 No `--translate` channel, but keep the fold key

INNs are an international standard; there is no Dutch word for pembrolizumab, so the
sponsor translation channel has no analogue. The **sorted-word-bag key** is kept and
costs no API call — on the sponsor side most of that channel's yield came from the key
(punctuation, spacing, diacritics, `&` vs `and`) rather than from any translation.

### 4.7 Retrieval: n-grams are primary, and the slate must interleave

Drug names are single tokens — 12,610 of 17,272 canonicals are one word — so
`ch_token_idf`, the sponsor workhorse, has nothing to overlap. `ch_ngram` carries this
pass, at `ngram_n = 3` and threshold **0.30** (the 0.45 default drops
`SODIO ASCORBATO -> sodium ascorbate`, which scores 0.35).

Index the **surface forms plus the full alias table** (120,190 labels), not the
canonicals. `BNT162b2` is not a pref_name but IS a ChEMBL synonym.

**`interleave = TRUE` is not cosmetic.** `CHANNEL_RANK` puts token_idf above ngram, so
ten token hits fill the slate and ngram never gets a slot. Measured on
`Olopatadin Micro Labs 1 mg`: the slate was tretinoin / fenofibrate / potassium
chloride, and `olopatadine` — which ngram DID find — never appeared. It is OFF by
default because candidate order feeds `cands_sha` in the sponsor cache key.

**The slate must CONTAIN the answer; it does not have to rank it first.**

```
metotrexate -> ketotrexate[0.80] metotrexato[0.80] ketotrexato[0.64] methotrexate[0.58]
```

The correct answer is fourth and the top hit is a different drug. `tests/` asserts
membership and explicitly asserts that the top hit is NOT methotrexate — if that ever
starts passing by rank, someone has reintroduced fuzzy auto-accept.

### 4.7a The prompt must say that vaccine components ARE substances

**Found on the first live gate, and it was my prompt's fault, not the model's.**

`substance-assign-v1` listed influenza strain names among the `-1` (not-a-substance)
examples. The model followed the instruction exactly and returned `-1` for `Brisbane`,
`California`, `Wisconsin`, `Victoria`, `New Caledonia` and `VARI` — every one of them
an influenza strain, i.e. the active substance of a flu vaccine. A wrong `-1` deletes a
substance from the dataset with nothing downstream to catch it.

`v2` inverts the rule: a strain designation, antigen, toxoid or serotype IS a substance;
a bare geographic word in this dataset is a strain name, not a place; when torn between
`0` and `-1`, answer `0`. Measured on the 132 strings both gates covered: **7 rescued
from a wrong `-1`, 0 lost.**

**A SECOND, LARGER EFFECT.** The same version added factual framing — that this is
curation of a public registry of authorised and investigational medicines, in which
vaccines, therapeutic toxins, blood products and radiopharmaceuticals are ordinary
licensed drugs. That unlocked biological matches v1 would not make at all:

```
Filamentous Haemagglutinin                  -> Bordetella pertussis filamentous hemagglutinin
Recombinant N. meningitidis group B NadA    -> Neisseria meningitidis adhesin a
INFLUENZA VACCINE SPLIT VIRION, INACTIVATED -> Influenza virus vaccine
```

**BIO REFUSALS ARE REAL, STOCHASTIC, AND SELF-HEALING.** The API's safety classifier
refuses some strings outright (`reason = "refusal (bio)"`) — botulinum toxin type A
(a licensed medicine), influenza reassortant strains like `IVR-145`. Measured 3 of 200
(1.5%) on v2, down from 5 of 200 on v1, and **the set changes between runs**: three
that failed under v1 succeeded under v2 and one that succeeded then failed. Roughly
1,191 residue strings / 2,099 trial pairs (8.4% / 9.6%) are bio-sensitive, so expect
~160 refusals across the batch.

They are not fatal and need no special handling: `save_rows()` only marks a cache key
done when `chosen_index` is non-NA, so **a failed row is retried on the next run**.
Re-run `--batch` once or twice and most clear. What is left falls through to C_mint.

### 4.7b B_assign must skip on the STRING, not on the cache key

**Found by running the batch twice, and it cost real money.**

The cache key is `sha256(raw_substance, PROMPT_VERSION, MODEL_ID, cands_sha)`, and
`cands_sha` is NOT stable across runs: `registry_surface_forms()` indexes every raw
string already assigned, so the moment a batch assigns anything, the index grows, every
slate shifts, and every cache key changes. Keyed on `cache_key`, a re-run therefore
re-asks strings it has already answered.

Measured: a retry intended to recover **481 genuine failures** re-asked **3,695
strings** and cost **$2.22** instead of ~$0.40. The cache ended with 14,990 rows for
11,295 distinct strings. The pass never converges, and each run costs more.

Now: a string with a non-NA `chosen_index` under the current prompt version and model
is DONE. Only NA rows — API errors, refusals, usage limits — are retried, which is what
the run instructions have always claimed ("re-running costs nothing"). To deliberately
re-ask everything, bump `PROMPT_VERSION`; that is the one lever, and it is explicit.

**The same run exposed a second, worse bug: `B_abstained.csv` was written from one
run's rows.** It is C_mint's entire work list, and overwriting it with the current
batch's abstentions silently discarded every earlier one — measured, the list collapsed
from 9,000 strings to 4,566, losing 4,400 strings that had legitimately abstained in
the first batch. Nothing downstream would ever have asked about them again, and no
error was raised.

Both derived files are now rebuilt from the decision cache, which is the durable
record, and `--rebuild-lists` regenerates them offline for free:

```sh
Rscript .../B_assign.R --rebuild-lists    # no API call
```

**The lesson: derived state must be derived from the durable store every time, never
accumulated in place.** A file that is both an output and the only record of an
output is one interrupted run away from being wrong.

### 4.7c THE BASELINE MUST COME FROM THE SAME CORPUS SNAPSHOT

**The first clean-looking gate reported 6,112 regressions, and none of them were real.**

`data/trial_substance_labels_baseline.csv` was frozen from the labels file as it stood,
but that file had been built from a different snapshot of the trial DB than
`data/trial_substances_raw.csv`. A EudraCT trial has ONE RECORD PER COUNTRY, and the two
snapshots retained different ones:

```
baseline : 2004-000015-25-LT
raw file : 2004-000015-25-GB      same trial, different country record
```

**5,438 of the 6,105 missing IDs were the same EudraCT number under another country
code.** The gate was measuring a corpus difference and calling it a pipeline regression.

Regenerating the baseline from v1 against the CURRENT raw file dropped it to **9**, and
those 9 were entirely the bio-refusal core (§4.7a) — exactly as predicted. So:

```sh
Rscript helper_scripts/substance_norm_pipeline/3_build_substance_labels.R   # ~7 min
rm data/trial_substance_labels_baseline.csv        # --freeze-baseline refuses to overwrite
Rscript .../E_emit.R --freeze-baseline
```

**A baseline is only meaningful against the corpus it was built from.** Re-freeze it
whenever `trial_substances_raw.csv` is regenerated, or the gate silently measures churn
in the DB rather than in the pipeline.

### 4.7d Nine hand-written overrides, and why they are not a rule layer

The 9 remaining regressions were strings the bio classifier refuses outright, so no
model pass can ever resolve them — botulinum toxin, `Clostridium type A neurotoxin
complex`, `Botulinum Neurotoxin Serotype E BoNT`, `modified cobratoxin`.

`helper_scripts/substance_norm_pipeline_v2/manual_overrides.csv` maps those nine strings
by hand, and `A_resolve --apply-overrides` pins them with `decided_by = "human"` so
`registry_from_clusters()` and `B_assign` will never overwrite them.

**This is not v1's rule layer returning.** v1 had 111,000 alias rows standing between
the corpus and the answer. This is nine lines covering strings the model is not
permitted to see, each with its reason recorded. If the list ever grows past a few
dozen, that is a signal to re-examine, not to keep adding.

### 4.7e Canonical names are INN, not ChEMBL pref_name

ChEMBL `pref_name` is USAN. This corpus is EU trial submissions and the granularity
decision is the INN, so `inn_names.csv` renames the entities where the two genuinely
differ — **11 entities, 405 trial labels**:

```
Acetaminophen -> Paracetamol      Albuterol      -> Salbutamol
Aspirin       -> Acetylsalicylic acid            Epinephrine -> Adrenaline
Cholecalciferol -> Colecalciferol  Mesalamine    -> Mesalazine
Cyclosporine  -> Ciclosporin       Dextrose      -> Glucose
```

**A rename can COLLIDE**, and that is not hypothetical: ChEMBL lists both `Cyclosporine`
and `Ciclosporin` as separate molecules, so renaming one produced two live entities
sharing a canonical — a duplicate nothing downstream would have noticed.
`apply_inn_names()` now merges into the existing entity instead of renaming when the
target name is already live.

### 4.7f Idempotence: the re-join must resolve through merge chains

`tests/substance_v2_idempotence.R` failed after D_consolidate ran, reporting 159 new
entities and 387 re-pointed assignments. Two separate causes, both real:

1. **C_mint's re-join keyed on LIVE entities only.** Once D merged `Leucovorin calcium`
   away, the minted `Calcium folinate` could no longer find it and minted a fresh
   duplicate. Six entities leaked on a single re-run. It now resolves through merge
   chains over EVERY registry row with live rows winning ties — the same rule
   `registry_from_clusters()` uses, and for the same reason.
2. **The test itself had drifted from the code.** It called `registry_from_clusters()`
   directly, skipping the re-join that `--materialise` performs, so it was testing a
   path the pipeline never runs. The re-join now lives in `substance_common.R` as
   `rejoin_minted_canonicals()` and both call it.

`--materialise` is verified idempotent: run twice, 21,351 entities both times.

**`dedup_registry()` cleans up what those bugs left**, and is worth keeping as a
standing repair. Two rules, both deterministic:

- two live entities sharing an identical folded canonical (the INN-rename collision)
- a MODEL-MINTED canonical that is an unambiguous reference alias of another live
  entity (`Calcium folinate` -> Leucovorin, `CC-220` -> Iberdomide)

It never merges a registry-derived entity away, and only ever on an alias naming exactly
one substance.

### 4.7g The merge direction, which no summary statistic shows

`parse_merge()` elected the survivor of a merge family by ASSIGNMENT COUNT. That is
wrong under the INN-base decision: `Rucaparib camsylate` outnumbers `Rucaparib` in this
corpus, so impact elected the salt. **62 of 678 merges pointed backwards** —
`Bavisant -> Bavisant dihydrochloride`, `Delafloxacin -> Delafloxacin meglumine`.

The merge SET was correct throughout. Only its direction was wrong, and the merge count,
the confidence distribution and the mis-index guard all looked healthy while it was.
`pick_winner()` now prefers a member whose name is a word-prefix OR word-suffix of
another's — salt order is not consistent (`rucaparib camsylate` vs `calcium clofibrate`)
— and falls back to impact only where no base exists, so families with no base/suffix
relationship are left exactly as the model answered them.

### 4.7h The nightly, and the two ways it was wired wrong

`rebuild_cache.R` ran the **v1** substance scripts until 2026-08-21. Both v1's
`3_build_substance_labels.R` and v2's `E_emit.R` write
`data/trial_substance_labels.csv`, so a production rebuild would have silently
replaced the v2 labels with v1 output and undone the rewrite — no error, because
both "succeed". This is the identical trap the sponsor block documents at
`rebuild_cache.R:49-52`, from when it happened to sponsors. It was caught only
because a rebuild was interrupted by hand mid-run.

Now mirrored on the sponsor shape:

```
1_export_trial_substances.R          (copied INTO the v2 dir, so the LEGACY move cannot break it)
N_nightly_resolve.R                  resolve strings the registry has never seen
E_emit.R --diff-only --assert-no-regressions      gate BEFORE writing
E_emit.R                             only if the gate passes
```

A regression keeps yesterday's labels; exit 2 (no baseline) writes anyway but
raises `.substance_nightly_failed` so the deploy goes non-zero.

**New strings need two mechanisms, not one.**

- `A_resolve.R --incremental` classifies only unseen strings and APPENDS. The
  full rebuild is refused once B and C have run (it discards every model-minted
  entity), so this is the only safe entry point. Measured on a real delta: 986
  new strings, of which **431 matched ChEMBL outright and 12 were filtered —
  44% never reached the API.**
- `N_nightly_resolve.R` orchestrates the rest: deterministic pass, `B_assign
  --sync` against the existing registry, `C_mint --sync --singletons` for
  abstentions, `--materialise`. Assign-before-mint, or a new spelling of an
  existing drug becomes a second entity. Ceiling (300 strings) and per-run
  budget ($1.00), sponsor exit codes, never `D_consolidate`, never `--batch`.

**Two bugs it shipped with, both caught before they cost anything real:**

1. It counted "unresolved" as "not assigned", which included ~1,000 strings the
   model had already judged not-a-substance. That would have re-sent the same
   Italian and Polish dosage language to the API **every night forever** — the
   recurring-cost form of §4.7b. Fixed by treating any non-NA answer as an
   answer; the work list went 1,713 -> 540.
2. Its run logger crashed AFTER all the work was saved: `readr` guessed
   `<datetime>` for the ISO timestamp it had itself written, and `bind_rows`
   refused to combine it with a fresh character row. Same failure as
   `llm_cache_merge` (§3.0a of the sponsor handover). Every column is now read as
   character, and `finish()` wraps the log write in `tryCatch` — bookkeeping must
   never change the outcome of a run that already succeeded.

### 4.7i Rendering the report leaked its workspace into the caller

`rebuild_cache.R` ended with `Error in parse(text = i) : unexpected SPECIAL` —
AFTER the cache, the labels and the report had all been written correctly.
`rmarkdown::render()` defaults to `envir = parent.frame()`, so the Rmd's ~100
objects land in the calling script's environment, including the helper `%||%`.
Something walking the globals at session end calls `parse(text = "%||%")`, which
is not a parseable expression, and Rscript exits non-zero.

Cosmetic in its effects, expensive in its consequences: **the nightly deploy
branches on that exit code**, so every night would have been reported as a failed
deploy. Fixed by rendering into `new.env(parent = globalenv())` — verified: exit
0, zero globals leaked.

### 4.7j `block_id` is positional, and the warning that reveals it

`registry_from_clusters()` warns `N cluster(s) carry more than one canonical`.
It is benign but the cause is worth knowing: C_mint assigns `sblk_%05d` by
POSITION in the work list, and the work list changes between runs, so the same
`block_id` means different strings in different runs while the cache accumulates
rows from all of them. Grouping is by `(block_id, cluster_no, canonical)`, so
each still becomes its own entity and nothing is dropped or conflated.

Making `block_id` content-addressed from `members_sha` would remove the warning
and the latent ambiguity. Not done: it would renumber every cached row mid-run.

### 4.8 Three slate-poisoning bugs, all found by READING the slates

None of these threw an error. All three were found by running
`B_assign.R --candidates-only` and looking at the output, which is the entire reason
that mode exists.

**Placebo was a retrieval magnet.** `is_placebo()` matches any string CONTAINING
"placebo", so `Placebo Forxiga 10 mg` is correctly assigned to the placebo entity — and
`registry_surface_forms()` then indexes that raw string, making `forxiga` a surface form
of Placebo. The entity accumulated the name of every drug it was a placebo for:

```
Forxiga 10 mg film-coated tablets   (33 trials)
   1. Dapagliflozin propanediol             1.00 token_idf
   3. Placebo                               1.00 token_idf   <- wrong, top score

Dexamethason 4 mg JENAPHARM         (26 trials)
   1. Placebo                               1.00 token_idf   <- the ONLY candidate
```

Dexamethasone is in the registry and was crowded out completely. B_assign now excludes
`channel == "placebo"` assignments from the index; the canonical still participates.
This costs nothing, because a placebo string never reaches B_assign anyway.

**The acronym channel scored noise at 1.00.** `ch_acronym` returns score 1 for any
initials match, and under `interleave` that guarantees it a slot:

```
Forxiga 10 mg film-coated tablets
   3. Perampanel                            1.00 acronym
```

839 strings had an acronym hit as their TOP candidate. `retrieve()` coupled it to
`ch_ngram` under one `extra_channels` flag; they are now `use_ngram` / `use_acronym`,
mirroring `build_pair_graph()`. Substances set acronym FALSE — initials of a product
label say nothing about a molecule.

**Dutch, Nordic and Finnish dosage language was not stoplisted.** `.UNIT_ONLY` carried
German, Spanish, Italian and Croatian only:

```
ml oplossing voor injectie          (26 trials)
   1. Aldesleukin                           1.00 token_idf
   2. Amoxicillin                           1.00 token_idf
   3. Amphotericin b                        1.00 token_idf
```

A full slate of unrelated drugs, all at maximum score, for a string naming no
substance. Added to both the junk filter and `SUBSTANCE_GENERIC_TOKENS`.

**The lesson worth carrying:** every one of these produced a confident, well-formed,
completely wrong slate. Nothing errored. `--candidates-only` before `--sync` before
`--batch`, and read the output rather than checking the exit code.

---

## 5. Corrections to my own reasoning, recorded so they are not repeated

### 5.1 `confidence_prior` was dropped, and the reason generalises

v1 attached 0.90/0.85/0.65 to ChEMBL synonyms by `syn_type`. Dropped because:
it is a pure lookup on `alias_type` and therefore carries no information; it was never
measured; and in v2 `confidence` means *the model's confidence in its own answer* and
`route_for_review()` gates on it — so feeding a 0.65 in for the 97,851 plain synonyms
would route essentially every registry match into a ~16,000-row "review queue".

I initially proposed carrying it through. That was wrong.

### 5.2 Two claims I made and then measured to be false

- **"token_idf's 0.15 floor is too permissive."** It comes from the sponsor pipeline,
  where the handover already lists it under *"thresholds are all judgement, not
  measurement"*. I repeated it as if it were evidence. Swept it: 0.15/0.25/0.35/0.45
  gives 7/7/6/7 of 12. **No signal. The floor is not the lever** — slot allocation is
  (§4.7). The parameter I added for it has been removed.
- **The manufacturer stoplist "fixed" the Olopatadin case.** It did not: 11/12 with and
  without. The words are kept because they are generic by inspection and shrink the
  pair graph, and the comment in `retrieve.R` now says exactly that.

Two of my probe "failures" were also the test being wrong, not the code:
`TAGRISSO -> osimertinib mesilate` and `Forxiga -> dapagliflozin propanediol
monohydrate` are correct (D rolls the salt up), and `BNT162b2 -> tozinameran` is
correct because tozinameran IS the INN. The fixture now matches on prefix.

### 5.2a Two calls I made wrongly during the live run

- **"`Citalopram -> Escitalopram` and `Insulin human -> Insulin glargine` are wrong
  merges."** They are not. The raw strings are literally `Escitalopram` and
  `Insulin glargine`; neither entity was merged at all. v2 is CORRECTING 84 trials that
  v1 mislabelled by collapsing an enantiomer and an insulin analogue into their parents.
  I should have read the raw strings before calling it — a "label changed" row is not
  evidence of a wrong merge, it is evidence that something changed.
- **The first `pick_winner()` elected the shortest name whenever no base existed.**
  That silently rewrote `Imidazole-4-carboxylic acid` to `4-imidazolecarboxylic acid`
  purely on length, which is not a judgement that function is entitled to make. It now
  leaves such families exactly as the model answered them.

### 5.3 The sponsor handover's "NA scores" note — root cause found

`normalisation-v2-handover.md` §3.8 records the n-gram channel as "returns NA scores",
and treats that as a reason it was dropped. **It was never `ch_ngram`.** Two separate
things, both now fixed:

- `ch_ngram()` (the retrieval channel) is sound. Over the substance index it returns
  **0 NA of 20 rows**. It simply was not earning its cost for organisation names.
- **`build_pair_graph()`'s ACRONYM channel is what emitted NA.** `acr_pairs` came from
  `pairs_from_postings()`, which returns `a, b, channel` and **no `score` column**, so
  binding it with the scored channels produced NA for every acronym pair. That NA then
  broke `quantile()` in the reporting and — worse, silently — made every
  `score >= threshold` comparison NA inside `canopy_blocks()`. Anyone who ever ran
  `A_block.R --extra-channels` got a quietly corrupt pair graph. Acronym is a presence
  channel, so it is now scored 1, the same way `structured` is.

**And the n-gram PAIR channel was inert, not merely weak.** `pairs_from_postings()` was
called with a hardcoded `max_postings = 20L`; at `n = 3` almost every gram occurs in
more than 20 labels, so nearly all are dropped. Measured on the substance corpus before
the fix: **0 n-gram pairs out of 558,957.** The cap is now a parameter
(`ngram_max_postings`), and `use_ngram` / `use_acronym` are separate flags instead of
one `extra_channels` switch.

This matters for the sponsor conclusion too: §3.4's "n-gram written, measured, dropped"
was measured with the channel crippled by that cap. Not worth re-opening for sponsors —
token overlap genuinely does the work there — but do not cite it as evidence that
character n-grams do not help in general.

---

## 6. Changes to the shared library (`helper_scripts/llm_norm/`)

353 insertions, 82 deletions across three files. **Every change is backward-compatible
by defaulting to today's sponsor behaviour, and that is verified, not asserted:**
`tests/sponsor_v2_idempotence.R` passes including its live-registry tier, and
`A_block.R` regenerates `data/sponsor_blocks.csv` **byte-identical** to the committed
file (2,438 multi-member blocks, 3,877 singletons — the documented figures).

| File | Change |
|---|---|
| `retrieve.R` | `tokens_of()` takes `generic` and `drop_numeric` instead of reading a global; `build_index()` stores them on the index so a query cannot be tokenised under a different stoplist than the index; `SUBSTANCE_GENERIC_TOKENS` added; `retrieve()` gains `ngram_threshold` and `interleave`. |
| `retrieve.R` | **Hashed postings.** `ch_ngram`/`ch_token_idf` were a dplyr filter over the whole index per query — fine at 16,594 sponsor strings, 20+ minutes at 13,727 substance queries against a 586k-row gram table. Now `key -> label_ids` environments. **127x faster, and verified identical: 0 mismatches over 300 queries against the previous implementation.** |
| `retrieve.R` | Empty n-grams dropped. `char_ngrams()` returns `""` for a punctuation-only label and `list2env()` cannot hold a zero-length name. |
| `registry.R` | `raw_col` threaded through the 9 places `raw_sponsor` was a literal; `registry_resolve_labels()` takes a column map; `salt_form`/`brand` added to `REGISTRY_COLS`; `registry_empty()` now creates every column its own contract names (`legal_entity` was missing). |
| `registry.R` | **`registry_add()` was O(n²)** — a `bind_rows` per entity. Fine for B_mint's block-sized chunks, did not finish in two minutes when A_resolve mints 17,272 at once. IDs are sequential, so the batch form is exactly equivalent. |
| `client.R` | `llm_run_cap_guard()` takes the env-var name to name in its error, instead of hardcoding `SPONSOR_NIGHTLY_CAP_USD`. |

---

## 7. File inventory

### New, untracked

| Path | Lines |
|---|---|
| `helper_scripts/substance_norm_pipeline_v2/substance_common.R` | 179 |
| `helper_scripts/substance_norm_pipeline_v2/A_resolve.R` | 424 |
| `helper_scripts/substance_norm_pipeline_v2/B_assign.R` | 457 |
| `helper_scripts/substance_norm_pipeline_v2/C_mint.R` | 501 |
| `helper_scripts/substance_norm_pipeline_v2/D_consolidate.R` | 533 |
| `helper_scripts/substance_norm_pipeline_v2/E_emit.R` | 270 |
| `tests/substance_v2_idempotence.R` | 206 |
| `PLANS/substance-normalisation-v2.md` | the plan this was built from |

Generated: `config/substance_norm_v2/{chembl_cache,epar_cache,registry,assignments,registry_aliases,D_salt_rollups}.csv`,
`data/substance_{residue,rejected}.csv`.

`config/substance_norm_v2/` should be **tracked** (it is paid/derived seed state, as
`config/sponsor_norm_v2/` is), but note `.gitignore` currently has no
`config/substance_norm_v2/N_*.csv` equivalent — add one if a nightly is ever built.

### The baseline, and how to regenerate it

`data/trial_substance_labels_baseline.csv` is frozen from v1's output and **gitignored**
(`data/*labels*`), so git cannot restore it. To rebuild:

```sh
Rscript helper_scripts/substance_norm_pipeline/1_export_trial_substances.R
Rscript helper_scripts/substance_norm_pipeline/3_build_substance_labels.R
Rscript .../E_emit.R --freeze-baseline
```

`--freeze-baseline` **refuses to overwrite an existing baseline** — on the sponsor side
an auto-freeze captured v2 as its own baseline and the gate compared v2 to v2 forever
while printing a healthy table.

**v1 is deliberately still in place.** `rebuild_cache.R:103-141` and the nightly call
it, and it is what regenerates the baseline. Move
`helper_scripts/substance_norm_pipeline/` and `config/substance_norm_pipeline/` to
`LEGACY/` only once E_emit's gate is clean.

---

## 8. What is left

1. **Run the API passes** (§2). Nothing else is blocked on anything.
2. **E_emit's diff will show `dropped: v1 raw fallback (intended)` rows.** That class is
   counted and listed separately from real regressions because v2 drops v1's
   raw-string fallback by decision. **Read the sample** — a real substance name
   appearing there means a `not_a_substance` judgement was wrong.
3. `rmarkdown/preprocessing.Rmd:1178-1320` still reads the v1 log; point it at
   `data/substance_normalisation_log_v2.csv`.
4. **`AGENTS/AGENTS.md:267-293` is stale and actively misleading** — it documents a
   "Normalisation v2 substance resolution (v0.12.10)" as completed and verified
   2026-08-04, citing `helper_scripts/normalisation_v2/substance_resolution.R` and four
   other paths. **None of them exist and `git log --all` finds nothing.** Delete or
   correct it, or the next person will think this work is already done.
5. On commit, per §9 of the sponsor handover: bump `README.md`, `CHANGELOG.md`,
   `app.R:2`, **`DATA_PROCESSING_VERSION` at `app.R:244`** (or the cache will not
   rebuild), the About-tab changelog and the footer; add an `AGENTS.md` section.
   Never commit `trials_cache.rds`, `www/preprocessing.html`, or `data/*labels*`.

## 9. Suggested first move

```sh
Rscript helper_scripts/substance_norm_pipeline_v2/B_assign.R --candidates-only
```

Free, no credentials, ~4 minutes. It prints the candidate-slate size distribution and
a sample of the slates the model will actually see. On the last run **6,328 of 11,012
strings got a full slate of 10**, which is retrieval scraping the barrel rather than
finding one or two strong hits — worth understanding before paying for a batch, since
a full slate is also what the sponsor gate identified as the signature of an
abstention.

Then `--sync --limit=200`, and read the `-1` answers before submitting anything.

## 10. One loose end, not blocking

**The n-gram PAIR channel contributes 0 pairs** in `C_mint`, even at
`ngram_max_postings = 400` (544,629 pairs, all `token_idf`). Note this is the PAIR
channel used for blocking, not `ch_ngram` used for retrieval — that one works and is
doing the heavy lifting in B_assign. The blocks C_mint produces are good regardless:
one holds 20 peginterferon variants including the misspelling `peginterfern alfa-2a`,
so token overlap is carrying blocking on its own.

But a channel that is nominally on and contributing nothing is the kind of thing that
gets cited later as evidence it was tried. Either raise the cap until it fires and
measure what it adds, or turn it off honestly. **Do not assume it is helping.**

(The Dutch/Nordic/Finnish dosage-language gap that was listed here has been fixed —
see §4.8.)
