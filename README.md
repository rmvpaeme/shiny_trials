# EU Paediatric Clinical Trials Dashboard `v0.1.3`

An interactive R Shiny dashboard providing a unified view of paediatric
clinical trials registered in the European Union, integrating two primary
sources:

| Register | Source | Filter |
|----------|--------|--------|
| **EUCTR** — EU Clinical Trials Register | [clinicaltrialsregister.eu](https://www.clinicaltrialsregister.eu) | Age group: under 18 |
| **CTIS** — Clinical Trials Information System | [euclinicaltrials.eu](https://euclinicaltrials.eu) | Age group code 2 (paediatric) |

---

## Features

### Data Integration

- **Multi-register harmonisation** — unifies fields (trial ID, title,
  conditions, countries, status, dates) across EUCTR and CTIS into a
  single searchable dataset
- **Smart deduplication** — EUCTR stores one record per member state per
  trial; all countries, statuses, and MedDRA terms are aggregated
  *before* collapsing to one row per unique trial
- **Country name cleaning** — strips EUCTR agency suffixes
  (`"Germany - BfArM"` → `"Germany"`), removes CTIS numeric/timestamp
  junk, normalises against a canonical list of ~200 country names
- **CTIS PIP detection** — the `paediatricInvestigationPlan` field in CTIS
  contains PIP record objects rather than a yes/no string; presence of any
  content is correctly mapped to "Yes", absence to "No"
- **MedDRA code resolution** — EUCTR numeric prefixes and CTIS EMA SOC codes
  are resolved to human-readable organ class names
- **RDS caching** — processed data saved to `.rds` on first build;
  subsequent app starts load in ~1 second

### Registry Overlap Detection

- Trials matched across EUCTR and CTIS by **normalised title text**
  (lowercase, remove punctuation, first 80 characters)
- Proportional **Euler/Venn diagram** (via `eulerr` package)
- Summary panel showing unique-to-register and shared trial counts

### Interactive Filters (sidebar)

- Trial status (Ongoing / Completed / Other)
- Source register (EUCTR / CTIS)
- Submission date range
- MedDRA organ class (searchable)
- Condition / MedDRA term (searchable)
- Country / member state (searchable)
- Paediatric Investigation Plan (PIP) status
- Free-text search (title, product, CT number)

### Dashboard Tabs

#### Overview

- 4 summary value boxes: Total Trials, Ongoing, Completed, With PIP
- **5 most recently submitted trials** table (by submission date, respects active filters; CT numbers are clickable links to the respective register)
- Cumulative start-date ECDF plot by status (width 7/12)
- **Sponsor type by register** grouped bar chart (width 5/12) — Academic vs Industry breakdown per register and combined
- Registry overlap Venn diagram
- Overlap summary with counts and percentages
- Submissions per year stacked bar
- Register comparison bar chart — "Other" status is expanded into its
  constituent raw values when there are fewer than 6 distinct categories

#### Map

- Interactive **Leaflet map** showing open/ongoing trials by country
- Circle markers sized and coloured by trial count (green → yellow → orange → red)
- When zoomed in to level 5 or higher, a sortable trial table appears below the map showing trials within the current map view
- Trials sorted by submission date descending (most recent first)

#### Data Explorer

- Full interactive DataTable with per-column filters
- Sorted by submission date descending by default
- CSV and Excel download

#### Analytics

- Top MedDRA organ classes (configurable N)
- Top conditions / MedDRA terms (configurable N)
- Trials by country (top 30)
- PIP status by year (stacked bar chart)
- Quarterly start-date timeline

#### About

- Data sources, methodology, changelog, version info

### Visual Themes

- **Nord** — dark theme using the [Nord colour palette](https://www.nordtheme.com/)
- **Default** — standard shinydashboard light blue theme
- Toggle via radio button in the sidebar; all charts, tables, and UI elements adapt instantly

---

## Quick Start

### Prerequisites

- **R** >= 4.1
- **System dependencies** (for `ctrdata`): `node.js` (recommended) or `V8`; `libcurl`, `libssl`, `libxml2`

### 1. Install R packages

```r
install.packages(c(
  "shiny", "shinydashboard", "shinycssloaders",
  "ctrdata", "nodbi", "RSQLite",
  "dplyr", "tidyr", "ggplot2", "stringr", "lubridate",
  "DT", "plotly", "leaflet", "readr", "writexl", "eulerr"
))
```

### 2. Populate the database

```bash
Rscript update_data.R
```

> First run takes 30–60 minutes (EUCTR ~30 min, CTIS ~5 min).
> Subsequent runs are incremental and faster.

### 3. Launch the dashboard

```bash
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

Or from RStudio: open `app.R` → click **Run App**.

---

## Docker

### Build & run

```bash
mkdir -p data
docker run -p 3838:3838 \
  -v $(pwd)/data:/app/data \
  rmvpaeme/shiny_trials:0.1.3
```

Open [http://localhost:3838](http://localhost:3838).

The `-v` flag mounts a local `data/` directory so the SQLite database
and RDS cache persist across container restarts.

### Pre-populate before launching

```bash
mkdir -p data

# Fetch data (30-60 min first time)
docker run --rm -v $(pwd)/data:/app/data rmvpaeme/shiny_trials:0.1.3 \
  Rscript /app/update_data.R

# Launch dashboard
docker run -d -p 3838:3838 \
  -v $(pwd)/data:/app/data \
  --name shiny_trials \
  rmvpaeme/shiny_trials:0.1.3
```

### Docker Compose

```bash
docker compose up -d
docker compose exec app Rscript /app/update_data.R   # first time
# open http://localhost:3838
```

---

## Project Structure

```text
pediatric-trials-dashboard/
├── app.R                    # Shiny dashboard (UI + server)
├── update_data.R            # Data fetching script (EUCTR + CTIS)
├── Dockerfile               # Container definition
├── docker-compose.yml       # Compose orchestration
├── README.md                # This file
└── data/                    # Runtime data (created automatically)
    ├── pediatric_trials.sqlite    # SQLite database
    └── pediatric_trials_cache.rds # Processed data cache
```

---

## Data Pipeline

```text
┌──────────────────────────┐    ┌──────────────────────────┐
│  EUCTR                    │    │  CTIS                     │
│  clinicaltrialsregister.eu│    │  euclinicaltrials.eu      │
│  age < 18                 │    │  ageGroupCode = 2         │
│  ~10k records             │    │  ~1k records              │
│  (per-country duplicates) │    │  (nested JSON metadata)   │
└───────────┬──────────────┘    └───────────┬──────────────┘
            │                                │
            ▼                                ▼
┌─────────────────────────────────────────────────────────────┐
│                    ctrdata + SQLite                          │
│                                                             │
│  1. Flatten list-columns to " / "-separated strings         │
│  2. Coerce all columns to character (type-safety)           │
│  3. Clean country names                                     │
│  4. Resolve MedDRA numeric codes to human-readable names    │
│  5. Unite corresponding fields across registers             │
│  6. Aggregate countries / statuses / MedDRA per trial       │
│     BEFORE deduplication                                    │
│  7. dbFindIdsUniqueTrials → one row per trial               │
│  8. Harmonise status → Ongoing / Completed / Other          │
│  9. Detect CTIS PIP from field presence (not yes/no string) │
│ 10. Parse dates safely (multiple formats)                   │
│ 11. Compute normalised title key for overlap detection      │
│ 12. Cache processed data to .rds                            │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │   Shiny Dashboard    │
              │   • Filters          │
              │   • Overview plots   │
              │   • Map (Leaflet)    │
              │   • Plots (plotly)   │
              │   • Venn (eulerr)    │
              │   • DataTable (DT)   │
              │   • CSV/Excel export │
              │   • Nord/Default     │
              └─────────────────────┘
```

---

## Changelog

### v0.1.3 (2026-03-28) — v0.1.2 skipped

- **Map tab**: new interactive Leaflet map showing open/ongoing trials by country; circle markers sized and coloured by trial count; trial table appears below when zoomed in (zoom ≥ 5)
- **Fix**: EUCTR trial links now use the correct URL format (`/{country_code}` instead of `/results`)
- **Data Explorer & Map**: tables now sorted by submission date descending (most recent first)

### v0.1.1 (2026-03-28)

- **Overview**: replaced Status Distribution chart with Sponsor Type by Register (Academic vs Industry breakdown per register and combined)
- **Overview**: CT numbers in "5 Most Recently Submitted Trials" are now clickable links to the respective registry
- **Analytics**: added PIP Status by Year stacked bar chart
- **Data**: MedDRA organ class numeric codes resolved to human-readable names

### v0.1

Initial release.

---

## Known Issues / Caveats

| Issue | Details |
| ----- | ------- |
| **EUCTR `rows_update` errors** | `ctrdata` uses `dplyr::rows_update()` which fails on duplicate/unmatched keys in newer dplyr versions. `update_data.R` and the in-app update button both temporarily monkey-patch this function. |
| **CTIS country field** | Contains nested metadata (numeric IDs, timestamps) alongside country names. Cleaned by matching against a canonical country list of ~200 entries. |
| **MedDRA classification** | EUCTR and CTIS both use MedDRA but may classify the same trial differently. Terms are aggregated as-is. |
| **PIP data** | For EUCTR, PIP is stored as `"Yes"/"No"/"true"/"false"`. For CTIS, the `paediatricInvestigationPlan` field holds a list of PIP record objects — presence = Yes, absent = No. |
| **Overlap detection** | Based on normalised title matching (first 80 chars). Conservative estimate — actual overlap may be higher for trials with different title formulations across registries. |
| **Cache invalidation** | Cache auto-invalidates when SQLite DB is newer. Delete `pediatric_trials_cache.rds` manually to force rebuild without re-downloading. |

---

## Configuration

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `DB_PATH` | `./data/pediatric_trials.sqlite` | Path to SQLite database file |
| `DB_COLLECTION` | `trials` | Collection name within the database |
| `CACHE_PATH` | `pediatric_trials_cache.rds` | Path to processed data cache |

These can be overridden via environment variables (used automatically by Docker) or edited at the top of `app.R` and `update_data.R`.

---

## Technology Stack

| Component | Package | Purpose |
|-----------|---------|---------|
| Data retrieval | [`ctrdata`](https://github.com/rfhb/ctrdata) | Unified access to EU clinical trial registers |
| Database | [`nodbi`](https://github.com/ropensci/nodbi) + [`RSQLite`](https://cran.r-project.org/package=RSQLite) | Local document store |
| Dashboard | [`shiny`](https://shiny.posit.co/) + [`shinydashboard`](https://rstudio.github.io/shinydashboard/) | Web framework |
| Charts | [`plotly`](https://plotly.com/r/) + [`ggplot2`](https://ggplot2.tidyverse.org/) | Interactive visualisation |
| Map | [`leaflet`](https://rstudio.github.io/leaflet/) | Interactive country-level map |
| Venn diagram | [`eulerr`](https://cran.r-project.org/package=eulerr) | Proportional area-accurate Euler diagrams |
| Tables | [`DT`](https://rstudio.github.io/DT/) | Interactive data tables |
| Data wrangling | [`dplyr`](https://dplyr.tidyverse.org/), [`tidyr`](https://tidyr.tidyverse.org/), [`stringr`](https://stringr.tidyverse.org/), [`lubridate`](https://lubridate.tidyverse.org/) | Data manipulation |
| Export | [`readr`](https://readr.tidyverse.org/), [`writexl`](https://cran.r-project.org/package=writexl) | CSV / Excel download |

---

## License

MIT

---

## Author

Ruben Van Paemel & Claude Sonnet 4.6

---

## Acknowledgements

- [`ctrdata`](https://github.com/rfhb/ctrdata) by Ralf Herold — unified access to EU and US clinical trial registers from R
- [EU Clinical Trials Register](https://www.clinicaltrialsregister.eu)
- [Clinical Trials Information System](https://euclinicaltrials.eu)
- [Nord Theme](https://www.nordtheme.com/) colour palette
