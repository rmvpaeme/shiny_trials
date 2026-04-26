when committing, update the version number everywhere in the code, update the readme and about with the changelog and commit all changes to github

update CLAUDE.md every time the project has a git commit (add a section for the version/feature with what was built)

when making a new version, update the rmd file to reflect the most recent changes.

## Completed: Sponsor / Company feature (v0.2.4) — shipped 2026-04-05

### What was built
- normalize_sponsor_name() function added (app.R ~line 347)
  - Strips legal suffixes (GmbH Co. KG, Inc., Ltd., SA, SL, DAC, A/S, LP, ...)
  - Strips pharma-descriptor words (Pharmaceuticals, Pharma, Biotech, ...)
  - Strips country/region subsidiaries (Deutschland, France, Europe, ...)
  - Strips "a wholly-owned subsidiary of..." and department qualifiers
  - Strips "- [long acronym expansion]" patterns
  - Title-cases non-abbreviation strings; leaves dotted abbreviations (A.I.E.O.P.) intact
  - Brand-prefix extraction for ~70 known pharma companies -> canonical names
  - 2724 raw EUCTR names -> 1981 normalized (28% reduction, 0 case-only duplicates)
- EUCTR sponsor field: b1_sponsor.b11_name_of_sponsor
- CTIS sponsor field: authorizedApplication.authorizedPartI.sponsors.organisation.name
  (confirmed 1446 non-NA values; .organisationName without .organisation was wrong — all NA)
- sponsor_name column created in prepare_trial_data()
- raw_sponsor captured before normalization so log can compare raw vs normalised
- Sponsor normalisation log written to data/sponsor_normalisation_log.csv on each cache
  rebuild (columns: register, raw, normalised, n_trials, changed)
- selectizeInput("sponsor_filter", ...) added to sidebar
- updateSelectizeInput for sponsor_filter in observe block
- Filter logic added to filt() reactive and map reactive
- sponsor_filter added to save/restore JSON
- "Top Sponsors / Companies" box added to Analytics tab UI
- output$plot_top_sponsors server render added
- Sponsor Trial Timeline (uiOutput("sponsor_timeline_ui")) — appears only when exactly
  one sponsor is selected; dual-axis plotly: bars = new trials/year, line = cumulative
- sponsor_name + sponsor_type columns added to Data Explorer table
- top_sponsor_tab pre-compute + bar chart + table added to report.Rmd
- Version bumped to v0.2.4 in app.R header, About tab footer, README.md
- README corrected: Analytics chart list, Data Explorer columns, sidebar filter table,
  project structure, data pipeline steps
- Committed and pushed to GitHub (commits 86b4ae0, fbcb58b, d2f49e2)

## Completed: Chart Builder tab (v0.3.0) — shipped 2026-04-06

### What was built
- New "Chart Builder" tab added as second item in sidebar (after Overview, before Map)
- Tab name: `tabName="chartbuilder"`, label "Chart Builder", icon: chart-line
- "Analytics" renamed to "Basic Analytics"; "Phase Analysis" renamed to "Phase Analytics"

#### UI controls (4 columns)
- **X axis** (`explore_x`): Year of submission, Status, Register, Phase, Sponsor Type, PIP Status, Organ Class (MedDRA SOC), Condition (MedDRA term), Country / Member State
- **Group by** (`explore_group`): same options as X axis + "None" (default)
- **Chart type** (`explore_chart_type`): Bar (stacked), Bar (grouped), Bar (100% stacked), Line
- **Max groups shown** slider (`explore_top_n`, 3–20): visible only when group != None

#### Server
- `EXPLORE_MULTI_COLS`: columns requiring `separate_rows` before aggregation: MEDDRA_organ_class, MEDDRA_term, Member_state
- `EXPLORE_LABELS`: named vector mapping column names → display labels
- `explore_data()` reactive: handles multi-value splitting for both x_var and grp; returns `list(data, x_var, grp)` where data has columns `x_val`, `grp_val` (if grouped), `n`
- `output$explore_note`: shows info note when X or group is a multi-value column
- `output$plot_explore`: bar (stacked/grouped/100%), line — all use `x_val` from reactive; year axis gets integer tick formatting; palette from colorRampPalette of theme colours
- `output$table_explore`: aggregated counts table, column headers pulled from EXPLORE_LABELS

#### What was NOT built / removed
- Heatmap: removed after initial implementation
- Scatter plot: removed after initial implementation (X/Y axis selectors, explore_scatter_data reactive, SCATTER_VAR_LABELS — all gone)

## Completed: Extended normalisation logging (2026-04-06)

### Changes

- write_norm_log() helper function added (app.R ~line 532, section 5)
  - Generic helper: takes raw_vec, norm_vec, register_vec, type_name, log_dir
  - Writes CSV with columns: register, raw, normalised, n_trials, changed
  - Used for all normalisation steps below
- Normalisation logs now written on every cache rebuild to data/:
  - country_normalisation_log.csv — Member_state raw → clean_member_state() output
    (captured post-unite, before whitespace trim; shows country alias resolution, junk removal)
  - meddra_term_normalisation_log.csv — MEDDRA_term raw → clean_meddra_term() output
    (spelling fixes, Roman numeral → Arabic, deduplication)
  - organ_class_normalisation_log.csv — MEDDRA_organ_class raw → clean_organ_class() output
    (strip numeric prefix, CTIS code lookup, canonical form correction)
  - phase_normalisation_log.csv — raw phase (EUCTR: flag-derived labels; CTIS: trialPhase text) → phase
    (CTIS text like "Therapeutic confirmatory (Phase III)" → "Phase III")
  - status_category_normalisation_log.csv — status_raw_orig → status (Ongoing/Completed/Other)
  - status_display_normalisation_log.csv — status_raw_orig → status_raw (display string cleanup)
  - sponsor_normalisation_log.csv — already existed; unchanged
- MedDRA/organ class pipeline split into two steps to allow raw capture before cleaning
  (app.R ~line 833: aggregation join + if_else first, then separate mutate for vapply cleaning)
- Country log captured post-unite, pre-whitespace-trim (app.R ~line 711)
- Status logs captured before select(-status_raw_orig) removes the raw column (app.R ~line 961)
- Phase raw capture added before the phase mutate block (app.R ~line 1023)

## Completed: UI improvements (v0.4.0) — shipped 2026-04-15

### Branch info
- Branched from main (commit 229e2c5 "shinylive"), merged/committed on ui-improvements branch
- shiny_fluent branch work is stashed (shiny.fluent UI rebuild, not yet merged/committed)

### What was built
- **Trial detail modal** — clicking a row in Data Explorer opens a `modalDialog()` with full trial record (title, CT number link to EUCTR/CTIS, register, status, phase, sponsor, MedDRA, countries, dates). Uses `selection = list(mode="single", target="row")` on trials_table DT + `observeEvent(input$trials_table_rows_selected, ...)`
- **URL state** — filters encoded as base64 JSON in `?f=` query param via `base64enc::base64encode()` + `jsonlite::toJSON()`. `updateQueryString()` updates URL on filter change (debounced). `observeEvent(rv$data, ..., once=TRUE)` restores on load. NOTE: `observe({...}, once=TRUE)` is invalid — must use `observeEvent(..., once=TRUE)`
- **Active filter chips** — `uiOutput("active_filters_row")` renders colored chip badges for each non-default filter above tab content. Style: `#eaf2fb` background, `2px solid #3c8dbc` top border, `margin-bottom:18px`. "Reset all" `actionButton("reset_filters")` clears all filters to defaults
- **Decision time by sponsor type** — new `output$plot_decision_time_sponsor` violin plot in Basic Analytics splitting days-to-decision by Academic vs Industry sponsor type
- **Section headers** — "Therapeutic Areas", "Geography & PIP", "Sponsors" `h4()` headings in Basic Analytics tab using `.analytics-section-header` CSS class
- **Empty-state illustrations** — `empty_state()` helper returns centered div with search icon + message when no data matches filters. Applied to major chart outputs via `plotly_empty() %>% layout(...)` pattern
- **Plotly export button** — `plt_layout()` now includes `%>% config(displayModeBar=TRUE, displaylogo=FALSE, modeBarButtonsToRemove=list(...))` so camera/download toolbar is always visible
- **Responsive metric cards** — CSS media queries: ≤768px → 2 cards/row; ≤480px → 1 card/row
- **PDF chart builder** — was already fully implemented in v0.3.0 (app.R dl_report passes `explore_data()` + `chart_type` to report.Rmd which has a "Custom Chart Builder" section)

### What was NOT built / removed
- Country choropleth map — removed per user request ("less clear than circle markers")
- YoY delta trend on organ class chart — removed per user request
- shiny.fluent UI rebuild — that work is on the stashed `shiny_fluent` branch, not included here

## Completed: Analytics improvements (v0.5.0) — shipped 2026-04-18

### What was built
- **Free-text search** — sponsor_name added to search (filt() and eu_map_ongoing() reactives)
- **Phase funnel** — `output$plot_phase_funnel`: plotly funnel chart of Phase I–IV distribution with % of total labels; new box in Phase Analytics tab below existing 3 charts
- **Completion cohort chart** — `output$plot_completion_cohort`: line chart of % completed by authorization year, split by register; uses `year(decision_date)` + `status == "Completed"`; cohorts with < 5 trials filtered out; in same row as funnel
- **Sponsor comparison** — `output$sponsor_compare_ui` + `plot_compare_phase` + `plot_compare_status` + `plot_compare_organ`: appears only when 2–3 sponsors selected; shows phase, status, and top 8 organ class grouped bar charts side-by-side; uses `compare_pal()` reactive for consistent colours across the 3 charts
- **Removed eulerr** — `has_eulerr` / `library(eulerr)` lines removed (were unused)

## Completed: Sponsor Comparison tab + polish (v0.5.1) — shipped 2026-04-18

### What was built
- Sponsor Comparison promoted to dedicated sidebar tab (between Phase Analytics and About)
- `output$sponsor_compare_tab_ui`: 0 sponsors → help, 1 → prompt, 4+ → error, 2–3 → 6 charts (phase, status, organ class, country, PIP, year)
- PIP Unknown colour changed from `t$fg` to `t$yellow` in `plot_compare_pip`
- Removed Cumulative Trials by Start Date from Overview; Sponsor Type by Register spans full row
- README rewritten from scratch (accurate tab list, updated feature descriptions, removed eulerr from install)
- manuscript.md: abstract (8 modules), Phase Analytics description updated, new Sponsor Comparison paragraph, version updated to 0.5.1
- report.Rmd: Phase Distribution funnel chart + Completion Rate by Authorisation Cohort added to Trial Phases section

## Completed: Research Analytics (v0.7.0) — shipped 2026-04-19, branch feature/research-analytics

### What was built

- **Compliance tab** (tabName="compliance") — new sidebar menu entry with icon "shield-alt"
  - 4 value boxes: Completed Trials, With Results Posted, Academic no-results >12mo, Industry no-results >12mo
  - `output$plot_results_compliance_overview`: stacked bar by auth year colored by "Results posted" / "Within 12mo" / "12-24mo missing" / ">24mo missing"
  - `output$plot_results_by_sponsor`: stacked bar Academic vs Industry — OK vs missing
  - `output$plot_results_by_area`: horizontal bar top-15 organ classes by missing results count
  - `output$table_overdue` + `output$dl_overdue_list`: DT table + CSV download of overdue trials
  - `compliance_base()` reactive: completed trials with decision_date, used by all compliance outputs
- **Orphan designation** — real data from registry
  - EUCTR: `dimp.d25_the_imp_has_been_designated_in_this_indication_as_an_orphan_drug_in_the_community` (Yes/No per DIMP product) → `is_orphan` column
  - CTIS: `authorizedApplication.authorizedPartI.products.orphanDrugDesigNumber` (EU/3/... numbers) → non-NA = "Yes"
  - `orphan_filter` selectInput in sidebar "Trial" section
  - Plumbed into `filt()`, `reset_filters`, `filter_state`, URL restore, `badge_trial`, `active_filters_row`
- **Results posted** — real data from registry
  - EUCTR: `endPoints.endPoint.readyForValues` (non-NA = results section populated) → `has_results` column
  - CTIS: `resultsFirstReceived` (TRUE/FALSE) → `has_results` column
  - Cache must be rebuilt for has_results/is_orphan to activate; Compliance tab degrades gracefully without it
- **Co-participation heatmap** — added to Map tab (below existing map + table)
  - `sliderInput("copara_n")` to control number of countries shown (5–30, default 20)
  - `output$plot_copara`: plotly heatmap of trial co-participation counts via self-join on `_id`
  - Ordered by trial count; diagonal blank; symmetric matrix
- **Phase Pipeline by Authorization Year** — added to Phase Analytics
  - `output$plot_phase_pipeline`: stacked bar Phase I–IV by auth_year (decision_date); uses separate_rows for multi-phase trials
- **Completion Rate vs Cohort Age** — added to Phase Analytics (survival-style chart)
  - `output$plot_trial_survival`: bubble scatter — x=cohort age (years), y=% completed, bubble size=cohort size, color=register; cohort year as text label
  - Approximates a KM survival curve without requiring individual completion dates
- Version bumped to v0.7.0 in header, About tab changelog, footer

## Completed: UI trimming + README overhaul (v0.7.0 patch) — shipped 2026-04-19

### What was removed
- **Country Co-participation Heatmap** — removed from Map tab UI (`copara_n` sliderInput + `plot_copara` plotlyOutput box) and `output$plot_copara` server function
- **Phase Pipeline & Cohort Duration** — removed section header + both boxes (`plot_phase_pipeline`, `plot_trial_survival`) from Phase Analytics UI, plus `output$plot_phase_pipeline` and `output$plot_trial_survival` server functions
- **Text labels in Results Posting by Sponsor Type** — replaced `text`/`hoverinfo` with `customdata`/`hovertemplate` (hover still works, no bar text annotations)
- **Missing Results by Organ Class (top 15)** — removed box from Compliance tab UI (Results Posting by Sponsor Type now spans full width 12), plus `output$plot_results_by_area` server function
- **"Geographic equity analysis" example use** — removed from README (referenced deleted heatmap)

### README overhaul
- Added **Source data** section: register table (EUCTR/CTIS), exact search URLs, explanation of incremental update logic and euctrresults fetching
- Added author/license to header
- Added `RSQLite` + `DBI` to install list
- Clarified `update_data.R` (fetch) vs `rebuild_cache.R` (cache-only) distinction in deploy steps
- Added Docker Compose instructions
- Added **Technology stack** table
- Added **Configuration** table (DB_PATH, DB_COLLECTION, CACHE_PATH)
- Expanded project structure to list all 7 normalisation logs + docker-compose.yml
- Improved `rows_update` Known Issue with monkey-patch explanation
- Extended changelog back to v0.1.0 (was truncated at v0.2.4)
- Updated tabs table and example uses to reflect deleted features

## Completed: Nord Light theme (v0.7.1) — shipped 2026-04-20

### What was built
- `THEMES[["Nord Light"]]` added to THEMES list in app.R (~line 119)
  - bg0–bg3: Nord Snow Storm palette reversed (ECEFF4 lightest → C4CEDE darkest) for body, sidebar, inputs, borders
  - fg0–fg2: Nord Polar Night (2E3440 darkest → 434C5E medium) for text — inverted vs Nord dark
  - Frost, Aurora, status, register colours identical to Nord dark (work on both light/dark)
  - chart_bg/chart_fg/chart_grid set for light background rendering
- `NORD_LIGHT_CSS` pre-computed after `NORD_CSS` (~line 244):
  - `generate_css(THEMES[["Nord Light"]])` + appended overrides for `.bg-yellow`, `.bg-green`, `.bg-blue` to force `color:#2E3440` (dark text on aurora-coloured value boxes)
- `output$active_theme` refactored from `if/else` to `switch()` handling Nord / Nord Light / Default
- Radio buttons: `"Nord Light"` present in choices list but NOT exposed in UI (hidden until development complete)
- Version bumped to v0.7.1 in app.R header, About tab changelog entry + footer, README header + changelog

## Completed: PDF fix + log-scale violins (v0.7.1 patch) — shipped 2026-04-20

### What was built
- **PDF LaTeX engine** — `report.Rmd` switched from `pdflatex` to `xelatex` (line 7)
  - Fixes runtime crash when trial data contains Unicode characters (e.g. `≥`, `–`, `±`) that end up in kable table cells
  - `\usepackage{helvet}` + `\renewcommand{\familydefault}{\sfdefault}` replaced with `\usepackage{fontspec}` + `\IfFontExistsTF{Helvetica}{...}{...}` fallback to TeX Gyre Heros for Linux/shinyapps.io
- **Violin plots — log₁₀ scale** — both `plot_decision_time` and `plot_decision_time_sponsor` in app.R, and the `decision-violin` chunk in report.Rmd
  - Root cause of bad shapes: plotly computes KDE on raw values then stretches axis — violin collapses to a line
  - Fix: pre-transform data with `log10(pmax(days_to_decision, 1))`, plot on linear axis, use custom `tickvals`/`ticktext` to show readable day labels (1, 10, 30, 100, 365, 1000, 3650)
  - Hover text shows original day count
  - report.Rmd uses `scale_y_log10(labels = comma)` (ggplot2 handles KDE correctly on transformed scale)

## Current version: v0.7.1

## README audit (2026-04-06)

### Known Issues
- **EUCTR `rows_update` errors**: still accurate; stale "in-app update button" reference removed
- **CTIS country field**: still accurate
- **MedDRA classification divergence**: still accurate
- **Overlap detection accuracy**: still accurate
- **Cache invalidation**: still accurate

### Other fixes applied
- Data pipeline diagram: tab names updated (Phase Analysis → Phase Analytics, etc.)
- Project structure: added rebuild_cache.R; expanded data/ to list all 7 normalisation logs
- Key processing steps: sponsor normalisation description updated; new "Normalisation logs" paragraph added covering all 7 log files
- Docker image version still shows 0.2.1 — intentionally not changed (depends on whether Docker image was rebuilt)

### Residual notes
- `eulerr` is conditionally loaded in app.R (~line 21) but never used in any chart output — worth removing

## Future ideas (not yet implemented)

### Email notifications on new trials
Use `blastula` package in `rebuild_cache.R`. After `prepare_trial_data()` runs, diff new vs old CT numbers; if any new IDs found, compose and send an HTML email via `blastula::smtp_send()`. Credentials stored via `blastula::create_smtp_credentials()` (keychain). Schedule `rebuild_cache.R` via cron (macOS/Linux) or Task Scheduler (Windows). Example code was discussed 2026-04-19.

### Other pending ideas
- Export Data Explorer to CSV/Excel (download button on DT table)
- Time-to-decision histogram (days from submission to decision)
- Trial status over time stacked area chart
- "Copy shareable link" button in Tools tab (URL state already encoded)
- Empty state on map when 0 countries match filters
- Filter reset per group (× on each details summary)
- PDF report respects active sidebar filters (currently always full dataset)
- Lazy tab rendering (only fire expensive plots when tab is viewed)
