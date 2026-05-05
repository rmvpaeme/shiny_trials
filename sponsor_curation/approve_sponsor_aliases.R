# Promote approved sponsor alias candidates into the reviewed alias table.
#
# Workflow:
#   1. Open data/sponsor_alias_candidates.csv.
#   2. Set approved=TRUE for rows that are genuinely the same sponsor.
#      Optional: edit canonical_suggestion, suggested_pattern, suggested_match_type,
#      or notes before approving.
#   3. Run:
#        Rscript sponsor_curation/approve_sponsor_aliases.R
#
# This appends approved candidates to config/sponsor_aliases.csv and then
# regenerates data/sponsor_alias_candidates.csv so approved rows disappear.

script_path <- local({
  cmd_args <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    return(normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE))
  }
  ofiles <- vapply(sys.frames(), function(frame) {
    if (!is.null(frame$ofile)) frame$ofile else NA_character_
  }, character(1))
  ofiles <- ofiles[!is.na(ofiles)]
  if (length(ofiles)) normalizePath(ofiles[[length(ofiles)]], mustWork = TRUE) else NA_character_
})
script_dir <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)
audit_script <- file.path(script_dir, "audit_sponsors.R")
rscript_bin <- function() {
  bin <- file.path(R.home("bin"), "Rscript")
  if (file.exists(bin)) bin else "Rscript"
}

args <- commandArgs(trailingOnly = TRUE)
candidate_path <- if (length(args) >= 1) args[[1]] else project_path("data", "sponsor_alias_candidates.csv")
alias_path <- if (length(args) >= 2) args[[2]] else project_path("config", "sponsor_aliases.csv")

truthy <- function(x) {
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")
}

if (!file.exists(candidate_path)) {
  stop("Candidate file not found: ", candidate_path,
       ". Run Rscript sponsor_curation/audit_sponsors.R first.")
}
if (!file.exists(alias_path)) {
  stop("Alias table not found: ", alias_path)
}

candidates <- read.csv(candidate_path, stringsAsFactors = FALSE, check.names = FALSE)
aliases <- read.csv(alias_path, stringsAsFactors = FALSE, check.names = FALSE)

required_candidates <- c(
  "canonical_suggestion", "suggested_pattern", "suggested_match_type",
  "approved"
)
missing_candidates <- setdiff(required_candidates, names(candidates))
if (length(missing_candidates)) {
  stop("Candidate file missing required columns: ",
       paste(missing_candidates, collapse = ", "))
}

required_aliases <- c("priority", "pattern", "canonical", "match_type", "approved", "notes")
missing_aliases <- setdiff(required_aliases, names(aliases))
if (length(missing_aliases)) {
  stop("Alias table missing required columns: ",
       paste(missing_aliases, collapse = ", "))
}

approved <- candidates[truthy(candidates$approved), , drop = FALSE]
if (!nrow(approved)) {
  message("No approved candidate rows found in ", candidate_path)
  message("For the first manual curation, run: Rscript sponsor_curation/review_sponsor_aliases.R")
  message("Or set approved=TRUE for accepted rows in the candidate CSV, then rerun this script.")
  quit(save = "no", status = 0)
}

approved$canonical_suggestion <- trimws(approved$canonical_suggestion)
approved$suggested_pattern <- trimws(approved$suggested_pattern)
approved$suggested_match_type <- trimws(approved$suggested_match_type)
approved$suggested_match_type[approved$suggested_match_type == ""] <- "exact"

approved <- approved[
  nzchar(approved$canonical_suggestion) &
    nzchar(approved$suggested_pattern),
  ,
  drop = FALSE
]
if (!nrow(approved)) {
  stop("Approved rows were present, but none had both canonical_suggestion and suggested_pattern.")
}

next_priority <- suppressWarnings(max(as.integer(aliases$priority), na.rm = TRUE))
if (!is.finite(next_priority)) next_priority <- 0L

default_note <- "Approved from data/sponsor_alias_candidates.csv"
notes <- rep(default_note, nrow(approved))
if ("notes" %in% names(approved)) {
  has_note <- !is.na(approved$notes) & nzchar(trimws(approved$notes))
  notes[has_note] <- approved$notes[has_note]
}

new_aliases <- data.frame(
  priority = seq(next_priority + 10L, by = 10L, length.out = nrow(approved)),
  pattern = approved$suggested_pattern,
  canonical = approved$canonical_suggestion,
  match_type = approved$suggested_match_type,
  approved = TRUE,
  notes = notes,
  stringsAsFactors = FALSE
)

combined <- rbind(aliases[, required_aliases], new_aliases)
dedupe_key <- paste(
  tolower(trimws(combined$pattern)),
  tolower(trimws(combined$canonical)),
  tolower(trimws(combined$match_type)),
  sep = "\r"
)
before <- nrow(combined)
combined <- combined[!duplicated(dedupe_key), , drop = FALSE]
combined$priority <- seq(10L, by = 10L, length.out = nrow(combined))

write.csv(combined, alias_path, row.names = FALSE, na = "")

added <- nrow(combined) - nrow(aliases)
skipped <- nrow(new_aliases) - added
message("Approved candidate rows: ", nrow(approved))
message("Added to alias table: ", added)
message("Skipped as duplicates: ", skipped)
message("Alias table now has ", nrow(combined), " rows: ", alias_path)

if (file.exists(audit_script)) {
  message("Regenerating candidate queue...")
  status <- system2(
    rscript_bin(),
    c(audit_script, project_path("data", "sponsor_normalisation_log.csv"), candidate_path, alias_path)
  )
  if (!identical(status, 0L)) {
    warning("audit_sponsors.R exited with status ", status,
            ". Alias table was updated, but candidate queue may be stale.")
  }
}
