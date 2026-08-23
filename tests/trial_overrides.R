# Per-trial overrides are applied, typed correctly, and REFUSED where they
# would collide with the registries.
#
#   CACHE_PATH=<a current cache> DB_PATH=<its db> Rscript tests/trial_overrides.R
#
# Writes only to a temp directory; TRIAL_OVERRIDES_PATH is pointed at it and the
# real data/trial_overrides.csv is never read or written.

suppressPackageStartupMessages({ library(dplyr) })

cache_path <- Sys.getenv("CACHE_PATH", unset = "trials_cache.rds")
db_path    <- Sys.getenv("DB_PATH",    unset = "./data/trials.sqlite")

# CHECK THE CACHE BEFORE SOURCING app.R, NOT AFTER.
#
# Sourcing app.R calls load_trial_data(), which silently rebuilds from SQLite
# when the cache is stale. Against the production database that is a ~40-minute
# full rebuild — so a test that merely sources app.R can hang CI for a reason
# that has nothing to do with what it is testing. Exit 2 = could not measure,
# the convention E_emit.R sets.
if (file.exists(cache_path)) {
  cv <- unique(readRDS(cache_path)$data_processing_version)
  ln <- grep("^DATA_PROCESSING_VERSION <-", readLines("app.R", warn = FALSE), value = TRUE)
  av <- if (length(ln)) sub('.*"(.*)".*', "\\1", ln[[1]]) else NA_character_
  if (!is.na(av) && !identical(cv, av) && file.exists(db_path)) {
    message("COULD NOT MEASURE: ", cache_path, " is stale and a database exists,")
    message("  so sourcing app.R would trigger a full rebuild.")
    message("    cache : ", paste(cv, collapse = ", "))
    message("    app.R : ", av)
    message("  Point CACHE_PATH/DB_PATH at a current pair, or run rebuild_cache.R.")
    quit(save = "no", status = 2L)
  }
}

tmp <- tempfile("trialov"); dir.create(tmp)
ovp <- file.path(tmp, "trial_overrides.csv")
Sys.setenv(TRIAL_OVERRIDES_PATH = ovp)

suppressMessages(source("app.R"))
if (is.null(trials_data)) stop("no data loaded", call. = FALSE)

d <- trials_data
failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

ids <- d$`_id`[1:3]

# Row 4 names a trial that does not exist. A EudraCT trial genuinely changes
# country suffix between snapshots (5,438 of them did once), so a stale override
# must be ignored rather than error. Row 5 is the one that must be refused.
utils::write.csv(data.frame(
  `_id`          = c(ids[1], ids[2], ids[3], "2999-000000-00-XX", ids[1]),
  field_id       = c("phase", "participants", "countries", "phase", "sponsor"),
  column         = c("phase", "participants_n", "Member_state", "phase", "sponsor_label"),
  value          = c("Phase III", "999", "Belgium / France / Spain", "Phase I", "ACME Corp"),
  value_type     = c("character", "numeric", "character", "character", "character"),
  reviewer       = "tester",
  decided_at_utc = "2026-08-23T10:00:00Z",
  decision_id    = 1:5,
  comment        = "",
  check.names    = FALSE), ovp, row.names = FALSE, na = "")

d2 <- attach_trial_overrides(d)

check(identical(d2$phase[1], "Phase III"), "a character override is applied")
check(identical(d2$participants_n[2], 999), "a numeric override is cast, not left a string")
check(is.numeric(d2$participants_n), "the numeric column stays numeric")
check(identical(d2$Member_state[3], "Belgium / France / Spain"), "a country override is applied")
check(identical(as.integer(d2$n_countries[3]), 3L), "n_countries is recomputed from the override")
check(grepl("phase", d2$override_fields[1]), "override_fields records what was overridden")
check(is.na(d2$override_fields[4]), "an untouched trial has no override_fields")

# THE GUARD. Without it the registry/per-trial routing split is convention only.
check(identical(d2$sponsor_label[1], d$sponsor_label[1]),
      "a sponsor_label override is REFUSED (the registries own that field)")
check(!grepl("sponsor", ifelse(is.na(d2$override_fields[1]), "", d2$override_fields[1])),
      "the refused field is not recorded as applied")

deny <- trial_override_deny(d)
for (col in c("substance_label", "sponsor_clean", "sponsor_parent",
              "MEDDRA_term_raw", "phase_raw", "_id")) {
  check(col %in% deny, sprintf("'%s' is on the deny list", col))
}

unlink(ovp)
d3 <- attach_trial_overrides(d)
check(all(is.na(d3$override_fields)), "no override file = no-op")
check("override_fields" %in% names(d3), "override_fields exists even with no file")

writeLines(c("not,a,valid", "override,file,here"), ovp)
d4 <- tryCatch(attach_trial_overrides(d), error = function(e) e)
check(!inherits(d4, "error"), "a malformed override file does not error")

cat("\n")
if (length(failures)) {
  cat(sprintf("%d check(s) failed\n", length(failures)))
  quit(save = "no", status = 1L)
}
cat("all checks passed\n")
