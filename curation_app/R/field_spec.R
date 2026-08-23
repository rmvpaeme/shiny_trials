# ══════════════════════════════════════════════════════════════════════════════
# THE RECODED-FIELD CATALOGUE
# ══════════════════════════════════════════════════════════════════════════════
#
# SOURCED BY TWO APPLICATIONS. Check both before changing anything here.
#
#   ../app.R          the dashboard, which renders it READ-ONLY in the
#                     trial-detail modal (trial_detail_modal())
#   ./app.R           the curation app, which renders it WITH INPUTS in the
#                     trial-validation tab
#
# It lives under curation_app/ rather than at the repo root for a mechanical
# reason: a Posit Cloud bundle is rooted at a directory and cannot reference
# paths above it, so the curation app cannot reach UP into the repo — but the
# dashboard can reach DOWN. manifest.json carries this path explicitly.
#
# Therefore: no shiny, no shinydashboard, no DT. stringr and dplyr only, both of
# which each app already loads.
#
# ── THE BOUNDARY ──────────────────────────────────────────────────────────────
#
# THE SPEC DESCRIBES. IT MUST NOT COMPUTE.
#
# Do not try to drive prepare_trial_data() (app.R) from it. That is ~1,000 lines
# of register-specific derivation on the dashboard's only data path, with no test
# harness. Shared here = the catalogue plus pure extraction from an already-built
# row. Rendering stays in each app, because one needs a table and the other needs
# a form. A spec that both describes and computes cannot be wrong-but-harmless.
#
# Because it can drift from prepare_trial_data(), tests/field_spec_matches_cache.R
# pins every column name in it against the actual cache.
#
# ── KEYS ──────────────────────────────────────────────────────────────────────
#
#   id         PERMANENT. Lands in trial_decisions.field_id and in
#              data/trial_overrides.csv. Renaming one orphans every decision
#              ever recorded against it.
#   label      One string, so the modal and the form cannot disagree.
#   group      Which section renders it. "entities" gets the 3-column
#              raw-vs-normalised table; "status" gets the 2-column table.
#   raw_cols   Ordered coalesce chain over the registry's own values. Empty
#              when the register has no single raw counterpart to show.
#   norm_col   The column in trials_cache.rds holding the normalised value.
#   render     Optional function(row) -> display string, for the few cells that
#              are composites rather than a single column.
#
# Edit-side keys (editable/control/vocab/route/override_col) arrive with the
# curation app's trial-validation tab. They are deliberately absent until there
# is something that reads them.

FIELD_SPEC_VERSION <- "1"

# ── Pure extraction helpers ───────────────────────────────────────────────────

# NA-safe single-cell read. A missing COLUMN and a missing VALUE both yield NA
# rather than an error, because the two apps read caches of different vintages
# and a spec entry that is ahead of the cache must degrade to an em-dash, not
# take the whole modal down.
row_val <- function(row, name) {
  if (!name %in% names(row)) return(NA_character_)
  val <- row[[name]][[1]]
  if (length(val) == 0 || is.null(val)) NA_character_ else as.character(val)
}

show_val <- function(x) {
  x <- as.character(x)
  if (length(x) == 0 || is.na(x) || !nzchar(stringr::str_trim(x)) || identical(x, "NA")) "—" else x
}

bool_label <- function(x) {
  if (isTRUE(x)) "Yes" else if (identical(x, FALSE)) "No" else "Unknown"
}

# First NON-NA of an ordered chain of columns.
#
# Deliberately dplyr::coalesce semantics — non-NA, NOT non-empty. A column
# holding "" must win over the next candidate and render as an em-dash, because
# that is what the dashboard has always shown and because "the register sent an
# empty value" and "the register sent nothing" are different facts. Skipping ""
# would silently promote a fallback column into a cell the register left blank.
coalesce_raw <- function(row, cols) {
  for (cn in cols) {
    v <- row_val(row, cn)
    if (!is.na(v)) return(v)
  }
  NA_character_
}

# ── The few composite cells ───────────────────────────────────────────────────
# These are functions of the row alone, so they belong on the data side of the
# boundary. Each reproduces a display string the dashboard has always shown.

fmt_sponsor <- function(row) {
  paste(show_val(row_val(row, "sponsor_name")),
        paste0("(final label: ", show_val(row_val(row, "sponsor_label")), ")"))
}

fmt_status <- function(row) {
  paste(show_val(row_val(row, "status_raw")),
        paste0("(category: ", show_val(row_val(row, "status")), ")"))
}

fmt_participants <- function(row) {
  n <- suppressWarnings(as.numeric(row_val(row, "participants_n")))
  if (is.na(n)) "—" else format(n, big.mark = ",", scientific = FALSE)
}

fmt_duration <- function(row) {
  days <- suppressWarnings(as.numeric(row_val(row, "trial_duration_days")))
  if (is.na(days) || !is.finite(days)) return("—")
  sprintf("%.1f months (%s days)", days / 30.4375,
          format(round(days), big.mark = ",", scientific = FALSE))
}

# The raw result flag is dropped from the cache (app.R's select(-any_of(...))),
# so when it is absent say WHICH register field it came from rather than showing
# a bare em-dash that reads as "no results information exists".
fmt_result_source <- function(row) {
  raw <- row_val(row, "results_source_raw")
  if (!is.na(raw) && nzchar(stringr::str_trim(raw))) return(raw)
  reg <- row_val(row, "register")
  if (identical(reg, "CTIS")) {
    "Derived from CTIS resultsFirstReceived; raw value not retained in this cache."
  } else if (identical(reg, "EUCTR")) {
    "Derived from EUCTR endPoints.endPoint.readyForValues; raw value not retained in this cache."
  } else {
    "Raw result source not retained in this cache."
  }
}

fmt_results_reported <- function(row) {
  if (!"has_results" %in% names(row)) return("Unknown")
  bool_label(row[["has_results"]][[1]])
}

fmt_date <- function(col) function(row) {
  v <- row[[col]]
  if (is.null(v) || length(v) == 0 || is.na(v[[1]])) NA_character_ else as.character(v[[1]])
}

# ── The catalogue ─────────────────────────────────────────────────────────────

TRIAL_FIELD_SPEC <- list(
  list(id = "sponsor", label = "Sponsor", group = "entities",
       raw_cols = c("sponsor_name_raw",
                    "b1_sponsor.b11_name_of_sponsor",
                    "authorizedApplication.authorizedPartI.sponsors.organisation.name"),
       norm_col = "sponsor_label", render = fmt_sponsor),

  list(id = "sponsor_type", label = "Sponsor type", group = "entities",
       raw_cols = c("b1_sponsor.b31_and_b32_status_of_the_sponsor",
                    "authorizedApplication.authorizedPartI.sponsors.commercial"),
       norm_col = "sponsor_type", render = NULL),

  list(id = "product", label = "Product", group = "entities",
       raw_cols = c("DIMP_product_name_raw", "DIMP_product_name"),
       norm_col = "DIMP_product_name", render = NULL),

  list(id = "inn", label = "INN / Generic name", group = "entities",
       raw_cols = c("DIMP_inn_name_raw", "DIMP_inn_name"),
       norm_col = "DIMP_inn_name", render = NULL),

  list(id = "substance", label = "Active substance", group = "entities",
       raw_cols = c("DIMP_inn_name_raw", "DIMP_product_name_raw",
                    "DIMP_inn_name", "DIMP_product_name"),
       norm_col = "substance_label", render = NULL),

  list(id = "organ_class", label = "MedDRA organ class", group = "entities",
       raw_cols = c("MEDDRA_organ_class_raw", "MEDDRA_organ_class"),
       norm_col = "MEDDRA_organ_class", render = NULL),

  list(id = "meddra_term", label = "MedDRA term", group = "entities",
       raw_cols = c("MEDDRA_term_raw", "MEDDRA_term"),
       norm_col = "MEDDRA_term", render = NULL),

  list(id = "register", label = "Register", group = "status",
       raw_cols = character(), norm_col = "register", render = NULL),

  list(id = "status", label = "Status", group = "status",
       raw_cols = "status_raw", norm_col = "status", render = fmt_status),

  list(id = "phase", label = "Phase", group = "status",
       raw_cols = character(), norm_col = "phase", render = NULL),

  list(id = "participants", label = "Participants", group = "status",
       raw_cols = character(), norm_col = "participants_n",
       render = fmt_participants),

  list(id = "countries", label = "Countries", group = "status",
       raw_cols = character(), norm_col = "Member_state", render = NULL),

  list(id = "submitted", label = "Submitted", group = "status",
       raw_cols = "submission_date", norm_col = "submission_date_parsed",
       render = fmt_date("submission_date_parsed")),

  list(id = "start_date", label = "Start Date", group = "status",
       raw_cols = character(), norm_col = "start_date",
       render = fmt_date("start_date")),

  list(id = "decision_date", label = "Decision Date", group = "status",
       raw_cols = character(), norm_col = "decision_date",
       render = fmt_date("decision_date")),

  list(id = "trial_end_date", label = "Trial End Date", group = "status",
       raw_cols = character(), norm_col = "trial_duration_end_date",
       render = fmt_date("trial_duration_end_date")),

  list(id = "trial_duration", label = "Trial duration", group = "status",
       raw_cols = character(), norm_col = "trial_duration_days",
       render = fmt_duration),

  list(id = "has_results", label = "Results reported", group = "status",
       raw_cols = "results_source_raw", norm_col = "has_results",
       render = fmt_results_reported),

  list(id = "result_source", label = "Result source", group = "status",
       raw_cols = "results_source_raw", norm_col = "results_source_raw",
       render = fmt_result_source)
)

# ── The extraction contract ───────────────────────────────────────────────────
#
# One row of trials_cache.rds in, one list per field out. Pure and testable with
# a one-row tibble; both apps build their own widgets from the result.
field_rows <- function(row, group = NULL, spec = TRIAL_FIELD_SPEC) {
  if (!is.null(group)) spec <- Filter(function(f) f$group %in% group, spec)
  lapply(spec, function(f) {
    list(
      id    = f$id,
      label = f$label,
      group = f$group,
      raw   = if (length(f$raw_cols)) coalesce_raw(row, f$raw_cols) else NA_character_,
      norm  = if (is.function(f$render)) f$render(row) else row_val(row, f$norm_col)
    )
  })
}

# ── Registry links ────────────────────────────────────────────────────────────
#
# CT_number can be a " / "-joined list; only the first token is a real accession,
# and the EUCTR URL additionally needs the country code, which lives on the END
# of `_id` and nowhere else.
trial_ct_number <- function(row) {
  stringr::str_trim(stringr::str_split_fixed(row_val(row, "CT_number"), " / ", 2)[, 1])
}

trial_link <- function(row) {
  ct <- trial_ct_number(row)
  if (identical(row_val(row, "register"), "EUCTR")) {
    cc <- stringr::str_extract(row_val(row, "_id"), "[A-Z]{2,3}$")
    paste0("https://www.clinicaltrialsregister.eu/ctr-search/trial/", ct, "/", cc)
  } else {
    paste0("https://euclinicaltrials.eu/ctis-public/view/", ct)
  }
}
