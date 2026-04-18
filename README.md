# EU Paediatric Trial Monitor

![Overview](overview.png)

**Version:** `v0.5.0` | **License:** MIT | **Author:** Ruben Van Paemel & Claude Sonnet 4.6

An interactive R Shiny dashboard that provides a unified, searchable view of paediatric clinical trials registered in the European Union. Data is pulled from two complementary registers and harmonised into a single dataset.

| Register | URL | Paediatric filter |
|---|---|---|
| **EUCTR** — EU Clinical Trials Register | [clinicaltrialsregister.eu](https://www.clinicaltrialsregister.eu) | Age group: under 18 |
| **CTIS** — Clinical Trials Information System | [euclinicaltrials.eu](https://euclinicaltrials.eu) | Age group code 2 (paediatric) |

---

## Contents

- [Quick Start](#quick-start)
- [Docker](#docker)
- [Dashboard Overview](#dashboard-overview)
- [Sidebar Filters](#sidebar-filters)
- [Data Pipeline](#data-pipeline)
- [Configuration](#configuration)
- [Project Structure](#project-structure)
- [Technology Stack](#technology-stack)
- [Known Issues](#known-issues)
- [Changelog](#changelog)

---

## Quick Start

### Prerequisites

- **R** ≥ 4.1
- System libraries for `ctrdata`: `libcurl`, `libssl`, `libxml2`, and `node.js` (recommended) or `V8`

### 1. Install R packages

```r
install.packages(c(
  "shiny", "shinydashboard", "shinycssloaders",
  "ctrdata", "nodbi", "RSQLite", "DBI",
  "dplyr", "tidyr", "ggplot2", "stringr", "lubridate",
  "DT", "plotly", "leaflet", "readr", "writexl", "eulerr"
))
```

### 2. Populate the database

```bash
Rscript update_data.R
```

> First run takes 30–60 minutes (EUCTR ~30 min, CTIS ~5 min). Subsequent runs are incremental.

### 3. Launch

```bash
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

Or open `app.R` in RStudio and click **Run App**.

---

## Docker

The easiest way to run the dashboard without a local R installation.

### Run with pre-built image

```bash
mkdir -p data

docker run -d -p 3838:3838 \
  -v $(pwd)/data:/app/data \
  --name shiny_trials \
  rmvpaeme/shiny_trials:0.2.1
```

Open [http://localhost:3838](http://localhost:3838).

The `-v` flag mounts a local `data/` directory so the SQLite database and RDS cache persist across container restarts.

### Pre-populate the database before launching

```bash
mkdir -p data

# Fetch data (30–60 min on first run)
docker run --rm \
  -v $(pwd)/data:/app/data \
  rmvpaeme/shiny_trials:0.2.1 \
  Rscript /app/update_data.R

# Launch the dashboard
docker run -d -p 3838:3838 \
  -v $(pwd)/data:/app/data \
  --name shiny_trials \
  rmvpaeme/shiny_trials:0.2.1
```

### Docker Compose

```bash
docker compose up -d
docker compose exec app Rscript /app/update_data.R  # first-time data load
```

---

## Dashboard Overview

The dashboard has seven tabs, each respecting the active sidebar filters.

### Overview

The landing tab. Provides a high-level summary of the filtered dataset:

- **Value boxes** — Total Trials, Ongoing, Completed, With PIP
- **5 most recently submitted trials** — sortable table; CT numbers are clickable links to the originating registry
- **Cumulative Trials by Start Date** — ECDF of trial start dates, coloured by status (Ongoing / Completed / Other)
- **Sponsor type by register** — grouped bar chart comparing Academic vs Industry across EUCTR, CTIS, and combined
- **Submissions per year** — stacked bar chart by register
- **Register Comparison** — status breakdown stacked by register

### Chart Builder

A flexible custom chart tab for building ad-hoc visualisations of the filtered dataset:

- **X axis** — choose from: Year of Submission, Status, Register, Phase, Sponsor Type, PIP Status, MedDRA Organ Class, MedDRA Condition, Country / Member State
- **Group by** — optional second variable for colour-splitting (same choices as X axis)
- **Chart types** — Bar (stacked), Bar (grouped), Bar (100% stacked), Line
- **Max groups slider** — limit the number of colour groups shown (3–20) when a grouping variable is selected
- **Summary table** — aggregated counts with % of total and cumulative % columns
- **Statistics panel** — Total, Mean, Median, SD, Min, Max of counts; per group when a grouping variable is active
- **PDF export** — the custom chart and its statistics table are included in the downloaded PDF report

Multi-value variables (Organ Class, Condition, Country) are split before aggregation; a note is shown when counts may exceed the total number of trials.

### Map

An interactive Leaflet map of ongoing/open trials by country:

- Circle markers sized and colour-coded by trial count (green → yellow → orange → red)
- A sortable trial table appears below the map when zoomed to level 5 or higher, showing only trials within the current map viewport
- Trials sorted by submission date, most recent first

### Data Explorer

A full interactive DataTable of all trials matching the active filters:

- Per-column search filters
- Columns: CT number, register, title, product, MedDRA term, MedDRA organ class, countries, country count, status, PIP, phase, sponsor name, sponsor type, submission date, start date, decision date
- Default sort: submission date descending
- Download as CSV or Excel

### Basic Analytics

Charts focused on therapeutic area, geography, PIP trends, and sponsors:

- **Top MedDRA organ classes** — configurable N, stacked by register
- **Top conditions / MedDRA terms** — configurable N, stacked by register
- **Trials by country** — top 30, horizontal bar chart
- **PIP Status** — pie chart of Yes / No / Unknown
- **Start-Date Timeline (quarterly)** — count of new trials per quarter
- **PIP Status by Year** — stacked bar showing Yes / No / Unknown split over time
- **Time from Submission to Decision** — violin plot of days from submission to regulatory decision, split by register
- **Top Sponsors / Companies** — horizontal bar chart coloured by sponsor type (Academic / Industry), configurable Top N
- **Sponsor Trial Timeline** *(visible only when exactly one sponsor is selected in the sidebar)* — bars showing new trials per year with a cumulative line overlay

### Phase Analytics

Charts focused on trial phase across different dimensions:

- **Trial Phase by Register** — stacked bar showing Phase I / II / III / IV distribution across EUCTR and CTIS
- **Trial Phase by Status** — phase breakdown split by Ongoing, Completed, Other
- **Trial Phase by Sponsor Type** — phase breakdown split by Academic vs Industry

### About

Data sources, processing methodology, MedDRA SOC code reference table, changelog, and version information.

---

## Sidebar Filters

All filters apply globally across every tab.

| Filter | Description |
|---|---|
| **Trial Status** | Ongoing / Completed / Other (multi-select checkboxes) |
| **Register** | EUCTR / CTIS (multi-select checkboxes) |
| **Submission Date** | Date range picker |
| **MedDRA Organ Class** | Searchable multi-select |
| **Condition / MedDRA Term** | Searchable multi-select |
| **Country / Member State** | Searchable multi-select |
| **Trial Phase** | Phase I / II / III / IV (searchable multi-select) |
| **PIP Status** | All / Yes / No / Unknown (single-select dropdown) |
| **Sponsor / Company** | Searchable multi-select; names are normalised and deduplicated |
| **Search** | Free-text search across title, product name, and CT number |

A **Theme** toggle (Nord dark / Default light) is also in the sidebar. All charts, tables, and UI elements switch instantly.

---

## Data Pipeline

```
┌──────────────────────────┐    ┌──────────────────────────┐
│  EUCTR                   │    │  CTIS                    │
│  ~10 000 records         │    │  ~1 000 records          │
│  (per-country duplicates)│    │  (nested JSON metadata)  │
└───────────┬──────────────┘    └────────────┬─────────────┘
            │                                │
            └────────────────┬───────────────┘
                             ▼
            ┌────────────────────────────────┐
            │       ctrdata + SQLite         │
            │                                │
            │  1.  Flatten list-columns      │
            │  2.  Coerce all to character   │
            │  3.  Clean country names       │
            │  4.  Resolve MedDRA codes      │
            │  5.  Unite cross-register cols │
            │  6.  Aggregate per trial       │
            │       (before dedup)           │
            │  7.  dbFindIdsUniqueTrials     │
            │  8.  Harmonise status          │
            │  9.  Detect CTIS PIP           │
            │  10. Map trial phase           │
            │  11. Parse dates               │
            │  12. Normalise sponsor names   │
            │  13. Normalise title key       │
            │  14. Cache to .rds             │
            └──────────────┬─────────────────┘
                           ▼
                ┌─────────────────────┐
                │   Shiny Dashboard   │
                │  Overview           │
                │  Chart Builder · Map│
                │  Explorer · Analytics│
                │  Phase · About      │
                └─────────────────────┘
```

### Key processing steps

**Deduplication** — EUCTR registers one record per member state per trial. Countries, statuses, and MedDRA terms are aggregated *before* `dbFindIdsUniqueTrials()` collapses to one row per unique trial.

**Country name cleaning** — EUCTR country strings include agency suffixes (`"Germany - BfArM"` → `"Germany"`). CTIS country fields contain nested numeric IDs and timestamps. Both are normalised against a canonical list of ~200 country names.

**MedDRA resolution** — EUCTR stores numeric prefixes (`"10028395 - Neoplasms…"`); CTIS stores EMA SOC numeric codes (`"100000004864"`). Both are mapped to human-readable System Organ Class names.

**PIP detection** — EUCTR stores PIP as `"Yes"/"No"/"true"/"false"`. In CTIS the `paediatricInvestigationPlan` field holds a list of record objects; presence of any content maps to "Yes", absence to "No".

**Trial phase** — EUCTR phase is stored as four boolean fields (Phase I–IV). CTIS stores descriptive text (`"Therapeutic exploratory (Phase II)"`). Both are mapped to a common set of labels via regex matching.

**EUCTR → CTIS transition** — EUCTR records with status "Trial now transitioned to CTIS" are matched to their CTIS counterpart by normalised title (first 80 characters). The CTIS record is preferred in the deduplicated dataset.

**Sponsor name normalisation** — raw sponsor names from both registers are cleaned in a multi-pass pipeline: legal suffixes stripped (GmbH & Co. KG, Inc., Ltd., S.A., DAC, A/S, …), department qualifiers removed, subsidiary boilerplate stripped, title-case applied (dotted abbreviations like A.I.E.O.P. are preserved), and ~70 known pharma brand prefixes are mapped to canonical names (e.g. GlaxoSmithKline → GSK).

**Normalisation logs** — on every cache rebuild, a CSV log is written to `data/` for each normalisation step: sponsor names, country names, MedDRA terms, organ classes, trial phase, status category, and status display labels. Each log contains the raw value, normalised output, register, trial count, and a flag indicating whether the value changed.

**Caching** — processed data is saved to `pediatric_trials_cache.rds` in the app root. The cache is automatically invalidated when the SQLite database is newer. Delete this file manually to force a rebuild without re-downloading data.

---

## Configuration

Environment variables control runtime paths. They can be set in the shell, passed to Docker with `-e`, or edited at the top of `app.R` and `update_data.R`.

| Variable | Default | Description |
|---|---|---|
| `DB_PATH` | `./data/pediatric_trials.sqlite` | SQLite database file |
| `DB_COLLECTION` | `trials` | Collection name within the database |
| `CACHE_PATH` | `pediatric_trials_cache.rds` | Processed data cache (app root) |

---

## Project Structure

```
shiny_trials/
├── app.R                          # Shiny UI + server (single-file app)
├── update_data.R                  # Data fetching script (EUCTR + CTIS)
├── rebuild_cache.R                # Rebuilds RDS cache from SQLite without re-downloading
├── report.Rmd                     # R Markdown template for the PDF report
├── pediatric_trials_cache.rds     # Processed data cache (auto-generated)
├── Dockerfile                     # Two-stage container build
├── docker-compose.yml             # Compose orchestration
├── README.md                      # This file
└── data/
    ├── pediatric_trials.sqlite              # SQLite database (auto-generated)
    ├── sponsor_normalisation_log.csv        # Sponsor name mapping log (auto-generated)
    ├── country_normalisation_log.csv        # Country name cleaning log (auto-generated)
    ├── meddra_term_normalisation_log.csv    # MedDRA term cleaning log (auto-generated)
    ├── organ_class_normalisation_log.csv    # Organ class cleaning log (auto-generated)
    ├── phase_normalisation_log.csv          # Phase mapping log (auto-generated)
    ├── status_category_normalisation_log.csv  # Status category log (auto-generated)
    └── status_display_normalisation_log.csv   # Status display label log (auto-generated)
```

---

## Technology Stack

| Layer | Package(s) | Role |
|---|---|---|
| Data retrieval | [`ctrdata`](https://github.com/rfhb/ctrdata) | Unified access to EUCTR and CTIS |
| Database | [`nodbi`](https://github.com/ropensci/nodbi) + [`RSQLite`](https://cran.r-project.org/package=RSQLite) | Local document store over SQLite |
| Web framework | [`shiny`](https://shiny.posit.co/) + [`shinydashboard`](https://rstudio.github.io/shinydashboard/) | Dashboard UI |
| Charts | [`plotly`](https://plotly.com/r/) + [`ggplot2`](https://ggplot2.tidyverse.org/) | Interactive visualisations |
| Map | [`leaflet`](https://rstudio.github.io/leaflet/) | Country-level interactive map |
| Euler diagram | [`eulerr`](https://cran.r-project.org/package=eulerr) | Proportional Venn / Euler diagram |
| Tables | [`DT`](https://rstudio.github.io/DT/) | Interactive data tables |
| Data wrangling | [`dplyr`](https://dplyr.tidyverse.org/), [`tidyr`](https://tidyr.tidyverse.org/), [`stringr`](https://stringr.tidyverse.org/), [`lubridate`](https://lubridate.tidyverse.org/) | Data manipulation |
| Export | [`writexl`](https://cran.r-project.org/package=writexl), [`readr`](https://readr.tidyverse.org/) | CSV and Excel download |

---

## Known Issues

| Issue | Details |
|---|---|
| **EUCTR `rows_update` errors** | `ctrdata` calls `dplyr::rows_update()`, which fails on duplicate or unmatched keys in newer dplyr versions. `update_data.R` monkey-patches this function before each EUCTR load and restores the original afterwards. |
| **CTIS country field** | Contains nested metadata (numeric IDs, timestamps) alongside country names. Cleaned by matching against a canonical ~200-entry country list. |
| **MedDRA classification divergence** | EUCTR and CTIS may classify the same trial under different MedDRA terms. Terms are aggregated as-is without cross-register normalisation. |
| **Overlap detection accuracy** | Title-based matching (first 80 normalised characters) is a conservative estimate. Trials phrased differently across registers will not be linked. |
| **Cache invalidation** | The cache is invalidated by SQLite modification time. If you add new fields to the query in `app.R`, delete `pediatric_trials_cache.rds` to force a rebuild. |

---

## Changelog

### v0.5.0 (2026-04-18)

- **Free-text search:** now also matches against sponsor name (previously searched title, CT number, MedDRA term, and product name only)
- **Phase Analytics — Phase Funnel:** new chart showing the distribution of trials across Phase I–IV as a proportional funnel with % of total labels
- **Phase Analytics — Completion Rate by Authorization Cohort:** line chart showing what % of trials authorized in each year have since completed, split by register (EUCTR / CTIS); more recent cohorts naturally show lower rates
- **Sponsor Comparison:** when exactly 2 or 3 sponsors are selected in the sidebar Sponsor filter, a comparison panel appears in the Sponsors section of Basic Analytics with side-by-side phase distribution, trial status, and top organ class charts
- **Code:** removed unused `eulerr` package import

### v0.4.0 (2026-04-15)

- **Trial detail modal:** clicking any row in the Data Explorer opens a modal dialog with full trial details — title, CT number (linked to source register), register, status, phase, sponsor, MedDRA terms, countries, and key dates
- **URL state:** active filters are encoded in the URL query string (`?f=`) so filtered views can be bookmarked and shared; filters are restored automatically on page load
- **Active filter chips:** a badge bar above the tab content shows all non-default filters as coloured chips; a "Reset all" button clears all filters at once
- **Days-to-decision violin:** new chart in the Sponsors section of Basic Analytics showing distribution of days from submission to authorisation/registration, split by sponsor type (Academic / Industry) with register overlay
- **Analytics section headers:** boxes in Basic Analytics grouped under section headers — Therapeutic Areas, Geography & PIP, Sponsors
- **Empty states:** when no trials match the active filters all main plotly charts show a friendly "no data" message instead of a blank area
- **Plotly toolbar:** mode bar always visible with camera icon for PNG download; non-essential buttons removed
- **Responsive metric cards:** KPI cards shown 2-per-row on tablet-width screens and 1-per-row on very small screens

### v0.3.0 (2026-04-06)

- **Chart Builder tab:** new tab (second position, after Overview) for building custom charts from the filtered dataset — choose X axis, optional grouping variable, and chart type (bar stacked / grouped / 100% stacked, line); multi-value variables (organ class, condition, country) are split before aggregation with an inline warning when counts may exceed trial totals
- **Chart Builder — statistics:** summary table shows counts with % of total and cumulative %; a companion statistics panel shows Total, Mean, Median, SD, Min, Max — one row per group when a grouping variable is active
- **Chart Builder — PDF export:** the custom chart and matching statistics table are included in the downloaded PDF report, rendered with ggplot2 using the Nord colour palette
- **Navigation:** "Analytics" renamed to "Basic Analytics"; "Phase Analysis" renamed to "Phase Analytics"

### v0.2.4 (2026-04-05)

- **Sidebar:** new Sponsor / Company filter with multi-select, supporting both EUCTR and CTIS registers
- **Data:** sponsor names normalised and deduplicated — legal suffixes stripped, brand-name canonicalisation for ~70 major pharma companies, title-case applied where appropriate
- **Analytics:** new Top Sponsors chart (horizontal bar, coloured by sponsor type, configurable Top N slider)
- **Data Explorer:** Sponsor Name and Sponsor Type columns added
- **Report:** Top Sponsors section added (bar chart + table)
- **Fix:** CTIS sponsor name field corrected to `authorizedApplication.authorizedPartI.sponsors.organisation.name`

### v0.2.3 (2026-03-30)

- **Data Explorer:** added Decision Date column (Competent Authority decision date for EUCTR; authorisation date for CTIS)
- **Analytics:** added violin plot showing the distribution of days from submission to decision, split by register

### v0.2.2 (2026-03-30)

- **Data pipeline:** EUCTR download is now skipped when the query URL has not changed since the last successful load; the normalised query term is stored in a `_meta` table in the SQLite database and compared on each run — nightly updates now only fetch CTIS (~5 min) unless the search criteria are modified

### v0.2.1 (2026-03-29)

- **Data:** normalise MedDRA condition name spelling variants between EUCTR (American) and CTIS (British MedDRA preferred) — leukemia/leukaemia, tumor/tumour, diarrhea/diarrhoea, esophag/oesophag, tyrosinemia/tyrosinaemia, localized/localised
- **Data:** convert Roman numeral type notation (Type I/II/III/IV) to Arabic numerals (Type 1/2/3/4) so cross-register duplicates collapse into single entries

### v0.2.0 (2026-03-29)

- **Filter save/restore:** download active filter settings as a JSON file and re-upload them in any future session to instantly restore the same selection
- **PDF report:** new "Download PDF Report" button generates a full summary PDF for the current filter selection, including all dashboard charts and descriptive statistics (n, %, mean ± SD, median, IQR) for each section; uses R Markdown + pdflatex with Helvetica/Arial font

### v0.1.5 (2026-03-29)

- **Navigation:** split the Analytics tab into two separate tabs — Analytics and Phase Analysis
- **Phase Analysis tab:** trial phase breakdown by register, by status, and by sponsor type (Academic vs Industry)

### v0.1.4 (2026-03-28)

- **Sidebar:** added Trial Phase filter (Phase I / II / III / IV)
- **Data Explorer:** added Phase column
- **Analytics:** added Trial Phase by Register, by Status, and by Sponsor Type charts
- **Fix:** CTIS phase resolved from top-level `trialPhase` field using regex mapping (descriptive text format)

### v0.1.3 (2026-03-28)

- **Map tab:** new interactive Leaflet map showing open/ongoing trials by country; circle markers sized and colour-coded by trial count; trial table appears below the map when zoomed in (zoom ≥ 5)
- **Fix:** EUCTR trial links now use the correct URL format (`/{country_code}` instead of `/results`)
- **Data Explorer & Map:** tables now sorted by submission date descending

### v0.1.1 (2026-03-28)

- **Overview:** replaced Status Distribution chart with Sponsor Type by Register (Academic vs Industry per register and combined)
- **Overview:** CT numbers in "5 Most Recently Submitted Trials" are now clickable links to the respective registry
- **Analytics:** added PIP Status by Year stacked bar chart
- **Data:** MedDRA organ class numeric codes (EUCTR prefix format and CTIS EMA SOC codes) resolved to human-readable names

### v0.1.0

Initial release.

---

## Acknowledgements

- [`ctrdata`](https://github.com/rfhb/ctrdata) by Ralf Herold — unified R access to EU and US clinical trial registers
- [EU Clinical Trials Register](https://www.clinicaltrialsregister.eu)
- [Clinical Trials Information System](https://euclinicaltrials.eu)
- [Nord colour palette](https://www.nordtheme.com/)
