# EU Paediatric Trial Monitor

**v0.10.4** · R Shiny · EUCTR + CTIS · ~17 500 trials · **License:** MIT · **Authors:** Ruben Van Paemel, Levi Hoste

A research dashboard for exploring, analysing, and monitoring clinical trials registered in the European Union, with a focus on paediatric trials. The database covers all age groups so that paediatric and adult populations can be compared directly; the sidebar Age Group filter defaults to `< 18 years` to preserve the paediatric focus. Data is pulled from the EU Clinical Trials Register (EUCTR) and the Clinical Trials Information System (CTIS) using the [`ctrdata`](https://cran.r-project.org/package=ctrdata) package.

![Dashboard overview](overview.png)

---

## Source data

Trial records are retrieved from two complementary EU registries using the `ctrdata` R package. Both queries fetch **all age groups** — paediatric and adult — so that the two populations can be compared directly in the dashboard.

| Register | URL | Query |
| -------- | --- | ----- |
| **EUCTR** — EU Clinical Trials Register | [clinicaltrialsregister.eu](https://www.clinicaltrialsregister.eu) | All trials (no age filter) |
| **CTIS** — Clinical Trials Information System | [euclinicaltrials.eu](https://euclinicaltrials.eu) | All trials (no age filter) |

### Search strings used

**EUCTR** — all trials, no age restriction:

```text
https://www.clinicaltrialsregister.eu/ctr-search/search?query=
```

**CTIS** — all trials:

```text
https://euclinicaltrials.eu/ctis-public/search#searchCriteria={}
```

These URLs are defined in `update_data.R` and passed to `ctrdata::ctrLoadQueryIntoDb()`. The default update refreshes **CTIS only**, because EUCTR changes slowly and the full historical EUCTR load has already been captured. To refresh EUCTR explicitly, run `Rscript update_data.R --euctr` or `REFRESH_EUCTR=true Rscript update_data.R`. EUCTR is fetched in quarterly date-range chunks (2004 → present); if a range fails, the script recursively bisects it down toward single-day ranges before falling back to trial-by-trial loading. Completed chunks are logged to `data/done_chunks.txt` and failed chunks/trials to `data/failed_chunks.txt` so interrupted runs can resume. EUCTR result documents (`euctrresults`) are **not** fetched by default because they make ingestion much slower; use `Rscript update_data.R --euctr-results` or `FORCE_RESULTS=true Rscript update_data.R` when you explicitly want to refresh them.

---

## Example uses

The dashboard is designed for specific analytical workflows, not just browsing. Here are the scenarios it was built to support.

**Tracking a disease area over time**
Select a MedDRA organ class or specific condition, set a date range, and see how trial activity has changed year by year — including which sponsors are most active, whether the Phase I → Phase III pipeline is growing or stalling, and which EU member states participate most. The Chart Builder lets you cross any two dimensions without writing code.

**Result reporting overview**
The Result Reporting tab shows which completed trials have reported results to the registry and which have not. Results data is sourced directly from EUCTR (`endPoints.endPoint.readyForValues`) and CTIS (`resultsFirstReceived`) — not estimated. KPI cards show total completed trials, results reported (% of total), Academic without results (% of total), and Industry without results (% of total). Charts break down by authorization year and sponsor type; the full list of completed trials without results is downloadable as CSV.

**Comparing sponsor portfolios**
Select 2–3 sponsors and the Sponsor Comparison tab renders side-by-side breakdowns of phase distribution, trial status, therapeutic areas, geographic reach, PIP involvement, and submission volume over time. Useful for competitive intelligence, partnership scoping, or regulatory submissions that require landscape context.

**Orphan / rare disease landscape**
The Orphan Designation filter (sourced from EUCTR DIMP D.2.5 and CTIS orphan designation numbers) narrows the dataset to orphan-designated products. Combined with MedDRA filtering, this surfaces the rare disease trial landscape for a given indication without manual registry searches.

**Pipeline maturity assessment**
The Completion Rate by Authorization Cohort chart (Phase Analytics) shows what percentage of trials authorized in each year have since completed, split by register. More recent cohorts naturally show lower rates; a plateauing line in an older cohort signals trials that have stalled rather than completed.

---

## Dashboard tabs

| Tab | What it shows |
| --- | ------------- |
| **Overview** | KPI cards (total / ongoing / completed / PIP); clickable navigation shortcut cards (CSS grid, mobile-friendly); example questions that apply filters in one click; prominent "Compare Paediatric vs Adult" button in sidebar; 5 most recently authorized trials |
| **Chart Builder** | Fully custom bar / line chart — any column on X, optional grouping, 4 chart types; age-aware country per-million normalisation |
| **Map** | Open trials by country (circle map); age-aware per-million normalisation; sortable country table at zoom ≥ 5 |
| **Data Explorer** | Filterable/searchable table with CSV & Excel export, click-to-expand trial detail modal |
| **Analysis** *(collapsible group)* | |
| &nbsp;&nbsp;Basic Analytics | Top organ classes, top MedDRA terms, country bar chart, PIP status, regulatory timeline |
| &nbsp;&nbsp;Phase Analytics | Phase by register / status / sponsor type, phase funnel, completion cohort |
| &nbsp;&nbsp;Sponsor Comparison | Side-by-side comparison of 2–3 selected sponsors across 7 dimensions including result reporting |
| &nbsp;&nbsp;Country Comparison | Side-by-side comparison of 2–3 selected countries across 7 dimensions including result reporting |
| &nbsp;&nbsp;Result Reporting | Results reported vs not reported for completed trials, by year and sponsor type; downloadable list |
| **About** | Data sources, preprocessing audit report, changelog, trial status definitions |

### Sidebar filters

All charts and tables update simultaneously when filters change. Active filters appear as chips above the content area with a one-click Reset all.

| Filter | Options |
| ------ | ------- |
| **Age Group** | `< 18 years` (default) / `≥ 18 years` / `All` — trials enrolling both age groups ("Paediatric & Adult") appear under both |
| Submission date range | Any date range from 2004 to today |
| Free-text search | Title, CT number, condition, product name, sponsor |
| Country / Member State | Multi-select; normalised country names from the registry data |
| Sponsor / Company | Multi-select; normalised names (legal suffixes stripped) |
| Trial Status | Ongoing / Completed / Other |
| Source Register | EUCTR / CTIS |
| Trial Phase | Phase I / II / III / IV |
| Part of PIP | Yes / No / Unknown |
| Orphan Designation | Yes / No / Unknown |
| MedDRA Organ Class | Multi-select |
| Condition / MedDRA Term | Multi-select with server-side search |

Filter state is encoded in the URL (`?f=` query param, base64 JSON) for bookmarking and sharing.

---

## How to deploy

### Requirements

- R ≥ 4.3
- A LaTeX distribution for PDF export (TinyTeX recommended: `tinytex::install_tinytex()`)

### Install R packages

```r
install.packages(c(
  "shiny", "shinydashboard", "fresh", "shinycssloaders",
  "ctrdata", "nodbi", "RSQLite", "DBI",
  "dplyr", "tidyr", "stringr", "lubridate",
  "ggplot2", "plotly", "leaflet", "scales", "forcats",
  "DT", "jsonlite", "base64enc",
  "readr", "writexl",
  "rmarkdown", "knitr", "kableExtra"
))
```

### Fetch data

```bash
Rscript update_data.R
```

By default, this refreshes CTIS only and leaves the already-loaded EUCTR history untouched. To include EUCTR, run:

```bash
Rscript update_data.R --euctr
# or
REFRESH_EUCTR=true Rscript update_data.R
```

To include EUCTR result documents (`euctrresults = TRUE`), run:

```bash
Rscript update_data.R --euctr-results
# or, backwards-compatible alias
FORCE_RESULTS=true Rscript update_data.R
```

Requesting EUCTR results automatically enables the EUCTR refresh path. It is significantly slower than the normal EUCTR metadata refresh.

The explicit EUCTR refresh can take several hours because it checks ~44 000 registry rows in quarterly chunks. Completed chunks are logged to `data/done_chunks.txt`; delete this file only when you intentionally want a full EUCTR re-check. Failed ranges and trial IDs are written to `data/failed_chunks.txt` for follow-up.

### Build the cache

```r
source("rebuild_cache.R")
```

Processes the SQLite database into `trials_cache.rds`. Run this after `update_data.R` or whenever the pipeline logic in `app.R` changes. The cache is automatically invalidated when the database file is newer.

### Sponsor alias review

Sponsor-name cleanup in the app is deterministic code in `app.R`. The generated file `data/sponsor_alias_candidates.csv` and reviewed file `config/sponsor_aliases.csv` are **manual curation aids**: candidates are not applied to the app data or cache by themselves.

See [sponsor_curation/README.md](sponsor_curation/README.md) for the full guide.

To refresh the candidate review queue:

```bash
Rscript sponsor_curation/audit_sponsors.R
```

Review candidates manually; some high-scoring pairs are intentionally separate organisations. To approve rows, set `approved=TRUE` directly in `data/sponsor_alias_candidates.csv`, optionally adjust `canonical_suggestion` or `notes`, then run:

```bash
Rscript sponsor_curation/approve_sponsor_aliases.R
```

For a guided review, use the interactive reviewer instead:

```bash
Rscript sponsor_curation/review_sponsor_aliases.R
```

It shows one candidate at a time and lets you approve, skip, edit, or quit. The interactive reviewer saves approvals and skips immediately to `config/sponsor_review_decisions.csv`, so reopening it resumes at the next unreviewed candidate. Both approval scripts append approved rows to `config/sponsor_aliases.csv` and regenerate the candidate queue after applying the reviewed aliases, so accepted pairs disappear from later review rounds. The preprocessing audit also reports how many sponsor labels are new since `config/sponsor_curation_baseline.csv`. After review, apply the decisions to `app.R`, refresh the cache, regenerate candidates/logs, update the baseline, and render preprocessing with:

```sh
Rscript sponsor_curation/apply_sponsor_aliases.R
```

### Run the app

```r
shiny::runApp()
```

Or from the terminal:

```bash
Rscript -e "shiny::runApp(port = 3838)"
```

### Docker

A `Dockerfile` and `docker-compose.yml` are included, but they have not yet been fully refreshed for the v0.9 all-ages file names. For local development, the R commands above are the canonical path. Before production Docker deployment, confirm the container paths use `data/trials.sqlite` and `trials_cache.rds`.

```bash
docker build -t paediatric-trials .
docker run -p 3838:3838 \
  -v $(pwd)/data:/shiny_trials/shiny_trials/data \
  -v $(pwd)/trials_cache.rds:/shiny_trials/shiny_trials/trials_cache.rds \
  paediatric-trials
```

With Docker Compose:

```bash
docker compose up -d
docker compose exec app Rscript /app/update_data.R  # first-time data load
```

The PDF report uses `xelatex` so Unicode registry text (for example `≥`) does not break rendering. TinyTeX or a TeX Live installation with `xelatex` is sufficient.

### Scheduled data updates

To refresh overnight, schedule `update_data.R` and `rebuild_cache.R` via cron (macOS/Linux):

```bash
0 3 * * * Rscript /path/to/update_data.R && Rscript /path/to/rebuild_cache.R >> /var/log/trials_rebuild.log 2>&1
```

After each rebuild the app loads the new RDS on the next session start (or immediately if `force_rebuild = TRUE` is passed to `load_trial_data()`).

---

## Known issues and pipeline limitations

**EUCTR first run is slow**
The EUCTR refresh is opt-in. The initial explicit fetch downloads ~44 000 registry rows across quarterly date-range chunks (2004 → present). Expect several hours. Progress is logged to `data/done_chunks.txt`; if the run is interrupted, re-running `update_data.R --euctr` will skip already-completed chunks automatically. Some EUCTR date ranges return malformed responses; v18 bisects failing ranges toward single days and then tries individual trial IDs. `--euctr-results` / `FORCE_RESULTS=true` is slower again because it requests EUCTR result documents.

**CTIS country field**
CTIS stores member states as a nested JSON array. After flattening, some records return a string of numeric IDs or ISO codes rather than full country names. The `clean_member_state()` function resolves the majority, but edge cases (new member states, non-standard ISO entries) may appear as `NA` in the country column.

**MedDRA classification divergence between registers**
EUCTR stores MedDRA terms at the condition level; CTIS stores them at the trial level with additional codes. Trials appearing in both registers may show slightly different MedDRA assignments depending on which register version is kept after deduplication. The dashboard always prefers the CTIS record for trials present in both.

**Results and orphan fields require cache rebuild**
The `has_results` (results posted) and `is_orphan` (orphan designation) columns are derived during cache rebuild from registry fields added in v0.7.0. Re-run `rebuild_cache.R` after updating `app.R` pipeline logic.

**Phase assignment for multi-phase trials**
EUCTR allows a trial to tick multiple phase flags simultaneously (e.g. Phase I + Phase II). The dashboard preserves these as `/`-separated values (`Phase I / Phase II`) rather than arbitrarily picking one. Charts that use `separate_rows()` handle this correctly; any external analysis of the exported CSV should account for multi-valued phase cells.

**Overlap detection accuracy**
Cross-register deduplication uses CT number matching first, then normalised title matching (first 80 characters, lowercased, punctuation stripped). Unusual title formatting or very short titles can result in missed matches (same trial counted twice) or false matches (different trials merged). The deduplication log is printed to console during cache rebuild.

**Cache invalidation**
The cache is invalidated only when the SQLite database file is newer than the RDS. If you edit `prepare_trial_data()` logic without touching the database, delete `trials_cache.rds` manually before restarting the app to force a rebuild.

---

## Changelog

### v0.10.4 — 2026-05-05

- **CTIS transition matching**: transitioned EUCTR trials are now matched to CTIS using the CTIS embedded transition EudraCT number, not only title or CTIS ID assumptions.
- **Searchable aliases**: CTIS transition rows retain the old EudraCT number as a searchable alias so trials remain findable by either identifier.
- **Register Migration tab**: a dedicated Analysis view now highlights EUCTR-era records that are sourced from CTIS after migration.
- **Safer deduplication audit**: title-only duplicate drops are limited to explicitly transitioned records, CTIS swaps keep the latest amendment version, and the preprocessing report audits canonical trial IDs.
- **CTIS MedDRA organ classes restored**: numeric EMA MedDRA SOC codes are preserved during CTIS flattening so the Top MedDRA Organ Classes chart works when filtering to CTIS.
- **Sponsor curation workflow**: sponsor alias review tools now live in `sponsor_curation/`, with resumable interactive review, CSV batch approval, self-service alias application to `app.R`, cache/log/candidate regeneration, and baseline updates.

See [CHANGELOG.md](CHANGELOG.md) for the full version history.


---

## Project structure

```text
.
├── app.R                        # Main Shiny application
├── update_data.R                # Fetches data from EUCTR and CTIS into SQLite
├── rebuild_cache.R              # Rebuilds RDS cache from SQLite (no re-download)
├── sponsor_curation/
│   ├── README.md                        # Sponsor curation guide
│   ├── audit_sponsors.R                 # Generates sponsor alias review candidates
│   ├── approve_sponsor_aliases.R        # Promotes approved candidate rows into config
│   ├── apply_sponsor_aliases.R          # Applies reviewed aliases to app/cache/baseline
│   ├── review_sponsor_aliases.R         # Interactive sponsor alias reviewer
│   └── sponsors.md                      # Sponsor normalisation handover notes
├── report.Rmd                   # PDF report template (rendered on demand)
├── preprocessing.Rmd            # Pipeline audit report source
├── trials_cache.rds             # Processed data cache (git-ignored)
├── config/
│   ├── sponsor_aliases.csv              # Manual sponsor alias review decisions
│   └── sponsor_curation_baseline.csv    # Sponsor labels present at last manual curation
├── Dockerfile
├── docker-compose.yml
├── data/
│   ├── trials.sqlite                    # Raw trial data from ctrdata (git-ignored)
│   ├── sponsor_alias_candidates.csv     # Generated review queue; not applied automatically
│   ├── sponsor_normalisation_log.csv
│   ├── country_normalisation_log.csv
│   ├── meddra_term_normalisation_log.csv
│   ├── organ_class_normalisation_log.csv
│   ├── phase_normalisation_log.csv
│   ├── status_category_normalisation_log.csv
│   ├── status_display_normalisation_log.csv
│   └── deploy/                          # Docker deployment files
└── www/
    ├── favicon.svg
    └── preprocessing.html        # Rendered pipeline audit report
```

---

## Configuration

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `DB_PATH` | `./data/trials.sqlite` | SQLite database file |
| `DB_COLLECTION` | `trials` | Collection name within the database |
| `CACHE_PATH` | `trials_cache.rds` | Processed data cache (app root) |

---

## Technology stack

| Layer | Package(s) | Role |
| ----- | ---------- | ---- |
| Data retrieval | [`ctrdata`](https://github.com/rfhb/ctrdata) | Unified access to EUCTR and CTIS |
| Database | [`nodbi`](https://github.com/ropensci/nodbi) + [`RSQLite`](https://cran.r-project.org/package=RSQLite) | Local document store over SQLite |
| Web framework | [`shiny`](https://shiny.posit.co/) + [`shinydashboard`](https://rstudio.github.io/shinydashboard/) + [`fresh`](https://dreamrs.github.io/fresh/) | Dashboard UI + AdminLTE theming |
| Charts | [`plotly`](https://plotly.com/r/) + [`ggplot2`](https://ggplot2.tidyverse.org/) | Interactive + PDF visualisations |
| Map | [`leaflet`](https://rstudio.github.io/leaflet/) | Country-level interactive map |
| Tables | [`DT`](https://rstudio.github.io/DT/) | Interactive data tables |
| Data wrangling | [`dplyr`](https://dplyr.tidyverse.org/), [`tidyr`](https://tidyr.tidyverse.org/), [`stringr`](https://stringr.tidyverse.org/), [`lubridate`](https://lubridate.tidyverse.org/) | Data manipulation |
| Export | [`writexl`](https://cran.r-project.org/package=writexl), [`readr`](https://readr.tidyverse.org/) | CSV and Excel download |
| URL state | [`base64enc`](https://cran.r-project.org/package=base64enc), [`jsonlite`](https://cran.r-project.org/package=jsonlite) | Filter serialisation to URL |
| Report | [`rmarkdown`](https://rmarkdown.rstudio.com/) | PDF report generation |

---

## Acknowledgements

Trial data is retrieved from two official EU registries:

- **EUCTR** — [EU Clinical Trials Register](https://www.clinicaltrialsregister.eu), European Medicines Agency. Covers trials submitted from 2004 under Directive 2001/20/EC.
- **CTIS** — [Clinical Trials Information System](https://euclinicaltrials.eu), European Medicines Agency. Mandatory for new applications from January 2023 under Regulation (EU) No 536/2014.

Data retrieval is powered by the [`ctrdata`](https://cran.r-project.org/package=ctrdata) R package (Ralf Herold), which provides a unified interface for querying, downloading, and storing trial records from multiple EU and international registries.

MedDRA terminology is the property of the International Council for Harmonisation of Technical Requirements for Pharmaceuticals for Human Use (ICH). Use of MedDRA terminology requires a licence; this dashboard uses MedDRA codes and terms as provided by the registries under their public data policies.

Built with [R Shiny](https://shiny.posit.co), [shinydashboard](https://rstudio.github.io/shinydashboard/), [plotly](https://plotly.com/r/), [leaflet](https://rstudio.github.io/leaflet/), and [DT](https://rstudio.github.io/DT/).
