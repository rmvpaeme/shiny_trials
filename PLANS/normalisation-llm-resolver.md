# Settle the canonical vocabulary, then resolve the residue with a pinned LLM

**Status: proposed, not started.** Filed for a later session. The measurements in
*What the vocabulary audit found* were taken on 2026-08-10 against the tree at
`1eeb08c` and are reproducible from the committed config files.

Related: [`normalisation-reproducibility.md`](normalisation-reproducibility.md)
is where the residue this plan targets was measured and where §2's override
prune was completed. [`normalisation-reviewer-multiuser.md`](normalisation-reviewer-multiuser.md)
is where the proposals this plan produces get reviewed.

## Context

The derivation layer was built, measured, and reverted: rules move 0.05% of
sponsor labels and 0.5% of substance labels, because the residue is entity
resolution, not string editing. `1. Frauenklinik der LMU-Innenstadt` →
`Klinikum Der Universitat Munchen AöR` shares no material with its input. **240
sponsors and 7,003 substances are still unresolved**, and nothing in the repo
resolves them without another LLM pass.

The defect in the historical LLM passes was never that an LLM made the
decisions. It is that nobody recorded which model, which prompt, or on what
date, so the decisions cannot be re-derived or audited — and 20 of them are
demonstrably wrong (the failing gold fixtures). This builds the LLM back in as a
*documented pipeline stage*: pinned model id, versioned prompt, committed
decision cache, and output that reaches a human before it reaches a label.

**The resolver picks from the canonical list, so the canonical list has to be
right first.** Asking a model to choose between `Medical University Of Graz` and
`Medical University of Graz` just freezes an arbitrary pick, and the cache key
includes a hash of the candidate set — so a canonical merged *after* proposals
are cached silently invalidates them, paying twice and discarding the review
work. Cleanup is Phase 0, not a parallel track.

## Decisions taken

| Decision | Choice |
|---|---|
| Domain first | **Sponsors.** 240 strings, ~$2, small enough to read every proposal |
| Transport | **Batch API**, with a `--sync` fallback for prompt iteration |
| Output vocabulary | **Constrained to existing canonicals.** The model picks or abstains; it never writes a name |
| Where proposals land | **The reviewer app.** Nothing auto-applies |

## What the vocabulary audit found

7,636 distinct sponsor canonicals. Measured 2026-08-10:

| Check | Result |
|---|---|
| Collide under `clean_sponsor_alias()` (case, accents, punctuation) | **1 pair** — `Medical University Of Graz` / `Medical University of Graz` |
| Differ only by a trailing legal suffix | **1 pair** — `Bracco Imaging` / `Bracco Imaging S.p.A` |
| Backed by exactly one alias | **5,928 (78%)** |
| No self-alias — the label maps nothing to itself | **4,461 (58%)** |
| Unapplied rows in the existing merge queue | **937 of 1,225** (861 blocked, 76 review) |

The mechanical axes are far cleaner than expected — two collisions in the whole
table. The real gaps are the last two rows, and neither needs an LLM.

---

## Phase 0 — settle the vocabulary

Three workstreams, ordered by how much judgment each needs. Only the third
touches the API.

### 0a. Self-alias integrity (deterministic, no LLM)

4,461 canonicals have no row mapping the label to itself. `check_alias()`
matches `alias_clean %in% candidates`, so if one of those labels arrives verbatim
as a raw sponsor it does not match on the alias tier at all — it falls through to
containment or fuzzy, or misses. Emitting `(clean_sponsor_alias(canonical),
canonical)` rows closes that.

Not blindly: an emitted alias that collides with an *existing* alias pointing
somewhere else is a real conflict and must be reported, not overwritten. Expect
few; they are findings, not noise.

New `helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R` reports all
five rows of the table above and, with `--fix-self-aliases`, writes the safe
subset. Gated on `data/trial_sponsor_labels.csv` — labels may *gain* matches
where they were `unknown`, but no already-matched trial may change.

### 0b. Work the existing merge queue (human judgment, no LLM)

`2_final_sponsor_canonical_review.csv` already holds 1,225 generated merge
proposals from `2_build_sponsor_index.R`; **937 are unapplied**. This is machinery
that exists and has never been worked, so it comes before building anything new.

- **861 `blocked`** — 856 share one `blocked_reason`: *"combined multi-entity
  label or alias-only family evidence excluded from auto-map"*. That is one
  systematic exclusion rule, not 861 individual judgments. Read the rule in
  `2_build_sponsor_index.R`, decide once whether it is still right, and either
  unblock the class or document why it stays. The other 5 are `sponsor types
  differ` — the university-vs-teaching-hospital red flag the config README
  already warns about; those stay blocked.
- **76 `review`** — the genuine per-case calls. Accepted rows go to
  `final_sponsor_canonical_map.csv` (label-to-label) or
  `final_sponsor_family_map.csv` (entity-family), per the existing convention.

Because the file is regenerated, decisions recorded only there are lost — copy
accepted rows into the final maps as you go.

### 0c. LLM recheck of the ambiguous remainder (constrained, same machinery as Phase 1)

Only for pairs where 0a and 0b leave a genuine question: *are these two labels
the same organisation?* That is yes / no / unsure classification with the
evidence supplied — the same constrained shape as the resolver, so it reuses the
same request builder, cache, and pinning. It writes proposals, never merges.

Scope this **after** 0b, since working the queue will answer most of it and
shrink the bill.

---

## Phase 1 — the resolver

### The constraint that makes it safe

**The model picks from a list. It never writes a name.**

Candidates come from machinery the repo already has. Every answer is either one
of the supplied candidates or an explicit abstention, enforced twice — by
`output_config.format` with an `enum` of the candidate labels, and by a
post-response check rejecting anything not in the list. A model that can only
choose cannot introduce a spelling, drift a canonical, or invent an
organisation.

That is also why the residue is worth an API call: choosing between
`Klinikum Der Universitat Munchen AöR` and nine plausible neighbours is
classification. Generating the string from scratch is not.

### Candidate retrieval — reuse, don't rebuild

`helper_scripts/sponsor_norm_pipeline/5_llm_resolve.R`. For each raw string the
matcher left `unknown`, assemble ~10 candidates from functions already in
`normalise_sponsors.R`:

| Source | Function | Gives |
|---|---|---|
| Fuzzy neighbours | `check_fuzzy()` internals over `cfg$fuzzy_targets` | Jaro-Winkler nearest labels, keyed by first letter |
| Token containment | `cfg$containment_token_index` | Labels sharing a signal token |
| Entity family | `sponsor_entity_key()` / `cfg$family_targets` | Same anchor + class (`radboud hospital`) |
| Generated candidates | `make_sponsor_candidates()` | The stripped forms the matcher already tried |

Deduplicate, cap at 10, carry each candidate's `sponsor_parent`, `sponsor_group`
and `source` so the model sees what it is choosing between. **If retrieval
yields nothing, skip the string** — there is nothing to choose from, and asking
anyway invites invention.

### The request

Raw HTTP via `httr2` (installed, 1.2.2). R has no official Anthropic SDK, which
is the documented condition for raw HTTP over an SDK.

- **Model** `claude-opus-5`, pinned as a constant, echoed into every cache row.
- **`output_config.format`** — `json_schema` with
  `{chosen: enum[...candidates..., "NONE_OF_THESE"], confidence: enum[high, medium, low], reason: string}`,
  `additionalProperties: false`. This replaces prefill, which 400s on this model.
- **`output_config.effort: "low"`** — constrained choice from a supplied list is
  the cheap end of the ladder. Sweep against the pilot's 240 before assuming.
- **Thinking** left at its default (on). Opus 5 thinks unless disabled, and
  disabling it is the documented cause of tool calls leaking into visible text.
  Size `max_tokens` to cover thinking *and* the JSON — it caps both together.
- **No `temperature`/`top_p`/`top_k`** — all 400 on this model. Determinism comes
  from the cache, not sampling parameters.
- **Prompt caching** — `cache_control: {type: "ephemeral"}` on the system block,
  which is byte-identical across all 240 calls; candidates go in the user turn,
  after the breakpoint. Opus 5's minimum cacheable prefix is 512 tokens — check
  with `count_tokens` rather than assuming it clears.
- **Refusals** — check `stop_reason == "refusal"` *before* reading `content`;
  set `fallbacks: "default"` with beta `server-side-fallback-2026-07-01`.

### Batching

Message Batches: 50% cheaper, usually within the hour. `custom_id` carries the
cache key, so results — which arrive in **any order** — key straight back. Poll
`processing_status` until `"ended"`, then branch on all four `result.type`
values (`succeeded`/`errored`/`canceled`/`expired`). `--sync` sends the same
bodies one at a time for prompt iteration.

### The cache

`config/sponsor_norm_pipeline/5_llm_proposals.csv`, committed — the precedent
`2_chembl_cache.csv` sets (a frozen API fetch committed on purpose so deployment
and CI need no network).

```text
cache_key, raw_sponsor, model_id, prompt_version, candidates_sha256,
chosen, confidence, reason, abstained, decided_at_utc, batch_id
```

`cache_key = sha256(raw_clean + prompt_version + model_id + candidates_sha256)`
via `openssl::sha256`. A run resolves only absent keys, so **re-running costs
nothing and only genuinely new strings reach the API**. Bumping the prompt
version or model id invalidates deliberately and visibly, in the diff.

### Where proposals land — the reviewer, never the labels

Nothing auto-applies. A proposal becomes a label only when a human accepts it in
the reviewer app, the one place that writes `source: manual`
(`curation_app/apply.R:198`).

Minimal integration: `load_sponsor_queue()` (`curation_app/R/tiers.R:112`) gains
a left join against the cache on `raw_sponsor`, and the `sponsor_queue` tier's
`evidence` vector gains `llm_proposal` and `llm_confidence`. `proposed` stays the
*matcher's* candidate, so both are visible and their provenance stays distinct.
That is ~10 lines, with no queue-CSV schema change and no label-builder change —
the alternative, new columns in `3_sponsor_review_queue.csv`, would need the
builder to preserve them across rebuilds for no gain.

---

## Files

| File | Phase | Change |
|---|---|---|
| `helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R` | 0a | new — vocabulary report + `--fix-self-aliases` |
| `config/sponsor_norm_pipeline/final_sponsor_canonical_map.csv` | 0b | accepted label-to-label merges |
| `config/sponsor_norm_pipeline/final_sponsor_family_map.csv` | 0b | accepted entity-family merges |
| `helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R` | 0b | only if the 856-row blocking rule changes |
| `helper_scripts/sponsor_norm_pipeline/5_llm_resolve.R` | 0c, 1 | new — retrieval, batch submit/poll, cache write |
| `config/sponsor_norm_pipeline/5_llm_proposals.csv` | 0c, 1 | new — committed decision cache |
| `curation_app/R/tiers.R` | 1 | join cache into `load_sponsor_queue()`; extend `evidence` |
| `config/*_norm_pipeline/README.md`, `PLANS/normalisation-reproducibility.md` | all | document the cache, step 5, and progress on the residue |

Not touched: `normalise_sponsors.R` (retrieval reuses its functions; the matcher
is unchanged), the label builders, and the substance pipeline.

## Cost

240 sponsors × (~700 input + ~150 output) tokens at $5/$25 per MTok ≈ **$1.40**,
about **$0.70** batched, less with the system prompt cached. Verify with
`count_tokens` on a real assembled request rather than trusting this arithmetic.
Phase 0c is smaller again and only sized after 0b. The same design over all
7,003 substances lands near $25–50 batched — the number that decides whether
substances are worth doing next.

## Verification

```bash
# ── Phase 0 ──────────────────────────────────────────────────────────────
cp data/trial_sponsor_labels.csv /tmp/labels_before.csv

Rscript helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R
# expect the 5-row table above; confirm the alias-conflict list is short

Rscript helper_scripts/sponsor_norm_pipeline/audit_sponsor_canonicals.R --fix-self-aliases
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-ror --no-location
Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R
# GATE: no already-matched trial may change; only unknown → matched is allowed
# GATE: gold fixtures stay at 20 sponsor / 6 substance failures

# ── Phase 1 ──────────────────────────────────────────────────────────────
ant auth status                                   # credentials
Rscript .../5_llm_resolve.R --dry-run             # assemble + count tokens, no calls
Rscript .../5_llm_resolve.R --sync --limit=5      # prompt iteration
Rscript .../5_llm_resolve.R --batch               # full run
Rscript .../5_llm_resolve.R --batch               # expect "0 new" — cache complete

# GATE: every non-abstained choice is an existing canonical
Rscript -e '
  p <- readr::read_csv("config/sponsor_norm_pipeline/5_llm_proposals.csv", show_col_types=FALSE)
  idx <- readr::read_csv("config/sponsor_norm_pipeline/2_sponsor_alias_index.csv", show_col_types=FALSE)
  bad <- setdiff(p$chosen[!p$abstained], idx$sponsor_clean)
  stopifnot(length(bad) == 0); cat("all choices are existing canonicals\n")'

# GATE: the resolver is inert — it writes proposals, not labels
Rscript helper_scripts/sponsor_norm_pipeline/3_build_sponsor_labels.R
diff /tmp/labels_before.csv data/trial_sponsor_labels.csv && echo "labels unchanged"

Rscript -e 'source("curation_app/R/tiers.R"); str(load_sponsor_queue(".")[1, ])'
```

The enum gate is the mechanical proof that the constrained output actually
constrained. The label diff proves the resolver changes nothing until a human
acts.

**Then read all 240 proposals.** At this size that is the real acceptance test,
and the last point at which a bad prompt is cheap to fix. Spot-check the
abstentions too — a resolver that abstains on everything passes every mechanical
check above.

## Risks

- **Network.** The agent sandbox allowlist covers CRAN, Bioconductor,
  ClinicalTrials.gov and GitHub, but **not `api.anthropic.com`**. Phase 1 needs
  the allowlist widened or has to run outside the sandbox. All of Phase 0 and
  every gate runs offline.
- **The sandbox also blocks writes under `config/`** — hit twice during the
  override prune, once on the atomic write and once on a shell redirect. Both
  phases write there, so expect the same friction.
- **Ordering is load-bearing.** Merging a canonical after proposals are cached
  changes `candidates_sha256` and silently re-resolves those rows. Finish
  Phase 0 before spending on Phase 1.
- **The 856 blocked rows are one decision, not 856.** If that reading is wrong
  and they are genuinely heterogeneous, 0b is a much larger job than budgeted —
  sample before committing to the phase.
- **A confident wrong answer is still wrong.** The gold fixtures already record
  20 frozen decisions that are wrong; this pipeline can produce more. The
  reviewer step is not a formality, and `confidence: high` is the model's
  opinion, not evidence.
