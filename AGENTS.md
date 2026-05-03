when committing, update the version number everywhere in the code, update the readme and about with the changelog and commit all changes to github

update AGENTS.md every time the project has a git commit (add a section for the version/feature with what was built)

when making a new version, update the rmd file to reflect the most recent changes.

when bumping the version, always update CHANGELOG.md with the new entry (full detail). README.md and the About tab in app.R only keep the most recent entry and link to CHANGELOG.md for older history.

## Current version: v0.9.9

---

## Completed: Grouped sidebar navigation (v0.9.9) — shipped 2026-05-03

### What was built

- **Collapsible "Analysis" group** — `menuItem("Analysis", startExpanded=FALSE)` with four `menuSubItem` children: Basic Analytics, Phase Analytics, Sponsor Comparison, Results Posting. Reduces the flat 9-item sidebar to 6 top-level entries.
- **Data Explorer repositioned** — remains a standalone `menuItem` immediately below Map (not grouped).
- **Submenu CSS** — `SIDEBAR_SUBMENU_CSS` constant with Nord-palette colors for `.treeview-menu` links (hover, active, indent). Appended to both `NORD_SUPPLEMENT` and `NORD_LIGHT_SUPPLEMENT`.
- **CHANGELOG.md created** — full version history moved out of README.md; README and About tab now show only the latest entry with a link.
- **AGENTS.md rule added** — always update CHANGELOG.md when bumping version.

### Key files changed
- `app.R` — sidebarMenu restructured; `SIDEBAR_SUBMENU_CSS`; About tab changelog trimmed to latest only.
- `CHANGELOG.md` — new file with full history from v0.2.2 to v0.9.8.
- `README.md` — version badge, Dashboard tabs table, changelog section updated.
- `AGENTS.md` — this entry + versioning rule.

---

## Completed: Light theme default + full theming polish (v0.9.7) — shipped 2026-05-02

### What was built

- **Light theme is now the default** — `selectInput` default changed to `"Nord Light"`.
- **Sidebar background (definitive fix)** — JS `fixSidebar()` self-invoking function sets `background`/`background-color` as inline styles (highest CSS priority, cannot be overridden by any stylesheet rule). Eliminates the persistent AdminLTE skin-blue cascade conflict.
- **Sidebar text colours fully corrected** — root cause was `a{color:#5E81AC!important}` being universal; scoped to `.content-wrapper a` so it never bleeds into the sidebar. Filter group `<summary>` labels (closed: `#D8DEE9`, open: `#88C0D0`) and sidebar `p`/`h4` all forced light.
- **Button text colour** — `a{color}` was bleeding into `.btn` text; explicit `color:#fff!important` added to all button variants in the Nord Light active-theme inject.
- **Plotly + DataTable backgrounds** — `chart_bg` changed `#ECEFF4` → `#FFFFFF` to match white box background; DataTable body/header/hover overridden to white/`#E5E9F0`/`#F0F2F5`.
- **Nav cards equal height** — correct flexbox: `.qs-row { display:flex; align-items:stretch }`, `.qs-row > div { flex-direction:column }`, `.qs-card { flex:1 }`.
- **Orientation strip** — `align-items:stretch` + each tip column is `flex-direction:column` so icons/titles align across all three columns. Icon colour: `t$frost3` in light theme (darker, readable on white), `t$frost1` in dark theme.
- **Results Posting KPI parity** — 4 `valueBox` widgets replaced with custom kpi-card `renderUI` matching overview style.
- **Phase Analytics nav card** — added to overview; layout changed to 4+3 two-row grid.

### Key files changed
- `app.R` — version v0.9.7; all CSS/JS theming changes above; `selectInput` default `"Nord Light"`.
- `AGENTS.md`, `README.md` — this entry.

---

## Completed: Light theme + overview UX + compliance KPI parity (v0.9.6) — shipped 2026-05-02

### What was built

- **Nord Light theme re-enabled** — "Appearance" `selectInput` (Dark / Nord Light) now visible in the sidebar Tools tab; the hidden `radioButtons` with "Default" option was removed. Fixed `NORD_LIGHT_SUPPLEMENT`: `.insight-divider` was `rgba(255,255,255,0.1)` in static CSS (invisible on white) — override appended to the paste0 block.
- **Overview orientation strip** — `output$hero_banner` (previously dead code — rendered but never shown) repurposed as a 3-column horizontal tips bar using the existing `.insight-strip` / `.insight-divider` CSS classes. Tips: "Use sidebar filters" / "Click KPI cards" / "Select a feature below". All colours from `tc()` so both themes work.
- **Phase Analytics nav card** — Added as 7th card. Layout changed from 6 × `column(2)` to two rows: 4 × `column(3)` + 3 × `column(4)`. Section label "Explore the Dashboard" using `.analytics-section-header`.
- **KPI click-hint** — Small right-aligned text below the KPI strip: "Click any card to filter the dashboard by that group."
- **Results Posting KPI parity** — Replaced 4 `valueBoxOutput` / `renderValueBox` blocks with a single `output$kpi_strip_compliance` `renderUI`. Same `make_kpi()` helper pattern as the overview; colours: green (Completed), frost3 (Results Posted with %), yellow (Academic — no results), orange (Industry — no results). Lazy rendering list updated.

### Key files changed
- `app.R` — version bump to v0.9.6; `NORD_LIGHT_SUPPLEMENT` (divider fix); sidebar theme selector; overview tabItem (hero_banner, 2-row nav cards, section label); `output$kpi_strip` (tagList + hint); `output$hero_banner` (repurposed); compliance tabItem (uiOutput); removed 4 renderValueBox; new `output$kpi_strip_compliance`; lazy list updated.
- `AGENTS.md`, `README.md` — this entry.

---

## Completed: Overview page UI/UX overhaul + fresh theming (v0.9.5) — shipped 2026-05-01

### What was built

- **Overview page redesigned** — hero subtitle moved into the top navbar bar; KPI cards now use full Nord accent-colour backgrounds (frost3 blue, Nord green, Nord yellow, Nord purple) with white text; six clickable navigation shortcut cards link to each feature tab; quick-filter preset buttons (CTIS only, EUCTR only, Ongoing PIP, Orphan, Completed) apply sidebar filters in one click; "5 Most Recently Authorized Trials" table restored at the bottom of the overview.
- **`fresh` package theming** — removed the 90-line hand-crafted `generate_css()` `sprintf` template (which kept losing CSS specificity battles against AdminLTE). Replaced with `fresh::create_theme()` + `fresh::adminlte_color/sidebar/global()` which compiles AdminLTE SASS variables correctly. Box headers, sidebar colours, body background, and button colours are now set at the SASS variable level — no `!important` overrides needed for the core shell.
- **`generate_supplement_css()`** — slim replacement (~65 lines) for elements `fresh` doesn't reach: DataTables, modals, sliders, links, filter chips, navbar/logo background, and button text colours.
- **Nord dark theme** — sidebar darkest (`bg0`), main panel one step lighter (`bg1`), KPI cards on `bg2`; box solid headers use muted Nord blue; Download PDF / Compare buttons have explicit white text; Save/Load buttons have proper vertical spacing.
- **Nord Light theme** — dark sidebar (Nord dark values hardcoded in `NORD_LIGHT_SUPPLEMENT`) with light main panel; sidebar form controls, labels, and tab links correctly use dark-sidebar colours; nav cards use light overlay matching the light background.
- **Theme selector hidden** — radio buttons wrapped in `display:none` div; app defaults to Nord theme only.

### Key files changed
- `app.R` — version bump to v0.9.5; sections 1 (library: added `fresh`), 2 (themes: replaced `generate_css`/`NORD_CSS`/`NORD_LIGHT_CSS` with `.make_fresh_theme()`/`generate_supplement_css()`), UI (overview tab restructured), server (`output$active_theme` now injects fresh + supplement).
- `AGENTS.md` — this entry.

---

## Completed: Deduplicate slash-separated product names (v0.9.4) — shipped 2026-04-30

### What was built

- **`deep_flatten_col` fix** — added `trimws(flat)` before `unique()` so whitespace variants of the same token (e.g. leading/trailing space) no longer survive as separate entries after JSON list flattening.
- **`dedup_slash` post-processing** — new helper applied to `DIMP_product_name` after MedDRA cleaning; splits on `/`, trims each token, and keeps only unique values. Mirrors the dedup already present in `clean_meddra_term` and `clean_organ_class`.
- Root cause: EUCTR DIM entries occasionally repeated the same product name with minor whitespace differences, causing cells like "TMI-005 WAY-177005 / TMI-005 WAY-177005 / TMI-005 WAY-177005" in the Data Explorer.

---

## Completed: Paediatric vs Adult comparison report (v0.9.3) — shipped 2026-04-30

### What was built

- **`comparison_report.Rmd`** — new parameterized xelatex PDF report that compares Paediatric vs Adult trials side-by-side. Sections: Dataset Overview, Trial Status, Phase Distribution, Sponsor Type, PIP Status, Orphan Designation, Source Register, Results Posting, Submission Timeline, Decision Timeline (violin+boxplot with summary stats table), Therapeutic Areas (top 15 organ classes), Geographic Distribution (top 20 member states). "Paediatric & Adult" trials appear in the overview table but are excluded from all comparison charts.
- **"Compare Paediatric vs Adult" button** — added to the Tools tab (`downloadButton("dl_comparison_report")`, blue `btn-info`) below the existing Download PDF button.
- **Server handler** (`output$dl_comparison_report`) — applies all active sidebar filters to `rv$data` **except** `age_group_filter`, so the report always contains both groups regardless of the current age filter selection. Passes `data_path` (temp RDS) and `filters` (for display) to the Rmd.
- No `<<-` used; shared pre-computed variables (`sp_n_paed/adult`, `results_paed/adult`, `dec_paed/adult`, `has_decision`) defined in setup chunk.

---

## Completed: CTIS multinational decision date fix + spread graph (v0.9.2) — shipped 2026-04-30

### What was built

- **Per-country decision date extraction** — added `authorizedApplication.memberStatesConcerned.firstDecisionDate` and `lastDecisionDate` to `CTIS_fields`; parsed with `.parse_ctis_date_vec()` after register detection. For CTIS, `decision_date` now uses the earliest member-state decision date (`ctis_decision_date_first`) instead of the single application-level `applicationInfo.decisionDate` (which was NA for many multinational trials). Falls back to the application-level date when per-country data is absent.
- **Submission date fix** — CTIS `submissionDate` is a per-amendment list; now takes the minimum (first submission) date from the `" / "`-separated string before parsing, fixing empty `submission_date_parsed`, `year`, and `days_to_decision` for many CTIS trials.
- **`decision_date_spread_days` column** — new derived column for CTIS: days between the earliest and latest member-state first-decision date within a trial; NA for EUCTR.
- **New graph: Decision Date Spread Within CTIS Multinational Trials** — violin plot in the Sponsors/Analytics section, grouped by number of member states (2 / 3 / 4 / 5+), y-axis log₁₀ scale with ticks at 1, 10, 100, 1000 days. Only CTIS trials with `n_countries > 1` and a non-NA spread are included.
- **Cache note** — requires `trials_cache.rds` deletion and rebuild to pick up new fields and corrected dates.

---

## Completed: Preprocessing age coverage + EUCTR ingestion hardening (v0.9.1) — shipped 2026-04-29

### What was built

- **Preprocessing report: Age Group Coverage section** — standalone top-level section documenting Paediatric / Adult / Paediatric & Adult / Unknown classifications, app filter inclusion logic, summary counts, and register split.
- **Preprocessing report fixes** — deduplication waterfall now uses `data/trials.sqlite`, computes monotonic first-principles step counts, removes stale `n_other_drops`, and restores `cache_euctr_base` for EUCTR examples.
- **EUCTR ingestion hardening** (`update_data.R` v16) — recursive bisection now continues toward single-day ranges before trial-level fallback; fallback URL reads have bounded timeout/retry handling.
- **Docs/report path cleanup** — README and report cache references updated to `trials.sqlite` / `trials_cache.rds`; `www/preprocessing.html` regenerated.

---

## SQLite / ctrdata DB querying — how to read records

The database (`data/trials.sqlite`, collection `trials`) stores records in **MessagePack** format (not plain JSON). You cannot use `rawToChar()` or `jsonlite::fromJSON()` directly on the blob column. Use ctrdata's own extraction functions instead:

```r
library(nodbi); library(ctrdata)
db <- nodbi::src_sqlite(dbname = "./data/trials.sqlite", collection = "trials")

# Find fields matching a name fragment (samples 5 records per register)
ctrdata::dbFindFields(namepart = "age", con = db)

# Extract specific fields into a dataframe
df <- ctrdata::dbGetFieldsIntoDf(fields = c("field.path.one", "field.path.two"), con = db)

# Detect register: EUCTR IDs end with a letter country code (e.g. -BE, -GB3)
#                  CTIS IDs end with a numeric 2-digit segment (e.g. -00, -01)
is_euctr <- grepl("[A-Z][A-Z0-9]*$", df[["_id"]])
is_ctis  <- !is_euctr
```

For raw counts/ID queries only:

```r
library(DBI); library(RSQLite)
con <- DBI::dbConnect(RSQLite::SQLite(), "./data/trials.sqlite")
DBI::dbGetQuery(con, "SELECT COUNT(*) FROM trials WHERE _id GLOB '????-??????-??-[0-9][0-9]'")
DBI::dbDisconnect(con)
```

Note: `ctrdata::dbQueryFields` does **not** exist — use `ctrdata::dbFindFields(namepart=..., con=db)`.

---

## Key confirmed field names

### EUCTR age flags

- `f11_trial_has_subjects_under_18`
- `f12_adults_1864_years` (NOT `f12_adults_18_to_64_years`)
- `f13_elderly_65_years` (NOT `f13_elderly_over_65`)

### CTIS age group

- `ageGroup` — comma-separated string, e.g. `"0-17 years, 18-64 years"`
- Values: `"0-17 years"`, `"18-64 years"`, `"65+ years"`, `"In utero"`

### CTIS other fields used

- Sponsor name: `authorizedApplication.authorizedPartI.sponsors.organisation.name`
- PIP: `authorizedApplication.authorizedPartI.trialDetails.scientificAdviceAndPip.paediatricInvestigationPlan`
- Orphan: `authorizedApplication.authorizedPartI.products.orphanDrugDesigNumber`

### CTIS per-country decision dates (multinational trials)

Per-country decision dates live under `memberStatesConcerned`, **not** under `applicationInfo`:

- `authorizedApplication.memberStatesConcerned.firstDecisionDate` — list of `"YYYY-MM-DD"` strings, one per member state; after `deep_flatten_col` becomes a `" / "`-separated character string
- `authorizedApplication.memberStatesConcerned.lastDecisionDate` — same format
- `authorizedApplication.memberStatesConcerned.mscName` — country names, parallel list

`authorizedApplication.applicationInfo.decisionDate` is a **single** application-level date and is often NA for multinational trials — do **not** use it as the sole source.

Derived columns computed in `app.R` (after register detection):

- `ctis_decision_date_first` — minimum of `firstDecisionDate` across all MS, as `"YYYY-MM-DD"` string
- `decision_date_spread_days` — max minus min in days across MS; NA for EUCTR
- `decision_date` — uses `ctis_decision_date_first` for CTIS (falls back to `applicationInfo.decisionDate`)

---

## Completed: All-ages dataset + Age Group filter (v0.9.0) — shipped 2026-04-29

### Branch: feature/all-ages-filter

### What was built

- **All-ages data fetch** — EUCTR and CTIS queries now fetch all age groups (previously paediatric only). DB renamed `pediatric_trials.sqlite` → `trials.sqlite`; cache renamed `pediatric_trials_cache.rds` → `trials_cache.rds`.
- **`age_group` derived column** — "Paediatric" / "Adult" / "Paediatric & Adult" / "Unknown". EUCTR: f11/f12/f13 boolean flags. CTIS: `str_detect(ageGroup, "0-17")` for paediatric, `str_detect(ageGroup, "18-64|65\\+")` for adult.
- **Age Group sidebar filter** — `selectInput("age_group_filter")` pinned at top of filter panel. Choices: `< 18 years` (default) / `≥ 18 years` / `All`. "Paediatric & Adult" trials appear under both. Wired into: `filt()`, `filter_state`, URL restore, `reset_filters`, `badge_trial`, `active_filters_row`.
- **Chart Builder** — "Age Group" added to X-axis and Group-by choices.
- **Resilient ingestion engine** (`update_data.R` v15, rewritten by user) — quarterly date-range chunks with recursive bisection when >10 000 trials. Logs to `data/done_chunks.txt` / `data/failed_chunks.txt`.

---

## Completed: preprocessing.Rmd pipeline audit report — v0.8.2 (2026-04-28)

- `preprocessing.Rmd` knits to `www/preprocessing.html`; linked from About tab
- Documents every normalisation step, deduplication waterfall, and data quality issues
- Transitioned EUCTR → CTIS fallback: base-ID matching added after title_key matching

---

## Completed: Per-million-children normalisation — v0.8.1 (2026-04-28)

- `EU_CHILD_POP` data frame: 108 countries, child_pop in thousands (Eurostat 2023 + UN WPP 2022)
- Map tab: radio button toggles total trials vs trials per million children (0–17)
- Chart Builder: "Normalise by child population" checkbox when x/group = Country

---

## Completed: User feedback batch — v0.8.0 (2026-04-27)

- Recent trials sorted by `decision_date`; rows open trial detail modal
- Mononational toggle button in sidebar; state in URL
- Clickable KPI value boxes update status/PIP filters
- `days_to_decision` negative values set to NA
- Completion Rate by Sponsor Type + by Phase charts added to Phase Analytics

---

## Completed: Results Posting + Orphan tabs — v0.7.0 (2026-04-19)

- `has_results` column: EUCTR `endPoints.endPoint.readyForValues`, CTIS `resultsFirstReceived`
- `is_orphan` column: EUCTR DIMP D.2.5, CTIS `orphanDrugDesigNumber`
- Results Posting tab (tabName="compliance"): overdue table, by-year chart, by-sponsor chart

---

## Completed: Sponsor Comparison tab — v0.5.1 (2026-04-18)

- Dedicated sidebar tab; 6 side-by-side charts for 2–3 selected sponsors

---

## Completed: Chart Builder tab — v0.3.0 (2026-04-06)

- `EXPLORE_MULTI_COLS`: MEDDRA_organ_class, MEDDRA_term, Member_state (require `separate_rows`)
- `EXPLORE_LABELS`: named vector mapping column names → display labels
- `explore_data()` reactive returns `list(data, x_var, grp)`

---

## Completed: Sponsor normalisation — v0.2.4 (2026-04-05)

- `normalize_sponsor_name()`: strips legal suffixes, pharma descriptors, subsidiaries; ~70 canonical brand prefixes
- EUCTR: `b1_sponsor.b11_name_of_sponsor`; CTIS: `authorizedApplication.authorizedPartI.sponsors.organisation.name`

---

## Future ideas (not yet implemented)

- Email notifications on new trials (blastula package in rebuild_cache.R)
- Export Data Explorer to CSV/Excel
- "Copy shareable link" button (URL state already encoded)
- Filter reset per group (× on each details summary)
- PDF report respects active sidebar filters (currently always full dataset)
