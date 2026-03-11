


# 🧒 EU Paediatric Clinical Trials Dashboard

An interactive R Shiny dashboard that provides a unified view of paediatric
clinical trials across three European / international registers:

| Register | Source | Filter |
|----------|--------|--------|
| **EUCTR** — EU Clinical Trials Register | [clinicaltrialsregister.eu](https://www.clinicaltrialsregister.eu) | Subjects under 18 |
| **CTIS** — Clinical Trials Information System | [euclinicaltrials.eu](https://euclinicaltrials.eu) | Paediatric keywords |
| **CTGOV** — ClinicalTrials.gov | [clinicaltrials.gov](https://clinicaltrials.gov) | Child age group + 32 EU/EEA countries |

---

## ✨ Features

- **Multi-register integration** — harmonises fields (trial ID, title,
  conditions, countries, status, dates) across EUCTR, CTIS, and
  ClinicalTrials.gov into a single searchable dataset.

- **Smart deduplication** — EUCTR stores one record per member state per
  trial; the dashboard aggregates all countries, statuses, and MedDRA terms
  *before* collapsing to one row per unique trial. No more Belgium bias.

- **Country name cleaning** — strips EUCTR agency suffixes
  (`"Germany - BfArM"` → `"Germany"`), removes CTIS numeric/timestamp junk,
  and normalises against a canonical list of ~200 country names.

- **Interactive filters** (sidebar):
  - Trial status (Ongoing / Completed / Other)
  - Source register (EUCTR / CTIS / CTGOV)
  - Submission date range
  - MedDRA organ class
  - Condition / MedDRA term (searchable)
  - Country / member state (searchable)
  - Paediatric Investigation Plan (PIP) status
  - Free-text search (title, product, CT number, sponsor)

- **Dashboard tabs**:
  - **Overview** — value boxes, cumulative start-date plot, status pie chart,
    submissions per year, register comparison
  - **Data Explorer** — full interactive DataTable with column filters,
    CSV/Excel download
  - **Analytics** — top MedDRA organ classes, top conditions, country
    distribution, PIP breakdown, quarterly timeline, trial phase, top sponsors

- **In-app database refresh** — update button triggers re-download from all
  three registers with progress indicator.

---

## 🚀 Quick Start

### Prerequisites

- **R** ≥ 4.1
- **System dependencies** (for `ctrdata`):
  - A JavaScript runtime: `node.js` (recommended) or `V8`
  - `libcurl`, `libssl`, `libxml2` (usually pre-installed on Linux/macOS)

### 1. Install R packages

```r
install.packages(c(
  "shiny", "shinydashboard", "shinycssloaders",
  "ctrdata", "nodbi", "RSQLite",
  "dplyr", "tidyr", "ggplot2", "stringr", "lubridate",
  "DT", "plotly", "readr", "writexl"
))
```

### 2. Populate the database

```bash
Rscript update_data.R
```

> ⏱ **First run takes 1–3 hours** depending on network speed.
> EUCTR (~30 min), CTIS (~5 min), CTGOV (~1–2 hr for 32 countries).
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
docker run -p 3838:3838 \
  -v $(pwd)/data:/app/data \
  pediatric-trials
```

Open [http://localhost:3838](http://localhost:3838).

The `-v` flag mounts a local `data/` directory so the SQLite database
persists across container restarts. On first launch the database will
be empty — use the **Update Database** button in the sidebar or run:

```bash
docker exec -it <container_id> Rscript /app/update_wrapper.R
```

### Pre-populate before launching

```bash
# Build & populate in one step
docker build -t pediatric-trials .
mkdir -p data
docker run --rm -v $(pwd)/data:/app/data pediatric-trials \
  Rscript /app/update_wrapper.R

# Then run the dashboard
docker run -d -p 3838:3838 -v $(pwd)/data:/app/data \
  --name pediatric-trials pediatric-trials
```

### Docker Compose

```bash
docker compose up -d
docker compose exec app Rscript /app/update_wrapper.R    # first time only
# → open http://localhost:3838
```

---

## 📁 Project Structure

```
pediatric-trials-dashboard/
├── app.R                    # Shiny dashboard (UI + server)
├── update_data.R            # Data fetching script (EUCTR + CTIS + CTGOV)
├── Dockerfile               # Container definition
├── docker-compose.yml       # Compose orchestration
├── .dockerignore            # Files excluded from Docker build
├── README.md                # This file
├── data/                    # SQLite database (created at runtime)
│   └── pediatric_trials.sqlite
└── docs/
    └── screenshot.png       # Dashboard screenshot (optional)
```

---

## 🔄 Data Pipeline

```
┌──────────────────────┐   ┌──────────────────────┐   ┌────────────────────────┐
│   EUCTR              │   │   CTIS               │   │   ClinicalTrials.gov   │
│   age < 18           │   │   paediatric keywords│   │   ages:child           │
│   ~10k records       │   │   ~2k records        │   │   32 EU/EEA countries. │
│   (per-country dupes)│   │   (nested JSON junk) │   │   ~30k records         │
└────────┬─────────────┘   └────────┬─────────────┘   └────────┬───────────────┘
         │                         │                          │
         ▼                         ▼                          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                        ctrdata + SQLite                                      │
│                                                                              │
│  1. Flatten list-columns to " / "-separated strings                          │
│  2. Coerce all columns to character (type-safety)                            │
│  3. Clean country names (strip agencies, remove junk, canonicalise)          │
│  4. Unite corresponding fields across 3 registers                            │
│  5. Aggregate countries/statuses/MedDRA per trial BEFORE dedup               │
│  6. dbFindIdsUniqueTrials → one row per trial                                │
│  7. Harmonise status → Ongoing / Completed / Other                           │
│  8. Parse dates safely (multiple formats)                                    │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │   Shiny Dashboard    │
                        │   • Filters          │
                        │   • Plots (plotly)   │
                        │   • DataTable (DT)   │
                        │   • CSV/Excel export │
                        └──────────────────────┘
```

---

## ⚠️ Known Issues / Caveats

| Issue | Details |
|-------|---------|
| **EUCTR `rows_update` errors** | `ctrdata` internally uses `dplyr::rows_update()` which fails on duplicate/unmatched keys. The scripts temporarily monkey-patch this function during EUCTR loading. |
| **CTGOV stack overflow** | Countries with >3000 trials (Germany, France, UK, Spain) can overflow R's JSON parser. Queries are automatically split by recruitment status. |
| **CTIS country field** | Contains nested metadata (IDs, timestamps) alongside country names. Cleaned by matching against a canonical country list. |
| **MedDRA vs CTGOV conditions** | EUCTR/CTIS use MedDRA classification; CTGOV uses free-text condition names. They appear together in the "Condition" column but are not identical ontologies. |
| **PIP data** | Only available from EUCTR and CTIS. CTGOV trials show "Unknown" for PIP status. |
| **Incremental updates** | `ctrdata` performs upserts — existing records are updated, new ones added. Delete `pediatric_trials.sqlite` for a clean start. |

---

## ⚙️ Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_PATH` | `pediatric_trials.sqlite` | Path to SQLite database file |
| `DB_COLLECTION` | `trials` | Collection name within the database |
| `EU_COUNTRIES` | 32 countries | EU-27 + EEA + CH + UK for CTGOV queries |

Edit these at the top of both `app.R` and `update_data.R`.

---

## 🧰 Technology Stack

| Component | Package |
|-----------|---------|
| Data retrieval | [`ctrdata`](https://github.com/rfhb/ctrdata) |
| Database | [`nodbi`](https://github.com/ropensci/nodbi) + [`RSQLite`](https://cran.r-project.org/package=RSQLite) |
| Dashboard | [`shiny`](https://shiny.posit.co/) + [`shinydashboard`](https://rstudio.github.io/shinydashboard/) |
| Charts | [`plotly`](https://plotly.com/r/) + [`ggplot2`](https://ggplot2.tidyverse.org/) |
| Tables | [`DT`](https://rstudio.github.io/DT/) |
| Data wrangling | [`dplyr`](https://dplyr.tidyverse.org/), [`tidyr`](https://tidyr.tidyverse.org/), [`stringr`](https://stringr.tidyverse.org/), [`lubridate`](https://lubridate.tidyverse.org/) |

---

## 📄 License

MIT

---

## 👤 Author

Ruben Van Paemel & Claude Opus 4.6

---

## 🙏 Acknowledgements

- [`ctrdata`](https://github.com/rfhb/ctrdata) by Ralf Herold — the backbone
  of this project, providing unified access to EU and US clinical trial
  registers from R.
- [EU Clinical Trials Register](https://www.clinicaltrialsregister.eu)
- [Clinical Trials Information System](https://euclinicaltrials.eu)
- [ClinicalTrials.gov](https://clinicaltrials.gov)

