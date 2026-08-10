# Normalisation reproducibility — making raw → final derivable without an LLM

**Status: proposed, not started.** Filed for a later session. Nothing in this
document has been implemented; the measurements in *Context* were taken on
2026-08-07 against the tree at `64013fd` and are reproducible from the committed
config files.

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

| Decision | Choice |
|---|---|
| Rule layer vs. replacing table rows | **Layer.** Tables stay the frozen record; rules run before the queue |
| Redundant substance overrides | **Prune**, gated on byte-identical labels |
| The irreducible residue | Still open — see the last section |

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

## Still open: the irreducible residue

After §1, roughly 25% of new sponsors and 60% of new substances still need a
decision that no rule can produce. Two options, and this was not settled:

- **Pin and cache the LLM step** — a committed `5_llm_resolve.R` with pinned
  model id, versioned prompt, temperature 0, and decisions cached by
  `sha256(raw + prompt_version)`. Re-running is then reproducible and only
  genuinely new strings reach the API. Makes the LLM a documented pipeline stage
  rather than an undocumented past event.
- **Route to the reviewer app** — reproducible by construction, human-paced.

Recommendation: both, in that order — the LLM proposes, the reviewer app is where
a human confirms and stamps `source: manual`. That is already the architecture
`PLANS/normalisation-reviewer-multiuser.md` describes; the derivation layer just
makes the backlog reaching it substantially smaller.
