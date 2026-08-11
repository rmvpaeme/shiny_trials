# Step 5 — resolve the sponsor residue with a pinned LLM.
#
# The matcher leaves a few hundred raw sponsor strings at match_status
# "unknown". They are entity resolution, not string editing: "1. Frauenklinik
# der LMU-Innenstadt" -> "Klinikum Der Universitat Munchen AoR" shares no
# material with its input, so no rule derived from the frozen decisions closes
# it (see PLANS/normalisation-reproducibility.md).
#
# What makes this safe to hand to a model: THE MODEL PICKS FROM A LIST. It
# never writes a name. Candidates come from the matcher's own indexes, and the
# answer is constrained twice — by output_config.format with an enum of the
# supplied labels, and by a post-response check rejecting anything not in that
# list. A model that can only choose cannot introduce a spelling, drift a
# canonical, or invent an organisation.
#
# Nothing here writes a label. Decisions land in a committed cache and reach
# the reviewer app, where a human accepts or rejects them.
#
# Usage
#   Rscript .../5_llm_resolve.R --dry-run           # assemble + count tokens, no calls
#   Rscript .../5_llm_resolve.R --sync --limit=5    # one at a time, for prompt iteration
#   Rscript .../5_llm_resolve.R --batch             # full run via the Batches API
#   Rscript .../5_llm_resolve.R --batch --poll=<id> # resume polling an existing batch
#
# A run resolves only cache keys that are absent, so re-running costs nothing
# and only genuinely new strings reach the API. Bumping PROMPT_VERSION or
# MODEL_ID invalidates deliberately and visibly, in the diff.

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
# Both are echoed into every cache row. Changing either changes cache_key, so a
# bump re-resolves every string and shows up as a full-file diff — which is the
# point: a decision is only reproducible if you know what produced it.

MODEL_ID       <- "claude-opus-5"
PROMPT_VERSION <- "sponsor-resolve-v1"
EFFORT         <- "low"
MAX_TOKENS     <- 8192L
MAX_CANDIDATES <- 10L
ABSTAIN        <- "NONE_OF_THESE"

API_BASE       <- "https://api.anthropic.com"
API_VERSION    <- "2023-06-01"
# fallbacks: "default" re-serves a policy decline on Anthropic's recommended
# fallback model. It is rejected on the Batches API, so it is attached only to
# --sync requests (see build_body(for_batch=)).
FALLBACK_BETA  <- "server-side-fallback-2026-07-01"

args      <- commandArgs(trailingOnly = TRUE)
dry_run   <- "--dry-run" %in% args
do_sync   <- "--sync"    %in% args
do_batch  <- "--batch"   %in% args

arg_value <- function(flag) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit) == 0L) return(NA_character_)
  sub(paste0("^", flag, "="), "", hit[[1L]])
}
limit      <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch <- arg_value("--poll")

if (!dry_run && !do_sync && !do_batch && is.na(poll_batch)) {
  stop("Pick a mode: --dry-run, --sync, --batch, or --poll=<batch_id>", call. = FALSE)
}

SNP     <- project_path("config", "sponsor_norm_pipeline")
CACHE   <- file.path(SNP, "5_llm_proposals.csv")
LOG     <- project_path("data", "sponsor_normalisation_log.csv")

source(
  project_path("helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R"),
  local = TRUE
)

# ── Auth ──────────────────────────────────────────────────────────────────────
# An unset ANTHROPIC_API_KEY does not mean there are no credentials: the `ant`
# CLI stores an OAuth profile the SDKs read automatically. For raw HTTP we have
# to do that resolution ourselves. OAuth tokens go on Authorization: Bearer and
# additionally require the oauth beta header — it is a header change, not a
# key swap.
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
    stop(
      "No credentials. Set ANTHROPIC_API_KEY, or run `ant auth login`.",
      call. = FALSE
    )
  }
  list(
    headers = c("Authorization" = paste("Bearer", token[[length(token)]])),
    betas   = "oauth-2025-04-20"
  )
}

# ── Candidate retrieval ───────────────────────────────────────────────────────
# Reuse the matcher's own indexes rather than building a second retrieval path.
# Every candidate is an existing canonical, which is what makes the enum
# constraint meaningful.

fuzzy_neighbours <- function(queries, cfg, n = 8L) {
  targets <- cfg$fuzzy_targets
  if (is.null(targets) || nrow(targets) == 0L) return(tibble::tibble())
  queries <- unique(queries[nchar(queries) >= 4L])
  if (length(queries) == 0L) return(tibble::tibble())

  purrr::map_dfr(queries, function(q) {
    subset <- targets |> dplyr::filter(fuzzy_key == substr(q, 1L, 1L))
    if (nrow(subset) == 0L) return(tibble::tibble())
    sims <- 1 - stringdist::stringdist(q, subset$target_label, method = "jw")
    keep <- order(sims, decreasing = TRUE)[seq_len(min(n, length(sims)))]
    subset[keep, , drop = FALSE] |>
      dplyr::mutate(retrieval = "fuzzy", score = sims[keep])
  })
}

containment_neighbours <- function(raw_clean, candidates, cfg, n = 8L) {
  idx <- cfg$containment_token_index
  tgt <- cfg$containment_targets
  if (is.null(idx) || nrow(idx) == 0L || is.null(tgt) || nrow(tgt) == 0L) {
    return(tibble::tibble())
  }
  texts <- unique(stats::na.omit(c(raw_clean, candidates)))
  toks <- unique(unlist(purrr::map(texts, containment_tokens), use.names = FALSE))
  toks <- toks[nchar(toks) >= 4L & !toks %in% c(.fuzzy_block_tokens, .entity_generic_tokens)]
  if (length(toks) == 0L) return(tibble::tibble())

  ids <- idx |>
    dplyr::filter(signal_token %in% toks) |>
    dplyr::count(containment_id, sort = TRUE) |>
    utils::head(n) |>
    dplyr::pull(containment_id)
  if (length(ids) == 0L) return(tibble::tibble())

  tgt |>
    dplyr::filter(containment_id %in% ids) |>
    dplyr::transmute(
      target_label = alias_clean, target_kind = "alias_clean",
      sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, source,
      retrieval = "containment", score = NA_real_
    )
}

family_neighbours <- function(raw_clean, cfg) {
  tgt <- cfg$family_targets
  if (is.null(tgt) || nrow(tgt) == 0L) return(tibble::tibble())
  profile <- sponsor_entity_profile(raw_clean)
  keys <- unique(stats::na.omit(c(
    profile$entity_family_key, profile$department_parent_key
  )))
  keys <- keys[nzchar(keys)]
  if (length(keys) == 0L) return(tibble::tibble())
  tgt |>
    dplyr::filter(entity_key %in% keys) |>
    dplyr::transmute(
      target_label = sponsor_clean, target_kind = "family",
      sponsor_clean, sponsor_parent, sponsor_group, sponsor_type, source,
      retrieval = "family", score = NA_real_
    )
}

retrieve_candidates <- function(raw, cfg) {
  raw_clean  <- clean_sponsor_alias(raw)
  generated  <- make_sponsor_candidates(raw)
  queries    <- unique(c(raw_clean, generated))

  hits <- dplyr::bind_rows(
    family_neighbours(raw_clean, cfg),
    containment_neighbours(raw_clean, generated, cfg),
    fuzzy_neighbours(queries, cfg)
  )
  if (nrow(hits) == 0L) return(tibble::tibble())

  hits |>
    dplyr::filter(!is.na(sponsor_clean), nzchar(sponsor_clean)) |>
    # Family and containment evidence is stronger than a Jaro-Winkler
    # neighbour, so let them take the cap first.
    dplyr::mutate(
      retrieval_rank = match(retrieval, c("family", "containment", "fuzzy"))
    ) |>
    dplyr::arrange(retrieval_rank, dplyr::desc(dplyr::coalesce(score, 0))) |>
    dplyr::distinct(sponsor_clean, .keep_all = TRUE) |>
    utils::head(MAX_CANDIDATES) |>
    dplyr::select(
      sponsor_clean, sponsor_parent, sponsor_group, sponsor_type,
      source, retrieval, score
    )
}

# ── Request construction ──────────────────────────────────────────────────────

SYSTEM_PROMPT <- paste(
  "You match a raw clinical-trial sponsor string to an organisation from a",
  "supplied list of canonical names.",
  "",
  "The raw string comes from a trial registry. It may be a department, a",
  "hospital unit, a local subsidiary, a former company name, an abbreviation,",
  "or the same organisation written in another language. Your job is to decide",
  "which supplied canonical name, if any, refers to the SAME organisation, or to",
  "the parent organisation that the registry entry belongs to.",
  "",
  "Rules:",
  "- Choose exactly one value from the supplied candidate list, or",
  paste0("  \"", ABSTAIN, "\" if none of them is the same organisation."),
  "- A department or unit resolves to its parent institution when that parent",
  "  is among the candidates (a university clinic department resolves to the",
  "  university hospital).",
  "- Two organisations that merely share a city, a field, or a similar-looking",
  "  name are NOT the same organisation. Near-identical spellings are often",
  "  genuinely different companies.",
  "- A subsidiary resolves to its parent only when the candidate list makes",
  "  that relationship clear; otherwise abstain.",
  "- Abstaining is the correct answer whenever you are not confident. An",
  "  abstention costs a human a few seconds; a wrong match silently mislabels",
  "  every trial for that sponsor.",
  "",
  "Set confidence to:",
  "- high   — the candidate is unambiguously the same organisation.",
  "- medium — very likely the same, with a plausible alternative reading.",
  "- low    — a guess worth a human's attention.",
  "",
  "Keep reason under 25 words and state the evidence you used.",
  sep = "\n"
)

candidate_block <- function(raw, cands) {
  lines <- purrr::pmap_chr(
    cands |> dplyr::select(sponsor_clean, sponsor_parent, sponsor_group, source),
    function(sponsor_clean, sponsor_parent, sponsor_group, source) {
      extra <- c(
        if (!is.na(sponsor_parent) && nzchar(sponsor_parent) &&
            sponsor_parent != sponsor_clean) paste0("parent: ", sponsor_parent),
        if (!is.na(sponsor_group) && nzchar(sponsor_group) &&
            sponsor_group != sponsor_clean) paste0("group: ", sponsor_group),
        if (!is.na(source) && nzchar(source)) paste0("source: ", source)
      )
      paste0(
        "- ", sponsor_clean,
        if (length(extra)) paste0("  (", paste(extra, collapse = "; "), ")") else ""
      )
    }
  )
  paste0(
    "Raw sponsor string:\n", raw, "\n\nCandidate canonical names:\n",
    paste(lines, collapse = "\n")
  )
}

output_schema <- function(cands) {
  list(
    type = "json_schema",
    schema = list(
      type = "object",
      properties = list(
        chosen = list(
          type = "string",
          enum = c(cands$sponsor_clean, ABSTAIN)
        ),
        confidence = list(type = "string", enum = c("high", "medium", "low")),
        reason     = list(type = "string")
      ),
      required = list("chosen", "confidence", "reason"),
      additionalProperties = FALSE
    )
  )
}

# The system block is byte-identical across every call, so it is the cache
# breakpoint; the per-string candidates go in the user turn, after it. Opus 5's
# minimum cacheable prefix is 512 tokens — --dry-run reports whether the system
# block actually clears it rather than assuming.
build_body <- function(raw, cands, for_batch) {
  body <- list(
    model      = MODEL_ID,
    max_tokens = MAX_TOKENS,
    system = list(list(
      type = "text",
      text = SYSTEM_PROMPT,
      cache_control = list(type = "ephemeral")
    )),
    messages = list(list(
      role = "user",
      content = candidate_block(raw, cands)
    )),
    output_config = list(
      effort = EFFORT,
      format = output_schema(cands)
    )
  )
  # Thinking is left at its default (on for Opus 5). MAX_TOKENS covers thinking
  # and the JSON together. No temperature/top_p/top_k — all 400 on this model.
  if (!for_batch) body$fallbacks <- "default"
  body
}

candidates_sha <- function(cands) {
  paste(openssl::sha256(paste(cands$sponsor_clean, collapse = "\n")), collapse = "")
}

cache_key_for <- function(raw_clean, cand_sha) {
  paste(openssl::sha256(paste(
    raw_clean, PROMPT_VERSION, MODEL_ID, cand_sha, sep = "|"
  )), collapse = "")
}

# ── Cache ─────────────────────────────────────────────────────────────────────

CACHE_COLS <- c(
  "cache_key", "raw_sponsor", "model_id", "prompt_version", "candidates_sha256",
  "chosen", "confidence", "reason", "abstained", "decided_at_utc", "batch_id"
)

empty_cache <- function() {
  tibble::tibble(
    cache_key = character(), raw_sponsor = character(), model_id = character(),
    prompt_version = character(), candidates_sha256 = character(),
    chosen = character(), confidence = character(), reason = character(),
    abstained = logical(), decided_at_utc = character(), batch_id = character()
  )
}

read_cache <- function() {
  if (!file.exists(CACHE)) return(empty_cache())
  readr::read_csv(CACHE, show_col_types = FALSE, col_types = readr::cols(
    .default = readr::col_character(), abstained = readr::col_logical()
  ))
}

write_cache <- function(x) {
  x <- x |>
    dplyr::select(dplyr::all_of(CACHE_COLS)) |>
    dplyr::arrange(raw_sponsor, cache_key)
  tmp <- paste0(CACHE, ".tmp")
  readr::write_csv(x, tmp, na = "NA")
  invisible(file.rename(tmp, CACHE))
}

utc_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# ── Response handling ─────────────────────────────────────────────────────────

# Check stop_reason BEFORE reading content: a refusal returns HTTP 200 with an
# empty or partial content array, so indexing content[[1]] blindly breaks.
parse_message <- function(msg, cands) {
  stop_reason <- msg$stop_reason %||% NA_character_
  if (identical(stop_reason, "refusal")) {
    return(list(ok = FALSE, error = paste0(
      "refusal (", msg$stop_details$category %||% "unknown", ")"
    )))
  }
  if (identical(stop_reason, "max_tokens")) {
    return(list(ok = FALSE, error = "max_tokens — raise MAX_TOKENS"))
  }
  txt <- purrr::keep(msg$content, ~ identical(.x$type, "text"))
  if (length(txt) == 0L) {
    return(list(ok = FALSE, error = paste0("no text block (stop_reason=", stop_reason, ")")))
  }
  parsed <- tryCatch(
    jsonlite::fromJSON(txt[[1L]]$text),
    error = function(e) NULL
  )
  if (is.null(parsed) || is.null(parsed$chosen)) {
    return(list(ok = FALSE, error = "unparseable JSON"))
  }
  # Second enforcement, independent of output_config.format. If the enum ever
  # fails to constrain, the invented name stops here rather than in a label.
  allowed <- c(cands$sponsor_clean, ABSTAIN)
  if (!parsed$chosen %in% allowed) {
    return(list(ok = FALSE, error = paste0("off-list answer: ", parsed$chosen)))
  }
  list(
    ok = TRUE,
    chosen = parsed$chosen,
    confidence = parsed$confidence %||% NA_character_,
    reason = parsed$reason %||% NA_character_
  )
}

cache_row <- function(raw, cand_sha, key, res, batch_id = NA_character_) {
  tibble::tibble(
    cache_key = key, raw_sponsor = raw, model_id = MODEL_ID,
    prompt_version = PROMPT_VERSION, candidates_sha256 = cand_sha,
    chosen = if (res$ok && res$chosen != ABSTAIN) res$chosen else NA_character_,
    confidence = if (res$ok) res$confidence else NA_character_,
    reason = if (res$ok) res$reason else res$error,
    abstained = if (res$ok) res$chosen == ABSTAIN else NA,
    decided_at_utc = utc_now(), batch_id = batch_id
  )
}

# ── Work list ─────────────────────────────────────────────────────────────────

unknown_sponsors <- function() {
  if (!file.exists(LOG)) {
    stop("No normalisation log at ", LOG,
         " — run 3_build_sponsor_labels.R first.", call. = FALSE)
  }
  readr::read_csv(LOG, show_col_types = FALSE) |>
    dplyr::filter(match_status == "unknown") |>
    dplyr::distinct(raw_sponsor) |>
    dplyr::filter(!is.na(raw_sponsor), nzchar(raw_sponsor)) |>
    dplyr::arrange(raw_sponsor) |>
    dplyr::pull(raw_sponsor)
}

message("Loading sponsor configs...")
cfg <- load_sponsor_configs(SNP)
cache <- read_cache()

raws <- unknown_sponsors()
message(sprintf("Unknown sponsor strings: %d", length(raws)))

message("Assembling candidates...")
work <- purrr::map_dfr(raws, function(raw) {
  cands <- retrieve_candidates(raw, cfg)
  if (nrow(cands) == 0L) {
    # Nothing to choose from. Asking anyway invites invention, so skip.
    return(tibble::tibble(raw_sponsor = raw, n_candidates = 0L, skip = TRUE))
  }
  sha <- candidates_sha(cands)
  tibble::tibble(
    raw_sponsor = raw,
    n_candidates = nrow(cands),
    skip = FALSE,
    candidates_sha256 = sha,
    cache_key = cache_key_for(clean_sponsor_alias(raw), sha),
    cands = list(cands)
  )
})

skipped <- work |> dplyr::filter(skip)
work    <- work |> dplyr::filter(!skip)
todo    <- work |> dplyr::filter(!cache_key %in% cache$cache_key)

# Distinct raw strings can collapse to the same question. cache_key hashes
# raw_clean, and clean_sponsor_alias() maps "Dainippon Sumitomo Pharma America,
# Inc" and "...America Inc." to one value — same candidates, same key. Sharing
# the key is the point (one call answers both), but the Batches API rejects a
# duplicate custom_id, so ask once per key and fan the answer back out to every
# raw string that shares it. Each raw string still gets its own cache row, which
# is what the reviewer app joins on.
questions <- todo |> dplyr::distinct(cache_key, .keep_all = TRUE)

message(sprintf(
  "  %d resolvable, %d skipped (no candidates), %d already cached, %d new",
  nrow(work), nrow(skipped), nrow(work) - nrow(todo), nrow(todo)
))
if (nrow(questions) < nrow(todo)) {
  message(sprintf(
    "  %d distinct questions (%d raw strings share a cleaned form)",
    nrow(questions), nrow(todo) - nrow(questions)
  ))
}

if (!is.na(limit) && limit > 0L && nrow(questions) > limit) {
  questions <- questions |> utils::head(limit)
  message(sprintf("  --limit=%d applied", limit))
}

# One answered row per cache_key -> one cache row per raw string sharing it.
expand_to_raws <- function(rows) {
  if (nrow(rows) == 0L) return(rows)
  rows |>
    dplyr::select(-raw_sponsor) |>
    dplyr::inner_join(
      todo |> dplyr::select(cache_key, raw_sponsor),
      by = "cache_key", relationship = "one-to-many"
    )
}

# ── Dry run ───────────────────────────────────────────────────────────────────

if (dry_run) {
  if (nrow(questions) == 0L) {
    message("Nothing to resolve. Cache is complete.")
    quit(save = "no", status = 0L)
  }
  auth <- tryCatch(resolve_auth(), error = function(e) NULL)
  sample_row <- questions |> dplyr::slice(1L)
  body <- build_body(sample_row$raw_sponsor, sample_row$cands[[1L]], for_batch = FALSE)

  cat("\n--- sample request (first row) ---\n")
  cat("raw:        ", sample_row$raw_sponsor, "\n", sep = "")
  cat("candidates: ", nrow(sample_row$cands[[1L]]), "\n", sep = "")
  cat(candidate_block(sample_row$raw_sponsor, sample_row$cands[[1L]]), "\n")

  cat("\n--- candidate count distribution ---\n")
  print(summary(questions$n_candidates))

  if (is.null(auth)) {
    message("\nNo credentials available — skipping count_tokens.")
    quit(save = "no", status = 0L)
  }
  count_body <- body[c("model", "system", "messages")]
  resp <- httr2::request(paste0(API_BASE, "/v1/messages/count_tokens")) |>
    httr2::req_headers(!!!c(
      auth$headers,
      "anthropic-version" = API_VERSION,
      "content-type" = "application/json"
    )) |>
    (\(r) if (length(auth$betas)) httr2::req_headers(
      r, "anthropic-beta" = paste(auth$betas, collapse = ",")
    ) else r)() |>
    httr2::req_body_json(count_body, auto_unbox = TRUE) |>
    httr2::req_error(is_error = function(x) FALSE) |>
    httr2::req_perform()

  out <- httr2::resp_body_json(resp)
  if (!is.null(out$input_tokens)) {
    cat("\ninput_tokens (one request): ", out$input_tokens, "\n", sep = "")
    sys_only <- list(
      model = MODEL_ID, system = body$system,
      messages = list(list(role = "user", content = "x"))
    )
    resp2 <- httr2::request(paste0(API_BASE, "/v1/messages/count_tokens")) |>
      httr2::req_headers(!!!c(
        auth$headers, "anthropic-version" = API_VERSION,
        "content-type" = "application/json"
      )) |>
      (\(r) if (length(auth$betas)) httr2::req_headers(
        r, "anthropic-beta" = paste(auth$betas, collapse = ",")
      ) else r)() |>
      httr2::req_body_json(sys_only, auto_unbox = TRUE) |>
      httr2::req_error(is_error = function(x) FALSE) |>
      httr2::req_perform()
    sys_tokens <- httr2::resp_body_json(resp2)$input_tokens
    cat("system block:               ", sys_tokens, "\n", sep = "")
    cat("cacheable (needs >= 512):   ",
        if (!is.null(sys_tokens) && sys_tokens >= 512) "yes" else "NO — prefix too short",
        "\n", sep = "")
    est_in <- out$input_tokens * nrow(todo)
    cat(sprintf(
      "\nestimate for %d requests: ~%s input tokens; batched ~$%.2f in, ~$%.2f out (150 tok/resp)\n",
      nrow(todo), format(est_in, big.mark = ","),
      est_in / 1e6 * 5 * 0.5, nrow(todo) * 150 / 1e6 * 25 * 0.5
    ))
  } else {
    cat("\ncount_tokens failed:\n")
    print(out)
  }
  quit(save = "no", status = 0L)
}

# ── Sync mode ─────────────────────────────────────────────────────────────────

if (do_sync) {
  auth <- resolve_auth()
  betas <- unique(c(auth$betas, FALLBACK_BETA))
  message(sprintf("Resolving %d question(s) synchronously...", nrow(questions)))

  rows <- purrr::pmap_dfr(
    questions |> dplyr::select(raw_sponsor, candidates_sha256, cache_key, cands),
    function(raw_sponsor, candidates_sha256, cache_key, cands) {
      body <- build_body(raw_sponsor, cands, for_batch = FALSE)
      resp <- httr2::request(paste0(API_BASE, "/v1/messages")) |>
        httr2::req_headers(!!!c(
          auth$headers, "anthropic-version" = API_VERSION,
          "anthropic-beta" = paste(betas, collapse = ","),
          "content-type" = "application/json"
        )) |>
        httr2::req_body_json(body, auto_unbox = TRUE) |>
        httr2::req_retry(max_tries = 3L) |>
        httr2::req_error(is_error = function(x) FALSE) |>
        httr2::req_perform()

      if (httr2::resp_status(resp) >= 400L) {
        err <- httr2::resp_body_string(resp)
        message(sprintf("  [%d] %s", httr2::resp_status(resp), substr(err, 1, 300)))
        return(cache_row(
          raw_sponsor, candidates_sha256, cache_key,
          list(ok = FALSE, error = paste0("http ", httr2::resp_status(resp)))
        ))
      }
      res <- parse_message(httr2::resp_body_json(resp), cands)
      message(sprintf(
        "  %-50s -> %s",
        substr(raw_sponsor, 1, 50),
        if (res$ok) res$chosen else paste0("ERROR: ", res$error)
      ))
      cache_row(raw_sponsor, candidates_sha256, cache_key, res)
    }
  )

  rows <- expand_to_raws(rows)
  write_cache(dplyr::bind_rows(cache, rows))
  message(sprintf("Wrote %d rows to %s", nrow(rows), basename(CACHE)))
  quit(save = "no", status = 0L)
}

# ── Batch mode ────────────────────────────────────────────────────────────────
# 50% cheaper and usually within the hour. custom_id carries the cache key, so
# results — which arrive in ANY order — key straight back.

auth  <- resolve_auth()
betas <- auth$betas

req_headers <- function(r) {
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
  if (nrow(questions) == 0L) {
    message("Nothing to resolve. Cache is complete.")
    quit(save = "no", status = 0L)
  }
  requests <- purrr::pmap(
    questions |> dplyr::select(raw_sponsor, cache_key, cands),
    function(raw_sponsor, cache_key, cands) {
      list(
        custom_id = cache_key,
        params = build_body(raw_sponsor, cands, for_batch = TRUE)
      )
    }
  )
  # The API enforces this too, but failing here costs nothing and names the
  # offending key instead of returning a wall of hashes after the upload.
  ids <- purrr::map_chr(requests, "custom_id")
  if (anyDuplicated(ids)) {
    stop(
      "duplicate custom_id in batch: ",
      paste(unique(ids[duplicated(ids)]), collapse = ", "),
      call. = FALSE
    )
  }
  message(sprintf("Submitting batch of %d requests...", length(requests)))
  resp <- httr2::request(paste0(API_BASE, "/v1/messages/batches")) |>
    req_headers() |>
    httr2::req_body_json(list(requests = requests), auto_unbox = TRUE) |>
    httr2::req_error(is_error = function(x) FALSE) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) >= 400L) {
    stop("Batch submit failed: ", httr2::resp_body_string(resp), call. = FALSE)
  }
  batch_id <- httr2::resp_body_json(resp)$id
  message("batch id: ", batch_id)
  message("Resume later with --batch --poll=", batch_id)
}

repeat {
  resp <- httr2::request(paste0(API_BASE, "/v1/messages/batches/", batch_id)) |>
    req_headers() |>
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
  req_headers() |>
  httr2::req_error(is_error = function(x) FALSE) |>
  httr2::req_perform()
if (httr2::resp_status(resp) >= 400L) {
  stop("Batch results failed: ", httr2::resp_body_string(resp), call. = FALSE)
}

lines <- strsplit(httr2::resp_body_string(resp), "\n", fixed = TRUE)[[1L]]
lines <- lines[nzchar(lines)]
by_key <- questions |> dplyr::select(cache_key, raw_sponsor, candidates_sha256, cands)

rows <- purrr::map_dfr(lines, function(line) {
  r <- jsonlite::fromJSON(line, simplifyVector = FALSE)
  key <- r$custom_id
  hit <- by_key |> dplyr::filter(cache_key == key)
  if (nrow(hit) == 0L) return(tibble::tibble())
  cands <- hit$cands[[1L]]
  # Branch on all four result types — an expired or canceled request is a
  # missing decision, not a silent success.
  res <- switch(
    r$result$type,
    succeeded = parse_message(r$result$message, cands),
    errored   = list(ok = FALSE, error = paste0(
      "errored: ", r$result$error$type %||% "unknown")),
    canceled  = list(ok = FALSE, error = "canceled"),
    expired   = list(ok = FALSE, error = "expired"),
    list(ok = FALSE, error = paste0("unknown result type: ", r$result$type))
  )
  cache_row(hit$raw_sponsor, hit$candidates_sha256, key, res, batch_id)
})

rows <- expand_to_raws(rows)
write_cache(dplyr::bind_rows(cache, rows))

ok <- sum(!is.na(rows$abstained))
message(sprintf(
  "Wrote %d rows to %s (%d decided, %d abstained, %d failed)",
  nrow(rows), basename(CACHE),
  sum(!is.na(rows$chosen)), sum(rows$abstained %in% TRUE), nrow(rows) - ok
))
message("Nothing has been applied to any label. Review in the curation app.")
