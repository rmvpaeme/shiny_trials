# Generate candidate duplicate sponsor aliases from the current normalisation log.
#
# Usage:
#   Rscript sponsor_curation/audit_sponsors.R
#   Rscript sponsor_curation/audit_sponsors.R data/sponsor_normalisation_log.csv data/sponsor_alias_candidates.csv
#
# Review the output CSV, then approve rows with approve_sponsor_aliases.R or
# review_sponsor_aliases.R. Approved aliases are used here to suppress already
# curated overlaps; app.R does not read the manual curation table.

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

args <- commandArgs(trailingOnly = TRUE)
log_path <- if (length(args) >= 1) args[[1]] else project_path("data", "sponsor_normalisation_log.csv")
out_path <- if (length(args) >= 2) args[[2]] else project_path("data", "sponsor_alias_candidates.csv")
alias_path <- if (length(args) >= 3) args[[3]] else project_path("config", "sponsor_aliases.csv")

if (!file.exists(log_path)) {
  stop("Sponsor normalisation log not found: ", log_path)
}

# Load only helper functions/constants, not the Shiny app.
app_lines <- readLines(project_path("app.R"), warn = FALSE)
stop_at <- grep("^prepare_trial_data <-", app_lines)[1] - 1L
eval(parse(text = paste(app_lines[seq_len(stop_at)], collapse = "\n")))

log_df <- read.csv(log_path, stringsAsFactors = FALSE, check.names = FALSE)
required <- c("raw", "normalised", "n_trials")
if (!all(required %in% names(log_df))) {
  stop("Sponsor log missing required columns: ",
       paste(setdiff(required, names(log_df)), collapse = ", "))
}

log_df$normalised_current <- normalize_sponsor_name(log_df$raw)
log_df$normalised_current[is.na(log_df$normalised_current)] <- log_df$normalised[is.na(log_df$normalised_current)]

truthy <- function(x) {
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")
}

apply_review_aliases <- function(x, path = alias_path) {
  if (!file.exists(path)) {
    return(x)
  }

  aliases <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  required_aliases <- c("pattern", "canonical", "match_type", "approved")
  if (!all(required_aliases %in% names(aliases))) {
    warning(
      "Alias table missing required columns; skipping manual curation aliases: ",
      paste(setdiff(required_aliases, names(aliases)), collapse = ", ")
    )
    return(x)
  }

  aliases <- aliases[truthy(aliases$approved), , drop = FALSE]
  aliases <- aliases[
    nzchar(trimws(aliases$pattern)) & nzchar(trimws(aliases$canonical)),
    ,
    drop = FALSE
  ]
  if (!nrow(aliases)) {
    return(x)
  }

  aliases$priority <- suppressWarnings(as.integer(aliases$priority))
  aliases$priority[is.na(aliases$priority)] <- seq_len(sum(is.na(aliases$priority))) * 10L
  aliases <- aliases[order(aliases$priority), , drop = FALSE]

  out <- x
  for (i in seq_len(nrow(aliases))) {
    pattern <- trimws(aliases$pattern[[i]])
    canonical <- trimws(aliases$canonical[[i]])
    match_type <- tolower(trimws(aliases$match_type[[i]]))

    if (identical(match_type, "regex")) {
      hit <- grepl(pattern, out, ignore.case = TRUE, perl = TRUE)
    } else {
      hit <- tolower(trimws(out)) == tolower(pattern)
    }
    hit[is.na(hit)] <- FALSE
    out[hit] <- canonical
  }

  out
}

log_df$normalised_current <- apply_review_aliases(log_df$normalised_current)

agg <- aggregate(
  n_trials ~ normalised_current,
  log_df[!is.na(log_df$normalised_current) & nzchar(log_df$normalised_current), ],
  sum
)
names(agg) <- c("sponsor", "n_trials")
agg <- agg[order(-agg$n_trials, agg$sponsor), ]

make_key <- function(x) {
  x <- tolower(iconv(x, to = "ASCII//TRANSLIT", sub = ""))
  x <- gsub("&", " and ", x)
  x <- gsub("\\b(the|of|de|di|del|della|der|den|and|for|a|la|le|el)\\b", " ", x)
  x <- gsub("\\b(nhs|trust|foundation|stichting|fondation|fundacion|fundacio)\\b", " ", x)
  x <- gsub("\\b(university|universitaire|universitario|universita|universitat|universiteit)\\b", " university ", x)
  x <- gsub("\\b(hospital|hospitals|hopital|hopitaux|ziekenhuis)\\b", " hospital ", x)
  x <- gsub("\\b(centre|center|centrum|centro)\\b", " center ", x)
  x <- gsub("\\b(medical|medisch|medica|medizinische)\\b", " medical ", x)
  x <- gsub("\\b(ltd|limited|inc|corp|corporation|company|gmbh|ag|sa|sas|sarl|bv|nv|llc|plc)\\b", " ", x)
  x <- gsub("[^a-z0-9]+", " ", x)
  x <- gsub("\\s+", " ", trimws(x))
  x
}

tokens <- function(x) {
  toks <- strsplit(x, " ", fixed = TRUE)[[1]]
  toks[nzchar(toks)]
}

generic_tokens <- c(
  "university", "universitaire", "universitario", "hospital", "hospitals",
  "medical", "center", "centre", "clinic", "clinical", "institute", "institut",
  "irccs", "fondazione", "azienda", "ospedaliera", "ospedaliero", "chu", "chru",
  "nhs", "trust", "foundation", "stichting", "group", "research", "health"
)

top_n <- min(1200L, nrow(agg))
top <- agg[seq_len(top_n), ]
top$key <- vapply(top$sponsor, make_key, character(1))
top <- top[nchar(top$key) >= 5, ]

rows <- list()
k <- 1L
for (i in seq_len(nrow(top) - 1L)) {
  ti <- tokens(top$key[[i]])
  if (!length(ti)) next
  for (j in (i + 1L):nrow(top)) {
    tj <- tokens(top$key[[j]])
    if (!length(tj)) next
    common_tokens <- intersect(ti, tj)
    informative_common <- setdiff(common_tokens, generic_tokens)
    common <- length(common_tokens)
    if (common == 0L) next
    max_len <- max(nchar(top$key[[i]]), nchar(top$key[[j]]))
    distance <- as.numeric(adist(top$key[[i]], top$key[[j]])) / max_len
    containment <- grepl(top$key[[i]], top$key[[j]], fixed = TRUE) ||
      grepl(top$key[[j]], top$key[[i]], fixed = TRUE)
    token_overlap <- common / min(length(ti), length(tj))
    keep <- (length(informative_common) > 0L && distance <= 0.24) ||
      (length(informative_common) > 0L && containment) ||
      (length(informative_common) > 0L && common >= 2L && token_overlap >= 0.67)
    if (!keep) next
    rows[[k]] <- data.frame(
      canonical_suggestion = top$sponsor[[if (top$n_trials[[i]] >= top$n_trials[[j]]) i else j]],
      sponsor_a = top$sponsor[[i]],
      sponsor_b = top$sponsor[[j]],
      n_a = top$n_trials[[i]],
      n_b = top$n_trials[[j]],
      total_n = top$n_trials[[i]] + top$n_trials[[j]],
      similarity_score = round(1 - distance, 3),
      token_overlap = round(token_overlap, 3),
      key_a = top$key[[i]],
      key_b = top$key[[j]],
      informative_common = paste(informative_common, collapse = " / "),
      suggested_pattern = top$sponsor[[j]],
      suggested_match_type = "exact",
      approved = FALSE,
      notes = "",
      stringsAsFactors = FALSE
    )
    k <- k + 1L
  }
}

candidates <- if (length(rows)) do.call(rbind, rows) else data.frame()
if (nrow(candidates)) {
  candidates <- candidates[order(-candidates$total_n, -candidates$similarity_score), ]
  row.names(candidates) <- NULL
}

write.csv(candidates, out_path, row.names = FALSE)
message("Wrote ", nrow(candidates), " sponsor alias candidates to ", out_path)
message("Current unique sponsor labels after approved aliases: ", length(unique(agg$sponsor)))
