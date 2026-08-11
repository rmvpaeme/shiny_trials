# Step 6 — re-review frozen alias decisions with a pinned LLM.
#
# `sponsor_llm_reviewed.csv` holds ~11,900 alias -> canonical decisions at
# confidence_prior 1. Per config/sponsor_norm_pipeline/README.md, source
# `llm_reviewed` means "verified by a human: No". Nobody recorded which model,
# which prompt, or on what date, and measurement says some are wrong:
#
#   center for clinical metabolic research at herlev gentofte hospital
#     -> Herlev og Gentofte Hospital                      (correct: dept -> parent)
#   center for clinical metabolic research at herlev-gentofte hospital
#     -> Center for Clinical Metabolic Research at ...    (wrong: dept kept as canonical)
#
# Two aliases differing by one hyphen, disagreeing on the answer.
#
# THIS ASKS A DIFFERENT QUESTION FROM STEP 5. The resolver picks a canonical for
# an unresolved string. This one judges an EXISTING decision: is this mapping
# right? correct / incorrect / unsure. It proposes no replacement, which is
# deliberate — see "Why no suggested replacement" below.
#
# Usage
#   Rscript .../6_llm_verify.R --dry-run
#   Rscript .../6_llm_verify.R --target=defects --batch      # ~120 rows, pennies
#   Rscript .../6_llm_verify.R --target=single-alias --batch # ~6,000 rows
#   Rscript .../6_llm_verify.R --target=all --batch          # every llm_reviewed row
#   Rscript .../6_llm_verify.R --batch --poll=<batch_id>
#
# Start with --target=defects. It is the concentrated defect population, so it
# measures the base error rate before you commit to a full sweep: a high hit
# rate justifies the wider pass, a clean result says the known-bad examples were
# unlucky rather than typical.
#
# NOTE ON DUPLICATION: the auth, batch and cache plumbing below is parallel to
# 5_llm_resolve.R rather than shared with it. That is a deliberate, temporary
# choice — the resolver is in active use and refactoring it mid-run risks the
# thing that works. Factor both onto a common llm_client.R once step 5 is done.

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(readr)
  library(stringr)
  library(tibble)
  library(httr2)
  library(jsonlite)
  library(openssl)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

script_path <- tryCatch({
  cmd_args   <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
  } else {
    NA_character_
  }
}, error = function(e) NA_character_)
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)

# ── Pinned identity ───────────────────────────────────────────────────────────

MODEL_ID       <- "claude-opus-5"
PROMPT_VERSION <- "sponsor-verify-v1"
EFFORT         <- "low"

# --model swaps the pinned model for an A/B. MODEL_ID is part of cache_key, so
# two models' verdicts coexist in the cache rather than overwriting each other
# and can be compared row by row. Effort is not universal: it errors on Haiku
# 4.5, so drop it there rather than sending a parameter that 400s.
MODELS_WITHOUT_EFFORT <- c("claude-haiku-4-5", "claude-sonnet-4-5")
model_supports_effort <- function(m) !any(startsWith(m, MODELS_WITHOUT_EFFORT))
MAX_TOKENS     <- 4096L
MAX_SIBLINGS   <- 6L

API_BASE      <- "https://api.anthropic.com"
API_VERSION   <- "2023-06-01"
FALLBACK_BETA <- "server-side-fallback-2026-07-01"

VERDICTS <- c("correct", "incorrect", "unsure")
PROBLEMS <- c(
  "none",
  "department_should_resolve_to_parent",
  "different_organisation",
  "variant_of_another_canonical",
  "too_generic_to_be_a_sponsor",
  "other"
)

args     <- commandArgs(trailingOnly = TRUE)
dry_run  <- "--dry-run" %in% args
do_sync  <- "--sync"    %in% args
do_batch <- "--batch"   %in% args

arg_value <- function(flag) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit) == 0L) return(NA_character_)
  sub(paste0("^", flag, "="), "", hit[[1L]])
}
limit      <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch <- arg_value("--poll")
target     <- arg_value("--target")
if (is.na(target)) target <- "defects"
if (!target %in% c("defects", "single-alias", "all")) {
  stop("--target must be one of: defects, single-alias, all", call. = FALSE)
}
if (!dry_run && !do_sync && !do_batch && is.na(poll_batch)) {
  stop("Pick a mode: --dry-run, --sync, --batch, or --poll=<batch_id>", call. = FALSE)
}
model_arg <- arg_value("--model")
if (!is.na(model_arg) && nzchar(model_arg)) MODEL_ID <- model_arg

SNP   <- project_path("config", "sponsor_norm_pipeline")
INDEX <- file.path(SNP, "2_sponsor_alias_index.csv")
CACHE <- file.path(SNP, "6_llm_verifications.csv")
LOG   <- project_path("data", "sponsor_normalisation_log.csv")

source(
  project_path("helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R"),
  local = TRUE
)

# ── Auth ──────────────────────────────────────────────────────────────────────

resolve_auth <- function() {
  key <- Sys.getenv("ANTHROPIC_API_KEY", "")
  if (nzchar(key)) {
    return(list(headers = c("x-api-key" = key), betas = character()))
  }
  token <- tryCatch(
    suppressWarnings(system2(
      "ant", c("auth", "print-credentials", "--access-token"),
      stdout = TRUE, stderr = FALSE
    )),
    error = function(e) character()
  )
  token <- token[nzchar(token)]
  if (length(token) == 0L) {
    stop("No credentials. Set ANTHROPIC_API_KEY, or run `ant auth login`.",
         call. = FALSE)
  }
  list(
    headers = c("Authorization" = paste("Bearer", token[[length(token)]])),
    betas   = "oauth-2025-04-20"
  )
}

# ── Work list ─────────────────────────────────────────────────────────────────

index <- readr::read_csv(INDEX, show_col_types = FALSE)
if (nrow(index) == 0L) stop("No alias index at ", INDEX, call. = FALSE)

reviewable <- index |>
  dplyr::filter(
    !is.na(alias_clean), !is.na(sponsor_clean),
    nzchar(alias_clean), nzchar(sponsor_clean)
  )

# A canonical that IS a department label should almost always have resolved to
# its parent institution. The matcher already encodes that judgement in
# is_department_label(), so reuse it rather than inventing a second rule.
dept_canonicals <- reviewable |>
  dplyr::distinct(sponsor_clean) |>
  dplyr::filter(is_department_label(clean_sponsor_alias(sponsor_clean))) |>
  dplyr::pull(sponsor_clean)

# clean_sponsor_alias() normalises dash CHARACTERS but does not remove them, so
# "herlev-gentofte" and "herlev gentofte" survive as distinct keys and can
# disagree without tripping the exact-collision check in
# 2_sponsor_ambiguous_aliases.csv. Collapse every separator to find them.
sep_key <- function(x) {
  stringr::str_squish(stringr::str_replace_all(stringr::str_to_lower(x), "[^a-z0-9]+", " "))
}
disagreeing <- reviewable |>
  dplyr::mutate(.k = sep_key(alias_clean)) |>
  dplyr::group_by(.k) |>
  dplyr::filter(dplyr::n_distinct(sponsor_clean) > 1L) |>
  dplyr::ungroup() |>
  dplyr::select(-.k)

single_alias_canonicals <- reviewable |>
  dplyr::count(sponsor_clean, name = "n_aliases") |>
  dplyr::filter(n_aliases == 1L) |>
  dplyr::pull(sponsor_clean)

work <- switch(
  target,
  defects = dplyr::bind_rows(
    reviewable |> dplyr::filter(sponsor_clean %in% dept_canonicals),
    disagreeing
  ) |> dplyr::distinct(alias_clean, sponsor_clean, .keep_all = TRUE),
  `single-alias` = reviewable |>
    dplyr::filter(sponsor_clean %in% single_alias_canonicals),
  all = reviewable |> dplyr::filter(source %in% c("llm_reviewed", "llm_curated"))
)

# Impact drives review order: a wrong decision on a 40-trial alias matters more
# than one nobody hits.
impact <- if (file.exists(LOG)) {
  readr::read_csv(LOG, show_col_types = FALSE) |>
    dplyr::mutate(alias_clean = clean_sponsor_alias(raw_sponsor)) |>
    dplyr::group_by(alias_clean) |>
    dplyr::summarise(n_trials = sum(as.numeric(n_trials), na.rm = TRUE), .groups = "drop")
} else {
  tibble::tibble(alias_clean = character(), n_trials = numeric())
}

# Sibling aliases are the strongest cheap evidence: if six other strings map to
# the same canonical and they are all clearly that organisation, an odd one out
# stands revealed.
siblings <- reviewable |>
  dplyr::group_by(sponsor_clean) |>
  dplyr::summarise(
    n_aliases = dplyr::n(),
    sibling_sample = paste(utils::head(sort(unique(alias_clean)), MAX_SIBLINGS), collapse = "; "),
    .groups = "drop"
  )

work <- work |>
  dplyr::left_join(impact, by = "alias_clean") |>
  dplyr::left_join(siblings, by = "sponsor_clean") |>
  dplyr::mutate(n_trials = dplyr::coalesce(n_trials, 0)) |>
  dplyr::arrange(dplyr::desc(n_trials), alias_clean)

cache_key_for <- function(alias, canon) {
  paste(openssl::sha256(paste(alias, canon, PROMPT_VERSION, MODEL_ID, sep = "|")),
        collapse = "")
}
work <- work |>
  dplyr::mutate(cache_key = purrr::map2_chr(alias_clean, sponsor_clean, cache_key_for))

# ── Cache ─────────────────────────────────────────────────────────────────────

CACHE_COLS <- c(
  "cache_key", "alias_clean", "sponsor_clean", "model_id", "prompt_version",
  "verdict", "problem", "confidence", "reason", "n_trials",
  "decided_at_utc", "batch_id"
)

read_cache <- function() {
  if (!file.exists(CACHE)) {
    return(tibble::tibble(
      cache_key = character(), alias_clean = character(),
      sponsor_clean = character(), model_id = character(),
      prompt_version = character(), verdict = character(), problem = character(),
      confidence = character(), reason = character(), n_trials = numeric(),
      decided_at_utc = character(), batch_id = character()
    ))
  }
  readr::read_csv(CACHE, show_col_types = FALSE, col_types = readr::cols(
    .default = readr::col_character(), n_trials = readr::col_double()
  ))
}

write_cache <- function(x) {
  x <- x |>
    dplyr::select(dplyr::all_of(CACHE_COLS)) |>
    dplyr::arrange(dplyr::desc(n_trials), alias_clean)
  tmp <- paste0(CACHE, ".tmp")
  readr::write_csv(x, tmp, na = "NA")
  invisible(file.rename(tmp, CACHE))
}

utc_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

cache <- read_cache()
# Only a row carrying a VERDICT is done. Errors and expiries are recorded so a
# failure is visible, but treating them as resolved would make them permanent.
resolved <- cache |> dplyr::filter(!is.na(verdict)) |> dplyr::pull(cache_key)
todo <- work |> dplyr::filter(!cache_key %in% resolved)

message(sprintf(
  "target=%s: %d rows, %d already verified, %d to do",
  target, nrow(work), nrow(work) - nrow(todo), nrow(todo)
))
if (!is.na(limit) && limit > 0L && nrow(todo) > limit) {
  todo <- todo |> utils::head(limit)
  message(sprintf("  --limit=%d applied", limit))
}

# ── Request construction ──────────────────────────────────────────────────────

SYSTEM_PROMPT <- paste(
  "You audit frozen sponsor-normalisation decisions from a clinical-trial",
  "registry. Each decision maps a cleaned raw sponsor string (the alias) to a",
  "canonical organisation name. You judge whether that mapping is right.",
  "",
  "Answer `correct` when the alias genuinely refers to the canonical",
  "organisation, including these legitimate cases:",
  "- a department, clinic, unit or laboratory mapped to its PARENT institution",
  "- a former name, local subsidiary, abbreviation or translation mapped to the",
  "  organisation it belongs to",
  "- a spelling, accent or punctuation variant of the same organisation",
  "",
  "Answer `incorrect` when the mapping is wrong, most often because:",
  "- the canonical is itself a department or unit that should have resolved to",
  "  a parent institution (`department_should_resolve_to_parent`)",
  "- the alias and the canonical are genuinely different organisations that",
  "  merely look alike or share a city (`different_organisation`)",
  "- the canonical duplicates another spelling of the same organisation and one",
  "  of the two should win (`variant_of_another_canonical`)",
  "- the canonical is a generic phrase that could never identify one sponsor,",
  "  e.g. \"Clinical Pharmacology\" (`too_generic_to_be_a_sponsor`)",
  "",
  "Answer `unsure` when the evidence supplied does not settle it. Unsure is a",
  "real answer and is far better than a confident guess: a human reads every",
  "row you flag, and a wrong `correct` is never read at all.",
  "",
  "Set problem to `none` when the verdict is `correct`.",
  "",
  "Do NOT propose a replacement name. Your job is triage, not repair.",
  "Keep reason under 25 words and state the evidence you used.",
  sep = "\n"
)

# The schema is IDENTICAL for every request — all four fields are fixed, and the
# enums never vary by row. That is what makes this affordable at scale: the
# grammar compiles once and is cached, so a wide batch does not hit the 20
# compilations/minute org limit that sank step 5's first batch run. Do not be
# tempted to add a per-row enum of suggested replacements here.
OUTPUT_SCHEMA <- list(
  type = "json_schema",
  schema = list(
    type = "object",
    properties = list(
      verdict    = list(type = "string", enum = VERDICTS),
      problem    = list(type = "string", enum = PROBLEMS),
      confidence = list(type = "string", enum = c("high", "medium", "low")),
      reason     = list(type = "string")
    ),
    required = list("verdict", "problem", "confidence", "reason"),
    additionalProperties = FALSE
  )
)

user_block <- function(row) {
  parts <- c(
    paste0("Alias (cleaned raw sponsor string):\n", row$alias_clean),
    paste0("\nMapped to canonical:\n", row$sponsor_clean)
  )
  if (!is.na(row$sponsor_parent) && nzchar(row$sponsor_parent) &&
      row$sponsor_parent != "NA") {
    parts <- c(parts, paste0("\nCanonical's recorded parent: ", row$sponsor_parent))
  }
  if (!is.na(row$sponsor_type) && nzchar(row$sponsor_type) && row$sponsor_type != "NA") {
    parts <- c(parts, paste0("Canonical's recorded type: ", row$sponsor_type))
  }
  parts <- c(parts, paste0(
    "\nOther aliases mapping to this same canonical (", row$n_aliases, " total): ",
    if (!is.na(row$sibling_sample) && nzchar(row$sibling_sample)) row$sibling_sample else "(none)"
  ))
  parts <- c(parts, paste0("Trials affected by this alias: ", row$n_trials))
  paste(parts, collapse = "\n")
}

build_body <- function(row, for_batch) {
  body <- list(
    model      = MODEL_ID,
    max_tokens = MAX_TOKENS,
    system = list(list(
      type = "text",
      text = SYSTEM_PROMPT,
      cache_control = list(type = "ephemeral")
    )),
    messages = list(list(role = "user", content = user_block(row))),
    output_config = if (model_supports_effort(MODEL_ID)) {
      list(effort = EFFORT, format = OUTPUT_SCHEMA)
    } else {
      list(format = OUTPUT_SCHEMA)
    }
  )
  if (!for_batch) body$fallbacks <- "default"
  body
}

# ── Response handling ─────────────────────────────────────────────────────────

parse_message <- function(msg) {
  stop_reason <- msg$stop_reason %||% NA_character_
  if (identical(stop_reason, "refusal")) {
    return(list(ok = FALSE, error = paste0(
      "refusal (", msg$stop_details$category %||% "unknown", ")")))
  }
  if (identical(stop_reason, "max_tokens")) {
    return(list(ok = FALSE, error = "max_tokens — raise MAX_TOKENS"))
  }
  txt <- purrr::keep(msg$content, ~ identical(.x$type, "text"))
  if (length(txt) == 0L) {
    return(list(ok = FALSE, error = paste0("no text block (stop_reason=", stop_reason, ")")))
  }
  parsed <- tryCatch(jsonlite::fromJSON(txt[[1L]]$text), error = function(e) NULL)
  if (is.null(parsed) || is.null(parsed$verdict)) {
    return(list(ok = FALSE, error = "unparseable JSON"))
  }
  # Second enforcement, independent of the schema — same belt-and-braces as the
  # resolver's off-list check.
  if (!parsed$verdict %in% VERDICTS) {
    return(list(ok = FALSE, error = paste0("off-list verdict: ", parsed$verdict)))
  }
  problem <- parsed$problem %||% "other"
  if (!problem %in% PROBLEMS) problem <- "other"
  list(
    ok = TRUE, verdict = parsed$verdict, problem = problem,
    confidence = parsed$confidence %||% NA_character_,
    reason = parsed$reason %||% NA_character_
  )
}

cache_row <- function(row, res, batch_id = NA_character_) {
  tibble::tibble(
    cache_key = row$cache_key, alias_clean = row$alias_clean,
    sponsor_clean = row$sponsor_clean, model_id = MODEL_ID,
    prompt_version = PROMPT_VERSION,
    verdict    = if (res$ok) res$verdict else NA_character_,
    problem    = if (res$ok) res$problem else NA_character_,
    confidence = if (res$ok) res$confidence else NA_character_,
    reason     = if (res$ok) res$reason else res$error,
    n_trials   = row$n_trials,
    decided_at_utc = utc_now(), batch_id = batch_id
  )
}

merge_cache <- function(rows) {
  dplyr::bind_rows(
    cache |> dplyr::filter(!cache_key %in% rows$cache_key),
    rows
  )
}

# ── Dry run ───────────────────────────────────────────────────────────────────

if (dry_run) {
  if (nrow(todo) == 0L) {
    message("Nothing to verify.")
    quit(save = "no", status = 0L)
  }
  cat("\n--- work list ---\n")
  cat("target:            ", target, "\n", sep = "")
  cat("rows to verify:    ", nrow(todo), "\n", sep = "")
  cat("distinct canonicals:", dplyr::n_distinct(todo$sponsor_clean), "\n", sep = "")
  cat("trials covered:    ", sum(todo$n_trials), "\n", sep = "")

  cat("\n--- sample request (highest impact row) ---\n")
  cat(user_block(todo[1L, ]), "\n")

  cat("\n--- schema is constant across requests ---\n")
  a <- jsonlite::toJSON(OUTPUT_SCHEMA, auto_unbox = TRUE)
  cat("schema sha256: ", substr(paste(openssl::sha256(a), collapse = ""), 1, 16),
      " (identical for all ", nrow(todo), " requests -> 1 grammar compilation)\n", sep = "")

  est_in <- 700 * nrow(todo)
  cat(sprintf(
    "\nrough estimate: ~%s input tokens; batched ~$%.2f in, ~$%.2f out\n",
    format(est_in, big.mark = ","),
    est_in / 1e6 * 5 * 0.5, nrow(todo) * 90 / 1e6 * 25 * 0.5
  ))
  quit(save = "no", status = 0L)
}

# ── Sync mode ─────────────────────────────────────────────────────────────────

if (do_sync) {
  auth  <- resolve_auth()
  betas <- unique(c(auth$betas, FALLBACK_BETA))
  message(sprintf("Verifying %d row(s) synchronously...", nrow(todo)))

  rows <- purrr::map_dfr(seq_len(nrow(todo)), function(i) {
    row <- todo[i, ]
    resp <- httr2::request(paste0(API_BASE, "/v1/messages")) |>
      httr2::req_headers(!!!c(
        auth$headers, "anthropic-version" = API_VERSION,
        "anthropic-beta" = paste(betas, collapse = ","),
        "content-type" = "application/json"
      )) |>
      httr2::req_body_json(build_body(row, for_batch = FALSE), auto_unbox = TRUE) |>
      httr2::req_retry(max_tries = 3L) |>
      httr2::req_error(is_error = function(x) FALSE) |>
      httr2::req_perform()

    if (httr2::resp_status(resp) >= 400L) {
      return(cache_row(row, list(
        ok = FALSE, error = paste0("http ", httr2::resp_status(resp))
      )))
    }
    res <- parse_message(httr2::resp_body_json(resp))
    message(sprintf(
      "  %-44s -> %-9s %s",
      substr(row$alias_clean, 1, 44),
      if (res$ok) res$verdict else "ERROR",
      if (res$ok) res$problem else res$error
    ))
    cache_row(row, res)
  })

  write_cache(merge_cache(rows))
  message(sprintf("Wrote %d rows to %s", nrow(rows), basename(CACHE)))
  quit(save = "no", status = 0L)
}

# ── Batch mode ────────────────────────────────────────────────────────────────

auth  <- resolve_auth()
betas <- auth$betas
add_headers <- function(r) {
  r <- httr2::req_headers(r, !!!c(
    auth$headers, "anthropic-version" = API_VERSION,
    "content-type" = "application/json"
  ))
  if (length(betas)) {
    r <- httr2::req_headers(r, "anthropic-beta" = paste(betas, collapse = ","))
  }
  r
}

batch_id <- poll_batch

if (is.na(batch_id)) {
  if (nrow(todo) == 0L) {
    message("Nothing to verify.")
    quit(save = "no", status = 0L)
  }
  requests <- purrr::map(seq_len(nrow(todo)), function(i) {
    row <- todo[i, ]
    list(custom_id = row$cache_key, params = build_body(row, for_batch = TRUE))
  })
  ids <- purrr::map_chr(requests, "custom_id")
  if (anyDuplicated(ids)) {
    stop("duplicate custom_id: ",
         paste(unique(ids[duplicated(ids)]), collapse = ", "), call. = FALSE)
  }
  message(sprintf("Submitting batch of %d requests...", length(requests)))
  resp <- httr2::request(paste0(API_BASE, "/v1/messages/batches")) |>
    add_headers() |>
    httr2::req_body_json(list(requests = requests), auto_unbox = TRUE) |>
    httr2::req_error(is_error = function(x) FALSE) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) >= 400L) {
    stop("Batch submit failed: ", httr2::resp_body_string(resp), call. = FALSE)
  }
  batch_id <- httr2::resp_body_json(resp)$id
  message("batch id: ", batch_id)
  message("Resume later with --target=", target, " --batch --poll=", batch_id)
}

repeat {
  resp <- httr2::request(paste0(API_BASE, "/v1/messages/batches/", batch_id)) |>
    add_headers() |>
    httr2::req_error(is_error = function(x) FALSE) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) >= 400L) {
    stop("Batch poll failed: ", httr2::resp_body_string(resp), call. = FALSE)
  }
  b <- httr2::resp_body_json(resp)
  message(sprintf(
    "  status=%s  succeeded=%s errored=%s processing=%s",
    b$processing_status,
    b$request_counts$succeeded %||% 0, b$request_counts$errored %||% 0,
    b$request_counts$processing %||% 0
  ))
  if (identical(b$processing_status, "ended")) break
  Sys.sleep(60)
}

message("Fetching results...")
resp <- httr2::request(paste0(API_BASE, "/v1/messages/batches/", batch_id, "/results")) |>
  add_headers() |>
  httr2::req_error(is_error = function(x) FALSE) |>
  httr2::req_perform()
if (httr2::resp_status(resp) >= 400L) {
  stop("Batch results failed: ", httr2::resp_body_string(resp), call. = FALSE)
}

lines <- strsplit(httr2::resp_body_string(resp), "\n", fixed = TRUE)[[1L]]
lines <- lines[nzchar(lines)]

rows <- purrr::map_dfr(lines, function(line) {
  r <- jsonlite::fromJSON(line, simplifyVector = FALSE)
  hit <- todo |> dplyr::filter(cache_key == r$custom_id)
  if (nrow(hit) == 0L) return(tibble::tibble())
  res <- switch(
    r$result$type,
    succeeded = parse_message(r$result$message),
    errored   = list(ok = FALSE, error = {
      env_err <- r$result$error
      detail  <- env_err$error %||% env_err
      msg     <- detail$message %||% ""
      paste0("errored: ", detail$type %||% "unknown",
             if (nzchar(msg)) paste0(": ", substr(msg, 1, 300)) else "")
    }),
    canceled  = list(ok = FALSE, error = "canceled"),
    expired   = list(ok = FALSE, error = "expired"),
    list(ok = FALSE, error = paste0("unknown result type: ", r$result$type))
  )
  cache_row(hit[1L, ], res, batch_id)
})

write_cache(merge_cache(rows))

verdicts <- rows |> dplyr::filter(!is.na(verdict))
message(sprintf(
  "Wrote %d rows to %s (%d verified, %d failed)",
  nrow(rows), basename(CACHE), nrow(verdicts), nrow(rows) - nrow(verdicts)
))
if (nrow(verdicts) > 0L) {
  print(verdicts |> dplyr::count(verdict, problem, sort = TRUE))
}
message("Nothing has been changed. These are findings for a human to act on.")
