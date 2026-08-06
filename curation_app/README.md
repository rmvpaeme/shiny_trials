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
| Sponsor queue | 102 | `config/sponsor_norm_pipeline/sponsor_review_queue.csv` |
| Substance queue | 1,317 | `config/substance_norm_pipeline/substance_review_queue.csv` |
| Sponsor LLM aliases | 1,383 | `manual_sponsor_aliases.csv` where `source == llm_curated` |
| Substance LLM aliases | 1,380 | `manual_brand_to_substance.csv` where `source == llm_curated` |
| Substance canonicals | 370 | `canonical_substances.csv` where `source == llm_curated` |
| Fuzzy singletons | 1,879 | fuzzy matches dropped from the queue by the `n_occurrences >= 2` filter |

The queue tiers are ordered by trial/occurrence impact, the alias tiers by how
many trials currently resolve through them, and fuzzy singletons by ascending
match score (worst first).

## Reviewing

Each row shows the raw string, the normalisation currently claimed for it, the
evidence behind that claim, and every other alias mapping to the same canonical
— that last panel is usually what makes a wrong canonical obvious.

The proposed value is a dropdown over existing canonical names (8,309 sponsors,
17,603 substances, loaded server-side) rather than a free text box. Typing a
name that does not exist offers to create it, but that path shows a warning and
is recorded as `created_new_canonical` in the ledger. Uncontrolled canonical
creation is how the near-duplicate canonicals accumulated in the first place, so
it is deliberately visible rather than convenient.

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

`apply.R` covers the alias tiers. Accepted rows get `source: manual`, edited
rows have their canonical and extra fields rewritten, and rejected rows are
removed from the alias table and added to the negative-alias list. It replays
the whole ledger every run, so running it twice is a no-op the second time.

Queue tiers use the existing exporters instead:

```bash
Rscript helper_scripts/sponsor_norm_pipeline/curate_sponsors.R --export
Rscript helper_scripts/substance_norm_pipeline/curate_substances.R --export
```

Then rebuild the indexes so the decisions take effect:

```bash
Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror
Rscript helper_scripts/substance_norm_pipeline/build_substance_index.R --use-chembl-cache
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
