# Changelog

## v0.10.4 — 2026-05-05

- **CTIS transition EudraCT matching**: CTIS transition applications now extract `authorizedApplication.eudraCt.eudraCtCode`, the embedded legacy EudraCT number. Cross-register deduplication uses that field to replace EUCTR "Trial now transitioned" rows with the active CTIS record even when the CTIS EU trial number is a new `2024-...` identifier rather than the old EudraCT base.
- **Searchable transitioned-trial aliases**: transitioned CTIS rows keep their old EudraCT number in `transition_eudract_number` and expose `trial_identifiers`, so users can still find the trial by the legacy EudraCT number after the CTIS row is kept as canonical.
- **Preprocessing audit corrected**: the Deduplication Pipeline report now checks transition EudraCT number, CTIS base ID, and `title_key` fallbacks before labelling a transitioned EUCTR trial as unmatched. The previous "no CTIS match found" wording has been narrowed to "unmatched by current fallbacks."
- **Safer deduplication ordering**: transitioned EUCTR rows can now use identifier fallbacks even when their title is short or missing, and title-key-only cross-register drops are limited to records explicitly flagged as transitioned to avoid false merges on generic trial-title prefixes.
- **Latest CTIS amendment protection**: CTIS title/base fallback swaps now keep only the latest amendment version instead of reintroducing older CTIS versions after the first latest-version pass.
- **Source provenance preserved**: CTIS rows with pre-2023 submission dates now keep `register == "CTIS"` and use `analysis_register == "EUCTR"` only for timeline grouping, so filters, links, and source-register counts remain truthful.
- **Register Migration tab**: added a dedicated Analysis tab with a migration signal chart that separates EUCTR source records, CTIS-native records, and CTIS-source records analysed as EUCTR-era migrations over submission year.
- **Canonical duplicate audit**: the preprocessing report now audits duplicate `canonical_trial_id` values rather than exact display `CT_number` strings, catching transition-alias duplicates that exact CT-number checks miss.
- **Cache schema guard**: cached data now rebuilds automatically when the transition alias columns are absent, preventing old caches from masking the new deduplication behavior.
- **CTIS MedDRA organ classes restored**: the CTIS flattener now preserves known numeric EMA MedDRA SOC codes instead of dropping them as generic numeric IDs, allowing `clean_organ_class()` to resolve CTIS organ classes and repopulate the Top MedDRA Organ Classes chart when the Source Register filter is set to CTIS.
- **Migration detection corrected**: `analysis_register` now uses `transition_eudract_number` as the definitive migration signal instead of the CTIS submission date. CTIS stores its own authorization date (2023+) rather than the original EudraCT registration date, so the pre-2023 date heuristic only caught 402 of 3,955 migrated trials.
- **`analysis_year` column**: migrated CTIS trials now carry an `analysis_year` derived from the year encoded in the EudraCT number format (`YYYY-NNNNNN-NN`), placing them in their original registration year in timeline charts instead of 2023–2025.
- **Yearly submission chart corrected**: `plot_yearly` now groups by `analysis_year`, so migrated CTIS trials appear alongside original EUCTR registrations in the correct pre-2023 bars.
- **Migration Completeness gauge**: new plotly indicator on the Register Migration tab showing the fraction of EudraCT-era trials (EUCTR source + CTIS-migrated) that have transitioned to CTIS; filter-aware.
- **Migration Timeline chart**: new dual-axis chart on the Register Migration tab showing new migrations per CTIS authorization month (bars) and cumulative total (line).
- **Sponsor curation workflow tooling**: sponsor alias review scripts were moved into `sponsor_curation/` with a dedicated guide. The workflow now supports interactive review, CSV batch approval, applying approved aliases back into `app.R`, refreshing sponsor names in `trials_cache.rds`, regenerating sponsor logs/candidates, and updating the manual-curation baseline without needing Codex.
- **Resumable sponsor review**: `sponsor_curation/review_sponsor_aliases.R` now saves both approvals and skips to `config/sponsor_review_decisions.csv`, resumes after previously reviewed candidates, reports how many candidates remain, and avoids killing the R session when sourced from RStudio.

## v0.10.3 — 2026-05-04

- **Persistent sidebar comparison report button**: replaced the custom sidebar shortcut that attempted to click the Tools-tab download link with a real Shiny `downloadButton`, so "Compare Paediatric vs Adult" works from the side panel even when the Tools tab is not active.
- **Shared comparison report handler**: extracted the comparison PDF `downloadHandler` into a reusable helper and wired both the persistent sidebar button and the Tools-tab button to it. The generated filename, active filter handling, age-group exclusion logic, TinyTeX/PDF checks, and `comparison_report.Rmd` rendering path now stay identical for both entry points.

## v0.10.2 — 2026-05-04

- **Map normalisation by selected age group**: the Map tab now changes its per-million option according to the sidebar Age Group filter. Paediatric mode keeps the existing "Per million children (0-17)" denominator, adult mode uses "Per million adults (18+)", and All uses "Per million total population". Adult and total denominators use 2026 total-population estimates from Worldometer/UN Population Division, with adult population derived as total minus the existing child-population denominator.
- **Chart Builder age-aware country normalisation**: the country/member-state per-million checkbox now uses the same denominator as the selected Age Group filter: children for paediatric, adults for adult, and total population for All. Plot y-axis labels and summary-table headers update with the chosen denominator.

## v0.10.1 — 2026-05-04

- **Dynamic plot container heights**: the Top Sponsors box now auto-sizes to the selected Top N slider value so larger sponsor lists do not overflow their containing box. The CTIS multinational decision-date spread chart box now uses automatic height instead of clipping the violin plot.
- **Violin/box plot hover details**: removed the custom `hoverinfo` override so Plotly's default box/violin summaries are visible again, including Q1, median, Q3, minimum, and maximum. Log-axis labels now use plain `log10` text for clearer rendering.
- **Result Reporting KPI percentages**: the Academic and Industry "no results" KPI cards now show each group's percentage of all completed trials, matching the Results Posted card's denominator and making the compliance strip easier to compare.
- **Terminology cleanup**: renamed "Results Posting" to "Result Reporting" throughout the app UI and documentation for clearer wording.
- **Initial loading overlay timing**: the custom startup overlay now hides after the initial Shiny render reaches `shiny:idle`, with a short minimum display time and a 15-second fallback. This avoids exposing the half-themed default AdminLTE screen on shinyapps/Posit Cloud while still preventing a stuck overlay if startup fails.

## v0.10.0 — 2026-05-04

- **Country Comparison tab**: new Analysis sub-tab to compare trial activity across 2–3 EU member states side-by-side. Shows phase distribution, trial status, sponsor type, PIP status, top organ classes, submissions per year, and result reporting. Mirrors the Sponsor Comparison layout with a Count/Percentage toggle.
- **Example questions — tab redirect**: "How do the clinical trials between Belgium and Croatia differ?" applies the country filter and navigates directly to Country Comparison. "How does the portfolio of GSK, Novartis and Roche compare?" selects all three sponsors and navigates to Sponsor Comparison.

## v0.9.9 — 2026-05-03

- **Grouped sidebar navigation**: Basic Analytics, Phase Analytics, Sponsor Comparison, Country Comparison, and Result Reporting are nested under a collapsible "Analysis" parent item. Data Explorer remains a standalone top-level item below Map.
- **Submenu theming**: added dedicated sidebar submenu CSS for dark and light Nord themes, including hover, active, and indentation styling.
- **Changelog split**: full version history moved into `CHANGELOG.md`; README and the About tab now keep only the latest release entry and link to the full changelog.
- **Project instructions**: `AGENTS.md` now requires `CHANGELOG.md` updates whenever the project version is bumped.

## v0.9.8 — 2026-05-02

- **Example questions replace quick filters**: the overview footer now shows four conversational example questions instead of pill-shaped preset buttons. Each question applies the relevant sidebar filters in one click: "Which trials have been authorized in the last 12 months?", "What are the open trials for neuroblastoma in Belgium?", "How is the evolution of the PIPs in the past 10 years?", and "How does the portfolio of Novartis differ between paediatrics and adults?" (sets sponsor filter; see the Compare button). The Novartis preset uses server-side selectize correctly (choices + selected passed together).
- **Compare Paediatric vs Adult button promoted**: the button is now displayed prominently in the main sidebar directly below the navigation menu, always visible without switching to the Tools tab. The existing Tools tab button is retained.
- **Navigation cards — CSS grid**: the two mismatched `fluidRow`/`column` blocks (4 × col-3 + 3 × col-4) are replaced with a single `display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr))` container. Cards reflow cleanly at any screen width. Data Explorer card removed from the grid.
- **Removed orientation tips strip**: the three-column "Use sidebar filters / Shareable URL / Select a feature below" banner is removed from the overview page.

## v0.9.7 — 2026-05-02

- **Light theme now default**: Nord Light is the default appearance. Theme selector ("Dark" / "Light") in the sidebar Tools tab. Full sidebar theming via JS inline-style override (definitive — survives all CSS cascade). Sidebar nav text, filter group labels, open-state summaries, button text, and link colours all correctly themed for both modes.
- **Overview page — orientation strip**: a compact 3-column tips bar now appears at the top of the Overview page, pointing users to the sidebar filters, KPI card interactions, and feature navigation.
- **Overview page — Phase Analytics nav card added**: Phase Analytics was the only feature tab missing from the overview quick-start grid. The 6-card single-row layout is replaced with a 4+3 two-row grid (4 × `column(3)` + 3 × `column(4)`), with a labelled section header "Explore the Dashboard".
- **Overview page — KPI click hint**: a small right-aligned text line below the KPI strip reads "Click any card to filter the dashboard by that group."
- **Results Posting — KPI parity**: replaced the four old AdminLTE `valueBox` widgets with the same custom kpi-card style used on the overview. Cards: Completed Trials (green), Results Posted with % (blue), Academic — no results (yellow), Industry — no results (orange). Theme-aware colours via `tc()`.

## v0.9.5 — 2026-05-01

- **Overview page redesigned**: KPI cards now use full Nord accent colours (blue / green / yellow / purple) with white text and are sized appropriately. The hero subtitle is displayed in the top navbar. Six clickable navigation shortcut cards link directly to each feature tab. Nine quick-filter preset buttons (CTIS only, EUCTR only, Ongoing PIP trials, Orphan designation, Completed trials, Last 12 months, Last year, Adult trials, Paediatric trials) apply sidebar filters in one click. The 5 most recently authorized trials table is restored at the bottom of the overview.
- **AdminLTE theming replaced with `fresh`**: removed the hand-crafted 90-line `generate_css()` `sprintf` template that was losing CSS specificity battles against AdminLTE defaults (e.g. box headers rendering in the wrong orange). Replaced with `fresh::create_theme()` which compiles AdminLTE SASS variables at the correct level — box header colours, sidebar background, body background, and button colours are now set at source. A slim `generate_supplement_css()` covers elements `fresh` does not reach (DataTables, modals, sliders, links, filter chips, navbar background, button text).
- **Nord dark theme polished**: sidebar is now darker (`bg0`) than the main content panel (`bg1`), improving visual depth. Plotly chart backgrounds aligned with their containing box. Muted box solid headers. Download PDF and Compare buttons have white text. Save / Load buttons have proper vertical spacing.
- **Nord Light theme fixed**: dark sidebar with light main panel now correctly themed throughout — sidebar form controls, labels, tab links, and dropdown backgrounds all use the dark Nord palette; nav cards use a light overlay appropriate for the light main background.
- **Chart background consistency**: plotly `chart_bg` updated to match the box background (`bg2`), eliminating the visible dark rectangle inside chart boxes.
- **Theme selector hidden**: app defaults to Nord dark; the radio buttons remain in the DOM for future use but are hidden from the UI.

## v0.9.4 — 2026-04-30

- **Data Explorer**: fixed duplicate tokens in slash-separated fields (e.g. Product name). `deep_flatten_col` now trims whitespace before `unique()` so near-identical values collapse correctly; a dedicated `dedup_slash` pass is applied to `DIMP_product_name` after MedDRA cleaning.

## v0.9.3 — 2026-04-30

- **Compare Paediatric vs Adult report**: new parameterized PDF report (xelatex) downloadable from the Tools tab. Compares both age groups across status, phase, sponsor type, PIP, orphan designation, results posting, submission/decision timelines, therapeutic areas (top 15), and geographic distribution (top 20). Applies all active sidebar filters except age group so both populations are always present.

## v0.9.2 — 2026-04-30

- **CTIS decision date fix**: decision date now uses the earliest per-country member-state decision date (`memberStatesConcerned.firstDecisionDate`) instead of the application-level date, which was NA for many multinational trials.
- **CTIS submission date fix**: `submissionDate` is a per-amendment list; now takes the minimum (first submission) date, fixing empty `submission_date_parsed` / `year` / `days_to_decision` for many CTIS trials.
- **New graph**: Decision Date Spread Within CTIS Multinational Trials — violin plot grouped by number of member states (2 / 3 / 4 / 5+), log₁₀ y-axis.

## v0.9.1 — 2026-04-29

- **Preprocessing report**: added a standalone Age Group Coverage section for Paediatric / Adult / Paediatric & Adult / Unknown classifications, plus filter inclusion counts and register split.
- **Preprocessing audit fixes**: corrected the deduplication waterfall after the all-ages cache rename, restored EUCTR cache-base examples, and rendered the updated `www/preprocessing.html`.
- **Data pipeline**: `update_data.R` v18 refreshes CTIS by default and makes EUCTR opt-in; EUCTR result documents can be refreshed explicitly with `--euctr-results` or `FORCE_RESULTS=true`. Explicit EUCTR refreshes still bisect failures down to single-day ranges before trial-level fallback, with bounded retries/timeouts for fallback URL reads.
- **Docs and report paths**: updated remaining cache/database references to `trials.sqlite` and `trials_cache.rds`.

## v0.9.0 — 2026-04-29

- **All-ages dataset**: EUCTR and CTIS queries now fetch all age groups (not just paediatric). Database renamed from `pediatric_trials.sqlite` → `trials.sqlite`; cache renamed to `trials_cache.rds`. Total trials roughly doubled to ~17 500.
- **Age Group filter**: selectInput pinned at the top of the sidebar (`< 18 years` / `≥ 18 years` / `All`). Defaults to `< 18 years` to preserve existing behaviour. Trials enrolling both age groups appear under both filters. Wired into URL state, reset, active filter chips, and badge counter.
- **Chart Builder**: "Age Group" added as an X-axis and Group-by option (Paediatric / Adult / Both / Unknown).
- **Data pipeline — resilient ingestion engine** (`update_data.R` v15): quarterly date-range splitting with recursive bisection when a range exceeds the 10 000-trial EUCTR limit. Completed and failed chunks logged to `data/done_chunks.txt` / `data/failed_chunks.txt` so interrupted runs resume from where they left off.

## v0.8.2 — 2026-04-28

- **Pipeline audit report**: `preprocessing.Rmd` added — knits to `www/preprocessing.html` (linked from the About tab). Documents every normalisation step, deduplication counts with real intermediate row totals, before/after examples, and a severity-ranked data quality issue list with `app.R` fix suggestions.
- **Data pipeline**: transitioned EUCTR trials now matched to CTIS counterparts by base ID (strip country/version suffix) as a fallback after title_key matching — catches cases where the trial title changed during the EUCTR→CTIS transition.

## v0.8.1 — 2026-04-28

- **Map — per million children**: radio button in the map box toggles between total trial counts and trials per million children (0–17). Population data from Eurostat 2023 (EU/EEA) and UN WPP 2022 (all other countries); covers all 108 countries in the map. Countries with no population data (Liechtenstein) shown in grey with a note.
- **Chart Builder — normalise by child population**: a "Normalise by child population" checkbox appears below the controls when the x-axis or group is set to "Country / Member State". Divides each country's count by its own child population. Column header in the summary table updates to "Trials / M children".

## v0.8.0 — 2026-04-27

- **Recent trials table**: sorted by authorization date (was submission date); rows clickable — opens the same trial detail modal as the Data Explorer.
- **"Register Comparison" renamed** to "Trial Status by Register".
- **Mononational filter**: toggle button in Geography & Sponsor sidebar section below the Country filter; state encoded in URL; shows active badge and filter chip.
- **Clickable KPI value boxes**: clicking Ongoing/Completed filters trial status; clicking Total resets; clicking PIP sets PIP filter to Yes.
- **Results Posting tab**: new "Completed Trials With Results Posted" table with download button, above the existing overdue list.
- **Sponsor Comparison**: note added explaining that percentages are calculated within each sponsor's own portfolio.
- **Days to decision — data quality**: negative values (decision before submission, impossible in practice) now set to NA during cache build rather than silently dropped chart-by-chart. Requires cache rebuild.
- **Days to Decision by Sponsor Type**: changed from overlapping violin plot to grouped box plot (EUCTR / CTIS side-by-side per sponsor type).
- **Trial Phase by Sponsor Type**: changed from grouped to stacked bar chart, consistent with the other phase charts.
- **Phase Analytics — two new completion rate charts**: Completion Rate by Sponsor Type (line chart, Academic vs Industry) and Completion Rate by Phase (bar chart, Phase I–IV).

## v0.7.1 — 2026-04-20

- **Nord Light theme**: palette and CSS added to codebase (hidden from theme selector while in development).
- **PDF report**: switched LaTeX engine from pdflatex to xelatex to fix Unicode crash (`≥` and other characters from trial data breaking PDF generation); Helvetica font set via `fontspec` with automatic fallback to TeX Gyre Heros on Linux.
- **Violin plots (log scale)**: Time from Submission to Decision and Days to Decision by Sponsor Type now use a log₁₀ y-axis; data is pre-transformed before kernel density estimation so violin shapes are correct.

## v0.7.0 — 2026-04-19

- **Results Posting tab**: shows which completed trials have posted results to the registry and which have not, using real registry data (`endPoints.endPoint.readyForValues` for EUCTR; `resultsFirstReceived` for CTIS). Value boxes (completed total, results posted %, academic/industry without results), bar chart by authorization year, breakdown by sponsor type, downloadable CSV.
- **Orphan Designation filter**: derived from EUCTR DIMP D.2.5 field and CTIS orphan designation numbers; fully integrated with URL state, reset, and active filter chips.

## v0.6.1 — 2026-04-19

- Data pipeline: trials with NA status now classified as Other instead of being silently excluded.
- Additional cross-register deduplication: EUCTR records with a matching CT number or normalised title in CTIS are dropped in favour of the CTIS copy.
- Pre-2023 CTIS records (migrated from EudraCT) relabelled as EUCTR so the Submissions per Year chart shows CTIS bars only from 2023 onward.
- Sidebar trial count bar showing filtered / total trials.
- Basic Analytics: Top MedDRA Organ Classes and Top Conditions charts expanded to full width.

## v0.6.0 — 2026-04-18

- Sidebar filters and tools split into Filters / Tools tabs to reduce scrolling.
- Filters reordered: date range and free-text at top, then sponsor and country.
- Trial Status and Source Register converted from checkboxes to selectize dropdowns.
- Active filter chips redesigned as two-tone pills.
- Tools tab: compact full-width Save / Load / PDF / Theme buttons.

## v0.5.1 — 2026-04-18

- Sponsor Comparison promoted to a dedicated sidebar tab with contextual help.
- PIP Unknown category displayed in amber.
- Removed Cumulative Trials by Start Date from Overview.

## v0.5.0 — 2026-04-18

- Free-text search now includes sponsor name.
- Phase Funnel chart (Phase Analytics).
- Completion Rate by Authorization Cohort line chart.
- Sponsor Comparison section in Analytics (when 2–3 sponsors selected).

## v0.4.0 — 2026-04-15

- Trial detail modal (click any row in Data Explorer).
- URL state: filters encoded in `?f=` query string.
- Active filter chips with Reset all.
- Violin plot for days-to-decision by sponsor type.
- Empty-state messages on charts; plotly toolbar with PNG export.

## v0.3.0 — 2026-04-06

- Chart Builder tab: custom bar/line charts with freely chosen X axis, grouping, and four chart types; included in PDF report.

## v0.2.4 — 2026-04-05

- Sponsor name normalisation (legal suffix stripping, canonical brand mapping, ~28% reduction in duplicate names).
- Sponsor filter, Top Sponsors bar chart, Sponsor Trial Timeline.
- Seven normalisation logs written to `data/` on each cache rebuild.

## v0.2.3 — 2026-03-30

- Data Explorer: Decision Date column added.
- Basic Analytics: violin plot of days from submission to decision, split by register.

## v0.2.2 — 2026-03-30

- Data pipeline: EUCTR download skipped when query URL unchanged since last run; nightly updates re-fetch only CTIS (~5 min) unless search criteria change.


## v0.2.1 — 2026-03-29

- MedDRA spelling normalisation (leukemia → leukaemia, tumor → tumour, etc.) and Roman numeral type notation converted to Arabic (Type I → Type 1).

## v0.2.0 — 2026-03-29

- Filter save/restore: download active filter settings as JSON; re-upload to restore in any session.
- PDF report: full summary PDF for any filter selection via sidebar.

## v0.1.5 — 2026-03-29

- Analytics split into Analytics and Phase Analysis tabs.

## v0.1.4 — 2026-03-28

- Sidebar: Trial Phase filter added.
- Analytics: Phase charts by register, status, and sponsor type.

## v0.1.3 — 2026-03-28

- Map tab: interactive Leaflet map of ongoing trials by country; trial table at zoom ≥ 5.

## v0.1.1 — 2026-03-28

- Overview: Sponsor Type by Register chart; CT numbers as clickable links.
- Analytics: PIP Status by Year chart; MedDRA SOC code resolution.

## v0.1.0

Initial release.
