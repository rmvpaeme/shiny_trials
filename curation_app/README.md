# Normalisation reviewer

Local Shiny app for human verification of low-confidence sponsor and substance
normalisations.

It exists because the normalisation config was curated almost entirely by LLM
agents that stamped their rows `source: manual`, which claimed a human
verification that never happened. Those rows now read `source: llm_curated`,
and `manual` is written in exactly one place: by this app, when a person has
actually looked at the row.

## Run

```bash
Rscript -e 'shiny::runApp("curation_app")'
```

Set `REVIEWER` to name the reviewer recorded against each decision; it
otherwise defaults to the OS user and can be edited in the app header.

```bash
REVIEWER="rvp" Rscript -e 'shiny::runApp("curation_app")'
```

## Tiers

| Tier | Rows | Source |
|---|---:|---|
| **Sponsor fragments** | 194 | canonicals differing only by casing/punctuation/article — same entity, split trial counts |
| **Substance conflicts** | 42 | one raw string overridden to two different substances |
| Sponsor LLM-reviewed | 2,344 of 11,899 | `sponsor_llm_reviewed.csv`, filtered to ≥3 trials |
| Substance LLM-reviewed | 2,607 of 10,250 | `substance_llm_reviewed.csv`, filtered to ≥3 occurrences |
| Sponsor queue | 102 | `config/sponsor_norm_pipeline/3_sponsor_review_queue.csv` |
| Substance queue | 1,317 | `config/substance_norm_pipeline/3_substance_review_queue.csv` |
| Sponsor LLM aliases | 1,383 | `sponsor_llm_aliases.csv` where `source == llm_curated` |
| Substance LLM aliases | 1,380 | `substance_llm_brands.csv` where `source == llm_curated` |
| Substance canonicals | 370 | `canonical_substances.csv` where `source == llm_curated` |
| Fuzzy singletons | 1,879 | fuzzy matches dropped from the queue by the `n_occurrences >= 2` filter |

The queue tiers are ordered by trial/occurrence impact, the alias tiers by how
many trials currently resolve through them, and fuzzy singletons by ascending
match score (worst first).

## Scope: why the LLM-reviewed tiers are filtered

Those two tiers hold 22,149 rows between them, which nobody is going to review.
Most of the tail is not worth reviewing either — 7,403 sponsor rows resolve
exactly one trial and 447 resolve none at all. Rows with ≥3 trials are 2,344 of
the sponsor tier but carry **60% of its impact**, so that is the default
threshold. The slider moves it.

Impact is joined using the pipeline's own `clean_sponsor_alias()` /
`clean_alias()`, not `tolower(trimws(x))`. The cleaners also transliterate to
ASCII, normalise quotes and dashes, expand `&`, and turn punctuation into
spaces, so a naive key silently misses every sponsor with a comma, period or
accent — `Incyte Corp.` (54 trials) and `Lilly S.A.` (37) look like zero-impact
rows under it and fall below the threshold.

The excluded tail is not abandoned, it is sampled. Switch **Scope** to *Audit
sample of the tail* and the tier serves a fixed random sample of 200 rows drawn
from below the threshold, seeded on the tier id so the same rows come back every
session and for every reviewer. Review them, and the **Tail audit** table on the
Progress tab reports the observed error rate with a Wilson 95% interval and the
implied number of bad rows in the whole tail.

That is the point of it: a clean sample is what makes skipping ~18,000 rows
defensible. Without one, "we didn't look at the tail" has no error bar. With
0 errors in 200 the tail is at most 1.9% wrong and you can stop; with 30 it is
10.7–20.6% and it has earned attention.

## Reviewing

Each row shows the raw string, the normalisation currently claimed for it, and
three evidence panels:

- **Evidence** — match score, source, reason, and impact.
- **Other aliases mapping to this canonical** — usually what makes a wrong
  canonical obvious. Each sibling is actionable: **Detach** records a rejection
  against the file that alias actually lives in, so a bad sibling can be fixed
  without navigating to it. Aliases from the generated tiers (EPAR, CTIS
  businessKey, email domain, ChEMBL) are shown read-only and marked
  `generated`, because they are re-derived on every rebuild and an edit would
  be silently undone.
- **Registered trials using this raw value** — the EUCTR/CTIS trial IDs this
  string actually came from, linked to the public registers, with a country
  summary. This is what settles an ambiguous name: `UCL` appears on four
  trials, all `-GB`, so it is University College London and not Université
  catholique de Louvain (`-BE`).

The proposed value is a dropdown over existing canonical names (8,309 sponsors,
17,603 substances, loaded server-side) rather than a free text box. Typing a
name that does not exist offers to create it, but that path shows a warning and
is recorded as `created_new_canonical` in the ledger. Uncontrolled canonical
creation is how the near-duplicate canonicals accumulated in the first place, so
it is deliberately visible rather than convenient.

Classification fields are constrained too: `sponsor_type`, `alias_type` and
`substance_type` are fixed-vocabulary dropdowns (`FIELD_CHOICES` in
`R/tiers.R`), and `sponsor_parent` / `sponsor_group` use the canonical pool.
Free text on these fields is how one type becomes three spellings.

Actions: **Accept**, **Save edit**, **Reject** (comment required), **Skip**.

## Where decisions go

Every decision appends to `config/review_ledger/review_decisions.csv`. That
ledger is the durable record — the queue CSVs are not, because
`build_*_labels.R` drops decided rows when it rebuilds them (use
`--keep-decided` to carry them forward instead).

The ledger is append-only: changing your mind writes a second row, and the
latest decision per `(tier, row_key)` wins on replay.

Queue-tier decisions are additionally written into the queue CSV's
`decision` / `canonical_*` / `comment` columns, which is the format the existing
exporters already read.

## Applying decisions

```bash
Rscript curation_app/apply.R           # dry run — reports what would change
Rscript curation_app/apply.R --write   # apply
```

`apply.R` covers the alias and conflict tiers. It replays the whole ledger every
run, so running it twice is a no-op the second time.

| Tier | What applying does |
|---|---|
| alias tiers | accept → `source: manual`; edit → rewrite canonical and extra fields; reject → remove the row and add it to the negative-alias list |
| **Sponsor fragments** | append the losing spellings to `final_sponsor_canonical_map.csv` as `from` rows, which `apply_explicit_final_map()` in `2_build_sponsor_index.R` already collapses on the next rebuild |
| **Substance conflicts** | drop every competing target for that raw string from `substance_llm_overrides.csv` and `substance_llm_reviewed.csv`, keeping the chosen one |

Queue tiers use the existing exporters instead:

```bash
Rscript helper_scripts/sponsor_norm_pipeline/4_curate_sponsors.R --export
Rscript helper_scripts/substance_norm_pipeline/4_curate_substances.R --export
```

Then rebuild the indexes so the decisions take effect:

```bash
Rscript helper_scripts/sponsor_norm_pipeline/2_build_sponsor_index.R --no-ror
Rscript helper_scripts/substance_norm_pipeline/2_build_substance_index.R --use-chembl-cache
```

`--no-ror` matches how the committed index was built. Dropping the flag enables
the ROR tier, which adds ~118 aliases and changes ~33 canonicals — a real change,
but a separate decision from anything the reviewer does.

## Not deployed

`manifest.json` is an explicit 7-file allowlist, so this app is not part of the
Posit Cloud bundle. Do not regenerate the manifest with
`rsconnect::writeManifest`, which would sweep this directory in.

## Files

| File | Role |
|---|---|
| `app.R` | Entry point, navbar, progress/metrics panel |
| `R/tiers.R` | Tier definitions and loaders; canonical name pools |
| `R/review_card.R` | The review module used by every tier |
| `R/store.R` | Atomic writes, file locking, the decision ledger |
| `apply.R` | Replays the ledger onto the config files |
