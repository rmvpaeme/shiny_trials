# ============================================================================
# app.R  (v0.5.0 — Free-text searches sponsor, phase funnel, completion cohort chart, sponsor comparison, remove eulerr)
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

clean_meddra_term <- function(x) {
  if (is.na(x) || x == "") return(NA_character_)
  parts <- trimws(strsplit(x, " / ")[[1]])
  # Normalise American → MedDRA preferred British spelling
  parts <- gsub("Hemophilia", "Haemophilia", parts)
  parts <- gsub("hemophilia", "haemophilia", parts)
  parts <- gsub("Leukemia",   "Leukaemia",   parts)
  parts <- gsub("leukemia",   "leukaemia",   parts)
  parts <- gsub("\\bTumors\\b",  "Tumours",  parts)
  parts <- gsub("\\btumors\\b",  "tumours",  parts)
  parts <- gsub("\\bTumor\\b",   "Tumour",   parts)
  parts <- gsub("\\btumor\\b",   "tumour",   parts)
  parts <- gsub("Diarrhea",   "Diarrhoea",   parts)
  parts <- gsub("diarrhea",   "diarrhoea",   parts)
  parts <- gsub("Gastroesophag",    "Gastrooesophag",    parts)
  parts <- gsub("gastroesophag",    "gastrooesophag",    parts)
  parts <- gsub("(?<![oO])Esophag", "Oesophag", parts, perl = TRUE)
  parts <- gsub("(?<![oO])esophag", "oesophag", parts, perl = TRUE)
  parts <- gsub("Tyrosinemia", "Tyrosinaemia", parts)
  parts <- gsub("tyrosinemia", "tyrosinaemia", parts)
  parts <- gsub("Localized",  "Localised",   parts)
  parts <- gsub("localized",  "localised",   parts)
  # Roman numeral type notation → Arabic (order: IV before III before II before I)
  parts <- gsub("\\bType IV\\b",  "Type 4", parts)
  parts <- gsub("\\bType III\\b", "Type 3", parts)
  parts <- gsub("\\bType II\\b",  "Type 2", parts)
  parts <- gsub("\\bType I\\b",   "Type 1", parts)
  parts <- gsub("\\btype IV\\b",  "type 4", parts)
  parts <- gsub("\\btype III\\b", "type 3", parts)
  parts <- gsub("\\btype II\\b",  "type 2", parts)
  parts <- gsub("\\btype I\\b",   "type 1", parts)
  parts <- unique(trimws(parts[parts != ""]))
  if (length(parts) == 0) NA_character_ else paste(parts, collapse = " / ")
}

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
  # Normalise "unspecified incl cysts and polyps" (EUCTR) to canonical form with parens (CTIS)
  cleaned <- sub("unspecified incl cysts and polyps",
                 "unspecified (incl cysts and polyps)", cleaned, fixed = TRUE)
  cleaned <- unique(trimws(cleaned[!is.na(cleaned)]))
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
  .skin-blue .main-header .logo{background:%s!important;color:%s!important;font-weight:700;font-size:15px}
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

normalize_sponsor_name <- function(x) {
  x <- str_trim(as.character(x))
  x[x %in% c("NA", "", "NULL")] <- NA_character_
  # Collapse multiple spaces (raw EUCTR data has "GmbH  Co. KG" with double space)
  x <- str_replace_all(x, "\\s{2,}", " ")

  # ── Pre-step: structural cleanup before any token removal ─────────────────
  # Strip "a wholly[-owned] subsidiary of..." and similar sub-company noise
  x <- str_replace_all(x, regex(",?\\s*(an?\\s+)?wholly.owned\\s+subsidiary.*$|,?\\s*an?\\s+indirect.*subsidiary.*$|,?\\s*a\\s+wholly\\s+owned.*$|,?\\s*como\\s+filial.*$", ignore_case = TRUE), "")
  # Strip "- [long expansion]" (acronym + full name), with or without spaces
  x <- str_replace_all(x, "\\s*-\\s*[A-Z][A-Za-z\\s]{15,}$", "")
  # Strip trailing ", Department/Unit/Ward/Section..." qualifiers
  x <- str_replace_all(x,
    regex(",\\s*(Department|Dept|Unit|Ward|Section|Centre|Center|Division|Faculty|School|Institute|Laboratory|Clinic|Service|Team).*$",
          ignore_case = TRUE), "")
  x <- str_trim(x)

  # ── Strip legal-entity tokens early so they don't trigger is_abbrev ────────
  # (e.g. "ADAMED Pharma S.A." has "S.A." which would block title-casing)
  legal_tok_early <- paste0(
    "\\b(GmbH\\s+&\\s+Co\\.?\\s*KGaA|GmbH\\s+&\\s+Co\\.?\\s*KG|",
    "GmbH\\s+Co\\.?\\s*KGaA|GmbH\\s+Co\\.?\\s*KG|",
    "GmbH|AG|SE|KGaA|KG|LLC|L\\.L\\.C\\.?|SNC|SRL|SAS|SARL|DAC|",
    "Inc\\.?|Incorporated|Ltd\\.?|Limited|",
    "B\\.V\\.?|N\\.V\\.?|S\\.A\\.?|SA|S\\.L\\.?|SL\\.?|S\\.p\\.A\\.?|S\\.r\\.l\\.?|",
    "Corp\\.?|Corporation|PLC|LP\\.?|L\\.P\\.?|AB|Oy|NV|BV|A\\/S|",
    "&\\s*Co\\.?|and\\s+Co\\.?|Sp\\.\\s*z\\s*o\\.\\s*o\\.)\\b")
  x <- str_replace_all(x, regex(legal_tok_early, ignore_case = TRUE), " ")
  x <- str_replace_all(x, "(^[,\\.\\-/\\s]+|[,\\.\\-/\\s]+$)", "")
  x <- str_replace_all(x, "\\s{2,}", " ")
  x <- str_trim(x)

  # Title-case everything EXCEPT dotted abbreviations (A.I.E.O.P., A.O., etc.)
  is_abbrev <- !is.na(x) & str_detect(x, "[A-Za-z]\\.[A-Za-z]")
  x <- ifelse(!is.na(x) & !is_abbrev, str_to_title(x), x)

  # ── Step 1: prefix-brand extraction ───────────────────────────────────────
  # For known pharma brands: if the string STARTS WITH the brand name
  # (optionally followed by junk), return the canonical brand.
  # Order matters — more specific entries before general ones.
  brand_prefixes <- list(
    c("4D\\s+Molecular",                "4D Molecular Therapeutics"),
    c("4D\\s+Pharma",                  "4D Pharma"),
    c("A\\.?I\\.?E\\.?O\\.?P\\.?",    "AIEOP"),
    c("AIEOP",                         "AIEOP"),
    c("Ap-Hp",                         "AP-HP"),
    c("Aphp",                          "AP-HP"),
    c("Ap-Hp/Drcd",                    "AP-HP"),
    c("Assistance\\s+Publique",        "AP-HP"),
    c("Assistanc-Publique",            "AP-HP"),
    c("AbbVie",                        "AbbVie"),
    c("Abbott\\s+Laboratories",        "Abbott"),
    c("Abbott",                        "Abbott"),
    c("Actelion",                      "Actelion"),
    c("Aimmune",                       "Aimmune"),
    c("Alexion",                       "Alexion"),
    c("Allergan",                      "Allergan"),
    c("Amgen",                         "Amgen"),
    c("Astellas",                      "Astellas"),
    c("AstraZeneca",                   "AstraZeneca"),
    c("Baxalta",                       "Baxalta"),
    c("Baxter",                        "Baxter"),
    c("Bayer",                         "Bayer"),
    c("Biogen",                        "Biogen"),
    c("BioMarin",                      "BioMarin"),
    c("Biomarin",                      "BioMarin"),
    c("bluebird\\s+bio",               "bluebird bio"),
    c("Blueprint\\s+Medicines",        "Blueprint Medicines"),
    c("Boehringer\\s+Ingelheim",       "Boehringer Ingelheim"),
    c("Bristol.Myers\\s+Squibb",       "BMS"),
    c("CSL\\s+Behring",                "CSL Behring"),
    c("Celgene",                       "Celgene"),
    c("Chiesi",                        "Chiesi"),
    c("Eisai",                         "Eisai"),
    c("Eli\\s+Lilly",                  "Lilly"),
    c("F\\.?\\s*Hoffmann.La\\s+Roche", "Roche"),
    c("Genentech",                     "Genentech"),
    c("Gilead",                        "Gilead"),
    c("GlaxoSmithKline\\s+Biologicals","GSK Biologicals"),
    c("GlaxoSmithKline",               "GSK"),
    c("GSK\\s+Biologicals",            "GSK Biologicals"),
    c("GSK",                           "GSK"),
    c("GW\\s+(Pharma|Research)",       "GW Pharma"),
    c("Hoffmann.La\\s+Roche",          "Roche"),
    c("Ipsen",                         "Ipsen"),
    c("Janssen.Cilag",                 "Janssen"),
    c("Janssen",                       "Janssen"),
    c("Jazz\\s+Pharmaceuticals",       "Jazz Pharmaceuticals"),
    c("Kyowa\\s+Kirin",                "Kyowa Kirin"),
    c("Lilly",                         "Lilly"),
    c("Lundbeck",                      "Lundbeck"),
    c("Medimmune",                     "MedImmune"),
    c("Merck\\s+Sharp.{0,8}Dohme",     "MSD"),
    c("MSD\\s+Sharp.{0,8}Dohme",       "MSD"),
    c("Merck\\s+KGaA",                 "Merck KGaA"),
    c("Merck\\s+&\\s+Co",              "MSD"),
    c("Merck\\s+and\\s+Co",            "MSD"),
    c("MSD",                           "MSD"),
    c("Novartis\\s+Vaccines",          "Novartis Vaccines"),
    c("Novartis",                      "Novartis"),
    c("Novo\\s+Nordisk",               "Novo Nordisk"),
    c("Octapharma",                    "Octapharma"),
    c("Otsuka",                        "Otsuka"),
    c("Pfizer",                        "Pfizer"),
    c("PTC\\s+Therapeutics",           "PTC Therapeutics"),
    c("Regeneron",                     "Regeneron"),
    c("Roche",                         "Roche"),
    c("Sanofi\\s+Pasteur",             "Sanofi Pasteur"),
    c("Sanofi.Aventis",                "Sanofi"),
    c("Sanofi",                        "Sanofi"),
    c("Servier",                       "Servier"),
    c("Shire",                         "Shire"),
    c("Sobi",                          "Sobi"),
    c("Swedish\\s+Orphan\\s+Biovitrum","Sobi"),
    c("Takeda",                        "Takeda"),
    c("Teva",                          "Teva"),
    c("UCB\\s+Biosciences",            "UCB"),
    c("UCB\\s+Biopharma",              "UCB"),
    c("UCB\\s+Pharma",                 "UCB"),
    c("UCB",                           "UCB"),
    c("Vertex",                        "Vertex"),
    c("Wyeth",                         "Wyeth"),
    c("Zogenix",                       "Zogenix")
  )
  for (bp in brand_prefixes) {
    pat <- regex(paste0("^", bp[[1]], "(\\s|,|\\.|$)"), ignore_case = TRUE)
    x <- ifelse(!is.na(x) & str_detect(x, pat), bp[[2]], x)
  }

  # ── Step 2: for non-brand entries, strip pharma/country noise ────────────
  # Pharma-descriptor words that are noise when standalone
  pharma_tok <- paste0(
    "\\b(R\\s*&\\s*D|\\bR[dD]\\b|R\\s+D\\b|",   # R&D / RD / R D artifact
    "Pharmaceuticals?|Pharma|Biopharmaceuticals?|Biopharma|",
    "Biosciences?|Biotechnology|Biotech|Therapeutics?|",
    "Laboratories?|Sciences?|Research\\s+&\\s+Development|",
    "Research\\s+and\\s+Development|Research|Development|",
    "Healthcare|Health\\s+Care|Oncology|Biologics?|",
    "Products?|Ventures?|Partners?|Group|Holdings?|Division)\\b")
  x <- str_replace_all(x, regex(pharma_tok, ignore_case = TRUE), " ")

  # Country/region subsidiary words
  country_tok <- paste0(
    "\\b(Deutschland|Germany|France|Espa[nñ]a|Spain|Italy|Italia|",
    "Netherlands|Nederland|Belgium|Belgique|Austria|[Öö]sterreich|",
    "Switzerland|Schweiz|Suisse|Sweden|Sverige|Denmark|Danmark|",
    "Finland|Norway|Norge|Poland|Polska|Portugal|Greece|Ireland|",
    "Czech|Hungary|Romania|Slovakia|Slovenia|Croatia|",
    "UK|Europe|European|International|Worldwide|Global|",
    "North\\s+America|Latin\\s+America|Asia\\s+Pacific)\\b")
  x <- str_replace_all(x, regex(country_tok, ignore_case = TRUE), " ")

  # Remove stray punctuation and collapse spaces
  x <- str_replace_all(x, "(^[,\\.\\-/\\s]+|[,\\.\\-/\\s]+$)", "")
  x <- str_replace_all(x, "\\s{2,}", " ")
  x <- str_trim(x)

  x[x %in% c("Na", "NA", "")] <- NA_character_
  x
}

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
# 5. NORMALISATION LOGGER
# ══════════════════════════════════════════════════════════════════════════════

write_norm_log <- function(raw_vec, norm_vec, register_vec, type_name, log_dir) {
  tryCatch({
    log_df <- data.frame(
      register   = as.character(register_vec),
      raw        = as.character(raw_vec),
      normalised = as.character(norm_vec),
      stringsAsFactors = FALSE
    ) %>%
      group_by(register, raw, normalised) %>%
      summarise(n_trials = n(), .groups = "drop") %>%
      mutate(changed = !is.na(raw) & raw != coalesce(normalised, "")) %>%
      arrange(register, desc(n_trials))
    log_path <- file.path(log_dir, paste0(type_name, "_normalisation_log.csv"))
    write.csv(log_df, log_path, row.names = FALSE)
    message(sprintf("%s normalisation log: %d rows, %d changed -> %s",
                    type_name, nrow(log_df), sum(log_df$changed, na.rm = TRUE), log_path))
  }, error = function(e) {
    message(sprintf("Could not write %s log: %s", type_name, e$message))
  })
}

# ══════════════════════════════════════════════════════════════════════════════
# 6. DATA PREPARATION
# (normalisation logs written by write_norm_log defined in section 5)
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
    "b1_sponsor.b11_name_of_sponsor",
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
    "authorizedApplication.authorizedPartI.sponsors.organisation.name",
    "authorizedApplication.authorizedPartI.sponsors.commercial",
    "trialPhase",
    "authorizedApplication.applicationInfo.decisionDate")
  
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
    "b1_sponsor.b11_name_of_sponsor",
    "b1_sponsor.b31_and_b32_status_of_the_sponsor",
    "authorizedApplication.authorizedPartI.sponsors.organisation.name",
    "authorizedApplication.authorizedPartI.sponsors.commercial",
    "e71_human_pharmacology_phase_i","e72_therapeutic_exploratory_phase_ii",
    "e73_therapeutic_confirmatory_phase_iii","e74_therapeutic_use_phase_iv",
    "trialPhase",
    "authorizedApplication.applicationInfo.decisionDate")
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
  
  raw_country_for_log <- result$Member_state
  result <- result %>% mutate(Member_state = clean_member_state(Member_state))
  write_norm_log(raw_country_for_log, result$Member_state, result$register, "country", dirname(db_path))
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
  # Identify EUCTR "transitioned" title_keys — used below to prefer CTIS records
  raw_status_cols_pre <- intersect(c("trial_status_raw", "p_end_of_trial_status"), names(result))
  trans_pat_pre <- regex("transitioned", ignore_case = TRUE)
  if (length(raw_status_cols_pre) > 0) {
    trans_tks <- result %>%
      filter(register == "EUCTR", !is.na(title_key), nchar(title_key) >= 20) %>%
      filter(Reduce(`|`, lapply(raw_status_cols_pre, function(col)
        str_detect(coalesce(as.character(.data[[col]]), ""), trans_pat_pre)))) %>%
      pull(title_key) %>%
      unique()
  } else {
    trans_tks <- character(0)
  }

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
    select(-all_countries, -all_statuses_raw, -all_meddra, -all_organ)

  raw_meddra_for_log <- result$MEDDRA_term
  raw_organ_for_log  <- result$MEDDRA_organ_class

  result <- result %>%
    mutate(MEDDRA_term        = vapply(MEDDRA_term, clean_meddra_term, character(1)),
           MEDDRA_organ_class = vapply(MEDDRA_organ_class, clean_organ_class, character(1)))

  write_norm_log(raw_meddra_for_log, result$MEDDRA_term, result$register, "meddra_term", dirname(db_path))
  write_norm_log(raw_organ_for_log,  result$MEDDRA_organ_class, result$register, "organ_class", dirname(db_path))
  
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
  
  write_norm_log(result$status_raw_orig, result$status,     result$register, "status_category", dirname(db_path))
  write_norm_log(result$status_raw_orig, result$status_raw, result$register, "status_display",  dirname(db_path))
  result <- result %>% select(-status_raw_orig)

  # ── Decision date & time-to-decision ─────────────────────────────────────
  result <- result %>% mutate(
    decision_date = suppressWarnings(as.Date(parse_date_time(
      case_when(
        register == "EUCTR" ~ as.character(n_date_of_competent_authority_decision),
        register == "CTIS"  ~ as.character(`authorizedApplication.applicationInfo.decisionDate`),
        TRUE ~ NA_character_),
      orders = c("ymd", "ym", "y", "ymd HMS")))),
    days_to_decision = as.numeric(decision_date - submission_date_parsed)
  )

  # ── Sponsor type ──────────────────────────────────────────────────────────
  result <- result %>% mutate(
    sponsor_type = case_when(
      register == "EUCTR" & str_detect(tolower(as.character(`b1_sponsor.b31_and_b32_status_of_the_sponsor`)), "non.commercial|non commercial|academic") ~ "Academic",
      register == "EUCTR" & str_detect(tolower(as.character(`b1_sponsor.b31_and_b32_status_of_the_sponsor`)), "commercial") ~ "Industry",
      register == "CTIS" & str_detect(tolower(as.character(`authorizedApplication.authorizedPartI.sponsors.commercial`)), "non.commercial|non commercial|academic") ~ "Academic",
      register == "CTIS" & str_detect(tolower(as.character(`authorizedApplication.authorizedPartI.sponsors.commercial`)), "commercial") ~ "Industry",
      TRUE ~ NA_character_))

  # ── Sponsor name ──────────────────────────────────────────────────────────
  raw_sponsor <- case_when(
    result$register == "EUCTR" ~ str_split_fixed(as.character(result$`b1_sponsor.b11_name_of_sponsor`), " / ", 2)[, 1],
    result$register == "CTIS"  ~ as.character(result$`authorizedApplication.authorizedPartI.sponsors.organisation.name`),
    TRUE ~ NA_character_)
  result <- result %>% mutate(sponsor_name = normalize_sponsor_name(raw_sponsor))

  # Write sponsor normalisation log (raw -> normalised, with register + count)
  tryCatch({
    sponsor_log <- data.frame(
      raw        = raw_sponsor,
      normalised = result$sponsor_name,
      register   = result$register,
      stringsAsFactors = FALSE) %>%
      filter(!is.na(raw), raw != "NA", raw != "") %>%
      group_by(register, raw, normalised) %>%
      summarise(n_trials = n(), .groups = "drop") %>%
      mutate(changed = raw != coalesce(normalised, "")) %>%
      arrange(register, desc(n_trials))
    log_path <- file.path(dirname(db_path), "sponsor_normalisation_log.csv")
    write.csv(sponsor_log, log_path, row.names = FALSE)
    message(sprintf("Sponsor normalisation log written to %s (%d rows)", log_path, nrow(sponsor_log)))
  }, error = function(e) {
    message("Could not write sponsor log: ", e$message)
  })

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

  # Capture raw phase inputs for logging before transformation
  raw_phase_for_log <- {
    raw_euctr <- if (length(euctr_phase_cols_present) > 0) {
      apply(result[, euctr_phase_cols_present, drop = FALSE], 1, function(r) {
        flags <- str_detect(tolower(as.character(r)), "true|yes|1")
        flags[is.na(flags)] <- FALSE
        lbs <- euctr_phase_labels[match(euctr_phase_cols_present, euctr_phase_cols)]
        lbs <- lbs[flags]
        if (length(lbs) == 0) NA_character_ else paste(lbs, collapse = " / ")
      })
    } else rep(NA_character_, nrow(result))
    raw_ctis <- if (ctis_phase_col_present) as.character(result[[ctis_phase_col]]) else rep(NA_character_, nrow(result))
    dplyr::coalesce(
      if_else(result$register == "EUCTR", as.character(raw_euctr), NA_character_),
      if_else(result$register == "CTIS",  raw_ctis, NA_character_))
  }

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

  write_norm_log(raw_phase_for_log, result$phase, result$register, "phase", dirname(db_path))

  # Drop raw phase columns
  result <- result %>% select(-any_of(c(euctr_phase_cols, ctis_phase_col)))

  message(sprintf("Ready: %d trials, %d cols", nrow(result), ncol(result)))
  return(result)
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
                    title = "EU Paediatric Trial Monitor",
                    dashboardHeader(title = tagList(
                      tags$head(
                        tags$title("EU Paediatric Trial Monitor"),
                        tags$link(rel = "icon", type = "image/svg+xml", href = "favicon.svg")
                      ),
                      icon("child"), " EU Paediatric Trial Monitor"
                    ), titleWidth = 300),
                    dashboardSidebar(width = 300,
                                     sidebarMenu(id = "tabs",
                                                 menuItem("Overview",tabName="overview",icon=icon("dashboard")),
                                                 menuItem("Chart Builder",tabName="chartbuilder",icon=icon("chart-line")),
                                                 menuItem("Map",tabName="map",icon=icon("map")),
                                                 menuItem("Data Explorer",tabName="data",icon=icon("table")),
                                                 menuItem("Basic Analytics",tabName="analytics",icon=icon("chart-bar")),
                                                 menuItem("Phase Analytics",tabName="phase",icon=icon("flask")),
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
                                     selectizeInput("sponsor_filter","Sponsor / Company:",
                                                    choices=NULL,multiple=TRUE,options=list(placeholder="All sponsors")),
                                     textInput("text_search","Free-text search:",placeholder="e.g. neuroblastoma…"),
                                     hr(),
                                     div(style="padding:0 15px;",
                                         p("Save / restore filters:",style="font-size:12px;margin-bottom:4px;"),
                                         downloadButton("dl_filters","Save filters",class="btn-sm btn-primary",style="width:100%;margin-bottom:6px;"),
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
                      tags$head(tags$style(HTML("
                        @media (max-width: 768px) {
                          .small-box { min-width: calc(50% - 20px); max-width: calc(50% - 20px); }
                        }
                        @media (max-width: 480px) {
                          .small-box { min-width: 100%; max-width: 100%; }
                        }
                        .analytics-section-header { padding: 6px 0 4px; border-bottom: 2px solid #3c8dbc; margin: 10px 0 14px; color: #3c8dbc; font-size:14px; font-weight:700; letter-spacing:.2px; }
                        .filter-chip-row { padding: 8px 15px; background: #eaf2fb; border-top: 2px solid #3c8dbc; border-bottom: 1px solid #c8dff0; margin-bottom: 18px; min-height: 36px; display:flex; align-items:center; flex-wrap:wrap; gap:4px; }
                        .filter-chip { display:inline-flex; align-items:center; background:#3c8dbc; color:#fff; border-radius:12px; padding:3px 10px 3px 8px; font-size:11px; margin:2px 3px; gap:4px; }
                      "))),
                      uiOutput("active_theme"),
                      uiOutput("active_filters_row"),
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
                                  box(title="Submissions per Year",status="primary",solidHeader=TRUE,
                                      width=6,height=400,withSpinner(plotlyOutput("plot_yearly",height="340px"),type=6)),
                                  box(title="Register Comparison",status="info",solidHeader=TRUE,
                                      width=6,height=400,withSpinner(plotlyOutput("plot_register",height="340px"),type=6))),
                        ),
                        tabItem(tabName="chartbuilder",
                                fluidRow(
                                  box(title="Chart Builder", status="primary", solidHeader=TRUE, width=12,
                                      p(em("Build a custom chart. Select an X axis, chart type, and optional grouping variable."),
                                        style="font-size:12px;opacity:0.75;margin-bottom:10px;"),
                                      fluidRow(
                                        column(3,
                                               selectInput("explore_x","X axis:",
                                                           choices=c(
                                                             "Year of submission"="year",
                                                             "Status"="status",
                                                             "Register"="register",
                                                             "Phase"="phase",
                                                             "Sponsor Type"="sponsor_type",
                                                             "PIP Status"="has_PIP",
                                                             "Organ Class (MedDRA SOC)"="MEDDRA_organ_class",
                                                             "Condition (MedDRA term)"="MEDDRA_term",
                                                             "Country / Member State"="Member_state"),
                                                           selected="year")),
                                        column(3,
                                               selectInput("explore_group","Group by (optional):",
                                                           choices=c(
                                                             "None"="None",
                                                             "Year of submission"="year",
                                                             "Status"="status",
                                                             "Register"="register",
                                                             "Phase"="phase",
                                                             "Sponsor Type"="sponsor_type",
                                                             "PIP Status"="has_PIP",
                                                             "Organ Class (MedDRA SOC)"="MEDDRA_organ_class",
                                                             "Condition (MedDRA term)"="MEDDRA_term",
                                                             "Country / Member State"="Member_state"),
                                                           selected="None")),
                                        column(3,
                                               selectInput("explore_chart_type","Chart type:",
                                                           choices=c(
                                                             "Bar (stacked)"="bar_stacked",
                                                             "Bar (grouped)"="bar_grouped",
                                                             "Bar (100% stacked)"="bar_pct",
                                                             "Line"="line"),
                                                           selected="bar_stacked")),
                                        column(3,
                                               conditionalPanel(
                                                 condition="input.explore_group !== 'None'",
                                                 sliderInput("explore_top_n","Max groups shown:",
                                                             min=3, max=20, value=8, step=1)))
                                      ),
                                      uiOutput("explore_note"),
                                      withSpinner(plotlyOutput("plot_explore", height="450px"), type=6))
                                ),
                                fluidRow(
                                  box(title="Summary Table", status="info", solidHeader=TRUE, width=8,
                                      withSpinner(DT::dataTableOutput("table_explore"), type=6)),
                                  box(title="Statistics", status="warning", solidHeader=TRUE, width=4,
                                      withSpinner(DT::dataTableOutput("stats_explore"), type=6))
                                )
                        ),
                        tabItem(tabName="data",
                                fluidRow(box(title="Filtered Trial Data",width=12,status="primary",solidHeader=TRUE,
                                             downloadButton("dl_csv","CSV",class="btn-sm btn-success"),
                                             downloadButton("dl_excel","Excel",class="btn-sm btn-info"),br(),br(),
                                             withSpinner(DT::dataTableOutput("trials_table"),type=6)))
                        ),
                        tabItem(tabName="analytics",
                                fluidRow(column(12, h4(icon("stethoscope"), " Therapeutic Areas", class="analytics-section-header"))),
                                fluidRow(
                                  box(title="Top MedDRA Organ Classes",status="primary",solidHeader=TRUE,width=6,
                                      sliderInput("top_n_organ","Top N:",min=5,max=30,value=15),
                                      withSpinner(plotlyOutput("plot_organ",height="420px"),type=6)),
                                  box(title="Top Conditions / MedDRA Terms",status="info",solidHeader=TRUE,width=6,
                                      sliderInput("top_n_term","Top N:",min=5,max=30,value=15),
                                      withSpinner(plotlyOutput("plot_term",height="420px"),type=6))),
                                fluidRow(column(12, h4(icon("globe"), " Geography & PIP", class="analytics-section-header"))),
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
                                fluidRow(column(12, h4(icon("building"), " Sponsors", class="analytics-section-header"))),
                                fluidRow(
                                  box(title="Time from Submission to Decision (days)",status="info",solidHeader=TRUE,width=12,height=460,
                                      withSpinner(plotlyOutput("plot_decision_time",height="400px"),type=6))),
                                fluidRow(
                                  box(title="Days to Decision by Sponsor Type",status="warning",solidHeader=TRUE,width=12,height=460,
                                      withSpinner(plotlyOutput("plot_decision_time_sponsor",height="400px"),type=6))),
                                fluidRow(
                                  box(title="Top Sponsors / Companies",status="primary",solidHeader=TRUE,width=12,height=520,
                                      sliderInput("top_n_sponsor","Top N:",min=5,max=30,value=20),
                                      withSpinner(plotlyOutput("plot_top_sponsors",height="400px"),type=6))),
                                uiOutput("sponsor_timeline_ui"),
                                uiOutput("sponsor_compare_ui"),
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
                                fluidRow(column(12, h4(icon("chart-area"), " Phase Distribution & Completion", class="analytics-section-header"))),
                                fluidRow(
                                  box(title="Phase Distribution (Funnel)",status="primary",solidHeader=TRUE,width=5,height=460,
                                      p(em("Each trial phase shown as a proportion of all phased trials."),
                                        style="font-size:11px;opacity:0.7;margin-bottom:6px;"),
                                      withSpinner(plotlyOutput("plot_phase_funnel",height="370px"),type=6)),
                                  box(title="Completion Rate by Authorization Cohort",status="info",solidHeader=TRUE,width=7,height=460,
                                      p(em("% of trials authorized in each year that have completed. More recent cohorts naturally show lower rates."),
                                        style="font-size:11px;opacity:0.7;margin-bottom:6px;"),
                                      withSpinner(plotlyOutput("plot_completion_cohort",height="370px"),type=6))),
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
                                        " R package and stored in a local SQLite database. The database is refreshed automatically every night."),
                                      h4(icon("history")," Changelog"),
                                      tags$ul(
                                        tags$li(tags$b("v0.5.0 (2026-04-18):"),
                                          tags$ul(
                                            tags$li("Free-text search now also searches sponsor name (previously title, CT number, MedDRA term, and product name only)"),
                                            tags$li("Phase Analytics: new Phase Funnel chart showing the distribution of trials across Phase I–IV as proportional bars"),
                                            tags$li("Phase Analytics: new Completion Rate by Authorization Cohort line chart showing what % of trials authorized each year have since completed, split by register"),
                                            tags$li("Analytics: Sponsor Comparison section — when exactly 2 or 3 sponsors are selected in the Sponsor filter, a side-by-side comparison appears showing phase distribution, trial status, and top organ classes"),
                                            tags$li("Removed unused eulerr package import")
                                          )
                                        ),
                                        tags$li(tags$b("v0.4.0 (2026-04-15):"),
                                          tags$ul(
                                            tags$li("Data Explorer: clicking a row opens a modal dialog with full trial details (title, CT number link, register, status, phase, sponsor, MedDRA terms, countries, dates)"),
                                            tags$li("URL state: active filters are encoded in the URL query string (?f=) so views can be bookmarked and shared; filters are restored automatically on page load"),
                                            tags$li("Active filter chips: a badge row above the tab content shows all non-default filters as coloured chips with a Reset all button"),
                                            tags$li("Basic Analytics: new violin plot showing days-to-decision split by sponsor type (Academic / Industry) with register overlay"),
                                            tags$li("Basic Analytics: section headers group boxes into Therapeutic Areas, Geography & PIP, and Sponsors"),
                                            tags$li("Charts: empty-state message shown instead of blank area when no trials match filters (all main plotly outputs)"),
                                            tags$li("Charts: plotly toolbar visible with camera (PNG download) icon; non-essential mode bar buttons removed"),
                                            tags$li("Responsive layout: metric cards shown 2-per-row on narrow screens and 1-per-row on very small screens")
                                          )
                                        ),
                                        tags$li(tags$b("v0.3.0 (2026-04-06):"),
                                          tags$ul(
                                            tags$li("Chart Builder: new tab (second position in sidebar) for building custom bar and line charts with a freely chosen X axis, optional grouping variable, and four chart types (stacked bar, grouped bar, 100% stacked bar, line)"),
                                            tags$li("Chart Builder: summary table shows counts with % of total and cumulative %; statistics panel shows Total, Mean, Median, SD, Min, Max — per group when grouped"),
                                            tags$li("Chart Builder: custom chart included in PDF report with ggplot2 rendering and matching stats table"),
                                            tags$li("Navigation: Analytics renamed to Basic Analytics; Phase Analysis renamed to Phase Analytics")
                                          )
                                        ),
                                        tags$li(tags$b("v0.2.4 (2026-04-05):"),
                                          tags$ul(
                                            tags$li("Sidebar: new Sponsor / Company filter with multi-select, supporting both EUCTR and CTIS registers"),
                                            tags$li("Data: sponsor names normalised and deduplicated (legal suffixes stripped, brand-name canonicalisation for ~70 pharma companies, title-case)"),
                                            tags$li("Analytics: new Top Sponsors chart (horizontal bar, coloured by sponsor type, configurable Top N)"),
                                            tags$li("Data Explorer: Sponsor Name and Sponsor Type columns added"),
                                            tags$li("Report: Top Sponsors section added (bar chart + table)"),
                                            tags$li("Fix: CTIS sponsor name field corrected to authorizedApplication.authorizedPartI.sponsors.organisation.name")
                                          )
                                        ),
                                        tags$li(tags$b("v0.2.3 (2026-03-30):"),
                                          tags$ul(
                                            tags$li("Data Explorer: added Decision Date column (Competent Authority decision date for EUCTR; authorisation date for CTIS)"),
                                            tags$li("Analytics: added violin plot showing the distribution of days from submission to decision, split by register")
                                          )
                                        ),
                                        tags$li(tags$b("v0.2.2 (2026-03-30):"),
                                          tags$ul(
                                            tags$li("Data pipeline: EUCTR download skipped when query URL unchanged; normalised query term stored in _meta table and compared on each run — nightly updates now only fetch CTIS unless search criteria change")
                                          )
                                        ),
                                        tags$li(tags$b("v0.2.1 (2026-03-29):"),
                                          tags$ul(
                                            tags$li("Data: normalise MedDRA condition name spelling variants between EUCTR (American) and CTIS (British MedDRA preferred) — leukemia/leukaemia, tumor/tumour, diarrhea/diarrhoea, esophag/oesophag, tyrosinemia/tyrosinaemia, localized/localised"),
                                            tags$li("Data: convert Roman numeral type notation (Type I/II/III/IV) to Arabic numerals (Type 1/2/3/4) so cross-register duplicates collapse into single entries")
                                          )
                                        ),
                                        tags$li(tags$b("v0.2.0 (2026-03-29):"),
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
                                      p(em(paste0("v0.5.0 — ",Sys.Date())),style="opacity:0.5;")
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
                                      p("Trials covering multiple countries or conditions may appear in multiple filter categories.
                                        Data reflects the state of the registries at the time of the last database update.")
                                  )
                                ),
                                fluidRow(
                                  box(title="Trial Status Definitions", width=12, status="warning", solidHeader=TRUE,
                                      p("The dashboard groups all trials into three categories based on their registry status.
                                        The table below shows how each registry-specific status maps to a dashboard category,
                                        followed by a definition of each status."),
                                      fluidRow(
                                        column(5,
                                          tags$table(
                                            style="width:100%;border-collapse:collapse;font-size:13px;",
                                            tags$thead(tags$tr(
                                              tags$th(style="background:#5E81AC;color:#FFFFFF;padding:8px 12px;text-align:left;","Dashboard category"),
                                              tags$th(style="background:#5E81AC;color:#FFFFFF;padding:8px 12px;text-align:left;","EUCTR status"),
                                              tags$th(style="background:#5E81AC;color:#FFFFFF;padding:8px 12px;text-align:left;","CTIS status")
                                            )),
                                            tags$tbody(
                                              tags$tr(style="background:#E8F5E9;",
                                                tags$td(style="padding:8px 12px;font-weight:bold;color:#2E7D32;border-bottom:1px solid #C8E6C9;","Ongoing"),
                                                tags$td(style="padding:8px 12px;color:#1C1C1C;border-bottom:1px solid #C8E6C9;","Ongoing, Restarted, Temporarily halted"),
                                                tags$td(style="padding:8px 12px;color:#1C1C1C;border-bottom:1px solid #C8E6C9;","Authorised, In Progress, Temporarily halted")
                                              ),
                                              tags$tr(style="background:#E3F2FD;",
                                                tags$td(style="padding:8px 12px;font-weight:bold;color:#1565C0;border-bottom:1px solid #BBDEFB;","Completed"),
                                                tags$td(style="padding:8px 12px;color:#1C1C1C;border-bottom:1px solid #BBDEFB;","Completed, Prematurely Ended"),
                                                tags$td(style="padding:8px 12px;color:#1C1C1C;border-bottom:1px solid #BBDEFB;","Completed")
                                              ),
                                              tags$tr(style="background:#FFF3E0;",
                                                tags$td(style="padding:8px 12px;font-weight:bold;color:#E65100;","Other"),
                                                tags$td(style="padding:8px 12px;color:#1C1C1C;","Withdrawn, Not Authorised"),
                                                tags$td(style="padding:8px 12px;color:#1C1C1C;","Terminated, Withdrawn, Not Authorised")
                                              )
                                            )
                                          )
                                        ),
                                        column(7,
                                          tags$dl(style="font-size:13px;column-count:2;column-gap:30px;",
                                            tags$dt(tags$b("Authorised (CTIS)")),
                                            tags$dd(style="margin-bottom:6px;","Application approved; recruitment may not have started yet."),
                                            tags$dt(tags$b("In Progress (CTIS)")),
                                            tags$dd(style="margin-bottom:6px;","Trial is actively running and recruiting or treating participants."),
                                            tags$dt(tags$b("Ongoing (EUCTR)")),
                                            tags$dd(style="margin-bottom:6px;","Trial is authorised and active in at least one EU Member State."),
                                            tags$dt(tags$b("Temporarily halted")),
                                            tags$dd(style="margin-bottom:6px;","Recruitment paused (e.g. safety signal) but expected to resume. Counted as Ongoing."),
                                            tags$dt(tags$b("Restarted (EUCTR)")),
                                            tags$dd(style="margin-bottom:6px;","Previously halted trial that has resumed. Counted as Ongoing."),
                                            tags$dt(tags$b("Completed")),
                                            tags$dd(style="margin-bottom:6px;","All participants finished the protocol; trial formally closed."),
                                            tags$dt(tags$b("Prematurely Ended (EUCTR)")),
                                            tags$dd(style="margin-bottom:6px;","Stopped before completion (e.g. poor recruitment, sponsor decision, safety). Counted as Completed."),
                                            tags$dt(tags$b("Terminated (CTIS)")),
                                            tags$dd(style="margin-bottom:6px;","Permanently stopped before completion; not expected to resume. Counted as Other."),
                                            tags$dt(tags$b("Withdrawn")),
                                            tags$dd(style="margin-bottom:6px;","Sponsor withdrew before trial start; no participants enrolled. Counted as Other."),
                                            tags$dt(tags$b("Not Authorised")),
                                            tags$dd(style="margin-bottom:6px;","Application refused by competent authority or Ethics Committee. Counted as Other.")
                                          )
                                        )
                                      )
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
                 legend=list(font=list(color=t$chart_fg)),...) %>%
      config(displayModeBar=TRUE, displaylogo=FALSE,
             modeBarButtonsToRemove=list("lasso2d","select2d","autoScale2d",
               "zoom2d","pan2d","resetScale2d","hoverClosestCartesian",
               "hoverCompareCartesian","toggleSpikelines"))
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
    updateSelectizeInput(session,"sponsor_filter",
                         choices=sort(unique(rv$data$sponsor_name[!is.na(rv$data$sponsor_name)])),server=TRUE)
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
    if(length(input$sponsor_filter)>0)df<-df%>%filter(sponsor_name%in%input$sponsor_filter)
    if(nzchar(input$text_search)){
      pat<-regex(input$text_search,ignore_case=TRUE)
      df<-df%>%filter(str_detect(Full_title,pat)|str_detect(DIMP_product_name,pat)|
                        str_detect(CT_number,pat)|str_detect(MEDDRA_term,pat)|
                        str_detect(coalesce(sponsor_name,""),pat))}
    df
  })
  
  # ── URL-based state ──────────────────────────────────────────────────────
  # Restore filters from ?f= query param once data is loaded
  observeEvent(rv$data, {
    qs <- parseQueryString(session$clientData$url_search)
    if (!is.null(qs$f) && nzchar(qs$f)) {
      tryCatch({
        raw  <- rawToChar(base64enc::base64decode(qs$f))
        s    <- jsonlite::fromJSON(raw, simplifyVector = TRUE)
        if (!is.null(s$status_filter))
          updateCheckboxGroupInput(session, "status_filter",   selected = s$status_filter)
        if (!is.null(s$register_filter))
          updateCheckboxGroupInput(session, "register_filter", selected = s$register_filter)
        if (!is.null(s$date_range) && length(s$date_range) == 2)
          updateDateRangeInput(session, "date_range", start = s$date_range[1], end = s$date_range[2])
        if (!is.null(s$organ_class_filter))
          updateSelectizeInput(session, "organ_class_filter", selected = s$organ_class_filter)
        if (!is.null(s$condition_filter))
          updateSelectizeInput(session, "condition_filter",   selected = s$condition_filter)
        if (!is.null(s$country_filter))
          updateSelectizeInput(session, "country_filter",     selected = s$country_filter)
        if (!is.null(s$phase_filter))
          updateSelectizeInput(session, "phase_filter",       selected = s$phase_filter)
        if (!is.null(s$pip_filter))
          updateSelectInput(session, "pip_filter",            selected = s$pip_filter)
        if (!is.null(s$sponsor_filter))
          updateSelectizeInput(session, "sponsor_filter",     selected = s$sponsor_filter)
        if (!is.null(s$text_search))
          updateTextInput(session, "text_search", value = s$text_search)
      }, error = function(e) message("URL state restore failed: ", e$message))
    }
  }, once = TRUE, ignoreNULL = TRUE)

  # Debounced filter state -> encode to URL
  filter_state <- reactive({
    list(
      status_filter      = input$status_filter,
      register_filter    = input$register_filter,
      date_range         = as.character(input$date_range),
      organ_class_filter = input$organ_class_filter,
      condition_filter   = input$condition_filter,
      country_filter     = input$country_filter,
      phase_filter       = input$phase_filter,
      pip_filter         = input$pip_filter,
      sponsor_filter     = input$sponsor_filter,
      text_search        = input$text_search
    )
  }) %>% debounce(1000)

  observe({
    fs <- filter_state()
    tryCatch({
      encoded <- base64enc::base64encode(charToRaw(jsonlite::toJSON(fs, auto_unbox = TRUE)))
      updateQueryString(paste0("?f=", encoded), mode = "replace", session = session)
    }, error = function(e) NULL)
  })

  # ── Active filters badge row ──────────────────────────────────────────────
  output$active_filters_row <- renderUI({
    req(rv$data)
    chips <- list()
    default_date_start <- min(rv$data$submission_date_parsed, na.rm = TRUE)

    status_default <- c("Ongoing", "Completed", "Other")
    if (!setequal(input$status_filter, status_default))
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("Status: ", paste(input$status_filter, collapse = ", ")))))

    register_default <- c("EUCTR", "CTIS")
    if (!setequal(input$register_filter, register_default))
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("Register: ", paste(input$register_filter, collapse = ", ")))))

    if (!is.null(input$date_range)) {
      if (!is.na(input$date_range[1]) && input$date_range[1] != default_date_start)
        chips <- c(chips, list(span(class = "filter-chip",
          paste0("From: ", format(input$date_range[1])))))
      if (!is.na(input$date_range[2]) && input$date_range[2] != Sys.Date())
        chips <- c(chips, list(span(class = "filter-chip",
          paste0("To: ", format(input$date_range[2])))))
    }

    if (length(input$organ_class_filter) > 0)
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("Organ Class: ", paste(input$organ_class_filter, collapse = ", ")))))

    if (length(input$condition_filter) > 0)
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("Condition: ", paste(input$condition_filter, collapse = ", ")))))

    if (length(input$country_filter) > 0)
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("Country: ", paste(input$country_filter, collapse = ", ")))))

    if (length(input$phase_filter) > 0)
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("Phase: ", paste(input$phase_filter, collapse = ", ")))))

    if (!is.null(input$pip_filter) && input$pip_filter != "All")
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("PIP: ", input$pip_filter))))

    if (length(input$sponsor_filter) > 0)
      chips <- c(chips, list(span(class = "filter-chip",
        paste0("Sponsor: ", paste(input$sponsor_filter, collapse = ", ")))))

    if (nzchar(input$text_search))
      chips <- c(chips, list(span(class = "filter-chip",
        paste0('Search: "', input$text_search, '"'))))

    if (length(chips) == 0) return(NULL)

    div(class = "filter-chip-row",
        span(style = "font-size:11px;opacity:0.7;margin-right:6px;", "Active filters:"),
        chips,
        actionButton("reset_filters", "Reset all", class = "btn-xs btn-default",
                     style = "margin-left:8px;font-size:11px;padding:2px 8px;"))
  })

  observeEvent(input$reset_filters, {
    req(rv$data)
    updateCheckboxGroupInput(session, "status_filter",
                             selected = c("Ongoing", "Completed", "Other"))
    updateCheckboxGroupInput(session, "register_filter",
                             selected = c("EUCTR", "CTIS"))
    d <- rv$data$submission_date_parsed[!is.na(rv$data$submission_date_parsed)]
    updateDateRangeInput(session, "date_range",
                         start = if (length(d) > 0) min(d) else "2004-01-01",
                         end   = Sys.Date())
    updateSelectizeInput(session, "organ_class_filter", selected = character(0))
    updateSelectizeInput(session, "condition_filter",   selected = character(0))
    updateSelectizeInput(session, "country_filter",     selected = character(0))
    updateSelectizeInput(session, "phase_filter",       selected = character(0))
    updateSelectInput(session, "pip_filter", selected = "All")
    updateSelectizeInput(session, "sponsor_filter",     selected = character(0))
    updateTextInput(session, "text_search", value = "")
  })

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
             phase,sponsor_name,sponsor_type,submission_date_parsed,start_date,decision_date,`CT Number`)%>%
      select(-CT_number)%>%
      rename(Register=register,Title=Full_title,
             Product=DIMP_product_name,Condition=MEDDRA_term,
             `Organ Class`=MEDDRA_organ_class,Country=Member_state,
             `# Countries`=n_countries,Status=status_raw,PIP=has_PIP,
             Phase=phase,`Sponsor Name`=sponsor_name,`Sponsor Type`=sponsor_type,
             Submitted=submission_date_parsed,Started=start_date,
             `Decision Date`=decision_date)%>%
      relocate(`CT Number`)
    datatable(df,filter="top",rownames=FALSE,class="compact stripe hover",escape=FALSE,
              selection=list(mode="single",target="row"),
              options=list(pageLength=20,scrollX=TRUE,dom="lBfrtip",
                           order=list(list(12,"desc")),
                           columnDefs=list(list(width="350px",targets=2))))
  })
  
  output$dl_csv<-downloadHandler(filename=function()paste0("pediatric_trials_",Sys.Date(),".csv"),
                                 content=function(f)readr::write_csv(filt(),f))
  output$dl_excel<-downloadHandler(filename=function()paste0("pediatric_trials_",Sys.Date(),".xlsx"),
                                   content=function(f)writexl::write_xlsx(filt(),f))

  # ── Trial detail modal ────────────────────────────────────────────────────
  observeEvent(input$trials_table_rows_selected, {
    idx <- input$trials_table_rows_selected
    req(length(idx) == 1)
    row <- filt()[idx, ]
    ct_raw  <- row$CT_number
    reg     <- row$register
    link <- if (reg == "EUCTR") {
      ct1 <- str_trim(str_split_fixed(ct_raw, " / ", 2)[, 1])
      cc  <- str_extract(row$`_id`, "[A-Z]{2,3}$")
      paste0("https://www.clinicaltrialsregister.eu/ctr-search/trial/", ct1, "/", cc)
    } else {
      ct1 <- str_trim(str_split_fixed(ct_raw, " / ", 2)[, 1])
      paste0("https://euclinicaltrials.eu/ctis-public/view/", ct1)
    }
    ct_display <- str_trim(str_split_fixed(ct_raw, " / ", 2)[, 1])
    showModal(modalDialog(
      title = tagList(icon("flask"), " Trial Detail"),
      size  = "l",
      easyClose = TRUE,
      footer = modalButton("Close"),
      tags$dl(
        tags$dt("Full Title"),
        tags$dd(style = "margin-bottom:10px;", coalesce(row$Full_title, "—")),
        tags$dt("CT Number"),
        tags$dd(style = "margin-bottom:10px;",
                tags$a(ct_display, href = link, target = "_blank")),
        fluidRow(
          column(6,
            tags$dt("Register"),   tags$dd(coalesce(reg, "—")),
            tags$dt("Status"),     tags$dd(coalesce(row$status_raw, "—")),
            tags$dt("Phase"),      tags$dd(coalesce(row$phase, "—")),
            tags$dt("Sponsor Name"),  tags$dd(coalesce(row$sponsor_name, "—")),
            tags$dt("Sponsor Type"),  tags$dd(coalesce(row$sponsor_type, "—"))
          ),
          column(6,
            tags$dt("Organ Class"),   tags$dd(coalesce(row$MEDDRA_organ_class, "—")),
            tags$dt("MedDRA Term"),   tags$dd(coalesce(row$MEDDRA_term, "—")),
            tags$dt("Countries"),     tags$dd(coalesce(row$Member_state, "—")),
            tags$dt("Submitted"),     tags$dd(as.character(coalesce(row$submission_date_parsed, NA))),
            tags$dt("Start Date"),    tags$dd(as.character(coalesce(row$start_date, NA))),
            tags$dt("Decision Date"), tags$dd(as.character(coalesce(row$decision_date, NA)))
          )
        )
      )
    ))
  })

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
        sponsor_filter     = input$sponsor_filter,
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

      tmp_chart <- tempfile(fileext = ".rds")
      saveRDS(explore_data(), tmp_chart)
      on.exit(unlink(tmp_chart), add = TRUE)

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
          params      = list(data_path = tmp_data, filters = filters,
                             chart_data_path = tmp_chart,
                             chart_type      = input$explore_chart_type),
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
      if(!is.null(s$sponsor_filter))
        updateSelectizeInput(session,"sponsor_filter",selected=s$sponsor_filter)
      if(!is.null(s$text_search))
        updateTextInput(session,"text_search",value=s$text_search)
    },error=function(e)showNotification(paste("Could not load filters:",e$message),type="error"))
  })
  
  output$plot_organ <- renderPlotly({
    df <- filt() %>%
      filter(!is.na(MEDDRA_organ_class)) %>%
      separate_rows(MEDDRA_organ_class, sep = " / ") %>%
      mutate(MEDDRA_organ_class = str_trim(MEDDRA_organ_class)) %>%
      filter(MEDDRA_organ_class != "") %>%
      count(MEDDRA_organ_class, sort = TRUE) %>%
      head(input$top_n_organ)
    if (nrow(df) == 0) return(plotly_empty() %>%
      layout(title = list(text = "No data for current filters", font = list(size = 14, color = "#888")),
             annotations = list(text = "Adjust the sidebar filters to see data here.",
                                showarrow = FALSE, font = list(size = 12, color = "#aaa"))))
    plot_ly(df, y = ~reorder(MEDDRA_organ_class, n), x = ~n,
            type = "bar", orientation = "h",
            marker = list(color = tc()$frost2)) %>%
      plt_layout(margin = list(l = 220))
  })
  
  output$plot_term <- renderPlotly({
    df<-filt()%>%filter(!is.na(MEDDRA_term))%>%
      separate_rows(MEDDRA_term,sep=" / ")%>%
      mutate(MEDDRA_term=str_trim(MEDDRA_term))%>%
      filter(MEDDRA_term!="")%>%count(MEDDRA_term,sort=TRUE)%>%head(input$top_n_term)
    if(nrow(df)==0) return(plotly_empty()%>%layout(title=list(text="No data for current filters",font=list(size=14,color="#888")),annotations=list(text="Adjust the sidebar filters to see data here.",showarrow=FALSE,font=list(size=12,color="#aaa"))))
    plot_ly(df,y=~reorder(MEDDRA_term,n),x=~n,type="bar",orientation="h",
            marker=list(color=tc()$green))%>%plt_layout(margin=list(l=260))
  })
  
  output$plot_country <- renderPlotly({
    df<-filt()%>%filter(!is.na(Member_state))%>%
      separate_rows(Member_state,sep=" / |, ")%>%
      mutate(Member_state=str_trim(Member_state))%>%filter(Member_state!="")%>%
      count(Member_state,sort=TRUE)%>%head(30)
    if(nrow(df)==0) return(plotly_empty()%>%layout(title=list(text="No data for current filters",font=list(size=14,color="#888")),annotations=list(text="Adjust the sidebar filters to see data here.",showarrow=FALSE,font=list(size=12,color="#aaa"))))
    plot_ly(df,x=~reorder(Member_state,-n),y=~n,type="bar",marker=list(color=tc()$frost1))%>%
      plt_layout(margin=list(b=120),xaxis=list(tickangle=-45,tickfont=list(color=tc()$chart_fg)))
  })
  
  output$plot_pip <- renderPlotly({
    df<-filt()%>%count(has_PIP,register)%>%filter(!is.na(has_PIP))
    if(nrow(df)==0) return(plotly_empty()%>%layout(title=list(text="No data for current filters",font=list(size=14,color="#888")),annotations=list(text="Adjust the sidebar filters to see data here.",showarrow=FALSE,font=list(size=12,color="#aaa"))))
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
    if(nrow(df)==0) return(plotly_empty()%>%layout(title=list(text="No data for current filters",font=list(size=14,color="#888")),annotations=list(text="Adjust the sidebar filters to see data here.",showarrow=FALSE,font=list(size=12,color="#aaa"))))
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

  # ── Phase funnel ─────────────────────────────────────────────────────────────
  output$plot_phase_funnel <- renderPlotly({
    df <- filt() %>%
      filter(!is.na(phase), nzchar(str_trim(phase))) %>%
      separate_rows(phase, sep = " / ") %>%
      mutate(phase = str_trim(phase)) %>%
      filter(phase %in% c("Phase I","Phase II","Phase III","Phase IV")) %>%
      count(phase) %>%
      mutate(phase = factor(phase, levels = c("Phase I","Phase II","Phase III","Phase IV"))) %>%
      arrange(phase)
    if (nrow(df) == 0) return(plotly_empty() %>% layout(
      title = list(text = "No data for current filters", font = list(size = 14, color = "#888")),
      annotations = list(text = "Adjust the sidebar filters to see data here.",
                         showarrow = FALSE, font = list(size = 12, color = "#aaa"))))
    t <- tc()
    pal <- colorRampPalette(c(t$frost1, t$frost3, t$orange, t$yellow))(nrow(df))
    plot_ly(df, type = "funnel",
            y = ~phase, x = ~n,
            textinfo = "value+percent total",
            marker = list(color = pal),
            connector = list(line = list(color = t$chart_grid, width = 1))) %>%
      plt_layout(yaxis = list(title = ""), xaxis = list(title = "Number of Trials"))
  })

  # ── Completion rate by authorization cohort ───────────────────────────────
  output$plot_completion_cohort <- renderPlotly({
    df <- filt() %>%
      filter(!is.na(decision_date), !is.na(status)) %>%
      mutate(auth_year = year(decision_date)) %>%
      filter(auth_year >= 2004, auth_year < year(Sys.Date())) %>%
      group_by(auth_year, register) %>%
      summarise(n_total = n(),
                n_completed = sum(status == "Completed", na.rm = TRUE),
                .groups = "drop") %>%
      filter(n_total >= 5) %>%
      mutate(pct_completed = round(n_completed / n_total * 100, 1))
    if (nrow(df) == 0) return(plotly_empty() %>% layout(
      title = list(text = "No data for current filters", font = list(size = 14, color = "#888")),
      annotations = list(text = "Adjust the sidebar filters to see data here.",
                         showarrow = FALSE, font = list(size = 12, color = "#aaa"))))
    plot_ly(df, x = ~auth_year, y = ~pct_completed,
            color = ~register, colors = register_cols(),
            type = "scatter", mode = "lines+markers",
            line = list(width = 2), marker = list(size = 7),
            text = ~paste0(register, " ", auth_year, "<br>",
                           n_completed, "/", n_total, " completed (", pct_completed, "%)"),
            hoverinfo = "text") %>%
      plt_layout(
        xaxis = list(title = "Authorization Year", dtick = 1, tickformat = "d"),
        yaxis = list(title = "% Completed", range = c(0, 105)),
        legend = list(orientation = "h", y = -0.2))
  })

  output$plot_timeline_q <- renderPlotly({
    df<-filt()%>%filter(!is.na(start_date))%>%mutate(quarter=floor_date(start_date,"quarter"))%>%
      count(quarter,register)
    validate(need(nrow(df)>0,"No data."))
    plot_ly(df,x=~quarter,y=~n,color=~register,colors=register_cols(),type="bar")%>%
      plt_layout(barmode="stack",legend=list(orientation="h",y=-0.2))
  })

  output$plot_decision_time <- renderPlotly({
    base <- filt() %>%
      filter(!is.na(days_to_decision), is.finite(days_to_decision),
             days_to_decision >= 0, days_to_decision < 3650)
    if (nrow(base) == 0) return(plotly_empty() %>% layout(
      title = list(text = "No data for current filters", font = list(size = 14, color = "#888")),
      annotations = list(text = "Adjust the sidebar filters to see data here.",
                         showarrow = FALSE, font = list(size = 12, color = "#aaa"))))
    df <- bind_rows(base, mutate(base, register = "All")) %>%
      mutate(register = factor(register, levels = c("EUCTR", "CTIS", "All")))
    t <- tc()
    pal <- c(register_cols(), All = t$purple)
    plot_ly(df, x = ~register, y = ~days_to_decision, color = ~register,
            colors = pal, type = "violin",
            box = list(visible = TRUE),
            meanline = list(visible = TRUE),
            points = "outliers") %>%
      plt_layout(
        xaxis = list(title = "Register"),
        yaxis = list(title = "Days from Submission to Decision"),
        legend = list(orientation = "h", y = -0.2),
        showlegend = FALSE)
  })

  output$plot_decision_time_sponsor <- renderPlotly({
    base <- filt() %>%
      filter(!is.na(days_to_decision), is.finite(days_to_decision),
             days_to_decision >= 0, days_to_decision < 3650,
             !is.na(sponsor_type))
    if (nrow(base) == 0) return(plotly_empty() %>% layout(
      title = list(text = "No data for current filters", font = list(size = 14, color = "#888")),
      annotations = list(text = "Adjust the sidebar filters to see data here.",
                         showarrow = FALSE, font = list(size = 12, color = "#aaa"))))
    t <- tc()
    pal <- c("Academic" = t$frost1, "Industry" = t$orange)
    plot_ly(base, x = ~sponsor_type, y = ~days_to_decision,
            color = ~sponsor_type, colors = pal,
            type = "violin",
            box = list(visible = TRUE),
            meanline = list(visible = TRUE),
            points = "outliers",
            split = ~register) %>%
      plt_layout(
        xaxis = list(title = "Sponsor Type"),
        yaxis = list(title = "Days from Submission to Decision"),
        legend = list(orientation = "h", y = -0.2),
        violingap = 0, violingroupgap = 0.2)
  })

  output$plot_top_sponsors <- renderPlotly({
    df <- filt() %>% filter(!is.na(sponsor_name))
    if(nrow(df)==0) return(plotly_empty()%>%layout(title=list(text="No data for current filters",font=list(size=14,color="#888")),annotations=list(text="Adjust the sidebar filters to see data here.",showarrow=FALSE,font=list(size=12,color="#aaa"))))
    t <- tc()
    sp <- df %>%
      count(sponsor_name, sponsor_type, sort = TRUE) %>%
      slice_head(n = input$top_n_sponsor) %>%
      mutate(sponsor_name = factor(sponsor_name, levels = rev(sponsor_name)),
             sponsor_type = coalesce(sponsor_type, "Unknown"))
    pal <- c(Academic = t$frost1, Industry = t$orange, Unknown = t$fg)
    plot_ly(sp, x = ~n, y = ~sponsor_name, color = ~sponsor_type, colors = pal,
            type = "bar", orientation = "h",
            text = ~paste0(sponsor_name, "<br>", n, " trial(s) — ", sponsor_type),
            hoverinfo = "text") %>%
      plt_layout(
        xaxis = list(title = "Number of Trials"),
        yaxis = list(title = "", tickfont = list(size = 11)),
        legend = list(orientation = "h", y = -0.15),
        margin = list(l = 180))
  })

  output$sponsor_timeline_ui <- renderUI({
    req(length(input$sponsor_filter) == 1)
    fluidRow(
      box(title = paste0("Trial Timeline — ", input$sponsor_filter[[1]]),
          status = "info", solidHeader = TRUE, width = 12, height = 460,
          withSpinner(plotlyOutput("plot_sponsor_timeline", height = "380px"), type = 6)))
  })

  output$plot_sponsor_timeline <- renderPlotly({
    req(length(input$sponsor_filter) == 1)
    df <- filt() %>%
      filter(!is.na(sponsor_name), !is.na(submission_date_parsed)) %>%
      mutate(year = year(submission_date_parsed)) %>%
      count(year, name = "n") %>%
      arrange(year) %>%
      mutate(cumulative = cumsum(n))
    validate(need(nrow(df) > 0, "No submission date data available for this sponsor."))
    t <- tc()
    plot_ly(df) %>%
      add_bars(x = ~year, y = ~n, name = "New trials per year",
               marker = list(color = t$frost1),
               text = ~paste0(year, "<br>", n, " new trial(s)"),
               hoverinfo = "text") %>%
      add_lines(x = ~year, y = ~cumulative, name = "Cumulative",
                line = list(color = t$orange, width = 2.5),
                yaxis = "y2",
                text = ~paste0(year, "<br>", cumulative, " total"),
                hoverinfo = "text") %>%
      plt_layout(
        xaxis = list(title = "Year", dtick = 1, tickformat = "d"),
        yaxis = list(title = "New Trials per Year", rangemode = "tozero"),
        yaxis2 = list(title = "Cumulative Trials", overlaying = "y",
                      side = "right", rangemode = "tozero",
                      showgrid = FALSE),
        legend = list(orientation = "h", y = -0.2))
  })

  # ── Sponsor comparison (shown when 2–3 sponsors selected) ─────────────────
  output$sponsor_compare_ui <- renderUI({
    n <- length(input$sponsor_filter)
    req(n >= 2, n <= 3)
    ttl <- paste(input$sponsor_filter, collapse = " vs. ")
    fluidRow(
      box(title = paste0("Sponsor Comparison — ", ttl),
          status = "warning", solidHeader = TRUE, width = 12,
          p(em("Phase distribution, trial status, and top organ classes for selected sponsors."),
            style = "font-size:11px;opacity:0.7;margin-bottom:8px;"),
          fluidRow(
            column(6,
                   h5("Phase Distribution", style = "font-weight:600;margin-bottom:6px;"),
                   withSpinner(plotlyOutput("plot_compare_phase", height = "280px"), type = 6)),
            column(6,
                   h5("Trial Status", style = "font-weight:600;margin-bottom:6px;"),
                   withSpinner(plotlyOutput("plot_compare_status", height = "280px"), type = 6))
          ),
          fluidRow(
            column(12,
                   h5("Top Organ Classes", style = "font-weight:600;margin-bottom:6px;"),
                   withSpinner(plotlyOutput("plot_compare_organ", height = "300px"), type = 6))
          ))
    )
  })

  compare_pal <- reactive({
    sponsors <- input$sponsor_filter
    t <- tc()
    setNames(
      colorRampPalette(c(t$frost1, t$orange, t$green, t$purple))(length(sponsors)),
      sponsors)
  })

  output$plot_compare_phase <- renderPlotly({
    req(length(input$sponsor_filter) >= 2)
    df <- filt() %>%
      filter(!is.na(phase), nzchar(str_trim(phase)),
             sponsor_name %in% input$sponsor_filter) %>%
      separate_rows(phase, sep = " / ") %>%
      mutate(phase = str_trim(phase)) %>%
      filter(phase %in% c("Phase I","Phase II","Phase III","Phase IV")) %>%
      count(sponsor_name, phase) %>%
      mutate(phase = factor(phase, levels = c("Phase I","Phase II","Phase III","Phase IV")))
    validate(need(nrow(df) > 0, "No phase data for selected sponsors."))
    plot_ly(df, x = ~phase, y = ~n, color = ~sponsor_name, colors = compare_pal(),
            type = "bar", text = ~n, textposition = "outside", hoverinfo = "x+y+name") %>%
      plt_layout(barmode = "group",
                 xaxis = list(title = ""),
                 yaxis = list(title = "Trials"),
                 legend = list(orientation = "h", y = -0.25))
  })

  output$plot_compare_status <- renderPlotly({
    req(length(input$sponsor_filter) >= 2)
    df <- filt() %>%
      filter(!is.na(status), sponsor_name %in% input$sponsor_filter) %>%
      count(sponsor_name, status)
    validate(need(nrow(df) > 0, "No status data for selected sponsors."))
    plot_ly(df, x = ~status, y = ~n, color = ~sponsor_name, colors = compare_pal(),
            type = "bar", text = ~n, textposition = "outside", hoverinfo = "x+y+name") %>%
      plt_layout(barmode = "group",
                 xaxis = list(title = ""),
                 yaxis = list(title = "Trials"),
                 legend = list(orientation = "h", y = -0.25))
  })

  output$plot_compare_organ <- renderPlotly({
    req(length(input$sponsor_filter) >= 2)
    df <- filt() %>%
      filter(!is.na(MEDDRA_organ_class),
             sponsor_name %in% input$sponsor_filter) %>%
      separate_rows(MEDDRA_organ_class, sep = " / ") %>%
      mutate(MEDDRA_organ_class = str_trim(MEDDRA_organ_class)) %>%
      filter(nzchar(MEDDRA_organ_class)) %>%
      count(sponsor_name, MEDDRA_organ_class)
    top_oc <- df %>%
      group_by(MEDDRA_organ_class) %>%
      summarise(total = sum(n), .groups = "drop") %>%
      slice_max(total, n = 8) %>%
      pull(MEDDRA_organ_class)
    df <- df %>% filter(MEDDRA_organ_class %in% top_oc)
    validate(need(nrow(df) > 0, "No organ class data for selected sponsors."))
    plot_ly(df,
            y = ~reorder(MEDDRA_organ_class, n), x = ~n,
            color = ~sponsor_name, colors = compare_pal(),
            type = "bar", orientation = "h", hoverinfo = "x+y+name") %>%
      plt_layout(barmode = "group",
                 xaxis = list(title = "Trials"),
                 yaxis = list(title = ""),
                 legend = list(orientation = "h", y = -0.2),
                 margin = list(l = 240))
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
    if(length(input$sponsor_filter) > 0)
      df <- df %>% filter(sponsor_name %in% input$sponsor_filter)
    if(nzchar(input$text_search)) {
      pat <- regex(input$text_search, ignore_case=TRUE)
      df <- df %>% filter(str_detect(Full_title, pat) | str_detect(DIMP_product_name, pat) |
                            str_detect(CT_number, pat) | str_detect(MEDDRA_term, pat) |
                            str_detect(coalesce(sponsor_name,""), pat))
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

  # ── Chart Builder tab ────────────────────────────────────────────────────────

  EXPLORE_MULTI_COLS <- c("MEDDRA_organ_class", "MEDDRA_term", "Member_state")

  EXPLORE_LABELS <- c(
    "None"               = "None",
    "status"             = "Status",
    "register"           = "Register",
    "phase"              = "Phase",
    "sponsor_type"       = "Sponsor Type",
    "has_PIP"            = "PIP Status",
    "MEDDRA_organ_class" = "Organ Class (MedDRA SOC)",
    "MEDDRA_term"        = "Condition (MedDRA term)",
    "Member_state"       = "Country / Member State"
  )

  # Aggregated x_var × group counts (for bar / line charts)
  explore_data <- reactive({
    req(rv$data)
    x_var <- input$explore_x
    grp   <- input$explore_group
    req(x_var)

    # Handle multi-value columns for both x and group axes
    df <- filt()

    if (x_var %in% EXPLORE_MULTI_COLS) {
      df <- df %>%
        filter(!is.na(.data[[x_var]]), nzchar(as.character(.data[[x_var]]))) %>%
        separate_rows(all_of(x_var), sep = " / ") %>%
        mutate(across(all_of(x_var), str_trim)) %>%
        filter(nzchar(.data[[x_var]]))
    } else {
      df <- df %>% filter(!is.na(.data[[x_var]]), nzchar(as.character(.data[[x_var]])))
    }

    if (grp == "None") {
      d <- df %>% count(x_val = .data[[x_var]], name = "n")
      return(list(data = d, x_var = x_var, grp = "None"))
    }

    if (grp %in% EXPLORE_MULTI_COLS) {
      df <- df %>%
        filter(!is.na(.data[[grp]]), nzchar(as.character(.data[[grp]]))) %>%
        separate_rows(all_of(grp), sep = " / ") %>%
        mutate(across(all_of(grp), str_trim)) %>%
        filter(nzchar(.data[[grp]]))
    } else {
      df <- df %>% filter(!is.na(.data[[grp]]), nzchar(as.character(.data[[grp]])))
    }

    top_groups <- df %>%
      count(.data[[grp]], name = "n_total") %>%
      arrange(desc(n_total)) %>%
      head(input$explore_top_n) %>%
      pull(.data[[grp]])

    d <- df %>%
      filter(.data[[grp]] %in% top_groups) %>%
      count(x_val = .data[[x_var]], grp_val = .data[[grp]], name = "n")

    list(data = d, x_var = x_var, grp = grp)
  })

  output$explore_note <- renderUI({
    x_var <- input$explore_x
    grp   <- input$explore_group
    notes <- character(0)
    if (isTruthy(x_var) && x_var %in% EXPLORE_MULTI_COLS)
      notes <- c(notes, paste0(unname(EXPLORE_LABELS[x_var]), " (X axis): trials can match multiple categories; counts may exceed total trials."))
    if (isTruthy(grp) && grp %in% EXPLORE_MULTI_COLS && grp != x_var)
      notes <- c(notes, paste0(unname(EXPLORE_LABELS[grp]), " (group): trials can match multiple categories; counts may exceed total trials."))
    if (length(notes) == 0) return(NULL)
    div(style="font-size:11px;opacity:0.7;margin-bottom:8px;",
        lapply(notes, function(n) p(style="margin:2px 0;", icon("info-circle"), " ", n)))
  })

  output$plot_explore <- renderPlotly({
    t          <- tc()
    chart_type <- input$explore_chart_type
    ed         <- explore_data()
    d          <- ed$data
    x_var      <- ed$x_var
    grp        <- ed$grp
    validate(need(nrow(d) > 0, "No data available for this selection."))

    x_lbl  <- unname(EXPLORE_LABELS[x_var])
    x_tick  <- if (x_var == "year") list(dtick = 1, tickformat = "d") else list()
    y_lbl  <- if (chart_type == "bar_pct") "Percentage of Trials (%)" else "Number of Trials"

    if (grp == "None") {
      p <- if (chart_type == "line") {
        plot_ly(d, x = ~x_val, y = ~n, type = "scatter", mode = "lines+markers",
                line   = list(color = t$frost1, width = 2),
                marker = list(color = t$frost1, size = 7),
                hovertemplate = "%{x}<br>%{y} trials<extra></extra>")
      } else {
        plot_ly(d, x = ~x_val, y = ~n, type = "bar",
                marker = list(color = t$frost1),
                hovertemplate = "%{x}<br>%{y} trials<extra></extra>")
      }
      return(p %>% plt_layout(
        xaxis = c(list(title = x_lbl), x_tick),
        yaxis = list(title = y_lbl, rangemode = "tozero")))
    }

    groups <- sort(unique(d$grp_val))
    pal    <- setNames(
      colorRampPalette(c(t$frost1, t$frost3, t$orange, t$green, t$purple, t$red, t$yellow))(length(groups)),
      groups)

    if (chart_type == "line") {
      p <- plot_ly()
      for (g in groups) {
        sub <- d %>% filter(grp_val == g)
        p   <- p %>% add_lines(
          data = sub, x = ~x_val, y = ~n, name = g,
          line = list(color = pal[[g]], width = 2),
          hovertemplate = paste0(g, " | %{x}<br>%{y} trials<extra></extra>"))
      }
    } else {
      barmode <- if (chart_type == "bar_grouped") "group" else "stack"
      barnorm  <- if (chart_type == "bar_pct")    "percent" else ""
      p <- plot_ly(d, x = ~x_val, y = ~n, color = ~grp_val,
                   colors = pal, type = "bar",
                   hovertemplate = "%{fullData.name} | %{x}<br>%{y:.1f}<extra></extra>") %>%
        layout(barmode = barmode, barnorm = barnorm)
    }

    p %>% plt_layout(
      xaxis  = c(list(title = x_lbl), x_tick),
      yaxis  = list(title = y_lbl, rangemode = "tozero"),
      legend = list(orientation = "h", y = -0.25))
  })

  output$table_explore <- DT::renderDataTable({
    ed    <- explore_data()
    d     <- ed$data
    x_var <- ed$x_var
    grp   <- ed$grp
    validate(need(nrow(d) > 0, "No data available."))

    x_lbl       <- unname(EXPLORE_LABELS[x_var])
    grand_total  <- sum(d$n)

    if (grp == "None") {
      d %>% arrange(x_val) %>%
        mutate(`% of Total`  = round(n / grand_total * 100, 1),
               `Cumulative %` = round(cumsum(n) / grand_total * 100, 1)) %>%
        rename(!!x_lbl := x_val, `Trial Count` = n) %>%
        datatable(rownames = FALSE, class = "compact stripe hover",
                  options = list(pageLength = 20, dom = "ftp", scrollX = TRUE))
    } else {
      grp_label <- unname(EXPLORE_LABELS[grp])
      d %>%
        arrange(x_val, grp_val) %>%
        mutate(`% of Total` = round(n / grand_total * 100, 1)) %>%
        rename(!!x_lbl := x_val, !!grp_label := grp_val, `Trial Count` = n) %>%
        datatable(rownames = FALSE, class = "compact stripe hover",
                  options = list(pageLength = 20, dom = "ftp", scrollX = TRUE))
    }
  })

  output$stats_explore <- DT::renderDataTable({
    ed    <- explore_data()
    d     <- ed$data
    grp   <- ed$grp
    validate(need(nrow(d) > 0, "No data available."))

    if (grp == "None") {
      stats <- data.frame(
        Statistic = c("Total", "Mean", "Median", "SD", "Min", "Max"),
        Value     = c(
          sum(d$n),
          round(mean(d$n), 1),
          round(median(d$n), 1),
          round(sd(d$n), 1),
          min(d$n),
          max(d$n)
        ), stringsAsFactors = FALSE)
    } else {
      grand_total <- sum(d$n)
      stats <- d %>%
        group_by(grp_val) %>%
        summarise(
          Total    = sum(n),
          `% Total` = round(sum(n) / grand_total * 100, 1),
          Mean     = round(mean(n), 1),
          Median   = round(median(n), 1),
          SD       = round(sd(n), 1),
          Min      = min(n),
          Max      = max(n),
          .groups  = "drop") %>%
        arrange(desc(Total))
      grp_label <- unname(EXPLORE_LABELS[grp])
      stats <- stats %>% rename(!!grp_label := grp_val)
    }

    datatable(stats, rownames = FALSE, class = "compact stripe hover",
              options = list(pageLength = 20, dom = "t", scrollX = TRUE))
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