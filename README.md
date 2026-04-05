# EU Paediatric Trial Monitor

**Version:** `v0.2.4` | **License:** MIT | **Author:** Ruben Van Paemel & Claude Sonnet 4.6

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

The dashboard has six tabs, each respecting the active sidebar filters.

### Overview

The landing tab. Provides a high-level summary of the filtered dataset:

- **Value boxes** — Total Trials, Ongoing, Completed, With PIP
- **5 most recently submitted trials** — sortable table; CT numbers are clickable links to the originating registry
- **Cumulative ECDF** — trial start dates by status (Ongoing / Completed / Other)
- **Sponsor type by register** — grouped bar chart comparing Academic vs Industry across EUCTR, CTIS, and combined
- **Submissions per year** — stacked bar chart by register
- **Status by register** — comparative bar chart; when "Other" contains fewer than six distinct raw values, they are expanded individually

### Map

An interactive Leaflet map of ongoing/open trials by country:

- Circle markers sized and colour-coded by trial count (green → yellow → orange → red)
- A sortable trial table appears below the map when zoomed to level 5 or higher, showing only trials within the current map viewport
- Trials sorted by submission date, most recent first

### Data Explorer

A full interactive DataTable of all trials matching the active filters:

- Per-column search filters
- Columns: CT number, register, title, product, MedDRA term, MedDRA organ class, countries, country count, status, PIP, phase, sponsor type, submission date, start date
- Default sort: submission date descending
- Download as CSV or Excel

### Analytics

Charts focused on therapeutic area, geography, and PIP trends:

- **Top MedDRA organ classes** — configurable N, stacked by register
- **Top conditions / MedDRA terms** — configurable N, stacked by register
- **Trials by country** — top 30, horizontal bar chart
- **Submissions per year** — stacked by register
- **PIP status by year** — stacked bar showing Yes / No / Unknown split over time
- **Quarterly start-date timeline** — count of new trials per quarter

### Phase Analysis

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
| **PIP Status** | Yes / No (searchable multi-select) |
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
            │  12. Normalise title key       │
            │  13. Cache to .rds             │
            └──────────────┬─────────────────┘
                           ▼
                ┌─────────────────────┐
                │   Shiny Dashboard   │
                │  Overview · Map     │
                │  Explorer · Analytics│
                │  Phase Analysis     │
                │  About              │
                └─────────────────────┘
```

### Key processing steps

**Deduplication** — EUCTR registers one record per member state per trial. Countries, statuses, and MedDRA terms are aggregated *before* `dbFindIdsUniqueTrials()` collapses to one row per unique trial.

**Country name cleaning** — EUCTR country strings include agency suffixes (`"Germany - BfArM"` → `"Germany"`). CTIS country fields contain nested numeric IDs and timestamps. Both are normalised against a canonical list of ~200 country names.

**MedDRA resolution** — EUCTR stores numeric prefixes (`"10028395 - Neoplasms…"`); CTIS stores EMA SOC numeric codes (`"100000004864"`). Both are mapped to human-readable System Organ Class names.

**PIP detection** — EUCTR stores PIP as `"Yes"/"No"/"true"/"false"`. In CTIS the `paediatricInvestigationPlan` field holds a list of record objects; presence of any content maps to "Yes", absence to "No".

**Trial phase** — EUCTR phase is stored as four boolean fields (Phase I–IV). CTIS stores descriptive text (`"Therapeutic exploratory (Phase II)"`). Both are mapped to a common set of labels via regex matching.

**EUCTR → CTIS transition** — EUCTR records with status "Trial now transitioned to CTIS" are matched to their CTIS counterpart by normalised title (first 80 characters). The CTIS record is preferred in the deduplicated dataset.

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
├── pediatric_trials_cache.rds     # Processed data cache (auto-generated)
├── Dockerfile                     # Two-stage container build
├── docker-compose.yml             # Compose orchestration
├── README.md                      # This file
└── data/
    └── pediatric_trials.sqlite    # SQLite database (auto-generated)
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
| **EUCTR `rows_update` errors** | `ctrdata` calls `dplyr::rows_update()`, which fails on duplicate or unmatched keys in newer dplyr versions. `update_data.R` and the in-app update button monkey-patch this function before each EUCTR load and restore the original afterwards. |
| **CTIS country field** | Contains nested metadata (numeric IDs, timestamps) alongside country names. Cleaned by matching against a canonical ~200-entry country list. |
| **MedDRA classification divergence** | EUCTR and CTIS may classify the same trial under different MedDRA terms. Terms are aggregated as-is without cross-register normalisation. |
| **Overlap detection accuracy** | Title-based matching (first 80 normalised characters) is a conservative estimate. Trials phrased differently across registers will not be linked. |
| **Cache invalidation** | The cache is invalidated by SQLite modification time. If you add new fields to the query in `app.R`, delete `pediatric_trials_cache.rds` to force a rebuild. |

---

## Changelog

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
