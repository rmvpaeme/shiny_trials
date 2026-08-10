# Normalisation reproducibility — making raw → final derivable without an LLM

**Status: built, measured, and deliberately not wired in — 2026-08-10.**

The derivation layer in §1 was implemented in full, gated by a replay harness,
and run end-to-end against the real register. The harness rejected most of the
rules, and the ones that survived moved 0.05% of sponsor labels and 0.5% of
substance labels. On that evidence the wiring was reverted and the effort
redirected. See [Findings](#findings--what-the-measurements-showed).

**§2 shipped separately and is done** — `substance_llm_overrides.csv` is down
from 9,625 rows to 636, labels byte-identical. It never depended on the
derivation layer.

**What was kept:** §2, the mined additions to `.legal_suffixes_rx`, and the
`tests/derivation/` harness. **What was reverted:** the calls from the two label
builders into `derive_*_canonical()`.

The measurements in *Context* below are the 2026-08-07 estimates the plan was
written from, against `64013fd`. The Findings section carries the measured
replacements, which differ in places.

Related: [`normalisation-reviewer-multiuser.md`](normalisation-reviewer-multiuser.md)
is where the irreducible residue described in the last section gets reviewed.

## Context

The alias tables carry **~90% of sponsor coverage and ~87% of substance coverage**,
and every row in them is a frozen LLM decision. The pipeline is already
deterministic *given* those tables — re-running produces byte-identical labels —
but a future import brings raw strings the tables have never seen, and nothing in
the repo resolves those without another LLM pass.

The question asked was whether the decisions can be reverse-engineered into a
script by comparing raw against final. **Partly — and the split is measurable.**
I mined token-level transformations from every (raw, final) pair the register
still contains.

### Sponsors — 12,958 pairs

| Transformation | Rows | Share | Mineable? |
|---|---:|---:|---|
| `raw == final` after case/punctuation cleaning | 4,113 | 31.7% | ✅ |
| `final = raw` minus a token span | 5,381 | 41.5% | ✅ |
| `final = raw` plus a token span | 198 | 1.5% | ⚠️ expansion needs knowledge |
| Substitution — a different name entirely | 3,266 | 25.2% | ❌ |

**~73% is mineable.** The removals concentrate hard: 22 patterns cover 75% of
them, and they are all legal suffixes — `inc` (1,503), `ltd` (511), `gmbh` (299),
`limited` (241), `s a` (223). A single rule, *stripping trailing legal suffixes
from the raw string*, reproduces **54.4%** of sponsor decisions exactly and
another 6.0% up to capitalisation.

The irreducible 25.2% is entity resolution, not string editing:
`1. Frauenklinik der LMU-Innenstadt` → `Klinikum Der Universitat Munchen AöR`.
No regex produces that, because the output shares no material with the input.

### Substances — 18,824 pairs

| Transformation | Rows | Share | Mineable? |
|---|---:|---:|---|
| `raw == final` | 3,218 | 17.1% | ✅ |
| `final = raw` minus a token span | 4,021 | 21.4% | ✅ |
| `final = raw` plus a token span | 146 | 0.8% | ❌ |
| Substitution — a different name entirely | 11,439 | 60.8% | ❌ |

**Only ~39% is mineable**, and the mined removals are salt/hydrate forms —
`hydrochloride` (230), `sodium` (91), `hcl` (44), `acetate` (40). The 60.8%
residue is brand → INN, which is a *dictionary lookup by nature*: no
transformation turns `Humira` into `adalimumab`.

That residue is mostly already solved, though — ChEMBL and EPAR are reproducible
external sources the pipeline already queries, and 29% of
`substance_llm_reviewed.csv` is **redundant with ChEMBL** (the LLM re-derived
what the registry already knew).

### Verdict

Mining converts the derivable majority into code. It cannot recover the residue,
and no amount of cleverness will: the information is not in the input string.
What it buys is that a future import stops needing an LLM for the ~73% of new
sponsors and ~39% of new substances that are pure string reduction.

**Critical caveat:** mined rules reproduce the decisions that were made. They do
not validate them. The 19 pre-existing gold-fixture failures are evidence that
some frozen decisions are wrong, and mining would faithfully reproduce those too.

## Decisions taken

| Decision | Choice | Outcome |
|---|---|---|
| Rule layer vs. replacing table rows | **Layer.** Tables stay the frozen record; rules run before the queue | Right call, but the layer earned too little to keep — see Findings |
| Redundant substance overrides | **Prune**, gated on byte-identical labels | **Done** — 9,625 → 636 rows, labels byte-identical |
| The irreducible residue | Still open — see the last section | Now the whole problem |

> **Everything from here to the Findings section is the plan as written on
> 2026-08-07.** It was implemented as specified. Read it for the design intent;
> read [Findings](#findings--what-the-measurements-showed) for what the design
> turned out to be worth.

---

## 1. The derivation layer

Today an unmatched sponsor falls through to `unknown_fallbacks`
(`3_build_sponsor_labels.R:138-150`), which copies the raw string **verbatim**
and stamps `match_status = "unknown"`. That is the insertion point: replace a
dumb fallback with a principled derivation.

New `helper_scripts/sponsor_norm_pipeline/derive_sponsor_canonical.R` and
`helper_scripts/substance_norm_pipeline/derive_substance_canonical.R`, each
exposing one pure function `derive_*(raw)` returning
`(derived, rule_id, confidence)` or `NA`.

**Reuse what exists rather than writing new regexes.** `normalise_sponsors.R`
already defines `.legal_suffixes_rx` (line 28), `.address_rx` (line 39) and
`.country_tail_rx` (line 50). They are currently used only for *candidate
generation* during matching — the derivation layer applies the same patterns to
*produce a canonical*. Extend `.legal_suffixes_rx` with the mined patterns it
lacks: `s l`, `s p a`, `s r l`, `aps`, `gmbh co kg`, `mbh`, `sarl`, `oy`.

Rules, in order, each tagged with a `rule_id` so every derived label is traceable:

| Rule | Source | Sponsor | Substance |
|---|---|---|---|
| `case_punct` — cleaning only, no token change | 31.7% / 17.1% of pairs | ✅ | ✅ |
| `legal_suffix` — strip trailing legal form | mined, 22 patterns | ✅ | — |
| `salt_form` — strip salt/hydrate token | mined, `canonical_substances.csv` already maps these | — | ✅ |
| `dose_form` — existing `sanitise_substance_output()` | already in `normalise_substances.R` | — | ✅ |
| `address_tail`, `country_tail` | existing regexes | ✅ | — |

Emit `match_source = "derived:<rule_id>"` and `match_status = "review"`, **not
`accepted`**. A derived label is a good guess, not a verified decision, and the
reviewer app already sorts `review` rows by impact. This keeps the provenance
distinction the last cleanup established: `llm_curated` ≠ `manual` ≠ `derived`.

### The regression harness — the part that makes this trustworthy

`tests/derivation/` with a script that replays every rule against the existing
frozen decisions as a 22,000-row corpus, reporting per rule:

- **agree** — rule reproduces the frozen canonical exactly
- **cosmetic** — same entity, different capitalisation
- **conflict** — rule produces a *different* entity → the rule is unsafe, or the
  frozen row is wrong
- **no-op** — rule declines

Ship a rule only when its conflict rate is ~0. Expected baseline from this
analysis: `legal_suffix` at 54.4% agree / 6.0% cosmetic on sponsors. Commit the
report as the acceptance record; a rule change that moves these numbers should
be visible in the diff.

Cosmetic disagreements (`3M ITALIA` vs `3M Italia`, `4D pharma` vs `4D Pharma`)
are why derived rows must not be `accepted`: the rule cannot know that `89bio`
is lowercase-b and `4TEEN4` is all-caps. That is brand styling, not a pattern.

## 2. Prune the redundant substance overrides

`substance_llm_overrides.csv` is 9,625 rows and is checked at **step 2 of the
matcher**, ahead of the negative list and every alias tier — so it shadows
everything beneath it. Measured against the current alias index:

|  | Rows | Meaning |
|---|---:|---|
| Index already returns the same answer | 9,323 (96.9%) | redundant |
| Index returns something different | 121 (1.3%) | real override — **keep** |
| Not resolvable without the row | 181 (1.9%) | sole source — **keep** |

Procedure: classify with the same logic, write the ~302 survivors, rebuild via
`3_build_substance_labels.R`, and require `data/trial_substance_labels.csv` to be
**byte-identical**. Any row whose removal moves a label goes back — that is the
gate, not a judgement call. My 96.9% is an estimate using simplified matching;
the label diff is what actually decides.

The win is not disk space. It is that the highest-priority tier stops being 9,625
rows of frozen LLM output that silently outrank every rule added in §1.

## 3. Wiring

Both `derive_*` calls slot into the label builders, replacing the verbatim-copy
fallback:

- `3_build_sponsor_labels.R:138-150` — `unknown_fallbacks` calls `derive_sponsor_canonical()`
- `3_build_substance_labels.R` — the equivalent raw-fallback block

`normalise_*.R` stays untouched, so the reviewer app, `apply.R` and the tier
loaders need no changes. Document the new `derived:*` provenance value in both
`config/*_norm_pipeline/README.md` `source` tables.

## Verification

1. **Regression corpus** — `tests/derivation/` replay reports ≥54% agree and ~0%
   conflict for `legal_suffix`. This is the primary gate.
2. **No existing label moves** — rebuild both pipelines; `trial_sponsor_labels.csv`
   and `trial_substance_labels.csv` byte-identical apart from rows previously
   `unknown`. Derivation must only fill gaps, never override a matched row.
3. **Override prune is label-neutral** — byte-identical substance labels, or the
   pruned rows go back.
4. **Gold fixtures** — 116 sponsor / 111 substance, no regression against the
   current baseline. Note 19 sponsor cases already fail; the number must not grow.
5. **Coverage delta** — report `unknown` counts before/after. Currently 240
   sponsor and 7,003 substance unknowns; the derivation layer should cut the
   sponsor figure substantially and the substance figure much less, per §Context.
6. **Held-out check** — withhold 10% of frozen decisions, mine rules on the other
   90%, measure agreement on the held-out slice. Guards against rules that merely
   memorise the corpus.

---

## Findings — what the measurements showed

Everything below was measured on 2026-08-10 against the real register
(16,594 unique sponsors, 31,229 unique substances) and the committed config.

## The corpus is less mineable than the estimate

The estimates in §Context were computed over a different denominator. Measuring
only the LLM-sourced pairs — the decisions the derivation layer is actually
trying to replace, excluding registry rows from EMA, ROR and ChEMBL:

| | Pairs | identical | removal | addition | substitution | **mineable** |
|---|---:|---:|---:|---:|---:|---:|
| Sponsors | 12,510 | 29.6% | 39.9% | 2.1% | 28.5% | **69.4%** |
| Substances | 11,208 | 15.1% | 19.9% | 0.7% | 64.3% | **35.0%** |

Close to §Context for sponsors (73% estimated, 69% measured), close for
substances (39% vs 35%). The estimates held up. **The estimates were not the
problem — the assumption that "mineable" implies "safely mineable" was.**

## Four of six rules were rejected by their own acceptance test

`tests/derivation/replay.R` replays each rule against every frozen pair. The
gate that matters turned out not to be agree/conflict but **destructive** — a
firing that removes a token the frozen answer still contains — because the rules
compose, and a correct *partial* reduction scores as a "conflict" against the
final answer while being exactly right.

| Rule | Verdict | Evidence |
|---|---|---|
| `legal_suffix` | **shipped** | 4,340 fires, 3,407 agree, 3.8% destructive |
| `case_punct` | **shipped**, sponsor + substance | terminal fallback; removes nothing |
| `dose_form` | **shipped**, substance | 1,677 fires, 0.4% destructive |
| `prefix_trim` | **shipped**, substance | 81 fires, 1.2% destructive; low value |
| `department_tail` | rejected | 9 agree vs 59 conflict |
| `country_tail` | rejected | 36.8% destructive (32 of 87 fires) |
| `address_tail` | rejected | 30.6% destructive (19 of 62) |
| `salt_form` | rejected | 25.3% destructive (231 of 913) |

Why each failed is worth keeping, because each looks obviously correct up front:

- **`department_tail`** — "department" is the most-removed token in the corpus
  (169 rows), so stripping it looks like free coverage. But
  `aalborg university hospital dept of rheumatology` → `Aalborg University
  Hospital` works only because the parent happens to precede the department.
  `academical medical center department of dermatology` → `Amsterdam UMC` needs
  a fact that is not in the string, and `aalst dermatology group` →
  `Aalst Dermatology Group` shows the keyword is often part of the name.
- **`country_tail` / `address_tail`** — the country is not a suffix on a sponsor
  name, it is part of it: `BIOTRONIK France`, `Cancer Research UK`,
  `CHU de Fort-de-France`.
- **`salt_form`** — contradicts a convention already in the data.
  `canonical_substances.csv` gives a salt its own row with `parent_substance`
  pointing at the free base, so `acalabrutinib maleate` *is* the label and
  `acalabrutinib` is recorded beside it. Deriving the base as the label
  disagrees with every salt row already there.

### The generalisable lesson

**A pattern that is safe for generating match candidates is not automatically
safe for generating a label.** `.address_rx`, `.country_tail_rx` and
`.department_rx` have all been correct for years inside
`make_sponsor_candidates()`, where an over-stripped candidate simply matches
nothing and costs nothing. Pointed at label *production*, the same regexes
rename the organisation. Anyone reaching for these regexes again should read
this line first.

## The shipped rules moved almost nothing

Rebuilt end-to-end and compared trial by trial against the pre-change labels:

| | Labels moved | Unknowns resolved |
|---|---|---|
| Sponsors | **26 of 47,665 (0.05%)** | 20 of 240 |
| Substances | **213 of 43,478 (0.49%)** | 590 of 4,960 |

No trial lost a label. Gold fixtures were unchanged — 20 sponsor and 6 substance
failures before and after, the *same* cases both times (the plan's "19" was
slightly off; the true pre-existing baseline is 20/6, measured at `e364102`).

The held-out check passed and was uninformative, as expected for rules that fit
no parameters: sponsors 46.1% agree in-sample vs 46.5% held out, substances
59.1% vs 57.3%.

## The substance side needed four rounds of guards

Each of these was found by the trial-by-trial label comparison, and none by the
gold fixtures. They are recorded because they are what rule-based derivation
costs, not because any one of them is interesting:

| Symptom | Cause |
|---|---|
| `Suspension of autologous skeletal myoblasts` → `of autologous skeletal myoblasts` | removal from the front leaves a fragment |
| `Enantone-Gyn Monats-Depot` → `enantone-gyn monats-` | removal strands punctuation, and the lowercase cleaned form leaked out |
| `GRC 17536 potassium powder for inhalation` → `GRC 17536 potassium for` | removal from the middle strands a preposition |
| `TarcevaTM 100mg` → `Tarcevatm` | sentence-casing a value that had kept the register's own casing |
| `AMG 706` → `amg`, `Pneumo 23` → `pneumo` | a trailing number is a dose in `imatinib 100` and the identity in `amg 706`; not distinguishable by shape |

The fix for the casing class is worth remembering if this is ever revisited:
run the rules on the cleaned string, then map the result back onto the *original*
string's tokens, rather than title-casing the cleaned output.

## §2 — the override prune: **done**

Applied 2026-08-10. `substance_llm_overrides.csv` went from **9,625 rows to
636**, an 8,989-row cut, with `data/trial_substance_labels.csv` and
`3_substance_review_queue.csv` both byte-identical afterwards. The matcher's
highest-priority tier is no longer a dumping ground that silently outranks
everything below it.

What survives, and why:

| | Rows |
|---|---:|
| Sole source — nothing else resolves the string | 368 |
| Cross-string dependency — see below | 104 |
| Real correction — the index answers differently | 62 |
| Duplicate key — protected | 102 |

**The cross-string group is the finding worth keeping.** The first attempt
classified each override by re-matching *its own key* without the override tier,
which gave 9,107 redundant. That test is not sufficient: `check_override()`
matches `raw_clean %in% candidates`, and `candidates` is
`generate_candidates(raw)`, so an override keyed `metformina` also fires for
every longer register string whose `first_token` or dose-stripped form is
`metformina`. Deleting it moves *those* strings, not its own.

`prune_substance_overrides.R` therefore ends with a differential over the
register itself: compute candidates for all 31,229 strings, keep the 12,929
whose candidate set touches a pruned key, normalise them with and without the
prune, and restore any key that moved something. It restored **104 keys on the
first pass** and converged on the second. Without it, those 104 deletions would
have shipped and quietly changed real labels.

That gate is also strictly stronger than diffing the label file, because labels
are aggregated per trial (`sort(unique(...))` joined with `" / "`), so two
offsetting changes within one trial cancel out and pass unnoticed.

Two constraints the prune had to respect, both invisible from the CSV alone:

- **`check_override()` takes `slice(1)`** — only the first row per key is
  reachable, so dropping a redundant *first* row promotes the shadowed second
  one and changes the answer.
- **The reviewer app feeds on the duplicates.** `load_substance_conflicts()`
  (`curation_app/R/tiers.R`) builds its **Substance conflicts** tier from keys
  mapped to more than one target — 42 aliases, 84 rows. Pruning them would empty
  a known-wrong-rows queue before anyone worked it.

Both are handled by excluding every duplicated key from the prune: 102 rows, and
the tier still loads its 42 aliases unchanged.

## What was kept

1. **The mined `.legal_suffixes_rx` additions** — the one durable win, and it
   improves *matching* rather than derivation, so it helps every future import.
   `clean_sponsor_alias()` turns `S.A.` into `s a` and `B.V.` into `b v` before
   the regex runs, so the escaped `b\.v` and `s\.a` arms never fired in
   practice. The spaced spellings now do: `s a` [153 rows of support], `b v`
   [85], `s l` [77], `s p a` [47], `s r l` [39].

   This corrected a genuinely wrong label: `Schering Plough S.p.A.` and
   `Schering Plough, S.A` resolved to `Schering` (no parent, no group) and now
   resolve to `Schering-Plough` / `Merck & Co.` / `MSD / Merck & Co.` — the
   correct entity. **Rebuild both label files to pick this up.**

2. **`tests/derivation/`** — the corpus loader, the transformation miner, and
   the replay harness. Reads committed config only; no database, no network.
   Whatever resolves the residue next will need to be measured against the same
   frozen decisions, and this is the apparatus for that.

## Verification method — the part to reuse

The gold fixtures are 116 sponsor and 111 substance hand-picked cases. Every bug
in the list above passed them. What caught the bugs was rebuilding both pipelines
and diffing all ~91,000 labels against a saved baseline, categorised
(unchanged / case-only / shortened / rewritten / gained / lost) with samples
printed per category.

**Any future normalisation change should be gated that way, not on the
fixtures.** The tooling for it was written (`tests/compare_labels.R`,
`--save-baseline` then `--baseline`) and reverted; it is a short script and
worth writing again, or recovering from the stash.

---

## Still open: the irreducible residue — now the whole problem

After §1, roughly 25% of new sponsors and 60% of new substances still need a
decision that no rule can produce. With the derivation layer measured at
0.05%/0.5% of labels, that residue is not the remainder of the problem — it *is*
the problem, and the recommendation below is where the next effort should go.

- **Pin and cache the LLM step** — a committed `5_llm_resolve.R` with pinned
  model id, versioned prompt, temperature 0, and decisions cached by
  `sha256(raw + prompt_version)`. Re-running is then reproducible and only
  genuinely new strings reach the API. Makes the LLM a documented pipeline stage
  rather than an undocumented past event.
- **Route to the reviewer app** — reproducible by construction, human-paced.

Recommendation: both, in that order — the LLM proposes, the reviewer app is where
a human confirms and stamps `source: manual`.

### One design constraint, learned from this work

**Constrain the model to choosing from the existing canonical lists, never to
free generation.** Retrieve candidates with machinery the repo already has —
`check_containment`, `check_fuzzy`, `entity_family_key` — show the model ten
plausible options from `final_sponsor_canonical_map.csv` or
`canonical_substances.csv`, and require it to pick one or abstain. That turns
invention into classification, and any answer outside the list is rejectable
mechanically, so the output cannot introduce new spellings or drift.

The defect in the historical passes was never that an LLM made the decisions. It
is that nobody recorded which model, which prompt, or on what date, so the
decisions cannot be re-derived or audited — and 20 of them are demonstrably
wrong, per the failing gold fixtures. Pinning the model id, versioning the
prompt, and committing the cache (as `2_chembl_cache.csv` already is) fixes that
specific defect.

Two caveats for whoever picks this up:

- **Exhaust the registries first on the substance side.** §Context measured 29%
  of `substance_llm_reviewed.csv` as redundant with ChEMBL, which the pipeline
  already queries. Some of the residue is payable without any API call.
- **Network.** The agent sandbox allowlist covers CRAN, Bioconductor,
  ClinicalTrials.gov and GitHub, but not `api.anthropic.com`. That run needs the
  allowlist widened or to happen outside the sandbox.
