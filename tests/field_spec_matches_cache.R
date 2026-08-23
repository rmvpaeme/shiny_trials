# The field spec must describe columns that actually exist.
#
#   Rscript tests/field_spec_matches_cache.R
#
# curation_app/R/field_spec.R is a hand-written catalogue of what
# prepare_trial_data() produces. Nothing mechanically ties the two together, so
# a renamed or dropped column leaves the spec pointing at nothing — and the
# failure is silent by construction: row_val() returns NA for a missing column
# on purpose, so both apps render an em-dash and neither says why. That is the
# right runtime behaviour (a stale spec must not take the dashboard down) and
# exactly why it needs a test instead.
#
# Set CACHE_PATH to check a different cache.

suppressPackageStartupMessages({ library(dplyr) })

spec_path  <- "curation_app/R/field_spec.R"
cache_path <- Sys.getenv("CACHE_PATH", unset = "trials_cache.rds")

if (!file.exists(spec_path))  stop("no spec at ", spec_path, call. = FALSE)
if (!file.exists(cache_path)) {
  message("SKIP: no cache at ", cache_path, " — nothing to check the spec against.")
  quit(save = "no", status = 0L)
}

source(spec_path)

cols <- names(readRDS(cache_path))
failures <- character()
note <- function(msg) failures <<- c(failures, msg)

cat(sprintf("spec version %s, %d fields, cache has %d columns\n\n",
            FIELD_SPEC_VERSION, length(TRIAL_FIELD_SPEC), length(cols)))

ids <- vapply(TRIAL_FIELD_SPEC, function(f) f$id, character(1))
dup <- unique(ids[duplicated(ids)])
if (length(dup)) {
  note(sprintf("duplicate field id(s): %s", paste(dup, collapse = ", ")))
}
# An id is a decision key, so it has to survive being written to a CSV column
# and read back. Anything outside this class invites quoting bugs later.
bad_id <- ids[!grepl("^[a-z0-9_]+$", ids)]
if (length(bad_id)) {
  note(sprintf("field id(s) not lower_snake_case: %s", paste(bad_id, collapse = ", ")))
}

for (f in TRIAL_FIELD_SPEC) {
  if (!f$norm_col %in% cols) {
    note(sprintf("%s: norm_col '%s' is not in the cache", f$id, f$norm_col))
  }
  for (rc in f$raw_cols) {
    if (!rc %in% cols) {
      note(sprintf("%s: raw_cols entry '%s' is not in the cache", f$id, rc))
    }
  }
  if (!f$group %in% c("entities", "status")) {
    note(sprintf("%s: unknown group '%s'", f$id, f$group))
  }
  if (!is.null(f$render) && !is.function(f$render)) {
    note(sprintf("%s: render is set but is not a function", f$id))
  }
}

# field_rows() must survive a row with every column NA. Both apps hit this the
# moment a trial has no substance, no results and no dates, which is common.
blank <- readRDS(cache_path)[1, ]
for (cn in names(blank)) blank[[cn]][1] <- NA
out <- tryCatch(field_rows(blank), error = function(e) e)
if (inherits(out, "error")) {
  note(sprintf("field_rows() errors on an all-NA row: %s", conditionMessage(out)))
} else if (length(out) != length(TRIAL_FIELD_SPEC)) {
  note("field_rows() did not return one entry per field")
}

# And on a row that is missing columns entirely — a cache built before a spec
# entry was added. This is the case row_val()'s NA-safety exists for.
thin <- readRDS(cache_path)[1, c("_id", "register")]
out2 <- tryCatch(field_rows(thin), error = function(e) e)
if (inherits(out2, "error")) {
  note(sprintf("field_rows() errors on a row missing columns: %s", conditionMessage(out2)))
}

if (length(failures)) {
  cat(sprintf("%d problem(s):\n", length(failures)))
  cat(paste0("  - ", failures, collapse = "\n"), "\n")
  quit(save = "no", status = 1L)
}
cat("ok: every spec column exists in the cache\n")
