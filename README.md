# EU Paediatric Trial Monitor

![Overview](overview.png)

**Version:** `v0.6.0` | **License:** MIT | **Author:** Ruben Van Paemel & Claude Sonnet 4.6

An interactive R Shiny dashboard providing a unified, searchable view of paediatric clinical trials registered in the European Union. Data is retrieved nightly from two complementary registers and harmonised into a single, consistently coded dataset.

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
  "DT", "plotly", "leaflet", "readr", "writexl",
  "base64enc", "jsonlite", "rmarkdown"
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

The dashboard has eight tabs, all of which respect the active sidebar filters in real time.

### Overview

The landing tab. Provides a high-level summary of the filtered dataset:

- **Value boxes** — Total Trials, Ongoing, Completed, With PIP
- **5 most recently submitted trials** — sortable table; CT numbers are clickable links to the originating registry
- **Sponsor Type by Register** — grouped bar chart comparing Academic vs Industry across EUCTR, CTIS, and combined
- **Submissions per Year** — stacked bar chart by register
- **Register Comparison** — status breakdown stacked by register

### Chart Builder

A flexible custom chart tab for building ad-hoc visualisations of the filtered dataset:

- **X axis** — Year of Submission, Status, Register, Phase, Sponsor Type, PIP Status, MedDRA Organ Class, MedDRA Condition, Country / Member State
- **Group by** — optional second variable for colour-splitting (same choices, plus None)
- **Chart types** — Bar (stacked), Bar (grouped), Bar (100% stacked), Line
- **Max groups slider** — limit the number of colour groups shown (3–20) when a grouping variable is active
- **Summary table** — aggregated counts with % of total and cumulative % columns
- **Statistics panel** — Total, Mean, Median, SD, Min, Max per stratum
- **PDF export** — the custom chart and statistics table are included in the downloaded PDF report

Multi-value variables (Organ Class, Condition, Country) are split before aggregation; a note is shown when counts may exceed the total trial count.

### Map

An interactive Leaflet map of ongoing trials by country:

- Circle markers sized and colour-coded by trial count (green → yellow → orange → red)
- A sortable trial table appears below the map when zoomed to level 5 or higher

### Data Explorer

A full interactive DataTable of all trials matching the active filters:

- Columns: CT number (linked to registry), register, title, product, MedDRA term, MedDRA organ class, countries, country count, status, PIP, phase, sponsor name, sponsor type, submission date, start date, decision date
- Clicking a row opens a **modal dialog** with the full trial record and a direct link to the originating registry
- Download as CSV or Excel

### Basic Analytics

Pre-specified charts grouped into three sections:

**Therapeutic Areas**
- Top MedDRA organ classes (configurable N)
- Top conditions / MedDRA terms (configurable N)

**Geography & PIP**
- Trials by country (top 30)
- PIP Status distribution (Yes / No / Unknown)
- Start-date timeline (quarterly)
- PIP Status by year

**Sponsors**
- Time from submission to decision — violin plot by register
- Days to decision by sponsor type — violin split by Academic / Industry with register overlay
- Top sponsors by trial count (configurable N, coloured by sponsor type)
- Sponsor Trial Timeline *(visible only when exactly one sponsor is selected)* — bars for new trials per year with a cumulative line overlay

### Phase Analytics

Charts focused on trial phase:

- **Trial Phase by Register** — stacked bar, Phase I–IV across EUCTR and CTIS
- **Trial Phase by Status** — phase split by Ongoing / Completed / Other
- **Trial Phase by Sponsor Type** — phase split by Academic vs Industry
- **Phase Funnel** — proportional funnel showing the distribution across Phase I–IV with % of total labels
- **Completion Rate by Authorization Cohort** — line chart showing what % of trials authorized in each year have since completed, split by register; more recent cohorts naturally show lower rates

### Sponsor Comparison

A dedicated tab for side-by-side comparison of 2–3 sponsors:

- **0 sponsors selected** — instructions on how to use the tab
- **1 sponsor selected** — names the sponsor and prompts to add one more
- **4+ sponsors selected** — prompts to narrow the selection
- **2–3 sponsors selected** — six comparison charts:
  - Phase distribution (grouped bar)
  - Trial status (grouped bar)
  - Top organ classes (horizontal grouped bar, top 8 across selected sponsors)
  - Trials by country (horizontal grouped bar, top 10)
  - PIP status (stacked bar per sponsor; Yes = green, No = red, Unknown = amber)
  - Submissions per year (line chart)

### About

Data sources, processing methodology, registry-to-dashboard status mapping, MedDRA SOC code reference table, version changelog, and technical acknowledgements.

---

## Sidebar Filters

All filters apply globally across every tab in real time.

| Filter | Type | Description |
|---|---|---|
| **Trial Status** | Multi-select checkboxes | Ongoing / Completed / Other |
| **Register** | Multi-select checkboxes | EUCTR / CTIS |
| **Submission Date** | Date range picker | Inclusive date range |
| **MedDRA Organ Class** | Searchable multi-select | System Organ Class (SOC) level |
| **Condition / MedDRA Term** | Searchable multi-select | Preferred term level |
| **Country / Member State** | Searchable multi-select | EU member states |
| **Trial Phase** | Searchable multi-select | Phase I / II / III / IV |
| **PIP Status** | Single-select dropdown | All / Yes / No / Unknown |
| **Sponsor / Company** | Searchable multi-select | Normalised and deduplicated names |
| **Free-text search** | Text input | Searches title, CT number, product name, MedDRA term, and sponsor name |

Active filters are displayed as colour-coded chips above the tab content. A **Reset all** button clears every filter at once. Filter state is encoded in the URL query string (`?f=`) so views can be bookmarked and shared.

A **Theme** toggle (Nord dark / Default light) is in the sidebar. All charts, tables, and UI elements switch instantly.

---

## Data Pipeline

```
┌──────────────────────────┐    ┌──────────────────────────┐
│  EUCTR                   │    │  CTIS                    │
│  ~10 000 records         │    │  ~1 500 records          │
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
                ┌──────────────────────────┐
                │   Shiny Dashboard        │
                │  Overview · Chart Builder│
                │  Map · Data Explorer     │
                │  Basic Analytics         │
                │  Phase Analytics         │
                │  Sponsor Comparison      │
                │  About                   │
                └──────────────────────────┘
```

### Key processing steps

**Deduplication** — EUCTR registers one record per member state per trial. Countries, statuses, and MedDRA terms are aggregated *before* `dbFindIdsUniqueTrials()` collapses to one row per unique trial.

**Country name cleaning** — EUCTR country strings include agency suffixes (`"Germany - BfArM"` → `"Germany"`). CTIS country fields contain nested numeric IDs and timestamps. Both are normalised against a canonical list of ~200 country names.

**MedDRA resolution** — EUCTR stores numeric prefixes (`"10028395 - Neoplasms…"`); CTIS stores EMA SOC numeric codes (`"100000004864"`). Both are mapped to human-readable System Organ Class names.

**PIP detection** — EUCTR stores PIP as `"Yes"/"No"/"true"/"false"`. In CTIS the `paediatricInvestigationPlan` field holds a list of record objects; presence of any content maps to "Yes", absence to "No".

**Trial phase** — EUCTR phase is stored as four boolean fields (Phase I–IV). CTIS stores descriptive text (`"Therapeutic exploratory (Phase II)"`). Both are mapped to a common label set via regex matching.

**EUCTR → CTIS transition** — EUCTR records with status "Trial now transitioned to CTIS" are matched to their CTIS counterpart by normalised title (first 80 characters). The CTIS record is retained as the authoritative source.

**Sponsor name normalisation** — raw sponsor names undergo a multi-pass pipeline: legal suffixes stripped (GmbH & Co. KG, Inc., Ltd., S.A., DAC, A/S, …), department qualifiers removed, subsidiary boilerplate stripped, title-case applied (dotted abbreviations like A.I.E.O.P. preserved), and ~70 known pharma brand prefixes mapped to canonical names (e.g. GlaxoSmithKline → GSK).

**Normalisation logs** — on every cache rebuild, a CSV log is written to `data/` for each normalisation step: sponsor names, country names, MedDRA terms, organ classes, trial phase, status category, and status display labels. Each log contains the raw value, normalised output, register, trial count, and a changed flag.

**Caching** — processed data is saved to `pediatric_trials_cache.rds`. The cache is automatically invalidated when the SQLite database is newer. Delete the file manually to force a rebuild without re-downloading data.

---

## Configuration

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
    ├── sponsor_normalisation_log.csv        # Sponsor name mapping log
    ├── country_normalisation_log.csv        # Country name cleaning log
    ├── meddra_term_normalisation_log.csv    # MedDRA term cleaning log
    ├── organ_class_normalisation_log.csv    # Organ class cleaning log
    ├── phase_normalisation_log.csv          # Phase mapping log
    ├── status_category_normalisation_log.csv
    └── status_display_normalisation_log.csv
```

---

## Technology Stack

| Layer | Package(s) | Role |
|---|---|---|
| Data retrieval | [`ctrdata`](https://github.com/rfhb/ctrdata) | Unified access to EUCTR and CTIS |
| Database | [`nodbi`](https://github.com/ropensci/nodbi) + [`RSQLite`](https://cran.r-project.org/package=RSQLite) | Local document store over SQLite |
| Web framework | [`shiny`](https://shiny.posit.co/) + [`shinydashboard`](https://rstudio.github.io/shinydashboard/) | Dashboard UI |
| Charts | [`plotly`](https://plotly.com/r/) + [`ggplot2`](https://ggplot2.tidyverse.org/) | Interactive + PDF visualisations |
| Map | [`leaflet`](https://rstudio.github.io/leaflet/) | Country-level interactive map |
| Tables | [`DT`](https://rstudio.github.io/DT/) | Interactive data tables |
| Data wrangling | [`dplyr`](https://dplyr.tidyverse.org/), [`tidyr`](https://tidyr.tidyverse.org/), [`stringr`](https://stringr.tidyverse.org/), [`lubridate`](https://lubridate.tidyverse.org/) | Data manipulation |
| Export | [`writexl`](https://cran.r-project.org/package=writexl), [`readr`](https://readr.tidyverse.org/) | CSV and Excel download |
| URL state | [`base64enc`](https://cran.r-project.org/package=base64enc), [`jsonlite`](https://cran.r-project.org/package=jsonlite) | Filter serialisation to URL |
| Report | [`rmarkdown`](https://rmarkdown.rstudio.com/) | PDF report generation |

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

### v0.6.0 (2026-04-18)

- **Sidebar:** filters and tools split into two tabs (Filters / Tools) to eliminate scrolling
- **Filters tab:** reordered inputs — date range and free-text search at top, then sponsor, country, then remaining filters; Trial Status and Source Register converted from checkboxes to selectize dropdowns
- **Active filter chips:** two-tone pill design (darker label badge + lighter value) for easier scanning; colours adapt to Nord dark theme
- **Tools tab:** Save / Load / PDF / Theme redesigned as compact full-width buttons; Load uses a hidden file input triggered by a plain button to guarantee identical sizing with Save
- **Sponsor Comparison:** title and Count / Percentage toggle now co-linear on the same row

### v0.5.1 (2026-04-18)

- **Sponsor Comparison tab:** promoted to a dedicated sidebar tab between Phase Analytics and About; shows contextual help (with instructions) when 0 or 1 sponsors are selected, an error state when 4+ are selected, and a full comparison panel for 2–3 sponsors comprising phase distribution, trial status, top organ classes, trials by country, PIP status, and submissions per year
- **Sponsor Comparison — PIP Status:** Unknown category now displayed in amber (previously foreground grey, which was invisible on dark backgrounds)
- **Overview:** removed Cumulative Trials by Start Date chart; Sponsor Type by Register now spans the full row width

### v0.5.0 (2026-04-18)

- **Free-text search:** now also matches against sponsor name (previously title, CT number, MedDRA term, and product name only)
- **Phase Analytics — Phase Funnel:** new chart showing the distribution of trials across Phase I–IV as a proportional funnel with % of total labels
- **Phase Analytics — Completion Rate by Authorization Cohort:** line chart showing what % of trials authorized in each year have since completed, split by register; more recent cohorts naturally show lower rates
- **Code:** removed unused `eulerr` package import

### v0.4.0 (2026-04-15)

- **Trial detail modal:** clicking any row in the Data Explorer opens a modal dialog with full trial details — title, CT number (linked to source register), register, status, phase, sponsor, MedDRA terms, countries, and key dates
- **URL state:** active filters are encoded in the URL query string (`?f=`) so filtered views can be bookmarked and shared; filters are restored automatically on page load
- **Active filter chips:** a badge bar above the tab content shows all non-default filters as coloured chips; a "Reset all" button clears all filters at once
- **Days-to-decision by sponsor type:** new violin plot in Basic Analytics splitting days from submission to decision by Academic vs Industry, with register overlay
- **Analytics section headers:** boxes in Basic Analytics grouped under Therapeutic Areas, Geography & PIP, and Sponsors
- **Empty states:** when no trials match the active filters, all main charts show a friendly "no data" message
- **Plotly toolbar:** mode bar always visible with camera icon for PNG download; non-essential buttons removed
- **Responsive metric cards:** KPI cards shown 2-per-row on tablet-width screens, 1-per-row on mobile

### v0.3.0 (2026-04-06)

- **Chart Builder tab:** new tab for building custom bar and line charts — choose X axis, optional grouping variable, and chart type; multi-value variables split before aggregation
- **Chart Builder — statistics:** summary table with counts, % of total, and cumulative %; statistics panel with Total, Mean, Median, SD, Min, Max
- **Chart Builder — PDF export:** custom chart and statistics table included in the PDF report
- **Navigation:** "Analytics" renamed to "Basic Analytics"; "Phase Analysis" renamed to "Phase Analytics"

### v0.2.4 (2026-04-05)

- **Sponsor filter:** new Sponsor / Company sidebar filter with multi-select
- **Sponsor normalisation:** legal suffixes stripped, ~70 pharma brand canonicalisation, title-case applied
- **Analytics:** Top Sponsors chart (horizontal bar, coloured by sponsor type, configurable N)
- **Data Explorer:** Sponsor Name and Sponsor Type columns added

### v0.2.3 (2026-03-30)

- **Data Explorer:** Decision Date column added
- **Analytics:** violin plot of days from submission to decision, split by register

### v0.2.2 (2026-03-30)

- **Data pipeline:** EUCTR download skipped when query URL has not changed since last run; nightly updates now only re-fetch CTIS (~5 min) unless search criteria change

### v0.2.1 (2026-03-29)

- **Data:** MedDRA spelling normalisation (leukemia → leukaemia, tumor → tumour, etc.) and Roman numeral type notation converted to Arabic (Type I → Type 1)

### v0.2.0 (2026-03-29)

- **Filter save/restore:** download active filter settings as JSON; re-upload to restore them in any session
- **PDF report:** full summary PDF for any filter selection via sidebar

### v0.1.5 (2026-03-29)

- **Navigation:** Analytics split into Analytics and Phase Analysis tabs

### v0.1.4 (2026-03-28)

- **Sidebar:** Trial Phase filter added
- **Analytics:** Phase charts by register, status, and sponsor type

### v0.1.3 (2026-03-28)

- **Map tab:** interactive Leaflet map of ongoing trials by country; trial table at zoom ≥ 5

### v0.1.1 (2026-03-28)

- **Overview:** Sponsor Type by Register chart; CT numbers as clickable links
- **Analytics:** PIP Status by Year chart; MedDRA SOC code resolution

### v0.1.0

Initial release.

---

## Acknowledgements

- [`ctrdata`](https://github.com/rfhb/ctrdata) by Ralf Herold — unified R access to EU and US clinical trial registers
- [EU Clinical Trials Register](https://www.clinicaltrialsregister.eu)
- [Clinical Trials Information System](https://euclinicaltrials.eu)
- [Nord colour palette](https://www.nordtheme.com/)
