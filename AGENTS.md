# Project Agent Notes

## Project Rules

- When committing, update the version number everywhere in the code, update `README.md`, update the About tab changelog in `app.R`, and commit all changes to GitHub.
- Update `AGENTS.md` for every project git commit. Add a section for the version or feature with what was built.
- When making a new version, update the R Markdown report files to reflect the most recent changes.
- When bumping the version, always update `CHANGELOG.md` with a full-detail entry.
- `README.md` and the About tab in `app.R` only keep the most recent changelog entry and link to `CHANGELOG.md` for older history.

## Current Version

v0.10.4

---

## Database Notes

The database (`data/trials.sqlite`, collection `trials`) stores records in MessagePack format, not plain JSON. Do not use `rawToChar()` or `jsonlite::fromJSON()` directly on the blob column. Use `ctrdata` extraction helpers instead.

```r
library(nodbi)
library(ctrdata)

db <- nodbi::src_sqlite(dbname = "./data/trials.sqlite", collection = "trials")

# Find fields matching a name fragment. Samples 5 records per register.
ctrdata::dbFindFields(namepart = "age", con = db)

# Extract specific fields into a dataframe.
df <- ctrdata::dbGetFieldsIntoDf(
  fields = c("field.path.one", "field.path.two"),
  con = db
)

# Detect register:
# EUCTR IDs end with a letter country code, e.g. -BE or -GB3.
# CTIS IDs end with a numeric 2-digit segment, e.g. -00 or -01.
is_euctr <- grepl("[A-Z][A-Z0-9]*$", df[["_id"]])
is_ctis <- !is_euctr
```

For raw counts or ID queries only:

```r
library(DBI)
library(RSQLite)

con <- DBI::dbConnect(RSQLite::SQLite(), "./data/trials.sqlite")
DBI::dbGetQuery(
  con,
  "SELECT COUNT(*) FROM trials WHERE _id GLOB '????-??????-??-[0-9][0-9]'"
)
DBI::dbDisconnect(con)
```

`ctrdata::dbQueryFields` does not exist. Use `ctrdata::dbFindFields(namepart = ..., con = db)`.

## Confirmed Field Names

### EUCTR age flags

- `f11_trial_has_subjects_under_18`
- `f12_adults_1864_years`, not `f12_adults_18_to_64_years`
- `f13_elderly_65_years`, not `f13_elderly_over_65`

### CTIS age group

- `ageGroup`, comma-separated string, e.g. `"0-17 years, 18-64 years"`
- Known values: `"0-17 years"`, `"18-64 years"`, `"65+ years"`, `"In utero"`

### CTIS fields used

- Sponsor name: `authorizedApplication.authorizedPartI.sponsors.organisation.name`
- PIP: `authorizedApplication.authorizedPartI.trialDetails.scientificAdviceAndPip.paediatricInvestigationPlan`
- Orphan: `authorizedApplication.authorizedPartI.products.orphanDrugDesigNumber`

### CTIS per-country decision dates

Per-country decision dates live under `memberStatesConcerned`, not under `applicationInfo`:

- `authorizedApplication.memberStatesConcerned.firstDecisionDate`
- `authorizedApplication.memberStatesConcerned.lastDecisionDate`
- `authorizedApplication.memberStatesConcerned.mscName`

These date fields are lists of `"YYYY-MM-DD"` strings, one per member state. After `deep_flatten_col`, they become `" / "`-separated character strings.

`authorizedApplication.applicationInfo.decisionDate` is a single application-level date and is often missing for multinational trials. Do not use it as the sole decision-date source.

Derived columns computed in `app.R` after register detection:

- `ctis_decision_date_first`: minimum of `firstDecisionDate` across all member states, as `"YYYY-MM-DD"`
- `decision_date_spread_days`: max minus min in days across member states; `NA` for EUCTR
- `decision_date`: uses `ctis_decision_date_first` for CTIS, falling back to `applicationInfo.decisionDate`

---

## Release Notes

## Completed: Sponsor curation workflow tooling (v0.10.4) - shipped 2026-05-05

### What was built

- **Self-service sponsor curation folder** - sponsor review scripts and guide moved into `sponsor_curation/`, separating curation tooling from the Shiny app root.
- **Generated alias candidates** - `audit_sponsors.R` rebuilds candidate duplicate sponsor pairs from the current sponsor normalisation log and applies reviewed aliases for audit purposes only.
- **Resumable interactive review** - `review_sponsor_aliases.R` saves approvals and skips to `config/sponsor_review_decisions.csv`, resumes after reviewed candidates, reports how many candidates remain, and works from both `Rscript` and RStudio `source()`.
- **CSV batch approval** - `approve_sponsor_aliases.R` promotes `approved=TRUE` candidate rows into `config/sponsor_aliases.csv` and regenerates the queue.
- **Self-service apply step** - `apply_sponsor_aliases.R` folds approved aliases into `app.R`, refreshes sponsor names in `trials_cache.rds`, regenerates sponsor logs/candidates, updates `config/sponsor_curation_baseline.csv`, and renders preprocessing.
- **Preprocessing sponsor audit** - `preprocessing.Rmd` documents the manual alias workflow, visualises approved aliases and candidate queues, and reports new sponsors since the last manual curation baseline.

### Key files changed

- `sponsor_curation/` - new sponsor curation scripts, guide, and handover notes.
- `config/sponsor_aliases.csv` - reviewed sponsor alias decisions.
- `config/sponsor_review_decisions.csv` - resumable interactive-review decisions.
- `config/sponsor_curation_baseline.csv` - sponsor labels present at the last manual curation.
- `app.R` - sponsor alias normalisation expanded and About latest changelog updated.
- `preprocessing.Rmd`, `www/preprocessing.html` - sponsor curation audit, visuals, and new-sponsor baseline reporting added/regenerated.
- `README.md`, `CHANGELOG.md`, `AGENTS.md` - sponsor curation workflow documented.

---

## Completed: CTIS transition EudraCT deduplication aliases (v0.10.4) - shipped 2026-05-05

### What was built

- **CTIS transition EudraCT matching** - CTIS transition applications now extract `authorizedApplication.eudraCt.eudraCtCode`, so transitioned EUCTR trials can be matched to CTIS even when CTIS assigns a new EU trial number.
- **Canonical CTIS row with searchable legacy alias** - transitioned duplicates prefer the CTIS row, while `transition_eudract_number` and `trial_identifiers` preserve the old EudraCT number for search, display, and exports.
- **Safer deduplication order** - transition/base fallbacks no longer depend on title length; title-key-only drops are restricted to explicitly transitioned EUCTR rows; CTIS title/base swaps keep the latest amendment version.
- **Source provenance preserved** - pre-2023 CTIS migrated records keep source `register == "CTIS"` and use `analysis_register == "EUCTR"` only for timeline grouping.
- **Register Migration tab** - a dedicated Analysis tab now highlights EUCTR-era records sourced from CTIS after migration, separating them from EUCTR-source and CTIS-native records over submission year.
- **Deduplication audit corrected** - the preprocessing report now checks transition EudraCT number, CTIS base ID, and title-key fallbacks before calling a transitioned EUCTR record unmatched, and duplicate audits use canonical trial IDs.
- **Cache schema guard** - old caches without transition alias columns are treated as stale so the new deduplication logic is applied on the next rebuild.
- **CTIS MedDRA organ classes restored** - known numeric EMA MedDRA SOC codes are no longer stripped during CTIS flattening, so the Top MedDRA Organ Classes chart populates when filtering to CTIS.

### Key files changed

- `app.R` - version v0.10.4; extracts CTIS transition EudraCT numbers; uses them in cross-register deduplication; adds searchable aliases, canonical IDs, analysis register labels, the Register Migration tab, latest-amendment-safe swaps, cache schema validation, and CTIS SOC-code preservation during flattening.
- `preprocessing.Rmd` - deduplication report updated to document and audit transition-number fallback matching, latest CTIS amendment retention, analysis-register labelling, and canonical duplicate IDs.
- `README.md` - version badge and latest changelog entry updated.
- `CHANGELOG.md` - v0.10.4 full entry added.
- `report.Rmd`, `comparison_report.Rmd` - report subtitles updated to Dashboard v0.10.4.
- `AGENTS.md` - current version and this entry.

---

## Completed: Sidebar comparison report button fix (v0.10.3) - shipped 2026-05-04

- **Persistent side-panel report button fixed** - The sidebar "Compare Paediatric vs Adult" button is now a real Shiny download button instead of a custom DOM click shortcut to the Tools-tab button.
- **Shared comparison report handler** - Both comparison-report buttons use the same reusable `downloadHandler`, keeping active filter logic, age-group exclusion, filenames, PDF checks, and report rendering consistent.
- **Files changed** - `app.R`, `README.md`, `CHANGELOG.md`, `report.Rmd`, `comparison_report.Rmd`, `AGENTS.md`.

---

## Completed: Age-aware population normalisation (v0.10.2) - shipped 2026-05-04

- **Map age-aware per-million mode** - Map normalisation now follows the Age Group filter: `< 18 years` uses children 0-17, `>= 18 years` uses adults 18+, and `All` uses total population.
- **Chart Builder age-aware country normalisation** - Country/member-state per-million charts use the same denominator selection, with checkbox labels, y-axis titles, and table headers updated dynamically.
- **Population denominators expanded** - `EU_CHILD_POP` now includes 2026 total-population values from Worldometer/UN Population Division and derives adult population as total minus child population.
- **Visible map table labels** - zoomed-in map trial table now labels the active per-million denominator instead of always showing children.
- **Files changed** - `app.R`, `README.md`, `CHANGELOG.md`, `report.Rmd`, `comparison_report.Rmd`, `AGENTS.md`.

---

## Completed: UI fixes + result reporting wording (v0.10.1) - shipped 2026-05-04

- **Dynamic plot heights** - Top Sponsors box auto-sizes to the selected Top N slider value; CTIS multinational decision-date spread chart box height no longer clips the plot.
- **Violin/box hover details restored** - Plotly default hover summaries now show Q1, median, Q3, min, and max; log-axis labels use plain `log10` text.
- **Result Reporting KPI percentages** - Academic and Industry "no results" KPI cards now show percentages of all completed trials.
- **Terminology cleanup** - "Results Posting" renamed to "Result Reporting" throughout the app and docs.
- **Loading overlay timing** - startup overlay hides after the initial Shiny render reaches `shiny:idle`, with a 15-second fallback.
- **Files changed** - `app.R`, `README.md`, `CHANGELOG.md`, `report.Rmd`, `comparison_report.Rmd`, `AGENTS.md`.

---

## Completed: Country Comparison tab (v0.10.0) - shipped 2026-05-04

- **Country Comparison analysis tab** - compare 2-3 selected countries side-by-side across phase, status, sponsor type, PIP status, top organ classes, submissions per year, and result reporting.
- **Example question routing** - Belgium vs Croatia preset applies the country filter and opens Country Comparison; GSK/Novartis/Roche preset applies sponsor filters and opens Sponsor Comparison.
- **Overview navigation** - Country Comparison card added to the overview quick navigation grid.
- **Files changed** - `app.R`, `README.md`, `CHANGELOG.md`, `AGENTS.md`.

---

## Older Completed Work

### v0.9.9 - Grouped sidebar navigation - shipped 2026-05-03

- Added collapsible Analysis sidebar group with Basic Analytics, Phase Analytics, Sponsor Comparison, and Results Posting.
- Kept Data Explorer as a standalone sidebar item below Map.
- Added `SIDEBAR_SUBMENU_CSS` and created `CHANGELOG.md`.
- Updated `app.R`, `CHANGELOG.md`, `README.md`, and `AGENTS.md`.

### v0.9.7 - Light theme default + theming polish - shipped 2026-05-02

- Made Nord Light the default theme.
- Fixed sidebar background and text color cascade issues.
- Corrected button text colors, Plotly/DataTable backgrounds, nav card heights, orientation strip layout, and Results Posting KPI card parity.
- Updated `app.R`, `AGENTS.md`, and `README.md`.

### v0.9.6 - Light theme + overview UX + compliance KPI parity - shipped 2026-05-02

- Re-enabled the Nord Light theme selector.
- Added the overview orientation strip, Phase Analytics nav card, KPI click hint, and custom Result Reporting KPI strip.
- Updated `app.R`, `AGENTS.md`, and `README.md`.

### v0.9.5 - Overview page UI/UX overhaul + fresh theming - shipped 2026-05-01

- Redesigned the overview page with KPI cards, navigation shortcut cards, quick filters, and recent authorized trials.
- Replaced hand-crafted AdminLTE CSS with `fresh::create_theme()` and a smaller supplement CSS layer.
- Updated `app.R` and `AGENTS.md`.

### v0.9.4 - Deduplicate slash-separated product names - shipped 2026-04-30

- Trimmed flattened JSON list tokens before `unique()`.
- Added `dedup_slash` for `DIMP_product_name` after MedDRA cleaning.

### v0.9.3 - Paediatric vs Adult comparison report - shipped 2026-04-30

- Added `comparison_report.Rmd`, a parameterized xelatex PDF comparing Paediatric and Adult trials.
- Added "Compare Paediatric vs Adult" download button and server handler.
- Excluded `age_group_filter` from report filtering so both age groups are always included.

### v0.9.2 - CTIS multinational decision date fix + spread graph - shipped 2026-04-30

- Extracted per-country CTIS `firstDecisionDate` and `lastDecisionDate`.
- Fixed CTIS submission date parsing for per-amendment lists.
- Added `decision_date_spread_days` and a CTIS multinational decision-date spread chart.
- Cache note: delete and rebuild `trials_cache.rds` to pick up corrected fields and dates.

### v0.9.1 - Preprocessing age coverage + EUCTR ingestion hardening - shipped 2026-04-29

- Added Age Group Coverage section to `preprocessing.Rmd`.
- Fixed preprocessing deduplication waterfall and report paths.
- Hardened EUCTR ingestion bisection and fallback URL handling in `update_data.R` v16.

### v0.9.0 - All-ages dataset + Age Group filter - shipped 2026-04-29

- Fetches all age groups from EUCTR and CTIS.
- Renamed DB/cache to `trials.sqlite` and `trials_cache.rds`.
- Added derived `age_group` and sidebar Age Group filter.
- Added Age Group to Chart Builder.
- Introduced resilient ingestion engine in `update_data.R` v15.

### v0.8.2 - preprocessing.Rmd pipeline audit report - shipped 2026-04-28

- Added `preprocessing.Rmd`, rendered to `www/preprocessing.html` and linked from About.
- Documented normalisation, deduplication waterfall, and data quality issues.
- Added transitioned EUCTR to CTIS base-ID fallback after title-key matching.

### v0.8.1 - Per-million-children normalisation - shipped 2026-04-28

- Added `EU_CHILD_POP` data frame for 108 countries.
- Added Map total vs trials-per-million-children mode.
- Added Chart Builder child-population normalisation for country charts.

### v0.8.0 - User feedback batch - shipped 2026-04-27

- Sorted recent trials by `decision_date` and opened detail modals from rows.
- Added mononational sidebar toggle with URL state.
- Made KPI cards clickable filters.
- Set negative `days_to_decision` to `NA`.
- Added completion-rate charts by sponsor type and phase.

### v0.7.0 - Results Posting + Orphan tabs - shipped 2026-04-19

- Added `has_results` from EUCTR endpoint readiness and CTIS `resultsFirstReceived`.
- Added `is_orphan` from EUCTR DIMP D.2.5 and CTIS orphan designation number.
- Added Results Posting tab with overdue table, by-year chart, and by-sponsor chart.

### v0.5.1 - Sponsor Comparison tab - shipped 2026-04-18

- Added dedicated Sponsor Comparison tab with six side-by-side charts for 2-3 selected sponsors.

### v0.3.0 - Chart Builder tab - shipped 2026-04-06

- Added `EXPLORE_MULTI_COLS`, `EXPLORE_LABELS`, and `explore_data()` reactive.

### v0.2.4 - Sponsor normalisation - shipped 2026-04-05

- Added `normalize_sponsor_name()` with legal suffix, pharma descriptor, subsidiary, and canonical brand-prefix handling.
- EUCTR source: `b1_sponsor.b11_name_of_sponsor`.
- CTIS source: `authorizedApplication.authorizedPartI.sponsors.organisation.name`.

---

## Future Ideas

- Email notifications on new trials with `blastula` in `rebuild_cache.R`.
- Export Data Explorer to CSV/Excel.
- Add a "Copy shareable link" button. URL state is already encoded.
- Add filter reset per group via `x` on each details summary.
- Make the PDF report respect active sidebar filters. It currently always uses the full dataset.
