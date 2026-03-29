# ============================================================================
# app.R  (v2.0 — filter save/restore + PDF report export)
# ============================================================================

suppressPackageStartupMessages({
  library(shiny)
  library(shinydashboard)
  library(shinycssloaders)
  library(ctrdata)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(stringr)
  library(lubridate)
  library(DT)
  library(plotly)
  library(leaflet)
})


has_eulerr <- requireNamespace("eulerr", quietly = TRUE)
if (has_eulerr) library(eulerr)

# ── EMA CTIS MedDRA SOC code lookup ──────────────────────────────────────────
ctis_soc_lookup <- c(
  "100000004848" = "Investigations",
  "100000004849" = "Cardiac disorders",
  "100000004850" = "Congenital, familial and genetic disorders",
  "100000004851" = "Blood and lymphatic system disorders",
  "100000004852" = "Nervous system disorders",
  "100000004853" = "Eye disorders",
  "100000004854" = "Ear and labyrinth disorders",
  "100000004855" = "Respiratory, thoracic and mediastinal disorders",
  "100000004856" = "Gastrointestinal disorders",
  "100000004857" = "Renal and urinary disorders",
  "100000004858" = "Skin and subcutaneous tissue disorders",
  "100000004859" = "Musculoskeletal and connective tissue disorders",
  "100000004860" = "Endocrine disorders",
  "100000004861" = "Metabolism and nutrition disorders",
  "100000004862" = "Infections and infestations",
  "100000004863" = "Injury, poisoning and procedural complications",
  "100000004864" = "Neoplasms benign, malignant and unspecified (incl cysts and polyps)",
  "100000004865" = "Surgical and medical procedures",
  "100000004866" = "Vascular disorders",
  "100000004867" = "General disorders and administration site conditions",
  "100000004868" = "Pregnancy, puerperium and perinatal conditions",
  "100000004869" = "Social circumstances",
  "100000004870" = "Immune system disorders",
  "100000004871" = "Hepatobiliary disorders",
  "100000004872" = "Reproductive system and breast disorders",
  "100000004873" = "Psychiatric disorders"
)

clean_organ_class <- function(x) {
  if (is.na(x) || x == "") return(NA_character_)
  parts <- trimws(strsplit(x, " / ")[[1]])
  cleaned <- sapply(parts, function(p) {
    if (grepl("^[0-9]+ - ", p)) {
      sub("^[0-9]+ - ", "", p)                    # EUCTR: strip numeric prefix
    } else if (grepl("^[0-9]+$", trimws(p))) {
      lbl <- ctis_soc_lookup[trimws(p)]
      if (!is.na(lbl)) unname(lbl) else NA_character_ # CTIS: look up code
    } else {
      p
    }
  })
  cleaned <- unique(cleaned[!is.na(cleaned)])
  if (length(cleaned) == 0) NA_character_ else paste(cleaned, collapse = " / ")
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
try(setwd("/shiny_trials/shiny_trials"), silent = TRUE)

DB_PATH       <- "./data/pediatric_trials.sqlite"
DB_COLLECTION <- "trials"
CACHE_PATH    <- "pediatric_trials_cache.rds"

# ══════════════════════════════════════════════════════════════════════════════
# 2. THEMES
# ══════════════════════════════════════════════════════════════════════════════

THEMES <- list(
  Nord = list(
    bg0="#2E3440",bg1="#3B4252",bg2="#434C5E",bg3="#4C566A",
    fg0="#D8DEE9",fg1="#E5E9F0",fg2="#ECEFF4",
    frost0="#8FBCBB",frost1="#88C0D0",frost2="#81A1C1",frost3="#5E81AC",
    red="#BF616A",orange="#D08770",yellow="#EBCB8B",
    green="#A3BE8C",purple="#B48EAD",
    s_ongoing="#A3BE8C",s_completed="#EBCB8B",s_other="#BF616A",
    r_euctr="#5E81AC",r_ctis="#88C0D0",
    chart_bg="#3B4252",chart_fg="#D8DEE9",chart_grid="#434C5E",
    spinner="#88C0D0"),
  Default = list(
    bg0="#ecf0f5",bg1="#ffffff",bg2="#f5f5f5",bg3="#d2d6de",
    fg0="#333333",fg1="#666666",fg2="#000000",
    frost0="#3c8dbc",frost1="#00c0ef",frost2="#0073b7",frost3="#001f3f",
    red="#dd4b39",orange="#ff851b",yellow="#f39c12",
    green="#00a65a",purple="#605ca8",
    s_ongoing="#00a65a",s_completed="#f39c12",s_other="#dd4b39",
    r_euctr="#3c8dbc",r_ctis="#00c0ef",
    chart_bg="#ffffff",chart_fg="#333333",chart_grid="#e5e5e5",
    spinner="#3c8dbc")
)

generate_css <- function(t) {
  sprintf('
  body{background:%s!important;color:%s}
  .skin-blue .main-header .logo{background:%s!important;color:%s!important;font-weight:700}
  .skin-blue .main-header .logo:hover{background:%s!important}
  .skin-blue .main-header .navbar{background:%s!important}
  .skin-blue .main-header .navbar .sidebar-toggle{color:%s!important}
  .skin-blue .main-header .navbar .sidebar-toggle:hover{background:%s!important}
  .skin-blue .main-sidebar,.skin-blue .left-side{background:%s!important}
  .skin-blue .sidebar-menu>li>a{color:%s!important;border-left:3px solid transparent}
  .skin-blue .sidebar-menu>li:hover>a,.skin-blue .sidebar-menu>li.active>a{
    background:%s!important;color:%s!important;border-left:3px solid %s}
  .skin-blue .sidebar a{color:%s!important}
  .sidebar h4{color:%s!important}.sidebar hr{border-color:%s}
  .sidebar .form-control,.sidebar .selectize-input{
    background:%s!important;color:%s!important;border:1px solid %s!important}
  .sidebar .selectize-dropdown{
    background:%s!important;color:%s!important;border:1px solid %s!important}
  .sidebar .selectize-dropdown .active{background:%s!important;color:%s!important}
  .sidebar label,.sidebar .checkbox label,.sidebar .radio label{color:%s!important}
  .content-wrapper,.right-side{background:%s!important}
  .box{background:%s!important;border:1px solid %s!important;
    border-radius:6px;box-shadow:0 2px 8px rgba(0,0,0,.25)}
  .box-header{color:%s!important}.box-header .box-title{color:%s!important}
  .box.box-solid.box-primary{border-top:3px solid %s!important}
  .box.box-solid.box-info{border-top:3px solid %s!important}
  .box.box-solid.box-warning{border-top:3px solid %s!important}
  .box-header.with-border{border-bottom:1px solid %s!important}
  .small-box{border-radius:6px;box-shadow:0 2px 8px rgba(0,0,0,.25)}
  .small-box h3,.small-box p{color:%s!important}
  .bg-blue{background:%s!important}.bg-green{background:%s!important}
  .bg-yellow{background:%s!important;color:%s!important}
  .bg-purple{background:%s!important}
  .dataTables_wrapper{color:%s!important}
  table.dataTable{background:%s!important;color:%s!important}
  table.dataTable thead th,table.dataTable thead td,
  .dataTables_scrollHead table thead th,.dataTables_scrollHead table thead td{
    background:%s!important;color:%s!important;
    border-bottom:2px solid %s!important}
  table.dataTable thead tr,.dataTables_scrollHead,.dataTables_scrollHeadInner,
  .dataTables_scrollHead table thead tr{background:%s!important}
  table.dataTable thead .sorting,table.dataTable thead .sorting_asc,
  table.dataTable thead .sorting_desc,table.dataTable thead .sorting_asc_disabled,
  table.dataTable thead .sorting_desc_disabled,
  .dataTables_scrollHead table thead .sorting,
  .dataTables_scrollHead table thead .sorting_asc,
  .dataTables_scrollHead table thead .sorting_desc{background-color:%s!important;color:%s!important}
  table.dataTable tbody tr{background:%s!important}
  table.dataTable tbody tr:hover{background:%s!important}
  table.dataTable tbody td{border-top:1px solid %s!important}
  .dataTables_info,.dataTables_length,.dataTables_filter,
  .dataTables_paginate{color:%s!important}
  .dataTables_filter input,.dataTables_length select{
    background:%s!important;color:%s!important;border:1px solid %s!important}
  .paginate_button{color:%s!important}
  .paginate_button.current{background:%s!important;color:%s!important;
    border:1px solid %s!important}
  .dataTables_wrapper thead input,.dataTables_wrapper thead select{
    background:%s!important;color:%s!important;border:1px solid %s!important}
  td.ellipsis{max-width:350px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .btn-warning{background:%s!important;border-color:%s!important;color:%s!important}
  .btn-warning:hover{opacity:.85}
  .btn-success{background:%s!important;border-color:%s!important;color:%s!important}
  .btn-info{background:%s!important;border-color:%s!important;color:%s!important}
  a{color:%s}a:hover{color:%s}
  .modal-content{background:%s!important;color:%s!important;border:1px solid %s}
  .modal-header{border-bottom:1px solid %s!important}
  .modal-footer{border-top:1px solid %s!important}
  .irs--shiny .irs-bar{background:%s;border-color:%s}
  .irs--shiny .irs-handle{background:%s;border:2px solid %s}
  .irs--shiny .irs-single{background:%s;color:%s}
  .irs--shiny .irs-line{background:%s}
  .irs--shiny .irs-grid-text,.irs--shiny .irs-min,.irs--shiny .irs-max{
    color:%s;background:%s}',
          t$bg0,t$fg0,t$bg1,t$frost1,t$bg2,t$bg1,t$fg0,t$bg2,
          t$bg1,t$fg0,t$bg2,t$frost1,t$frost1,t$fg0,t$frost1,t$bg3,
          t$bg2,t$fg0,t$bg3,t$bg2,t$fg0,t$bg3,t$frost2,t$fg2,t$fg0,
          t$bg0,t$bg1,t$bg2,t$fg1,t$fg2,t$frost3,t$frost1,t$orange,t$bg2,
          t$fg2,t$frost3,t$green,t$yellow,t$bg0,t$purple,
          t$fg0,t$bg1,t$fg0,t$bg2,t$fg2,t$bg3,t$bg2,t$bg2,t$fg2,t$bg1,t$bg2,t$bg2,
          t$fg0,t$bg2,t$fg0,t$bg3,t$fg0,t$frost2,t$fg2,t$frost2,
          t$bg2,t$fg0,t$bg3,
          t$orange,t$orange,t$bg0,t$green,t$green,t$bg0,t$frost2,t$frost2,t$fg2,
          t$frost1,t$frost0,t$bg1,t$fg0,t$bg3,t$bg2,t$bg2,
          t$frost2,t$frost2,t$frost1,t$frost3,t$frost2,t$fg2,t$bg3,t$fg0,t$bg2)
}

NORD_CSS <- generate_css(THEMES$Nord)

# ══════════════════════════════════════════════════════════════════════════════
# 3. COUNTRY CLEANING
# ══════════════════════════════════════════════════════════════════════════════

KNOWN_COUNTRIES <- c(
  "Austria","Belgium","Bulgaria","Croatia","Cyprus","Czech Republic","Czechia",
  "Denmark","Estonia","Finland","France","Germany","Greece","Hungary","Ireland",
  "Italy","Latvia","Lithuania","Luxembourg","Malta","Netherlands","Poland",
  "Portugal","Romania","Slovakia","Slovenia","Spain","Sweden","Norway","Iceland",
  "Liechtenstein","Switzerland","United Kingdom","Great Britain",
  "Albania","Algeria","Argentina","Armenia","Australia","Azerbaijan","Bangladesh",
  "Belarus","Bolivia","Bosnia and Herzegovina","Brazil","Canada","Chile","China",
  "Colombia","Cuba","Dominican Republic","Ecuador","Egypt","Ethiopia","Georgia",
  "Ghana","Guatemala","India","Indonesia","Iran","Iraq","Israel","Japan","Jordan",
  "Kazakhstan","Kenya","South Korea","Kuwait","Lebanon","Malaysia","Mexico",
  "Moldova","Mongolia","Montenegro","Morocco","Mozambique","Myanmar","Nepal",
  "New Zealand","Nigeria","North Macedonia","Pakistan","Panama","Paraguay","Peru",
  "Philippines","Qatar","Russia","Russian Federation","Rwanda","Saudi Arabia",
  "Senegal","Serbia","Singapore","South Africa","Sri Lanka","Taiwan","Tanzania",
  "Thailand","Tunisia","Turkey","Türkiye","Uganda","Ukraine",
  "United Arab Emirates","United States","Uruguay","Uzbekistan","Venezuela",
  "Vietnam","Zambia","Zimbabwe")

COUNTRY_COORDS <- data.frame(
  country = c(
    "Austria","Belgium","Bulgaria","Croatia","Cyprus","Czech Republic",
    "Denmark","Estonia","Finland","France","Germany","Greece","Hungary",
    "Ireland","Italy","Latvia","Lithuania","Luxembourg","Malta","Netherlands",
    "Poland","Portugal","Romania","Slovakia","Slovenia","Spain","Sweden",
    "Norway","Iceland","Liechtenstein","Switzerland","United Kingdom",
    "Albania","Algeria","Argentina","Armenia","Australia","Azerbaijan",
    "Bangladesh","Belarus","Bolivia","Bosnia and Herzegovina","Brazil",
    "Canada","Chile","China","Colombia","Cuba","Dominican Republic",
    "Ecuador","Egypt","Ethiopia","Georgia","Ghana","Guatemala","India",
    "Indonesia","Iran","Iraq","Israel","Japan","Jordan","Kazakhstan",
    "Kenya","South Korea","Kuwait","Lebanon","Malaysia","Mexico",
    "Moldova","Mongolia","Montenegro","Morocco","Mozambique","Myanmar",
    "Nepal","New Zealand","Nigeria","North Macedonia","Pakistan","Panama",
    "Paraguay","Peru","Philippines","Qatar","Russia","Rwanda","Saudi Arabia",
    "Senegal","Serbia","Singapore","South Africa","Sri Lanka","Taiwan",
    "Tanzania","Thailand","Tunisia","Turkey","Uganda","Ukraine",
    "United Arab Emirates","United States","Uruguay","Uzbekistan","Venezuela",
    "Vietnam","Zambia","Zimbabwe"
  ),
  lat = c(
    47.52, 50.50, 42.73, 45.10, 34.92, 49.82, 56.26, 58.60, 64.96, 46.23,
    51.17, 39.07, 47.16, 53.41, 42.50, 56.88, 55.17, 49.82, 35.94, 52.13,
    51.92, 39.40, 45.94, 48.67, 46.15, 40.46, 60.13,
    60.47, 64.96, 47.14, 46.82, 54.91,
    41.15, 28.03, -38.42, 40.07, -25.27, 40.14, 23.69, 53.71, -16.29,
    43.92, -14.24, 56.13, -35.68, 35.86,  4.57, 21.52, 18.74,  -1.83,
    26.82,  9.15, 42.32,  7.95, 15.78, 20.59,  -0.79, 32.43, 33.22, 31.05,
    36.20, 30.59, 48.02,  -0.02, 35.91, 29.37, 33.86,  4.21, 23.63, 47.41,
    46.86, 42.71, 31.79, -18.67, 16.87, 28.39, -40.90,  9.08, 41.61, 30.38,
     8.54, -23.44,  -9.19, 12.88, 25.35, 61.52,  -1.94, 23.90, 14.50, 44.02,
     1.35, -28.47,  7.87, 23.70,  -6.37, 15.87, 33.89, 38.96,  1.37, 48.38,
    24.47,  37.09, -32.52, 41.38,  8.00, 14.06, -13.13, -19.02
  ),
  lng = c(
    14.55,  4.47, 25.49, 15.20, 32.91, 15.47,  9.50, 25.01, 25.75,  2.21,
    10.45, 21.82, 19.50, -8.24, 12.57, 24.60, 23.88,  6.13, 14.38,  5.29,
    19.15, -8.22, 24.97, 19.70, 14.80, -3.75, 18.64,
     8.47,-18.49,  9.55,  8.23, -3.44,
    20.17,  1.66,-63.62, 45.04,133.78, 47.58, 90.36, 27.95,-63.59,
    17.56,-51.93,-106.35,-71.54,104.20,-74.30,-79.52,-69.97,-78.18,
    30.80, 40.49, 43.36, -1.02,-90.23, 78.96,113.92, 53.69, 43.68, 34.85,
   138.25, 36.24, 66.92, 37.91,127.77, 47.48, 35.86,109.70,-102.55, 28.37,
   103.84, 19.37, -7.09, 35.53, 95.96, 84.12,172.50,  8.68, 21.75, 69.35,
   -80.78,-58.44,-75.02,122.56, 51.18,105.32, 29.87, 45.08,-14.45, 21.01,
   103.82, 25.08, 80.77,120.96, 34.89,100.99,  9.54, 35.24, 32.29, 31.17,
    53.85,-95.71,-56.17, 64.59,-66.59,108.28, 27.85, 29.15
  ),
  stringsAsFactors = FALSE
)

COUNTRY_LOOKUP <- setNames(KNOWN_COUNTRIES, tolower(KNOWN_COUNTRIES))
COUNTRY_LOOKUP[c("uk","u.k.","great britain")] <- "United Kingdom"
COUNTRY_LOOKUP[c("us","usa","u.s.a.","united states of america")] <- "United States"
COUNTRY_LOOKUP["czechia"] <- "Czech Republic"
COUNTRY_LOOKUP[c("republic of korea","korea")] <- "South Korea"
COUNTRY_LOOKUP["russian federation"] <- "Russia"
COUNTRY_LOOKUP["türkiye"] <- "Turkey"

clean_member_state <- function(x) {
  sapply(x, function(val) {
    if (is.na(val) || val == "") return(NA_character_)
    parts <- unlist(str_split(val, " / |, "))
    parts <- str_trim(parts)
    parts <- parts[parts != "" & !is.na(parts)]
    if (length(parts) == 0) return(NA_character_)
    parts <- str_replace(parts, "^([A-Za-z][A-Za-z .]+?)\\s*-\\s+.*$", "\\1")
    parts <- str_trim(parts)
    is_junk <- str_detect(parts, "^\\d+$") | str_detect(parts, "^\\d+\\.\\d+$") |
      str_detect(parts, "\\d{4}-\\d{2}-\\d{2}") | str_detect(parts, "T\\d{2}:") |
      str_detect(parts, "^[0-9a-f]{8}-") | (nchar(parts) <= 1)
    parts <- parts[!is_junk]
    if (length(parts) == 0) return(NA_character_)
    resolved <- vapply(parts, function(p) {
      pl <- tolower(p)
      if (pl %in% names(COUNTRY_LOOKUP)) return(COUNTRY_LOOKUP[[pl]])
      for (cn in names(COUNTRY_LOOKUP))
        if (str_starts(pl, fixed(cn))) return(COUNTRY_LOOKUP[[cn]])
      NA_character_
    }, character(1), USE.NAMES = FALSE)
    resolved <- sort(unique(resolved[!is.na(resolved)]))
    if (length(resolved) == 0) NA_character_ else paste(resolved, collapse = " / ")
  }, USE.NAMES = FALSE)
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. DEEP FLATTEN — handles CTIS nested lists that survive first pass
# ══════════════════════════════════════════════════════════════════════════════

deep_flatten_col <- function(x) {
  if (!is.list(x)) return(as.character(x))
  sapply(x, function(el) {
    if (is.null(el) || length(el) == 0) return(NA_character_)
    # Recursively unlist everything
    flat <- tryCatch({
      u <- unlist(el, recursive = TRUE)
      u <- as.character(u)
      u <- u[!is.na(u) & u != "" & u != "NULL" & u != "NA"]
      # Remove numeric-only tokens (IDs, timestamps from CTIS)
      u <- u[!grepl("^[0-9.]+$", u)]
      u <- u[!grepl("\\d{4}-\\d{2}-\\d{2}T", u)]
      u <- u[nchar(u) > 1]
      u
    }, error = function(e) character(0))
    if (length(flat) == 0) return(NA_character_)
    paste(unique(flat), collapse = " / ")
  }, USE.NAMES = FALSE)
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. DATA PREPARATION
# ══════════════════════════════════════════════════════════════════════════════

prepare_trial_data <- function(db_path = DB_PATH, collection = DB_COLLECTION) {
  
  db <- nodbi::src_sqlite(dbname = db_path, collection = collection)
  
  EUCTR_fields <- c(
    "a2_eudract_number","dimp.d31_product_name",
    "f11_trial_has_subjects_under_18",
    "e12_meddra_classification.e12_term",
    "e12_meddra_classification.e12_system_organ_class",
    "a1_member_state_concerned","a3_full_title_of_the_trial",
    "a7_trial_is_part_of_a_paediatric_investigation_plan","x5_trial_status",
    "x6_date_on_which_this_record_was_first_entered_in_the_eudract_database",
    "n_date_of_competent_authority_decision",
    "trialInformation.recruitmentStartDate","p_end_of_trial_status",
    "b1_sponsor.b31_and_b32_status_of_the_sponsor",
    "e71_human_pharmacology_phase_i","e72_therapeutic_exploratory_phase_ii",
    "e73_therapeutic_confirmatory_phase_iii","e74_therapeutic_use_phase_iv")
  
  CTIS_fields <- c(
    "authorizedApplication.applicationInfo.ctNumber",
    "authorizedApplication.authorizedPartI.products.productName",
    "authorizedApplication.authorizedPartI.trialDetails.trialInformation.medicalCondition.meddraConditionTerms.termName",
    "authorizedApplication.authorizedPartI.trialDetails.trialInformation.medicalCondition.meddraConditionTerms.organClass",
    "authorizedApplication.memberStatesConcerned",
    "authorizedApplication.authorizedPartI.trialDetails.clinicalTrialIdentifiers.fullTitle",
    "authorizedApplication.authorizedPartI.trialDetails.scientificAdviceAndPip.paediatricInvestigationPlan",
    "authorizedApplication.applicationInfo.trialStatus",
    "authorizedApplication.applicationInfo.submissionDate",
    "authorizedPartI.trialDetails.trialInformation.trialDuration.estimatedRecruitmentStartDate",
    "ctStatus",
    "authorizedApplication.authorizedPartI.sponsors.commercial",
    "trialPhase")
  
  result <- dbGetFieldsIntoDf(fields = c(EUCTR_fields, CTIS_fields), con = db)
  message(sprintf("Raw: %d x %d", nrow(result), ncol(result)))
  
  # ── AGGRESSIVE flatten: two passes ────────────────────────────────────────
  # Pass 1: standard flatten
  result <- result %>% mutate(across(where(is.list), deep_flatten_col))
  
  # Pass 2: anything still a list gets forced to character
  still_list <- sapply(result, is.list)
  if (any(still_list)) {
    message(sprintf("Force-flattening %d remaining list columns: %s",
                    sum(still_list), paste(names(result)[still_list], collapse = ", ")))
    result <- result %>% mutate(across(where(is.list), ~ {
      sapply(.x, function(el) {
        tryCatch(paste(unlist(el), collapse = " / "),
                 error = function(e) NA_character_)
      }, USE.NAMES = FALSE)
    }))
  }
  
  # Coerce ALL to character
  result <- result %>% mutate(across(-`_id`, ~ {
    if (is.character(.x)) .x
    else { o <- as.character(.x); o[o == "NA"] <- NA_character_; o }
  }))
  
  # Verify no lists remain
  still_list2 <- sapply(result, is.list)
  if (any(still_list2)) {
    message(sprintf("WARNING: %d columns still list after double flatten — dropping them",
                    sum(still_list2)))
    result <- result[, !still_list2]
  }
  
  message(sprintf("After flatten: %d x %d, all character: %s",
                  nrow(result), ncol(result),
                  all(sapply(result, is.character) | names(result) == "_id")))
  
  # Register detection
  # EUCTR IDs: YYYY-NNNNNN-NN-CC  (CC = letter country code, e.g. -BE, -GB3)
  # CTIS  IDs: YYYY-NNNNNN-NN-NN  (last segment is numeric, e.g. -00)
  # Both share the same numeric prefix — require a letter in the suffix for EUCTR.
  result <- result %>% mutate(register = case_when(
    str_detect(`_id`, "^\\d{4}-\\d{6}-\\d{2}-[A-Z]") ~ "EUCTR",
    TRUE ~ "CTIS"))
  message(sprintf("Registers: %s",
                  paste(names(table(result$register)), table(result$register), sep="=", collapse=", ")))
  
  # Ensure columns
  all_expected <- c(
    "a2_eudract_number","dimp.d31_product_name",
    "e12_meddra_classification.e12_term","e12_meddra_classification.e12_system_organ_class",
    "a1_member_state_concerned","a3_full_title_of_the_trial",
    "a7_trial_is_part_of_a_paediatric_investigation_plan","x5_trial_status",
    "x6_date_on_which_this_record_was_first_entered_in_the_eudract_database",
    "n_date_of_competent_authority_decision","trialInformation.recruitmentStartDate",
    "p_end_of_trial_status",
    "authorizedApplication.applicationInfo.ctNumber",
    "authorizedApplication.authorizedPartI.products.productName",
    "authorizedApplication.authorizedPartI.trialDetails.trialInformation.medicalCondition.meddraConditionTerms.termName",
    "authorizedApplication.authorizedPartI.trialDetails.trialInformation.medicalCondition.meddraConditionTerms.organClass",
    "authorizedApplication.memberStatesConcerned",
    "authorizedApplication.authorizedPartI.trialDetails.clinicalTrialIdentifiers.fullTitle",
    "authorizedApplication.authorizedPartI.trialDetails.scientificAdviceAndPip.paediatricInvestigationPlan",
    "authorizedApplication.applicationInfo.trialStatus",
    "authorizedApplication.applicationInfo.submissionDate",
    "authorizedPartI.trialDetails.trialInformation.trialDuration.estimatedRecruitmentStartDate",
    "ctStatus",
    "b1_sponsor.b31_and_b32_status_of_the_sponsor",
    "authorizedApplication.authorizedPartI.sponsors.commercial",
    "e71_human_pharmacology_phase_i","e72_therapeutic_exploratory_phase_ii",
    "e73_therapeutic_confirmatory_phase_iii","e74_therapeutic_use_phase_iv",
    "trialPhase")
  for (col in all_expected)
    if (!col %in% names(result)) result[[col]] <- NA_character_
  
  # Clean countries
  message("Cleaning countries...")
  result <- result %>% mutate(
    a1_member_state_concerned = clean_member_state(a1_member_state_concerned),
    `authorizedApplication.memberStatesConcerned` =
      clean_member_state(`authorizedApplication.memberStatesConcerned`))
  
  # Unite
  result <- result %>%
    unite("CT_number", a2_eudract_number,
          `authorizedApplication.applicationInfo.ctNumber`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("Full_title", a3_full_title_of_the_trial,
          `authorizedApplication.authorizedPartI.trialDetails.clinicalTrialIdentifiers.fullTitle`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("DIMP_product_name", `dimp.d31_product_name`,
          `authorizedApplication.authorizedPartI.products.productName`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("MEDDRA_term", `e12_meddra_classification.e12_term`,
          `authorizedApplication.authorizedPartI.trialDetails.trialInformation.medicalCondition.meddraConditionTerms.termName`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("MEDDRA_organ_class", `e12_meddra_classification.e12_system_organ_class`,
          `authorizedApplication.authorizedPartI.trialDetails.trialInformation.medicalCondition.meddraConditionTerms.organClass`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("Member_state", a1_member_state_concerned,
          `authorizedApplication.memberStatesConcerned`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("PIP_status", a7_trial_is_part_of_a_paediatric_investigation_plan,
          `authorizedApplication.authorizedPartI.trialDetails.scientificAdviceAndPip.paediatricInvestigationPlan`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("trial_status_raw", x5_trial_status,
          `authorizedApplication.applicationInfo.trialStatus`,
          na.rm=TRUE, remove=TRUE) %>%
    unite("submission_date",
          x6_date_on_which_this_record_was_first_entered_in_the_eudract_database,
          `authorizedApplication.applicationInfo.submissionDate`,
          na.rm=TRUE, remove=TRUE)
  
  result <- result %>% mutate(Member_state = clean_member_state(Member_state))
  result <- result %>% mutate(across(where(is.character), ~ na_if(str_trim(.x), "")))
  
  # ── Dedup ─────────────────────────────────────────────────────────────────
  unique_ids <- dbFindIdsUniqueTrials(con = db)
  result <- result %>% mutate(trial_base_id = case_when(
    register == "EUCTR" ~ str_replace(`_id`, "-[A-Z]{2,3}$", ""),
    TRUE ~ `_id`))
  
  agg_field <- function(df, col) {
    df %>% filter(!is.na(!!sym(col)) & !!sym(col) != "") %>%
      separate_rows(!!sym(col), sep = " / ") %>%
      mutate(!!sym(col) := str_trim(!!sym(col))) %>%
      filter(!!sym(col) != "") %>%
      group_by(trial_base_id) %>%
      summarise(val = paste(sort(unique(!!sym(col))), collapse = " / "), .groups = "drop")
  }
  
  clu <- agg_field(result, "Member_state") %>% rename(all_countries = val)
  nlu <- result %>% filter(!is.na(Member_state)) %>%
    separate_rows(Member_state, sep = " / ") %>%
    mutate(Member_state = str_trim(Member_state)) %>% filter(Member_state != "") %>%
    group_by(trial_base_id) %>%
    summarise(n_countries = n_distinct(Member_state), .groups = "drop")
  clu <- clu %>% left_join(nlu, by = "trial_base_id")
  slu <- agg_field(result, "trial_status_raw") %>% rename(all_statuses_raw = val)
  mlu <- agg_field(result, "MEDDRA_term") %>% rename(all_meddra = val)
  olu <- agg_field(result, "MEDDRA_organ_class") %>% rename(all_organ = val)

  # ── Cross-register overlap: must be computed BEFORE dedup ─────────────────
  # dbFindIdsUniqueTrials removes cross-register duplicates, so after filtering
  # to unique_ids a trial only appears in one register — title matching would
  # find zero overlap.  We therefore build the flag here on the full result.
  result <- result %>% mutate(
    title_key = {
      tt <- as.character(Full_title)
      tt <- tolower(tt)
      tt <- str_replace_all(tt, "[^a-z0-9 ]", " ")
      tt <- str_squish(tt)
      substr(tt, 1, 80)
    })
  both_tk <- result %>%
    filter(!is.na(title_key) & nchar(title_key) >= 20) %>%
    group_by(title_key) %>%
    filter(n_distinct(register) > 1) %>%
    ungroup() %>%
    pull(title_key) %>%
    unique()
  result <- result %>% mutate(in_both_registers = title_key %in% both_tk)
  message(sprintf("Cross-register overlap (by title): %d trial(s)", length(both_tk)))

  # ── For CTIS: always use the latest amendment version ─────────────────────
  # CTIS IDs end in -VV (amendment version, e.g. -01, -02).
  # dbFindIdsUniqueTrials may keep an older amendment; find any such cases
  # among the CTIS records already in unique_ids and swap to the latest version.
  ctis_in_unique <- result %>%
    filter(register == "CTIS", `_id` %in% unique_ids) %>%
    mutate(
      base_id = str_replace(`_id`, "-\\d+$", ""),
      version = as.integer(str_extract(`_id`, "\\d+$"))
    ) %>%
    select(`_id`, base_id, version)

  if (nrow(ctis_in_unique) > 0) {
    ctis_latest <- result %>%
      filter(register == "CTIS") %>%
      mutate(
        base_id = str_replace(`_id`, "-\\d+$", ""),
        version = as.integer(str_extract(`_id`, "\\d+$"))
      ) %>%
      group_by(base_id) %>%
      slice_max(version, n = 1, with_ties = FALSE) %>%
      ungroup() %>%
      select(base_id, latest_id = `_id`)

    to_update <- ctis_in_unique %>%
      left_join(ctis_latest, by = "base_id") %>%
      filter(`_id` != latest_id)

    if (nrow(to_update) > 0) {
      unique_ids <- unique(c(setdiff(unique_ids, to_update$`_id`), to_update$latest_id))
      message(sprintf("CTIS: updated %d record(s) to their latest amendment version",
                      nrow(to_update)))
    }
  }

  # ── Prefer CTIS over EUCTR "transitioned" records ─────────────────────────
  # dbFindIdsUniqueTrials may keep an EUCTR "Trial now transitioned" record
  # instead of its CTIS counterpart. Find such cases by normalised title and
  # swap the kept ID so the CTIS version is used after dedup.
  trans_pat <- regex("transitioned", ignore_case = TRUE)
  raw_status_cols <- intersect(c("trial_status_raw", "p_end_of_trial_status"), names(result))
  trans_euctr <- result %>%
    filter(register == "EUCTR", `_id` %in% unique_ids,
           !is.na(title_key), nchar(title_key) >= 20)
  if (length(raw_status_cols) > 0) {
    is_trans <- Reduce(`|`, lapply(raw_status_cols, function(col)
      str_detect(coalesce(as.character(trans_euctr[[col]]), ""), trans_pat)))
    trans_euctr <- trans_euctr[is_trans, ]
  } else {
    trans_euctr <- trans_euctr[0, ]
  }
  if (nrow(trans_euctr) > 0) {
    ctis_matches <- result %>%
      filter(register == "CTIS", !is.na(title_key), nchar(title_key) >= 20,
             title_key %in% trans_euctr$title_key)
    if (nrow(ctis_matches) > 0) {
      euctr_drop <- trans_euctr %>% filter(title_key %in% ctis_matches$title_key) %>% pull(`_id`)
      unique_ids <- unique(c(setdiff(unique_ids, euctr_drop), ctis_matches$`_id`))
      message(sprintf("Swapped %d EUCTR 'transitioned' record(s) for CTIS counterpart(s)",
                      length(euctr_drop)))
    }
  }

  result <- result %>% filter(`_id` %in% unique_ids)
  message(sprintf("Unique trials: %d", nrow(result)))
  
  result <- result %>%
    left_join(clu, by="trial_base_id") %>%
    mutate(Member_state = if_else(!is.na(all_countries), all_countries, Member_state)) %>%
    left_join(slu, by="trial_base_id") %>%
    mutate(trial_status_raw = if_else(!is.na(all_statuses_raw), all_statuses_raw, trial_status_raw)) %>%
    left_join(mlu, by="trial_base_id") %>%
    mutate(MEDDRA_term = if_else(!is.na(all_meddra), all_meddra, MEDDRA_term)) %>%
    left_join(olu, by="trial_base_id") %>%
    mutate(MEDDRA_organ_class = if_else(!is.na(all_organ), all_organ, MEDDRA_organ_class)) %>%
    select(-all_countries, -all_statuses_raw, -all_meddra, -all_organ) %>%
    mutate(MEDDRA_organ_class = vapply(MEDDRA_organ_class, clean_organ_class, character(1)))
  
  # ── Start date ────────────────────────────────────────────────────────────
  dcols <- intersect(c(
    "n_date_of_competent_authority_decision","trialInformation.recruitmentStartDate",
    "authorizedPartI.trialDetails.trialInformation.trialDuration.estimatedRecruitmentStartDate"),
    names(result))
  if (length(dcols) > 0) {
    ddf <- result %>% select(all_of(dcols)) %>%
      mutate(across(everything(), ~ suppressWarnings(
        as.Date(parse_date_time(as.character(.x),
                                orders = c("ymd","ym","y","ymd HMS","ymd HM"))))))
    result$start_date <- apply(ddf, 1, function(r) {
      v <- as.Date(r[!is.na(r)], origin = "1970-01-01")
      if (length(v) == 0) NA_real_ else as.numeric(max(v))
    })
    result$start_date <- as.Date(result$start_date, origin = "1970-01-01")
  } else result$start_date <- as.Date(NA)
  
  # ── Status ────────────────────────────────────────────────────────────────
  if (all(c("p_end_of_trial_status","n_date_of_competent_authority_decision") %in% names(result))) {
    result <- result %>% mutate(
      p_end_of_trial_status = as.character(p_end_of_trial_status),
      n_date_of_competent_authority_decision = as.character(n_date_of_competent_authority_decision)
    ) %>% mutate(p_end_of_trial_status = if_else(
      is.na(p_end_of_trial_status) & !is.na(n_date_of_competent_authority_decision),
      "Ongoing", p_end_of_trial_status))
  }
  if (!"p_end_of_trial_status" %in% names(result)) result$p_end_of_trial_status <- NA_character_
  if (!"ctStatus" %in% names(result)) result$ctStatus <- NA_character_
  result <- result %>% mutate(across(c(p_end_of_trial_status, ctStatus, trial_status_raw), as.character))
  
  ongoing_pat <- regex(paste(c(
    "Recruiting","Active","Ongoing","Temporarily Halted","Restarted",
    "Ongoing, recruiting","Ongoing, recruitment ended",
    "Ongoing, not yet recruiting","Authorised, not started",
    "Active, not recruiting","Enrolling by invitation","Not yet recruiting",
    # CTIS-specific status values
    "Authorised","In Progress","Temporarily halted"
  ), collapse = "|"), ignore_case = TRUE)
  completed_pat <- regex("Completed|COMPLETED|Ended", ignore_case = TRUE)

  # CTIS numeric status code mapping (CTIS API stores status as integer enums)
  ctis_status_map <- c(
    "1" = "Authorised", "2" = "In Progress", "3" = "Completed",
    "4" = "Terminated",  "5" = "Temporarily halted", "6" = "Withdrawn")

  result <- result %>% mutate(
    # status_raw_orig: used for Ongoing/Completed/Other classification only.
    status_raw_orig = coalesce(p_end_of_trial_status, ctStatus, trial_status_raw),
    # For CTIS, map numeric codes to human-readable labels before any processing.
    status_raw_orig = if_else(
      register == "CTIS" & !is.na(status_raw_orig) &
        str_trim(status_raw_orig) %in% names(ctis_status_map),
      ctis_status_map[str_trim(status_raw_orig)],
      status_raw_orig),
    # status_raw: display value — strip purely-numeric tokens from CTIS JSON
    # flattening and deduplicate repeated tokens in aggregated multi-country strings.
    status_raw = vapply(status_raw_orig, function(x) {
      if (is.na(x) || !nzchar(str_trim(x))) return(NA_character_)
      parts <- str_trim(unlist(str_split(x, " / ")))
      parts <- parts[nzchar(parts) & !str_detect(parts, "^[0-9]+$")]
      parts <- tolower(parts)
      parts <- dplyr::recode(parts,
        "temporarily halted"          = "Temporarily halted",
        "temporarily halted (current)"= "Temporarily halted",
        "restarted"                   = "Restarted",
        "withdrawn"                   = "Withdrawn",
        "terminated"                  = "Terminated",
        "completed"                   = "Completed",
        "authorised"                  = "Authorised",
        "in progress"                 = "Ongoing",
        "ongoing"                     = "Ongoing",
        "not authorised"              = "Not Authorised",
        .default = stringr::str_to_sentence(parts))
      parts <- unique(parts)
      if (length(parts) == 0) NA_character_ else paste(parts, collapse = " / ")
    }, FUN.VALUE = character(1L), USE.NAMES = FALSE),
    status = case_when(
      is.na(status_raw_orig) ~ NA_character_,
      str_detect(status_raw_orig, ongoing_pat) ~ "Ongoing",
      str_detect(status_raw_orig, completed_pat) ~ "Completed",
      TRUE ~ "Other")) %>%
    # Ensure the display column is never blank: fall back to the status category.
    mutate(status_raw = if_else(is.na(status_raw) & !is.na(status), status, status_raw))
  
  # ── Derived ───────────────────────────────────────────────────────────────
  result <- result %>% mutate(
    submission_date_parsed = suppressWarnings(
      as.Date(parse_date_time(submission_date, orders = c("ymd","ym","y","ymd HMS")))),
    year = year(submission_date_parsed),
    has_PIP = case_when(
      str_detect(tolower(PIP_status), "yes|true") ~ "Yes",
      str_detect(tolower(PIP_status), "no|false") ~ "No",
      # CTIS: paediatricInvestigationPlan is a list of PIP records; any non-empty
      # content means a PIP exists. Empty/NA means no PIP was specified.
      register == "CTIS" & !is.na(PIP_status) & nzchar(str_trim(PIP_status)) ~ "Yes",
      register == "CTIS" & (is.na(PIP_status) | !nzchar(str_trim(PIP_status))) ~ "No",
      TRUE ~ "Unknown"),
    # Overlap title key — guaranteed character
    title_key = {
      tt <- as.character(Full_title)
      tt <- tolower(tt)
      tt <- str_replace_all(tt, "[^a-z0-9 ]", " ")
      tt <- str_squish(tt)
      substr(tt, 1, 80)
    })
  
  result <- result %>% select(-status_raw_orig)

  # ── Sponsor type ──────────────────────────────────────────────────────────
  result <- result %>% mutate(
    sponsor_type = case_when(
      register == "EUCTR" & str_detect(tolower(as.character(`b1_sponsor.b31_and_b32_status_of_the_sponsor`)), "non.commercial|non commercial|academic") ~ "Academic",
      register == "EUCTR" & str_detect(tolower(as.character(`b1_sponsor.b31_and_b32_status_of_the_sponsor`)), "commercial") ~ "Industry",
      register == "CTIS" & str_detect(tolower(as.character(`authorizedApplication.authorizedPartI.sponsors.commercial`)), "non.commercial|non commercial|academic") ~ "Academic",
      register == "CTIS" & str_detect(tolower(as.character(`authorizedApplication.authorizedPartI.sponsors.commercial`)), "commercial") ~ "Industry",
      TRUE ~ NA_character_))

  # ── Trial phase ───────────────────────────────────────────────────────────
  euctr_phase_cols <- c(
    "e71_human_pharmacology_phase_i",
    "e72_therapeutic_exploratory_phase_ii",
    "e73_therapeutic_confirmatory_phase_iii",
    "e74_therapeutic_use_phase_iv")
  euctr_phase_labels <- c("Phase I", "Phase II", "Phase III", "Phase IV")
  ctis_phase_col <- "trialPhase"

  euctr_phase_cols_present <- intersect(euctr_phase_cols, names(result))
  ctis_phase_col_present <- ctis_phase_col %in% names(result)

  result <- result %>% mutate(phase = {
    euctr_phases <- if (length(euctr_phase_cols_present) > 0) {
      apply(result[, euctr_phase_cols_present, drop = FALSE], 1, function(r) {
        flags <- str_detect(tolower(as.character(r)), "true|yes|1")
        flags[is.na(flags)] <- FALSE
        lbs <- euctr_phase_labels[match(euctr_phase_cols_present, euctr_phase_cols)]
        lbs <- lbs[flags]
        if (length(lbs) == 0) NA_character_ else paste(lbs, collapse = " / ")
      })
    } else rep(NA_character_, nrow(result))

    ctis_phases <- if (ctis_phase_col_present) {
      vapply(as.character(result[[ctis_phase_col]]), function(x) {
        if (is.na(x) || !nzchar(str_trim(x))) return(NA_character_)
        x <- str_trim(x)
        # Map CTIS phase text to canonical labels
        # CTIS uses descriptions like "Therapeutic exploratory (Phase II)"
        lbl <- dplyr::case_when(
          grepl("phase i[^iv]|phase i$|human pharmacology", tolower(x)) ~ "Phase I",
          grepl("phase iv|therapeutic use", tolower(x))                  ~ "Phase IV",
          grepl("phase iii|confirmatory", tolower(x))                    ~ "Phase III",
          grepl("phase ii|exploratory", tolower(x))                      ~ "Phase II",
          TRUE ~ NA_character_)
        if (is.na(lbl)) x else lbl
      }, FUN.VALUE = character(1L), USE.NAMES = FALSE)
    } else rep(NA_character_, nrow(result))

    dplyr::coalesce(
      if_else(register == "EUCTR" & !is.na(euctr_phases), euctr_phases, NA_character_),
      if_else(register == "CTIS"  & !is.na(ctis_phases),  ctis_phases,  NA_character_))
  })

  # Drop raw phase columns
  result <- result %>% select(-any_of(c(euctr_phase_cols, ctis_phase_col)))

  message(sprintf("Ready: %d trials, %d cols", nrow(result), ncol(result)))
  return(result)
}

# ══════════════════════════════════════════════════════════════════════════════
# 6. OVERLAP — defensive, handles 0 rows
# ══════════════════════════════════════════════════════════════════════════════

compute_overlap <- function(df) {
  # n_euctr / n_ctis are the register counts in the already-deduped data.
  n_e <- sum(df$register == "EUCTR", na.rm = TRUE)
  n_c <- sum(df$register == "CTIS",  na.rm = TRUE)

  # in_both_registers is set by title-matching BEFORE dedup.
  # When ctrdata does NOT merge EUCTR<->CTIS duplicates (as is typical),
  # both a EUCTR record AND a CTIS record for the same trial survive in the
  # deduped set, each with in_both_registers=TRUE.  Counting all flagged rows
  # would double-count every shared trial.  We anchor the count on EUCTR to
  # count each shared trial exactly once.
  has_flag <- "in_both_registers" %in% names(df)
  if (has_flag) {
    flag   <- !is.na(df$in_both_registers) & df$in_both_registers
    n_ec   <- sum(df$register == "EUCTR" & flag, na.rm = TRUE)
  } else {
    n_ec   <- 0L
  }
  only_e <- n_e - n_ec
  only_c <- n_c - n_ec

  list(
    n_euctr      = n_e,
    n_ctis       = n_c,
    n_euctr_ctis = n_ec,
    only_euctr   = max(0L, only_e),
    only_ctis    = max(0L, only_c),
    n_total      = max(0L, only_e) + max(0L, only_c) + n_ec,
    n_overlap    = n_ec)
}

# ══════════════════════════════════════════════════════════════════════════════
# 7. CACHING
# ══════════════════════════════════════════════════════════════════════════════

cache_is_valid <- function(cp = CACHE_PATH, dp = DB_PATH) {
  file.exists(cp) && (!file.exists(dp) || file.mtime(cp) > file.mtime(dp))
}

load_trial_data <- function(force_rebuild = FALSE) {
  if (!force_rebuild && cache_is_valid()) {
    message("Loading cache..."); t0 <- Sys.time()
    d <- readRDS(CACHE_PATH)
    message(sprintf("Cached: %s trials in %.1fs",
                    format(nrow(d), big.mark=","),
                    as.numeric(Sys.time()-t0, units="secs")))
    return(d)
  }
  if (!file.exists(DB_PATH)) { message("No database."); return(NULL) }
  message("Rebuilding..."); t0 <- Sys.time()
  d <- prepare_trial_data()
  message(sprintf("Built in %.1fs", as.numeric(Sys.time()-t0, units="secs")))
  saveRDS(d, CACHE_PATH); return(d)
}

trials_data <- tryCatch(load_trial_data(),
                        error = function(e) { message("Data load error: ", e$message); NULL })

extract_choices <- function(x, sep = " / ") {
  v <- unlist(str_split(x[!is.na(x)], fixed(sep)))
  v <- str_trim(v); sort(unique(v[v != "" & !is.na(v)]))
}

# ══════════════════════════════════════════════════════════════════════════════
# 8. UI
# ══════════════════════════════════════════════════════════════════════════════

ui <- dashboardPage(skin = "blue",
                    title = "Shiny Trials",
                    dashboardHeader(title = tagList(
                      tags$head(
                        tags$title("Shiny Trials"),
                        tags$link(rel = "icon", type = "image/svg+xml", href = "favicon.svg")
                      ),
                      icon("child"), " EU Paediatric Trials"
                    ), titleWidth = 300),
                    dashboardSidebar(width = 300,
                                     sidebarMenu(id = "tabs",
                                                 menuItem("Overview",tabName="overview",icon=icon("dashboard")),
                                                 menuItem("Map",tabName="map",icon=icon("map")),
                                                 menuItem("Data Explorer",tabName="data",icon=icon("table")),
                                                 menuItem("Analytics",tabName="analytics",icon=icon("chart-bar")),
                                                 menuItem("Phase Analysis",tabName="phase",icon=icon("flask")),
                                                 menuItem("About",tabName="about",icon=icon("info-circle"))),
                                     hr(), h4("  Filters",style="padding-left:15px;"),
                                     checkboxGroupInput("status_filter","Trial Status:",
                                                        choices=c("Ongoing","Completed","Other"),selected=c("Ongoing","Completed","Other")),
                                     checkboxGroupInput("register_filter","Source Register:",
                                                        choices=c("EUCTR","CTIS"),selected=c("EUCTR","CTIS")),
                                     dateRangeInput("date_range","Submission Date Range:",
                                                    start="2004-01-01",end=Sys.Date(),format="yyyy-mm-dd"),
                                     selectizeInput("organ_class_filter","MedDRA Organ Class:",
                                                    choices=NULL,multiple=TRUE,options=list(placeholder="All organ classes")),
                                     selectizeInput("condition_filter","Condition / MedDRA Term:",
                                                    choices=NULL,multiple=TRUE,options=list(placeholder="Type to search…")),
                                     selectizeInput("country_filter","Country / Member State:",
                                                    choices=NULL,multiple=TRUE,options=list(placeholder="All countries")),
                                     selectizeInput("phase_filter","Trial Phase:",
                                                    choices=NULL,multiple=TRUE,options=list(placeholder="All phases")),
                                     selectInput("pip_filter","Part of PIP:",
                                                 choices=c("All","Yes","No","Unknown"),selected="All"),
                                     textInput("text_search","Free-text search:",placeholder="e.g. neuroblastoma…"),
                                     hr(),
                                     div(style="padding:0 15px;",
                                         p("Save / restore filters:",style="font-size:12px;margin-bottom:4px;"),
                                         downloadButton("dl_filters","Save filters",class="btn-sm btn-default",style="width:100%;margin-bottom:6px;"),
                                         fileInput("ul_filters",NULL,accept=".json",placeholder="Load filters (.json)",
                                                   buttonLabel="Load…",width="100%")),
                                     hr(),
                                     div(style="padding:0 15px 10px;",
                                         downloadButton("dl_report","Download PDF Report",
                                                        class="btn-sm btn-warning",
                                                        style="width:100%;")),
                                     hr(),
                                     div(style="padding:0 15px;",
                                         textOutput("data_info")%>%tagAppendAttributes(style="font-size:11px;opacity:0.75;")),
                                     hr(),
                                     div(style="padding:0 15px;",
                                         radioButtons("theme_select","Theme:",choices=c("Nord","Default"),selected="Nord",inline=TRUE))
                    ),
                    
                    dashboardBody(
                      uiOutput("active_theme"),
                      tabItems(
                        tabItem(tabName="overview",
                                uiOutput("no_data_banner"),
                                fluidRow(valueBoxOutput("vb_total",width=3),valueBoxOutput("vb_ongoing",width=3),
                                         valueBoxOutput("vb_completed",width=3),valueBoxOutput("vb_pip",width=3)),
                                fluidRow(
                                  box(title="5 Most Recently Submitted Trials",status="warning",solidHeader=TRUE,
                                      width=12,withSpinner(DT::dataTableOutput("recent_trials_table",height="auto"),type=6))),
                                fluidRow(
                                  box(title="Cumulative Trials by Start Date",status="primary",solidHeader=TRUE,
                                      width=7,height=420,withSpinner(plotlyOutput("plot_cumulative",height="360px"),type=6)),
                                  box(title="Sponsor Type by Register",status="warning",solidHeader=TRUE,
                                      width=5,height=420,withSpinner(plotlyOutput("plot_sponsor_top",height="360px"),type=6))),
                                fluidRow(
                                  box(title="Registry Overlap (title matching)",status="primary",solidHeader=TRUE,
                                      width=5,height=350,withSpinner(plotOutput("plot_overlap",height="250px"),type=6),
                                      p(em("Matched by normalised title (first 80 chars)."),
                                        style="font-size:10px;margin:2px 0 0;opacity:0.6;")),
                                  box(title="Overlap Summary",status="info",solidHeader=TRUE,
                                      width=4,height=350,div(style="overflow-y:auto;max-height:300px;",
                                                             uiOutput("overlap_summary"))),
                                  box(title="Unique vs Shared",status="primary",solidHeader=TRUE,
                                      width=3,height=350,withSpinner(plotlyOutput("plot_overlap_bar",height="270px"),type=6))),
                                fluidRow(
                                  box(title="Submissions per Year",status="primary",solidHeader=TRUE,
                                      width=6,height=400,withSpinner(plotlyOutput("plot_yearly",height="340px"),type=6)),
                                  box(title="Register Comparison",status="info",solidHeader=TRUE,
                                      width=6,height=400,withSpinner(plotlyOutput("plot_register",height="340px"),type=6))),
                        ),
                        tabItem(tabName="data",
                                fluidRow(box(title="Filtered Trial Data",width=12,status="primary",solidHeader=TRUE,
                                             downloadButton("dl_csv","CSV",class="btn-sm btn-success"),
                                             downloadButton("dl_excel","Excel",class="btn-sm btn-info"),br(),br(),
                                             withSpinner(DT::dataTableOutput("trials_table"),type=6)))
                        ),
                        tabItem(tabName="analytics",
                                fluidRow(
                                  box(title="Top MedDRA Organ Classes",status="primary",solidHeader=TRUE,width=6,height=520,
                                      sliderInput("top_n_organ","Top N:",min=5,max=30,value=15),
                                      withSpinner(plotlyOutput("plot_organ",height="400px"),type=6)),
                                  box(title="Top Conditions / MedDRA Terms",status="info",solidHeader=TRUE,width=6,height=520,
                                      sliderInput("top_n_term","Top N:",min=5,max=30,value=15),
                                      withSpinner(plotlyOutput("plot_term",height="400px"),type=6))),
                                fluidRow(box(title="Trials by Country",status="primary",solidHeader=TRUE,width=12,height=460,
                                             withSpinner(plotlyOutput("plot_country",height="400px"),type=6))),
                                fluidRow(
                                  box(title="PIP Status",status="info",solidHeader=TRUE,width=6,height=420,
                                      withSpinner(plotlyOutput("plot_pip",height="360px"),type=6)),
                                  box(title="Start-Date Timeline (quarterly)",status="primary",solidHeader=TRUE,width=6,height=420,
                                      withSpinner(plotlyOutput("plot_timeline_q",height="360px"),type=6))),
                                fluidRow(
                                  box(title="PIP Status by Year",status="warning",solidHeader=TRUE,width=12,height=420,
                                      withSpinner(plotlyOutput("plot_pip_year",height="360px"),type=6))),
                        ),
                        tabItem(tabName="phase",
                                fluidRow(
                                  box(title="Trial Phase by Register",status="primary",solidHeader=TRUE,width=6,height=420,
                                      withSpinner(plotlyOutput("plot_phase",height="360px"),type=6)),
                                  box(title="Trial Phase by Status",status="info",solidHeader=TRUE,width=6,height=420,
                                      withSpinner(plotlyOutput("plot_phase_status",height="360px"),type=6))),
                                fluidRow(
                                  box(title="Trial Phase by Sponsor Type",status="warning",solidHeader=TRUE,width=12,height=420,
                                      withSpinner(plotlyOutput("plot_phase_sponsor",height="360px"),type=6))),
                        ),
                        tabItem(tabName="map",
                                fluidRow(
                                  box(title="Open Trials by Country", status="primary", solidHeader=TRUE, width=12,
                                      p(em("Completed trials are excluded. Circle size and colour reflect trial count. Zoom in to level 5+ to see a trial list below the map."),
                                        style="font-size:11px;opacity:0.7;margin-bottom:6px;"),
                                      withSpinner(leafletOutput("eu_map", height="520px"), type=6))
                                ),
                                uiOutput("map_table_ui")
                        ),
                        tabItem(tabName="about",
                                fluidRow(
                                  box(title="About This Dashboard",width=8,status="primary",solidHeader=TRUE,
                                      h3(icon("child")," EU Paediatric Clinical Trials Dashboard"),
                                      p("This dashboard provides a comprehensive view of paediatric clinical trials
                                        registered in the European Union. It integrates data from two official EU
                                        clinical trial registries and allows users to explore, filter, and analyse
                                        trial activity across conditions, countries, and time."),
                                      h4(icon("database")," Data Sources"),
                                      tags$ul(
                                        tags$li(tags$b("EUCTR")," — EU Clinical Trials Register (",
                                                tags$a("clinicaltrialsregister.eu", href="https://www.clinicaltrialsregister.eu", target="_blank"),
                                                "). The legacy EU registry covering trials authorised under Directive 2001/20/EC.
                                                Contains trials submitted from 2004 onwards."),
                                        tags$li(tags$b("CTIS")," — Clinical Trials Information System (",
                                                tags$a("euclinicaltrials.eu", href="https://euclinicaltrials.eu", target="_blank"),
                                                "). The new EU registry under Regulation (EU) No 536/2014, mandatory for new
                                                applications from January 2023 onwards.")
                                      ),
                                      h4(icon("filter")," Filters & Features"),
                                      tags$ul(
                                        tags$li(tags$b("Trial Status:"), " Filter by ongoing, completed, or other trial status."),
                                        tags$li(tags$b("Source Register:"), " View data from EUCTR, CTIS, or both."),
                                        tags$li(tags$b("Date Range:"), " Restrict results to a specific submission period."),
                                        tags$li(tags$b("MedDRA Organ Class / Condition:"), " Filter by therapeutic area using standardised MedDRA terminology. Numeric codes (EUCTR prefix format and CTIS EMA vocabulary codes) are automatically resolved to human-readable SOC names."),
                                        tags$li(tags$b("Country:"), " Restrict to trials active in one or more EU Member States."),
                                        tags$li(tags$b("PIP Status:"), " Filter by Paediatric Investigation Plan involvement."),
                                        tags$li(tags$b("Free-text search:"), " Search across trial titles and other fields.")
                                      ),
                                      h4(icon("sync")," Data Updates"),
                                      p("Trial data is retrieved from the registries using the ",
                                        tags$a("ctrdata", href="https://cran.r-project.org/package=ctrdata", target="_blank"),
                                        " R package and stored in a local SQLite database. The database is refreshed automatically every night.
                                        Overlap between registries is detected by normalised trial title matching (first 80 characters)."),
                                      h4(icon("history")," Changelog"),
                                      tags$ul(
                                        tags$li(tags$b("v2.0 (2026-03-29):"),
                                          tags$ul(
                                            tags$li("Filters: save current filter settings to a JSON file and reload them in a later session"),
                                            tags$li("Report: download a full PDF summary report with all charts and descriptive statistics (n, %, mean, median, SD, IQR) for the active filter selection")
                                          )
                                        ),
                                        tags$li(tags$b("v0.1.5 (2026-03-29):"),
                                          tags$ul(
                                            tags$li("Navigation: split Analytics page into Analytics and Phase Analysis tabs"),
                                            tags$li("Phase Analysis: trial phase by register, by status, and by sponsor type (Academic vs Industry)")
                                          )
                                        ),
                                        tags$li(tags$b("v0.1.4 (2026-03-28):"),
                                          tags$ul(
                                            tags$li("Sidebar: added Trial Phase filter (Phase I–IV)"),
                                            tags$li("Analytics: added Trial Phase bar chart (stacked by register)")
                                          )
                                        ),
                                        tags$li(tags$b("v0.1.3 (2026-03-28):"), " (v0.1.2 skipped)",
                                          tags$ul(
                                            tags$li("Map: new Map tab showing open/ongoing trials by country on an interactive Leaflet map; trial table appears below when zoomed in"),
                                            tags$li("Fix: EUCTR trial links now use correct URL format (/{country_code} instead of /results)"),
                                            tags$li("Data Explorer & Map: tables now sorted by submission date descending (most recent first)")
                                          )
                                        ),
                                        tags$li(tags$b("v0.1.1 (2026-03-28):"),
                                          tags$ul(
                                            tags$li("Overview: replaced Status Distribution chart with Sponsor Type by Register (Academic vs Industry, per register and combined)"),
                                            tags$li("Overview: CT numbers in '5 Most Recently Submitted Trials' are now clickable links to the respective registry"),
                                            tags$li("Analytics: added PIP Status by Year stacked bar chart"),
                                            tags$li("Data: MedDRA organ class numeric codes (EUCTR prefix format and CTIS EMA SOC codes) are now resolved to human-readable names")
                                          )
                                        ),
                                        tags$li(tags$b("v0.1:"), " Initial release.")
                                      ),
                                      hr(),
                                      p(em(paste0("v2.0 — ",Sys.Date())),style="opacity:0.5;")
                                  ),
                                  box(title="Technical Details",width=4,status="info",solidHeader=TRUE,
                                      h4(icon("code")," Built With"),
                                      tags$ul(
                                        tags$li(tags$b("R Shiny"), " + ", tags$b("shinydashboard")),
                                        tags$li(tags$b("ctrdata"), " — registry data retrieval"),
                                        tags$li(tags$b("plotly"), " — interactive visualisations"),
                                        tags$li(tags$b("DT"), " — interactive data tables"),
                                        tags$li(tags$b("dplyr / tidyr"), " — data wrangling"),
                                        tags$li(tags$b("SQLite"), " — local data storage")
                                      ),
                                      h4(icon("chart-bar")," Dashboard Tabs"),
                                      tags$ul(
                                        tags$li(tags$b("Overview:"), " Summary statistics, cumulative trends, sponsor type breakdown, registry overlap, and yearly submission charts. CT numbers link directly to their registry."),
                                        tags$li(tags$b("Data Explorer:"), " Searchable, filterable table of all trials with CSV/Excel export."),
                                        tags$li(tags$b("Analytics:"), " MedDRA term breakdowns, country-level activity, PIP status by register and by year, and quarterly timeline."),
                                        tags$li(tags$b("Phase Analysis:"), " Trial phase breakdown by register, status, and sponsor type (Academic vs Industry).")
                                      ),
                                      h4(icon("info-circle")," Notes"),
                                      p("Overlap detection is approximate and based on normalised title matching.
                                        Trials covering multiple countries or conditions may appear in multiple filter categories.
                                        Data reflects the state of the registries at the time of the last database update.")
                                  )
                                ),
                                fluidRow(
                                  box(title="MedDRA System Organ Class (SOC) Code Reference",
                                      width=12, status="info", solidHeader=TRUE,
                                      p("CTIS stores MedDRA organ classes as numeric EMA vocabulary codes.
                                        The table below shows the mapping used to resolve these codes to
                                        human-readable System Organ Class names."),
                                      DT::dataTableOutput("meddra_soc_table")
                                  )
                                ))
                      )
                    )
)

# ══════════════════════════════════════════════════════════════════════════════
# 9. SERVER
# ══════════════════════════════════════════════════════════════════════════════

server <- function(input, output, session) {
  rv <- reactiveValues(data = trials_data)
  
  tc <- reactive(THEMES[[input$theme_select]])
  output$active_theme <- renderUI({
    if (input$theme_select=="Nord") tags$style(NORD_CSS) else tags$style("")
  })
  
  plt_layout <- function(p, ...) {
    t <- tc()
    p %>% layout(paper_bgcolor=t$chart_bg,plot_bgcolor=t$chart_bg,
                 font=list(color=t$chart_fg),
                 xaxis=list(gridcolor=t$chart_grid,zerolinecolor=t$chart_grid,
                            tickfont=list(color=t$chart_fg),titlefont=list(color=t$chart_fg)),
                 yaxis=list(gridcolor=t$chart_grid,zerolinecolor=t$chart_grid,
                            tickfont=list(color=t$chart_fg),titlefont=list(color=t$chart_fg)),
                 legend=list(font=list(color=t$chart_fg)),...)
  }
  
  gg_theme <- function() {
    t <- tc()
    theme_minimal(base_size=13) %+replace% theme(
      text=element_text(colour=t$chart_fg),
      plot.background=element_rect(fill=t$chart_bg,colour=NA),
      panel.background=element_rect(fill=t$chart_bg,colour=NA),
      panel.grid.major=element_line(colour=t$chart_grid,linewidth=0.3),
      panel.grid.minor=element_blank(),
      axis.text=element_text(colour=t$chart_fg),
      legend.background=element_rect(fill=t$chart_bg,colour=NA),
      legend.text=element_text(colour=t$chart_fg),legend.position="bottom")
  }
  
  status_cols <- reactive(c("Ongoing"=tc()$s_ongoing,"Completed"=tc()$s_completed,"Other"=tc()$s_other))
  register_cols <- reactive(c("EUCTR"=tc()$r_euctr,"CTIS"=tc()$r_ctis))
  
  observe({
    req(rv$data)
    updateSelectizeInput(session,"organ_class_filter",
                         choices=extract_choices(rv$data$MEDDRA_organ_class),server=TRUE)
    updateSelectizeInput(session,"condition_filter",
                         choices=extract_choices(rv$data$MEDDRA_term),server=TRUE)
    updateSelectizeInput(session,"country_filter",
                         choices=extract_choices(rv$data$Member_state,sep=" / "),server=TRUE)
    updateSelectizeInput(session,"phase_filter",
                         choices=extract_choices(rv$data$phase),server=TRUE)
    d<-rv$data$submission_date_parsed[!is.na(rv$data$submission_date_parsed)]
    if(length(d)>0)updateDateRangeInput(session,"date_range",start=min(d),end=Sys.Date())
  })
  
  filt <- reactive({
    req(rv$data); df<-rv$data
    if(length(input$status_filter)>0)df<-df%>%filter(status%in%input$status_filter)
    if(length(input$register_filter)>0)df<-df%>%filter(register%in%input$register_filter)
    if(!is.null(input$date_range))
      df<-df%>%filter(is.na(submission_date_parsed)|
                        (submission_date_parsed>=input$date_range[1]&submission_date_parsed<=input$date_range[2]))
    if(length(input$organ_class_filter)>0)
      df<-df%>%filter(str_detect(MEDDRA_organ_class,regex(paste(input$organ_class_filter,collapse="|"),ignore_case=TRUE)))
    if(length(input$condition_filter)>0)
      df<-df%>%filter(str_detect(MEDDRA_term,regex(paste(input$condition_filter,collapse="|"),ignore_case=TRUE)))
    if(length(input$country_filter)>0){
      pat<-paste(str_replace_all(input$country_filter,"([.()\\[\\]{}+*?^$|\\\\])","\\\\\\1"),collapse="|")
      df<-df%>%filter(str_detect(Member_state,regex(pat,ignore_case=TRUE)))}
    if(length(input$phase_filter)>0){
      pat<-paste(str_replace_all(input$phase_filter,"([.()\\[\\]{}+*?^$|\\\\])","\\\\\\1"),collapse="|")
      df<-df%>%filter(str_detect(coalesce(phase,""),regex(pat,ignore_case=TRUE)))}
    if(input$pip_filter!="All")df<-df%>%filter(has_PIP==input$pip_filter)
    if(nzchar(input$text_search)){
      pat<-regex(input$text_search,ignore_case=TRUE)
      df<-df%>%filter(str_detect(Full_title,pat)|str_detect(DIMP_product_name,pat)|
                        str_detect(CT_number,pat)|str_detect(MEDDRA_term,pat))}
    df
  })
  
  overlap <- reactive(tryCatch(compute_overlap(filt()),
                               error = function(e) list(n_euctr=0,n_ctis=0,n_euctr_ctis=0,
                                                        only_euctr=0,only_ctis=0,n_total=0,n_overlap=0)))
  
  output$data_info <- renderText({
    if(!file.exists(CACHE_PATH)) return("Database not yet loaded.")
    mtime <- file.mtime(CACHE_PATH)
    sprintf("Last updated: %s", format(mtime, "%Y-%m-%d %H:%M"))
  })
  
  output$no_data_banner <- renderUI({
    if(is.null(rv$data))
      div(class="text-center",style="padding:40px;",
          h3(icon("database")," No data loaded"),
          p("Run ",tags$code("update_data.R")," to populate the database."))
  })
  
  output$vb_total<-renderValueBox(valueBox(format(if(is.null(rv$data))0 else nrow(filt()),big.mark=","),"Total Trials",icon=icon("flask"),color="blue"))
  output$vb_ongoing<-renderValueBox(valueBox(format(if(is.null(rv$data))0 else sum(filt()$status=="Ongoing",na.rm=TRUE),big.mark=","),"Ongoing",icon=icon("play-circle"),color="green"))
  output$vb_completed<-renderValueBox(valueBox(format(if(is.null(rv$data))0 else sum(filt()$status=="Completed",na.rm=TRUE),big.mark=","),"Completed",icon=icon("check-circle"),color="yellow"))
  output$vb_pip<-renderValueBox(valueBox(format(if(is.null(rv$data))0 else sum(filt()$has_PIP=="Yes",na.rm=TRUE),big.mark=","),"With PIP",icon=icon("child"),color="purple"))

  output$recent_trials_table <- DT::renderDataTable({
    req(rv$data)
    df <- filt() %>%
      filter(!is.na(submission_date_parsed)) %>%
      arrange(desc(submission_date_parsed)) %>%
      head(5) %>%
      mutate(`CT Number` = case_when(
        register == "EUCTR" ~ paste0('<a href="https://www.clinicaltrialsregister.eu/ctr-search/trial/', CT_number, '/', str_extract(`_id`, "[A-Z]{2,3}$"), '" target="_blank">', CT_number, '</a>'),
        register == "CTIS"  ~ { ct1 <- str_trim(str_split_fixed(CT_number, " / ", 2)[, 1]); paste0('<a href="https://euclinicaltrials.eu/ctis-public/view/', ct1, '" target="_blank">', ct1, '</a>') },
        TRUE ~ CT_number)) %>%
      select(`CT Number`, Full_title, submission_date_parsed) %>%
      rename(Title = Full_title, Submitted = submission_date_parsed)
    validate(need(nrow(df) > 0, "No submission date information available."))
    datatable(df, rownames = FALSE, class = "compact stripe hover", escape = FALSE,
              options = list(pageLength = 5, scrollX = TRUE, dom = "t",
                             columnDefs = list(list(width = "500px", targets = 1))))
  })

  output$plot_cumulative <- renderPlotly({
    df<-filt()%>%filter(!is.na(start_date))
    validate(need(nrow(df)>0,"No trials with known start date."))
    p<-ggplot(df,aes(x=start_date,colour=status))+stat_ecdf(linewidth=0.9)+
      scale_colour_manual(values=status_cols())+labs(x="Start date",y="Cumulative proportion",colour="Status")+gg_theme()
    ggplotly(p)%>%plt_layout(legend=list(orientation="h",y=-0.15))
  })
  
  output$plot_status_pie <- renderPlotly({
    df<-filt()%>%filter(!is.na(status_raw))%>%count(status_raw)%>%arrange(desc(n))
    validate(need(nrow(df)>0,"No data."))
    t<-tc()
    pal<-colorRampPalette(c(tc()$s_completed,tc()$s_ongoing,tc()$frost1,tc()$purple,tc()$orange,tc()$s_other))(nrow(df))
    plot_ly(df,labels=~status_raw,values=~n,type="pie",hole=0.45,
            marker=list(colors=pal,line=list(color=t$chart_bg,width=2)),
            textfont=list(color=t$chart_bg),textinfo="label+percent",hoverinfo="label+value+percent")%>%
      plt_layout(showlegend=TRUE,legend=list(orientation="v"))
  })
  
  output$plot_overlap <- renderPlot({
    req(rv$data);ol<-overlap();t<-tc()
    validate(need(ol$n_total>0,"No data."))
    if(has_eulerr){
      vals<-c()
      if(ol$only_euctr>0)vals["EUCTR"]<-ol$only_euctr
      if(ol$only_ctis>0)vals["CTIS"]<-ol$only_ctis
      if(ol$n_euctr_ctis>0)vals["EUCTR&CTIS"]<-ol$n_euctr_ctis
      if(length(vals)==0||all(vals==0))vals<-c("EUCTR"=max(1,ol$n_euctr),"CTIS"=max(1,ol$n_ctis))
      fit<-euler(vals)
      par(bg=t$chart_bg,mar=c(0,0,0,0))
      plot(fit,fills=list(fill=c(t$r_euctr,t$r_ctis),alpha=0.5),
           edges=list(col=t$fg0,lwd=1.5),labels=list(col=t$fg2,fontsize=16,font=2),
           quantities=list(col=t$chart_fg,fontsize=13),main=NULL)
    } else {
      par(bg=t$chart_bg,mar=c(3,3,1,1))
      barplot(c(ol$n_euctr,ol$n_ctis),names.arg=c("EUCTR","CTIS"),
              col=c(t$r_euctr,t$r_ctis),border=NA,col.axis=t$chart_fg,col.lab=t$chart_fg)
      mtext("Install 'eulerr' for Venn diagram",side=3,col=t$s_other,cex=0.8)
    }
  },bg="transparent")
  
  output$overlap_summary <- renderUI({
    req(rv$data);ol<-overlap();t<-tc()
    mk<-function(label,n,col){
      div(style=sprintf("padding:5px 8px;margin:2px 0;border-left:4px solid %s;background:%s;border-radius:3px;",col,t$bg2),
          span(tags$b(format(n,big.mark=",")),style=sprintf("font-size:14px;color:%s;",t$fg2)),
          span(label,style=sprintf("margin-left:6px;color:%s;font-size:12px;",t$fg0)))}
    pct<-function(n,total)if(total==0)"0%" else paste0(round(100*n/total,1),"%")
    tagList(
      mk(sprintf("EUCTR (%s)",pct(ol$n_euctr,ol$n_total)),ol$n_euctr,t$r_euctr),
      mk(sprintf("CTIS (%s)",pct(ol$n_ctis,ol$n_total)),ol$n_ctis,t$r_ctis),
      hr(style=sprintf("border-color:%s;margin:6px 0;",t$bg3)),
      mk("EUCTR \u2194 CTIS (shared)",ol$n_euctr_ctis,t$orange),
      div(style=sprintf("margin-top:6px;padding:5px 8px;background:%s;border-radius:3px;border:1px dashed %s;",t$bg2,t$bg3),
          span(sprintf("\u2248 %s shared (%s)",format(ol$n_overlap,big.mark=","),pct(ol$n_overlap,ol$n_total)),
               style=sprintf("color:%s;font-weight:600;font-size:12px;",t$frost1))))
  })
  
  output$plot_overlap_bar <- renderPlotly({
    req(rv$data);ol<-overlap();t<-tc()
    validate(need(ol$n_total>0,"No data."))
    df<-data.frame(cat=c("Only\nEUCTR","Only\nCTIS","Shared"),
                   n=c(ol$only_euctr,ol$only_ctis,ol$n_euctr_ctis),
                   col=c(t$r_euctr,t$r_ctis,t$orange),stringsAsFactors=FALSE)%>%filter(n>0)
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,x=~reorder(cat,-n),y=~n,type="bar",marker=list(color=~col))%>%
      plt_layout(xaxis=list(title="",tickfont=list(size=10)),yaxis=list(title="Trials"),showlegend=FALSE)
  })
  
  output$plot_yearly <- renderPlotly({
    df<-filt()%>%filter(!is.na(year))%>%count(year,register)
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,x=~year,y=~n,color=~register,colors=register_cols(),type="bar")%>%
      plt_layout(barmode="stack",legend=list(orientation="h",y=-0.2))
  })
  
  output$plot_register <- renderPlotly({
    base <- filt() %>% filter(!is.na(status_raw))
    validate(need(nrow(base) > 0, "No data."))
    df2 <- base %>% count(register, status_raw)
    t <- tc()
    all_statuses <- unique(df2$status_raw)
    pal <- setNames(
      colorRampPalette(c(t$s_completed, t$s_ongoing, t$frost1, t$purple, t$orange, t$s_other))(length(all_statuses)),
      all_statuses)
    plot_ly(df2, x = ~register, y = ~n, color = ~status_raw,
            colors = pal, type = "bar") %>%
      plt_layout(barmode = "stack", legend = list(orientation = "h", y = -0.2))
  })
  
  output$trials_table <- DT::renderDataTable({
    req(rv$data)
    df<-filt()%>%
      mutate(`CT Number`=case_when(
        register=="EUCTR"~paste0('<a href="https://www.clinicaltrialsregister.eu/ctr-search/trial/',CT_number,'/',str_extract(`_id`,"[A-Z]{2,3}$"),'" target="_blank">',CT_number,'</a>'),
        register=="CTIS" ~{ct1=str_trim(str_split_fixed(CT_number," / ",2)[,1]);paste0('<a href="https://euclinicaltrials.eu/ctis-public/view/',ct1,'" target="_blank">',ct1,'</a>')},
        TRUE~CT_number))%>%
      select(CT_number,register,Full_title,DIMP_product_name,MEDDRA_term,
             MEDDRA_organ_class,Member_state,n_countries,status_raw,has_PIP,
             phase,sponsor_type,submission_date_parsed,start_date,`CT Number`)%>%
      select(-CT_number)%>%
      rename(Register=register,Title=Full_title,
             Product=DIMP_product_name,Condition=MEDDRA_term,
             `Organ Class`=MEDDRA_organ_class,Country=Member_state,
             `# Countries`=n_countries,Status=status_raw,PIP=has_PIP,
             Phase=phase,Sponsor=sponsor_type,
             Submitted=submission_date_parsed,Started=start_date)%>%
      relocate(`CT Number`)
    datatable(df,filter="top",rownames=FALSE,class="compact stripe hover",escape=FALSE,
              options=list(pageLength=20,scrollX=TRUE,dom="lBfrtip",
                           order=list(list(12,"desc")),
                           columnDefs=list(list(width="350px",targets=2))))
  })
  
  output$dl_csv<-downloadHandler(filename=function()paste0("pediatric_trials_",Sys.Date(),".csv"),
                                 content=function(f)readr::write_csv(filt(),f))
  output$dl_excel<-downloadHandler(filename=function()paste0("pediatric_trials_",Sys.Date(),".xlsx"),
                                   content=function(f)writexl::write_xlsx(filt(),f))

  output$dl_filters<-downloadHandler(
    filename=function()paste0("filters_",Sys.Date(),".json"),
    content=function(f){
      settings<-list(
        status_filter   = input$status_filter,
        register_filter = input$register_filter,
        date_range      = as.character(input$date_range),
        organ_class_filter = input$organ_class_filter,
        condition_filter   = input$condition_filter,
        country_filter     = input$country_filter,
        phase_filter       = input$phase_filter,
        pip_filter         = input$pip_filter,
        text_search        = input$text_search
      )
      jsonlite::write_json(settings,f,auto_unbox=TRUE)
    })

  output$dl_report <- downloadHandler(
    filename = function() paste0("paediatric_trials_report_", Sys.Date(), ".pdf"),
    content  = function(file) {
      notif <- showNotification("Generating PDF report\u2026 this may take 20\u201330 seconds.",
                                duration = NULL, type = "message")
      on.exit(removeNotification(notif), add = TRUE)

      tmp_data <- tempfile(fileext = ".rds")
      saveRDS(filt(), tmp_data)
      on.exit(unlink(tmp_data), add = TRUE)

      filters <- list(
        status      = input$status_filter,
        register    = input$register_filter,
        date_range  = as.character(input$date_range),
        organ_class = if (length(input$organ_class_filter) > 0) input$organ_class_filter else "All",
        condition   = if (length(input$condition_filter)   > 0) input$condition_filter   else "All",
        country     = if (length(input$country_filter)     > 0) input$country_filter     else "All",
        phase       = if (length(input$phase_filter)       > 0) input$phase_filter       else "All",
        pip         = input$pip_filter,
        text_search = if (nzchar(input$text_search)) input$text_search else "(none)"
      )

      # Ensure pdflatex is on PATH (handles TinyTeX on macOS where it isn't
      # in the system PATH, but is a no-op on shinyapps.io / Docker where
      # system texlive puts pdflatex in /usr/bin directly)
      if (!nzchar(Sys.which("pdflatex"))) {
        tl_candidates <- c(
          path.expand("~/Library/TinyTeX/bin"),
          path.expand("~/.TinyTeX/bin"),
          "/opt/TinyTeX/bin"
        )
        for (d in tl_candidates) {
          subs <- list.files(d, full.names = TRUE)
          if (length(subs) > 0 && file.exists(file.path(subs[[1]], "pdflatex"))) {
            orig_path <- Sys.getenv("PATH")
            Sys.setenv(PATH = paste(c(subs[[1]], orig_path), collapse = ":"))
            on.exit(Sys.setenv(PATH = orig_path), add = TRUE)
            break
          }
        }
      }

      if (!nzchar(Sys.which("pdflatex"))) {
        showNotification("pdflatex not found. Install TinyTeX or a system LaTeX distribution.",
                         type = "error", duration = 10)
        return()
      }

      tryCatch(
        rmarkdown::render(
          input       = file.path(getwd(), "report.Rmd"),
          output_file = file,
          params      = list(data_path = tmp_data, filters = filters),
          envir       = new.env(parent = globalenv()),
          quiet       = TRUE
        ),
        error = function(e) {
          showNotification(paste("PDF generation failed:", conditionMessage(e)),
                           type = "error", duration = 15)
        }
      )
    }
  )

  observeEvent(input$ul_filters,{
    req(input$ul_filters)
    tryCatch({
      s<-jsonlite::read_json(input$ul_filters$datapath,simplifyVector=TRUE)
      if(!is.null(s$status_filter))
        updateCheckboxGroupInput(session,"status_filter",selected=s$status_filter)
      if(!is.null(s$register_filter))
        updateCheckboxGroupInput(session,"register_filter",selected=s$register_filter)
      if(!is.null(s$date_range)&&length(s$date_range)==2)
        updateDateRangeInput(session,"date_range",start=s$date_range[1],end=s$date_range[2])
      if(!is.null(s$organ_class_filter))
        updateSelectizeInput(session,"organ_class_filter",selected=s$organ_class_filter)
      if(!is.null(s$condition_filter))
        updateSelectizeInput(session,"condition_filter",selected=s$condition_filter)
      if(!is.null(s$country_filter))
        updateSelectizeInput(session,"country_filter",selected=s$country_filter)
      if(!is.null(s$phase_filter))
        updateSelectizeInput(session,"phase_filter",selected=s$phase_filter)
      if(!is.null(s$pip_filter))
        updateSelectInput(session,"pip_filter",selected=s$pip_filter)
      if(!is.null(s$text_search))
        updateTextInput(session,"text_search",value=s$text_search)
    },error=function(e)showNotification(paste("Could not load filters:",e$message),type="error"))
  })
  
  output$plot_organ <- renderPlotly({
    df<-filt()%>%filter(!is.na(MEDDRA_organ_class))%>%
      separate_rows(MEDDRA_organ_class,sep=" / ")%>%
      mutate(MEDDRA_organ_class=str_trim(MEDDRA_organ_class))%>%
      filter(MEDDRA_organ_class!="")%>%count(MEDDRA_organ_class,sort=TRUE)%>%head(input$top_n_organ)
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,y=~reorder(MEDDRA_organ_class,n),x=~n,type="bar",orientation="h",
            marker=list(color=tc()$frost2))%>%plt_layout(margin=list(l=220))
  })
  
  output$plot_term <- renderPlotly({
    df<-filt()%>%filter(!is.na(MEDDRA_term))%>%
      separate_rows(MEDDRA_term,sep=" / ")%>%
      mutate(MEDDRA_term=str_trim(MEDDRA_term))%>%
      filter(MEDDRA_term!="")%>%count(MEDDRA_term,sort=TRUE)%>%head(input$top_n_term)
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,y=~reorder(MEDDRA_term,n),x=~n,type="bar",orientation="h",
            marker=list(color=tc()$green))%>%plt_layout(margin=list(l=260))
  })
  
  output$plot_country <- renderPlotly({
    df<-filt()%>%filter(!is.na(Member_state))%>%
      separate_rows(Member_state,sep=" / |, ")%>%
      mutate(Member_state=str_trim(Member_state))%>%filter(Member_state!="")%>%
      count(Member_state,sort=TRUE)%>%head(30)
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,x=~reorder(Member_state,-n),y=~n,type="bar",marker=list(color=tc()$frost1))%>%
      plt_layout(margin=list(b=120),xaxis=list(tickangle=-45,tickfont=list(color=tc()$chart_fg)))
  })
  
  output$plot_pip <- renderPlotly({
    df<-filt()%>%count(has_PIP,register)%>%filter(!is.na(has_PIP))
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,x=~has_PIP,y=~n,color=~register,colors=register_cols(),type="bar")%>%
      plt_layout(barmode="group",legend=list(orientation="h",y=-0.2))
  })

  output$plot_pip_year <- renderPlotly({
    df<-filt()%>%filter(!is.na(year),!is.na(has_PIP))%>%count(year,has_PIP)
    validate(need(nrow(df)>0,"No data."))
    pal<-c("Yes"=tc()$frost1,"No"=tc()$orange,"Unknown"=tc()$bg3)
    plot_ly(df,x=~year,y=~n,color=~has_PIP,colors=pal,type="bar")%>%
      plt_layout(barmode="stack",xaxis=list(title="Submission Year"),
                 yaxis=list(title="Number of Trials"),legend=list(orientation="h",y=-0.2))
  })
  
  output$plot_phase <- renderPlotly({
    df <- filt() %>%
      filter(!is.na(phase) & nzchar(str_trim(phase))) %>%
      separate_rows(phase, sep = " / ") %>%
      mutate(phase = str_trim(phase)) %>%
      filter(nzchar(phase)) %>%
      count(phase, register) %>%
      mutate(phase = factor(phase, levels = c("Phase I","Phase II","Phase III","Phase IV")))
    validate(need(nrow(df) > 0, "No phase data available."))
    plot_ly(df, x = ~phase, y = ~n, color = ~register, colors = register_cols(), type = "bar",
            text = ~n, textposition = "outside", hoverinfo = "x+y+text") %>%
      plt_layout(barmode = "stack",
                 xaxis = list(title = "Trial Phase"),
                 yaxis = list(title = "Number of Trials"),
                 legend = list(orientation = "h", y = -0.2))
  })

  output$plot_phase_status <- renderPlotly({
    df <- filt() %>%
      filter(!is.na(phase) & nzchar(str_trim(phase)), !is.na(status)) %>%
      separate_rows(phase, sep = " / ") %>%
      mutate(phase = str_trim(phase)) %>%
      filter(nzchar(phase)) %>%
      count(phase, status) %>%
      mutate(phase = factor(phase, levels = c("Phase I","Phase II","Phase III","Phase IV")))
    validate(need(nrow(df) > 0, "No phase data available."))
    pal <- status_cols()
    plot_ly(df, x = ~phase, y = ~n, color = ~status, colors = pal, type = "bar",
            text = ~n, textposition = "outside", hoverinfo = "x+y+text") %>%
      plt_layout(barmode = "stack",
                 xaxis = list(title = "Trial Phase"),
                 yaxis = list(title = "Number of Trials"),
                 legend = list(orientation = "h", y = -0.2))
  })

  output$plot_phase_sponsor <- renderPlotly({
    df <- filt() %>%
      filter(!is.na(phase) & nzchar(str_trim(phase)), !is.na(sponsor_type)) %>%
      separate_rows(phase, sep = " / ") %>%
      mutate(phase = str_trim(phase)) %>%
      filter(nzchar(phase)) %>%
      count(phase, sponsor_type) %>%
      mutate(phase = factor(phase, levels = c("Phase I","Phase II","Phase III","Phase IV")))
    validate(need(nrow(df) > 0, "No phase / sponsor type data available."))
    t <- tc()
    pal <- c("Academic" = t$frost1, "Industry" = t$orange)
    plot_ly(df, x = ~phase, y = ~n, color = ~sponsor_type, colors = pal, type = "bar",
            text = ~n, textposition = "outside", hoverinfo = "x+y+text") %>%
      plt_layout(barmode = "group",
                 xaxis = list(title = "Trial Phase"),
                 yaxis = list(title = "Number of Trials"),
                 legend = list(orientation = "h", y = -0.2))
  })

  output$plot_timeline_q <- renderPlotly({
    df<-filt()%>%filter(!is.na(start_date))%>%mutate(quarter=floor_date(start_date,"quarter"))%>%
      count(quarter,register)
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,x=~quarter,y=~n,color=~register,colors=register_cols(),type="bar")%>%
      plt_layout(barmode="stack",legend=list(orientation="h",y=-0.2))
  })

  output$plot_sponsor_top <- renderPlotly({
    df<-filt()%>%filter(!is.na(sponsor_type))%>%count(sponsor_type,register)
    validate(need(nrow(df)>0,"No sponsor type data available."))
    all_rows<-df%>%group_by(sponsor_type)%>%summarise(n=sum(n),.groups="drop")%>%mutate(register="All")
    df<-bind_rows(df,all_rows)%>%mutate(register=factor(register,levels=c("CTIS","EUCTR","All")))
    t<-tc()
    pal<-c("Academic"=t$frost1,"Industry"=t$orange)
    plot_ly(df,x=~register,y=~n,color=~sponsor_type,colors=pal,type="bar",
            text=~n,textposition="outside",hoverinfo="x+y+text")%>%
      plt_layout(barmode="group",xaxis=list(title=""),yaxis=list(title="Number of Trials"))
  })

  output$plot_sponsor <- renderPlotly({
    df<-filt()%>%filter(!is.na(sponsor_type))%>%count(sponsor_type,register)
    validate(need(nrow(df)>0,"No sponsor type data available."))
    all_rows<-df%>%group_by(sponsor_type)%>%summarise(n=sum(n),.groups="drop")%>%mutate(register="All")
    df<-bind_rows(df,all_rows)%>%mutate(register=factor(register,levels=c("CTIS","EUCTR","All")))
    t<-tc()
    pal<-c("Academic"=t$frost1,"Industry"=t$orange)
    plot_ly(df,x=~register,y=~n,color=~sponsor_type,colors=pal,type="bar",
            text=~n,textposition="outside",hoverinfo="x+y+text")%>%
      plt_layout(barmode="group",xaxis=list(title=""),yaxis=list(title="Number of Trials"))
  })

  output$meddra_soc_table <- DT::renderDataTable({
    df <- data.frame(
      Code = names(ctis_soc_lookup),
      `System Organ Class` = unname(ctis_soc_lookup),
      check.names = FALSE, stringsAsFactors = FALSE)
    datatable(df, rownames = FALSE, class = "compact stripe hover",
              options = list(pageLength = 30, dom = "ftp", scrollX = TRUE))
  })

  # ── Map tab ───────────────────────────────────────────────────────────────

  eu_map_ongoing <- reactive({
    req(rv$data)
    df <- rv$data %>% filter(status != "Completed")
    # Apply all sidebar filters except status (map always shows Ongoing)
    if(length(input$register_filter) > 0)
      df <- df %>% filter(register %in% input$register_filter)
    if(!is.null(input$date_range))
      df <- df %>% filter(is.na(submission_date_parsed) |
                            (submission_date_parsed >= input$date_range[1] &
                             submission_date_parsed <= input$date_range[2]))
    if(length(input$organ_class_filter) > 0)
      df <- df %>% filter(str_detect(MEDDRA_organ_class,
                                     regex(paste(input$organ_class_filter, collapse="|"), ignore_case=TRUE)))
    if(length(input$condition_filter) > 0)
      df <- df %>% filter(str_detect(MEDDRA_term,
                                     regex(paste(input$condition_filter, collapse="|"), ignore_case=TRUE)))
    if(length(input$country_filter) > 0) {
      pat <- paste(str_replace_all(input$country_filter, "([.()\\[\\]{}+*?^$|\\\\])", "\\\\\\1"), collapse="|")
      df <- df %>% filter(str_detect(Member_state, regex(pat, ignore_case=TRUE)))
    }
    if(input$pip_filter != "All")
      df <- df %>% filter(has_PIP == input$pip_filter)
    if(nzchar(input$text_search)) {
      pat <- regex(input$text_search, ignore_case=TRUE)
      df <- df %>% filter(str_detect(Full_title, pat) | str_detect(DIMP_product_name, pat) |
                            str_detect(CT_number, pat) | str_detect(MEDDRA_term, pat))
    }
    df %>%
      filter(!is.na(Member_state)) %>%
      separate_rows(Member_state, sep = " / ") %>%
      mutate(Member_state = str_trim(Member_state)) %>%
      filter(Member_state != "")
  })

  eu_country_counts <- reactive({
    eu_map_ongoing() %>%
      group_by(Member_state) %>%
      summarise(n_trials = n_distinct(`_id`), .groups = "drop") %>%
      left_join(COUNTRY_COORDS, by = c("Member_state" = "country")) %>%
      filter(!is.na(lat))
  })

  output$eu_map <- renderLeaflet({
    cc <- eu_country_counts()
    t  <- tc()
    pal <- colorNumeric(
      c(t$green, t$yellow, t$orange, t$red),
      domain = cc$n_trials, na.color = "grey")
    m <- leaflet(options = leafletOptions(minZoom = 2)) %>%
      addProviderTiles("Esri.WorldTopoMap") %>%
      setView(lng = 15, lat = 52, zoom = 4)
    if (nrow(cc) > 0) {
      m <- m %>%
        addCircleMarkers(
          data = cc,
          lat = ~lat, lng = ~lng,
          radius = ~pmin(8 + log1p(n_trials) * 4, 35),
          color = "white", weight = 1,
          fillColor = ~pal(n_trials),
          fillOpacity = 0.85,
          label = ~as.character(n_trials),
          labelOptions = labelOptions(
            noHide = TRUE, textOnly = TRUE, direction = "center",
            style = list("font-weight" = "bold", "color" = "white",
                         "font-size" = "11px")),
          popup = ~paste0("<b>", Member_state, "</b><br/>",
                          n_trials, " open trial(s)")
        ) %>%
        addLegend(
          position = "bottomright", pal = pal, values = cc$n_trials,
          title = "Open Trials", opacity = 0.85
        )
    }
    m
  })

  output$map_table_ui <- renderUI({
    zoom <- input$eu_map_zoom
    if (!is.null(zoom) && zoom >= 5) {
      fluidRow(
        box(title = "Trials in Current Map View", status = "info",
            solidHeader = TRUE, width = 12,
            withSpinner(DT::dataTableOutput("map_trials_table"), type = 6))
      )
    }
  })

  output$map_trials_table <- DT::renderDataTable({
    req(input$eu_map_bounds, input$eu_map_zoom)
    req(input$eu_map_zoom >= 5)
    bounds <- input$eu_map_bounds
    visible_ids <- eu_map_ongoing() %>%
      left_join(COUNTRY_COORDS, by = c("Member_state" = "country")) %>%
      filter(!is.na(lat),
             lat >= bounds$south & lat <= bounds$north,
             lng >= bounds$west & lng <= bounds$east) %>%
      pull(`_id`) %>% unique()
    validate(need(length(visible_ids) > 0, "No open trials in current map view."))
    rv$data %>%
      filter(`_id` %in% visible_ids) %>%
      arrange(desc(submission_date_parsed)) %>%
      mutate(`CT Number` = case_when(
        register == "EUCTR" ~ paste0(
          '<a href="https://www.clinicaltrialsregister.eu/ctr-search/trial/',
          CT_number, "/", str_extract(`_id`, "[A-Z]{2,3}$"),
          '" target="_blank">', CT_number, "</a>"),
        register == "CTIS"  ~ { ct1 <- str_trim(str_split_fixed(CT_number, " / ", 2)[, 1]);
                                paste0('<a href="https://euclinicaltrials.eu/ctis-public/view/',
                                       ct1, '" target="_blank">', ct1, '</a>') },
        TRUE ~ CT_number)) %>%
      select(`CT Number`, register, Full_title, Member_state, MEDDRA_term,
             status_raw, submission_date_parsed) %>%
      rename(Register = register, Title = Full_title, Country = Member_state,
             Condition = MEDDRA_term, Status = status_raw, Submitted = submission_date_parsed) %>%
      datatable(rownames = FALSE, class = "compact stripe hover", escape = FALSE,
                options = list(pageLength = 15, scrollX = TRUE, dom = "lBfrtip",
                               order = list(list(6, "desc")),
                               columnDefs = list(list(width = "350px", targets = 2))))
  })

}

shinyApp(ui, server)