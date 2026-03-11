
# 🧒 EU Paediatric Clinical Trials Dashboard

An interactive R Shiny dashboard providing a unified view of paediatric
clinical trials registered in the European Union, integrating two primary
sources:

| Register | Source | Filter |
|----------|--------|--------|
| **EUCTR** — EU Clinical Trials Register | [clinicaltrialsregister.eu](https://www.clinicaltrialsregister.eu) | Subjects under 18 |
| **CTIS** — Clinical Trials Information System | [euclinicaltrials.eu](https://euclinicaltrials.eu) | Paediatric keywords |

---

## ✨ Features

### Data Integration
- **Multi-register harmonisation** — unifies fields (trial ID, title,
  conditions, countries, status, dates) across EUCTR and CTIS into a
  single searchable dataset
- **Smart deduplication** — EUCTR stores one record per member state per
  trial; all countries, statuses, and MedDRA terms are aggregated
  *before* collapsing to one row per unique trial (no Belgium bias)
- **Country name cleaning** — strips EUCTR agency suffixes
  (`"Germany - BfArM"` → `"Germany"`), removes CTIS numeric/timestamp
  junk, normalises against a canonical list of ~200 country names
- **RDS caching** — processed data saved to `.rds` on first build;
  subsequent app starts load in ~1 second instead of minutes

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
- **Overview** — value boxes, cumulative start-date ECDF, status pie chart,
  registry overlap Venn diagram, submissions per year, register comparison
- **Data Explorer** — full interactive DataTable with per-column filters,
  CSV and Excel download
- **Analytics** — top MedDRA organ classes, top conditions, country
  distribution, PIP breakdown, quarterly start-date timeline
- **About** — data sources, methodology, version info

### Visual Themes
- **Nord** — dark theme using the [Nord colour palette](https://www.nordtheme.com/)
- **Default** — standard shinydashboard light blue theme
- Toggle between themes via radio button in the sidebar; all charts,
  tables, and UI elements adapt instantly

---

## 🚀 Quick Start

### Prerequisites

- **R** ≥ 4.1
- **System dependencies** (for `ctrdata`):
  - JavaScript runtime: `node.js` (recommended) or `V8`
  - `libcurl`, `libssl`, `libxml2` (usually pre-installed on Linux/macOS)

### 1. Install R packages

```r
install.packages(c(
  "shiny", "shinydashboard", "shinycssloaders",
  "ctrdata", "nodbi", "RSQLite",
  "dplyr", "tidyr", "ggplot2", "stringr", "lubridate",
  "DT", "plotly", "readr", "writexl", "eulerr"
))
```

### 2. Populate the database

```bash
Rscript update_data.R
```

> ⏱ **First run takes 30–60 minutes** depending on network speed.
> EUCTR (~30 min), CTIS (~5 min).
> Subsequent runs are incremental and faster.

### 3. Launch the dashboard

```bash
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

Or from RStudio: open `app.R` → click **Run App**.

---

## 🐳 Docker

### Build

```bash
docker build -t pediatric-trials .
```

### Run

```bash
mkdir -p data
docker run -p 3838:3838 \
  -v $(pwd)/data:/app/data \
  pediatric-trials
```

Open [http://localhost:3838](http://localhost:3838).

The `-v` flag mounts a local `data/` directory so the SQLite database
and RDS cache persist across container restarts.

### Pre-populate before launching

```bash
docker build -t pediatric-trials .
mkdir -p data

# Fetch data (30-60 min first time)
docker run --rm -v $(pwd)/data:/app/data pediatric-trials \
  Rscript /app/update_wrapper.R

# Launch dashboard
docker run -d -p 3838:3838 \
  -v $(pwd)/data:/app/data \
  --name pediatric-trials \
  pediatric-trials
```

### Docker Compose

```bash
docker compose up -d
docker compose exec app Rscript /app/update_wrapper.R   # first time
# → open http://localhost:3838
```

---

## 📁 Project Structure

```
pediatric-trials-dashboard/
├── app.R                    # Shiny dashboard (UI + server)
├── update_data.R            # Data fetching script (EUCTR + CTIS)
├── Dockerfile               # Container definition
├── docker-compose.yml       # Compose orchestration
├── .dockerignore            # Files excluded from Docker build
├── README.md                # This file
└── data/                    # Runtime data (created automatically)
    ├── pediatric_trials.sqlite    # SQLite database
    └── pediatric_trials_cache.rds # Processed data cache
```

---

## 🔄 Data Pipeline

```
┌──────────────────────────┐    ┌──────────────────────────┐
│  EUCTR                    │    │  CTIS                     │
│  clinicaltrialsregister.eu│    │  euclinicaltrials.eu      │
│  age < 18                 │    │  paediatric keywords      │
│  ~10k records             │    │  ~2k records              │
│  (per-country duplicates) │    │  (nested JSON metadata)   │
└───────────┬──────────────┘    └───────────┬──────────────┘
            │                                │
            ▼                                ▼
┌─────────────────────────────────────────────────────────────┐
│                    ctrdata + SQLite                          │
│                                                             │
│  1. Flatten list-columns to " / "-separated strings         │
│  2. Coerce all columns to character (type-safety)           │
│  3. Clean country names:                                    │
│     • Strip EUCTR agency suffixes                           │
│     • Remove CTIS numeric/timestamp junk                    │
│     • Normalise against canonical country list              │
│  4. Unite corresponding fields across registers             │
│  5. Aggregate countries / statuses / MedDRA per trial       │
│     BEFORE deduplication                                    │
│  6. dbFindIdsUniqueTrials → one row per trial               │
│  7. Harmonise status → Ongoing / Completed / Other          │
│  8. Parse dates safely (multiple formats)                   │
│  9. Compute normalised title key for overlap detection      │
│ 10. Cache processed data to .rds                            │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │   Shiny Dashboard    │
              │   • Filters          │
              │   • Plots (plotly)   │
              │   • Venn (eulerr)    │
              │   • DataTable (DT)   │
              │   • CSV/Excel export │
              │   • Nord/Default     │
              └─────────────────────┘
```

---

## ⚠️ Known Issues / Caveats

| Issue | Details |
|-------|---------|
| **EUCTR `rows_update` errors** | `ctrdata` internally uses `dplyr::rows_update()` which fails on duplicate/unmatched keys in newer dplyr versions. Scripts temporarily monkey-patch this function during EUCTR loading. |
| **CTIS country field** | Contains nested metadata (numeric IDs, timestamps) alongside country names. Cleaned by matching against a canonical country list of ~200 entries. |
| **MedDRA classification** | EUCTR and CTIS both use MedDRA but may classify the same trial differently. Terms are aggregated as-is. |
| **PIP data** | Only available from EUCTR and CTIS. Interpretation varies between `"Yes"`, `"true"`, and other values — normalised to Yes/No/Unknown. |
| **Overlap detection** | Based on normalised title matching (first 80 chars). Conservative estimate — actual overlap may be higher for trials with different title formulations across registries. |
| **Incremental updates** | `ctrdata` performs upserts — existing records updated, new ones added. Delete `pediatric_trials.sqlite` and `pediatric_trials_cache.rds` for a clean start. |
| **Cache invalidation** | Cache auto-invalidates when SQLite DB is newer. Delete `.rds` file manually to force rebuild without re-downloading. |

---

## ⚙️ Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_PATH` | `pediatric_trials.sqlite` | Path to SQLite database file |
| `DB_COLLECTION` | `trials` | Collection name within the database |
| `CACHE_PATH` | `pediatric_trials_cache.rds` | Path to processed data cache |

Edit these at the top of both `app.R` and `update_data.R`.

In Docker, override via environment variables:

```bash
docker run -e DB_PATH=/app/data/trials.sqlite \
           -e DB_COLLECTION=trials \
           -p 3838:3838 pediatric-trials
```

---

## 🧰 Technology Stack

| Component | Package | Purpose |
|-----------|---------|---------|
| Data retrieval | [`ctrdata`](https://github.com/rfhb/ctrdata) | Unified access to EU clinical trial registers |
| Database | [`nodbi`](https://github.com/ropensci/nodbi) + [`RSQLite`](https://cran.r-project.org/package=RSQLite) | Local document store |
| Dashboard | [`shiny`](https://shiny.posit.co/) + [`shinydashboard`](https://rstudio.github.io/shinydashboard/) | Web framework |
| Charts | [`plotly`](https://plotly.com/r/) + [`ggplot2`](https://ggplot2.tidyverse.org/) | Interactive visualisation |
| Venn diagram | [`eulerr`](https://cran.r-project.org/package=eulerr) | Proportional area-accurate Euler diagrams |
| Tables | [`DT`](https://rstudio.github.io/DT/) | Interactive data tables |
| Data wrangling | [`dplyr`](https://dplyr.tidyverse.org/), [`tidyr`](https://tidyr.tidyverse.org/), [`stringr`](https://stringr.tidyverse.org/), [`lubridate`](https://lubridate.tidyverse.org/) | Data manipulation |
| Export | [`readr`](https://readr.tidyverse.org/), [`writexl`](https://cran.r-project.org/package=writexl) | CSV / Excel download |

---

## 📄 License

MIT

---

## 👤 Author

Ruben Van Paemel & Claude Opus 4.6

---

## 🙏 Acknowledgements

- [`ctrdata`](https://github.com/rfhb/ctrdata) by Ralf Herold — unified
  access to EU and US clinical trial registers from R
- [EU Clinical Trials Register](https://www.clinicaltrialsregister.eu)
- [Clinical Trials Information System](https://euclinicaltrials.eu)
- [Nord Theme](https://www.nordtheme.com/) colour palette

