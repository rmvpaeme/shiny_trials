# Apply reviewed sponsor aliases to app.R and refresh sponsor-derived files.
#
# Typical use after manual review:
#   Rscript sponsor_curation/apply_sponsor_aliases.R
#
# Useful options:
#   --no-render   Skip rendering preprocessing.Rmd
#   --no-cache    Only update the alias block in app.R
#   --no-audit    Skip regenerating data/sponsor_alias_candidates.csv
#
# Test/advanced options:
#   --app=app.R
#   --alias=config/sponsor_aliases.csv
#   --cache=trials_cache.rds
#   --log=data/sponsor_normalisation_log.csv
#   --candidate=data/sponsor_alias_candidates.csv
#   --baseline=config/sponsor_curation_baseline.csv

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
setwd(project_root)

args <- commandArgs(trailingOnly = TRUE)

flags <- args[grepl("^--[A-Za-z0-9_-]+$", args)]
kv_args <- args[grepl("^--[A-Za-z0-9_-]+=", args)]

has_flag <- function(flag) flag %in% flags
get_opt <- function(name, default) {
  prefix <- paste0("--", name, "=")
  hit <- kv_args[startsWith(kv_args, prefix)]
  if (length(hit)) sub(prefix, "", hit[[length(hit)]], fixed = TRUE) else default
}

app_path <- get_opt("app", project_path("app.R"))
alias_path <- get_opt("alias", project_path("config", "sponsor_aliases.csv"))
cache_path <- get_opt("cache", project_path("trials_cache.rds"))
log_path <- get_opt("log", project_path("data", "sponsor_normalisation_log.csv"))
candidate_path <- get_opt("candidate", project_path("data", "sponsor_alias_candidates.csv"))
baseline_path <- get_opt("baseline", project_path("config", "sponsor_curation_baseline.csv"))

skip_cache <- has_flag("--no-cache")
skip_audit <- has_flag("--no-audit")
skip_render <- has_flag("--no-render")

truthy <- function(x) {
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")
}

r_string <- function(x) {
  encodeString(as.character(x), quote = "\"")
}

escape_regex <- function(x) {
  gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x, perl = TRUE)
}

read_aliases <- function(path) {
  if (!file.exists(path)) {
    stop("Alias table not found: ", path)
  }
  aliases <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  required <- c("priority", "pattern", "canonical", "match_type", "approved")
  missing <- setdiff(required, names(aliases))
  if (length(missing)) {
    stop("Alias table missing required columns: ", paste(missing, collapse = ", "))
  }

  aliases <- aliases[truthy(aliases$approved), , drop = FALSE]
  aliases$pattern <- trimws(aliases$pattern)
  aliases$canonical <- trimws(aliases$canonical)
  aliases$match_type <- tolower(trimws(aliases$match_type))
  aliases$match_type[aliases$match_type == ""] <- "exact"
  aliases <- aliases[
    nzchar(aliases$pattern) &
      nzchar(aliases$canonical) &
      aliases$match_type %in% c("exact", "regex"),
    ,
    drop = FALSE
  ]
  aliases$priority <- suppressWarnings(as.integer(aliases$priority))
  aliases$priority[is.na(aliases$priority)] <- seq_len(sum(is.na(aliases$priority))) * 10L
  aliases[order(aliases$priority, aliases$canonical, aliases$pattern), , drop = FALSE]
}

alias_to_regex <- function(pattern, match_type) {
  if (identical(match_type, "regex")) {
    pattern
  } else {
    paste0("^", escape_regex(pattern), "$")
  }
}

replace_app_alias_block <- function(app_path, aliases) {
  if (!file.exists(app_path)) {
    stop("App file not found: ", app_path)
  }
  lines <- readLines(app_path, warn = FALSE)
  start <- grep("^  sponsor_aliases <- list\\(", lines)
  apply_start <- grep("^  apply_sponsor_aliases <- function\\(vals\\)", lines)
  if (length(start) != 1L || length(apply_start) != 1L || start >= apply_start) {
    stop("Could not find a unique sponsor_aliases block in ", app_path)
  }

  regex_patterns <- mapply(alias_to_regex, aliases$pattern, aliases$match_type, USE.NAMES = FALSE)
  entries <- if (nrow(aliases)) {
    vapply(seq_len(nrow(aliases)), function(i) {
      comma <- if (i < nrow(aliases)) "," else ""
      paste0("    c(", r_string(regex_patterns[[i]]), ", ", r_string(aliases$canonical[[i]]), ")", comma)
    }, character(1))
  } else {
    character(0)
  }

  new_block <- c("  sponsor_aliases <- list(", entries, "  )")
  updated <- c(lines[seq_len(start - 1L)], new_block, lines[apply_start:length(lines)])
  writeLines(updated, app_path, useBytes = TRUE)
  invisible(length(entries))
}

load_normalizer <- function(app_path) {
  app_lines <- readLines(app_path, warn = FALSE)
  stop_at <- grep("^prepare_trial_data <-", app_lines)[1] - 1L
  if (!is.finite(stop_at) || stop_at <= 0L) {
    stop("Could not find prepare_trial_data marker in ", app_path)
  }
  eval(parse(text = paste(app_lines[seq_len(stop_at)], collapse = "\n")), envir = .GlobalEnv)
}

refresh_cache_and_logs <- function(cache_path, log_path, baseline_path) {
  if (!file.exists(cache_path)) {
    stop("Cache file not found: ", cache_path)
  }

  cache <- readRDS(cache_path)
  required <- c(
    "register",
    "b1_sponsor.b11_name_of_sponsor",
    "authorizedApplication.authorizedPartI.sponsors.organisation.name"
  )
  missing <- setdiff(required, names(cache))
  if (length(missing)) {
    stop("Cache missing required sponsor columns: ", paste(missing, collapse = ", "))
  }

  raw_sponsor <- dplyr::case_when(
    cache$register == "EUCTR" ~ stringr::str_split_fixed(
      as.character(cache[["b1_sponsor.b11_name_of_sponsor"]]), " / ", 2
    )[, 1],
    cache$register == "CTIS" ~ as.character(
      cache[["authorizedApplication.authorizedPartI.sponsors.organisation.name"]]
    ),
    TRUE ~ NA_character_
  )

  before_unique <- length(unique(stats::na.omit(cache$sponsor_name)))
  cache$sponsor_name <- normalize_sponsor_name(raw_sponsor)
  after_unique <- length(unique(stats::na.omit(cache$sponsor_name)))
  saveRDS(cache, cache_path)

  sponsor_log <- data.frame(
    raw = raw_sponsor,
    normalised = cache$sponsor_name,
    register = cache$register,
    stringsAsFactors = FALSE
  ) |>
    dplyr::filter(!is.na(raw), raw != "NA", raw != "") |>
    dplyr::group_by(register, raw, normalised) |>
    dplyr::summarise(n_trials = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(changed = raw != dplyr::coalesce(normalised, "")) |>
    dplyr::arrange(register, dplyr::desc(n_trials))

  dir.create(dirname(log_path), recursive = TRUE, showWarnings = FALSE)
  write.csv(sponsor_log, log_path, row.names = FALSE, na = "")

  baseline <- data.frame(
    sponsor_name = sort(unique(cache$sponsor_name[!is.na(cache$sponsor_name) & cache$sponsor_name != ""])),
    baseline_date = as.character(Sys.Date()),
    stringsAsFactors = FALSE
  )
  dir.create(dirname(baseline_path), recursive = TRUE, showWarnings = FALSE)
  write.csv(baseline, baseline_path, row.names = FALSE, na = "")

  list(
    rows = nrow(cache),
    unique_before = before_unique,
    unique_after = after_unique,
    log_rows = nrow(sponsor_log),
    baseline_rows = nrow(baseline)
  )
}

aliases <- read_aliases(alias_path)
message("Approved aliases read: ", nrow(aliases), " from ", alias_path)

written <- replace_app_alias_block(app_path, aliases)
message("Alias rules written to ", app_path, ": ", written)

if (!skip_cache) {
  load_normalizer(app_path)
  cache_stats <- refresh_cache_and_logs(cache_path, log_path, baseline_path)
  message("Cache refreshed: ", cache_stats$rows, " rows")
  message("Unique sponsors: ", cache_stats$unique_before, " -> ", cache_stats$unique_after)
  message("Sponsor log rows written: ", cache_stats$log_rows, " to ", log_path)
  message("Sponsor baseline rows written: ", cache_stats$baseline_rows, " to ", baseline_path)
}

if (!skip_audit && file.exists(audit_script)) {
  message("Regenerating sponsor alias candidates...")
  status <- system2(
    rscript_bin(),
    c(audit_script, log_path, candidate_path, alias_path)
  )
  if (!identical(status, 0L)) {
    warning("audit_sponsors.R exited with status ", status)
  }
}

preprocessing_path <- project_path("preprocessing.Rmd")
if (!skip_render && file.exists(preprocessing_path)) {
  if (requireNamespace("rmarkdown", quietly = TRUE)) {
    message("Rendering preprocessing.Rmd...")
    rmarkdown::render(preprocessing_path, quiet = TRUE)
  } else {
    warning("Package rmarkdown is not installed; skipping preprocessing render.")
  }
}

message("Done.")
