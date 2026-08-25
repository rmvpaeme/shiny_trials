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
#   editable   FALSE for derived fields. Load-bearing: allowing an edit to
#              trial_duration_days would silently contradict the two dates shown
#              on the same screen.
#   control    widget type: select | text | number | date | bool | entity
#   vocab      a literal vector, or NULL for free text. Registry-backed fields
#              resolve their choices server-side — 6,954 sponsor and 19,645
#              substance canonicals do not belong in a browser payload.
#   route      WHERE A CORRECTION GOES. sponsor_registry / substance_registry
#              generalise to every trial carrying that raw string;
#              trial_override applies to this trial alone.
#   override_col  the cache column an override writes. MUST be NA whenever
#              route is not trial_override — that is what keeps the routing
#              split enforced rather than conventional, and
#              attach_trial_overrides() refuses those columns a second time.

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

# The normalised column shows the LABEL, not the label plus a restatement of
# the raw. It used to read "GlaxoSmithKline AB (final label: GlaxoSmithKline)",
# which repeated what the raw column already said and buried the answer.
#
# The layer that produced it is worth noting, but NOT as a warning.
#
# 47% of trials (7,587 of 16,209 measured) have no registry match and fall back
# to the register's own name — and 6,757 of those names are already perfectly
# clean, "Bristol Myers Squibb" among them. Flagging that with a warning symbol
# fires on half the corpus and tells the reviewer something is wrong when
# nothing is; it is alarm fatigue by construction.
#
# So it is stated as a fact and not decorated. It also avoids naming the
# registry: "not in the sponsor registry" presumes the reader knows there is
# one and what membership implies. What the reviewer needs is what they are
# looking at — the register's own text, passed through unchanged — which is
# also the hint that the string is a candidate for tab 2.
fmt_sponsor <- function(row) {
  lab <- row_val(row, "sponsor_label")
  src <- row_val(row, "sponsor_label_source")
  if (is.na(lab)) return(NA_character_)
  if (identical(src, "raw"))               paste0(lab, "  · not normalised — register's own name")
  else if (identical(src, "human"))        paste0(lab, "  · human decision")
  else if (identical(src, "human_reject")) paste0(lab, "  · human rejected the proposal")
  else lab
}

# Same principle: show the category, and only mention the register's own
# wording when it differs. "Completed (category: Completed)" is noise.
fmt_status <- function(row) {
  cat_ <- row_val(row, "status")
  raw  <- row_val(row, "status_raw")
  if (is.na(cat_)) return(raw)
  if (is.na(raw) || identical(trimws(raw), trimws(cat_))) return(cat_)
  paste0(cat_, "  (register: ", raw, ")")
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
       norm_col = "sponsor_label", render = fmt_sponsor,
       editable = TRUE, control = "entity", vocab = NULL,
       route = "sponsor_registry", override_col = NA_character_,
       note = "Corrects EVERY trial carrying this raw sponsor string."),

  list(id = "sponsor_type", label = "Sponsor type", group = "entities",
       raw_cols = c("b1_sponsor.b31_and_b32_status_of_the_sponsor",
                    "authorizedApplication.authorizedPartI.sponsors.commercial"),
       norm_col = "sponsor_type", render = NULL,
       editable = TRUE, control = "select", vocab = c("academic", "industry"),
       route = "sponsor_registry", override_col = NA_character_,
       note = "Entity type on the registry; applies to every trial with this sponsor."),

  list(id = "product", label = "Product", group = "entities",
       raw_cols = c("DIMP_product_name_raw", "DIMP_product_name"),
       norm_col = "DIMP_product_name", render = NULL,
       editable = TRUE, control = "text", vocab = NULL,
       route = "trial_override", override_col = "DIMP_product_name",
       note = "This trial only."),

  list(id = "inn", label = "INN (register text)", group = "entities",
       raw_cols = c("DIMP_inn_name_raw", "DIMP_inn_name"),
       norm_col = "DIMP_inn_name", render = NULL,
       editable = TRUE, control = "text", vocab = NULL,
       route = "trial_override", override_col = "DIMP_inn_name",
       note = "This trial only. The register's own INN wording, with duplicate slash-parts removed — NOT the resolved substance."),

  list(id = "substance", label = "Active substance (resolved)", group = "entities",
       raw_cols = c("DIMP_inn_name_raw", "DIMP_product_name_raw",
                    "DIMP_inn_name", "DIMP_product_name"),
       norm_col = "substance_label", render = NULL,
       editable = TRUE, control = "entity", vocab = NULL,
       route = "substance_registry", override_col = NA_character_,
       note = "What the substance registry resolved the INN text to. Corrects EVERY trial carrying this raw substance string."),

  list(id = "organ_class", label = "MedDRA organ class", group = "entities",
       raw_cols = c("MEDDRA_organ_class_raw", "MEDDRA_organ_class"),
       norm_col = "MEDDRA_organ_class", render = NULL,
       editable = TRUE, control = "text", vocab = NULL,
       route = "trial_override", override_col = "MEDDRA_organ_class",
       note = "This trial only. MedDRA has no registry."),

  list(id = "meddra_term", label = "MedDRA term", group = "entities",
       raw_cols = c("MEDDRA_term_raw", "MEDDRA_term"),
       norm_col = "MEDDRA_term", render = NULL,
       editable = TRUE, control = "text", vocab = NULL,
       route = "trial_override", override_col = "MEDDRA_term",
       note = "This trial only. MedDRA has no registry."),

  list(id = "age_group", label = "Age group", group = "entities",
       raw_cols = "age_group_raw", norm_col = "age_group", render = NULL,
       editable = TRUE, control = "select", vocab = c("Paediatric", "Adult", "Paediatric & Adult", "Unknown"),
       route = "trial_override", override_col = "age_group",
       note = "This trial only."),

  list(id = "is_orphan", label = "Orphan designation", group = "entities",
       raw_cols = "is_orphan_raw", norm_col = "is_orphan", render = NULL,
       editable = TRUE, control = "select", vocab = c("Yes", "No", "Unknown"),
       route = "trial_override", override_col = "is_orphan",
       note = "This trial only."),

  list(id = "register", label = "Register", group = "status",
       raw_cols = character(), norm_col = "register", render = NULL,
       editable = FALSE, control = "text", vocab = NULL,
       route = NA_character_, override_col = NA_character_,
       note = "Identity, derived from the trial id. Not editable."),

  list(id = "status", label = "Status", group = "status",
       raw_cols = "status_raw", norm_col = "status", render = fmt_status,
       editable = TRUE, control = "select", vocab = c("Ongoing", "Completed", "Withdrawn", "Not Authorised", "Administrative"),
       route = "trial_override", override_col = "status",
       note = "This trial only. The status CATEGORY, not the register wording."),

  list(id = "phase", label = "Phase", group = "entities",
       raw_cols = "phase_raw", norm_col = "phase", render = NULL,
       editable = TRUE, control = "select", vocab = c("Phase I", "Phase II", "Phase III", "Phase IV",
                       "Phase I / Phase II", "Phase II / Phase III"),
       route = "trial_override", override_col = "phase",
       note = "This trial only."),

  list(id = "participants", label = "Participants", group = "entities",
       raw_cols = "participants_n_raw", norm_col = "participants_n",
       render = fmt_participants,
       editable = TRUE, control = "number", vocab = NULL,
       route = "trial_override", override_col = "participants_n",
       note = "This trial only."),

  list(id = "countries", label = "Countries", group = "entities",
       raw_cols = "Member_state_raw", norm_col = "Member_state", render = NULL,
       editable = TRUE, control = "text", vocab = NULL,
       route = "trial_override", override_col = "Member_state",
       note = "This trial only. Slash-separated; # Countries is recomputed."),

  list(id = "submitted", label = "Submitted", group = "status",
       raw_cols = "submission_date", norm_col = "submission_date_parsed",
       render = fmt_date("submission_date_parsed"),
       editable = TRUE, control = "date", vocab = NULL,
       route = "trial_override", override_col = "submission_date_parsed",
       note = "This trial only."),

  list(id = "start_date", label = "Start Date", group = "status",
       raw_cols = character(), norm_col = "start_date",
       render = fmt_date("start_date"),
       editable = TRUE, control = "date", vocab = NULL,
       route = "trial_override", override_col = "start_date",
       note = "This trial only."),

  list(id = "decision_date", label = "Decision Date", group = "status",
       raw_cols = character(), norm_col = "decision_date",
       render = fmt_date("decision_date"),
       editable = TRUE, control = "date", vocab = NULL,
       route = "trial_override", override_col = "decision_date",
       note = "This trial only."),

  list(id = "trial_end_date", label = "Trial End Date", group = "status",
       raw_cols = character(), norm_col = "trial_duration_end_date",
       render = fmt_date("trial_duration_end_date"),
       editable = TRUE, control = "date", vocab = NULL,
       route = "trial_override", override_col = "trial_duration_end_date",
       note = "This trial only. Trial duration is recomputed."),

  list(id = "trial_duration", label = "Trial duration", group = "status",
       raw_cols = character(), norm_col = "trial_duration_days",
       render = fmt_duration,
       editable = FALSE, control = "text", vocab = NULL,
       route = NA_character_, override_col = NA_character_,
       note = "Derived from the two dates. Edit those instead."),

  list(id = "has_results", label = "Results reported", group = "status",
       raw_cols = "results_source_raw", norm_col = "has_results",
       render = fmt_results_reported,
       editable = TRUE, control = "bool", vocab = NULL,
       route = "trial_override", override_col = "has_results",
       note = "This trial only."),

  list(id = "result_source", label = "Result source", group = "status",
       raw_cols = "results_source_raw", norm_col = "results_source_raw",
       render = fmt_result_source,
       editable = FALSE, control = "text", vocab = NULL,
       route = NA_character_, override_col = NA_character_,
       note = "The register's own words. Not editable.")
)

# ── The extraction contract ───────────────────────────────────────────────────
#
# One row of trials_cache.rds in, one list per field out. Pure and testable with
# a one-row tibble; both apps build their own widgets from the result.
# `raw_status` distinguishes three cases that all render as NA otherwise, and
# which a reviewer must be able to tell apart:
#
#   "none"    the field has no single raw counterpart (register, trial duration)
#   "absent"  the column is NOT IN THIS CACHE — an older snapshot that predates
#             it. The register may well have sent a value; this build cannot
#             show it.
#   "empty"   the column exists and the register sent nothing for this trial.
#
# Conflating "absent" with "empty" is how a reviewer concludes the data is
# missing when the cache is simply older than the field. Observed: the deployed
# v0.21.0 cache has 73 columns and lacks phase_raw, Member_state_raw,
# age_group_raw, is_orphan_raw and participants_n_raw, so five rows read as
# empty on every single trial.
field_rows <- function(row, group = NULL, spec = TRIAL_FIELD_SPEC) {
  if (!is.null(group)) spec <- Filter(function(f) f$group %in% group, spec)
  lapply(spec, function(f) {
    raw <- if (length(f$raw_cols)) coalesce_raw(row, f$raw_cols) else NA_character_
    status <- if (!length(f$raw_cols)) "none"
              else if (!any(f$raw_cols %in% names(row))) "absent"
              else if (is.na(raw) || !nzchar(trimws(raw))) "empty"
              else "present"
    list(
      id    = f$id,
      label = f$label,
      group = f$group,
      raw   = raw,
      raw_status = status,
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
