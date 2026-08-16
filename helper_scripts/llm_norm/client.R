# Shared Anthropic client for the normalisation passes.
#
# Consolidates the auth / batch / cache plumbing that was duplicated between
# 5_llm_resolve.R and 6_llm_verify.R (see the note at 6_llm_verify.R:32-35).
# Domain-agnostic: sponsors and substances both drive it.
#
# THE ONE RULE THIS MODULE EXISTS TO ENFORCE: the output schema is a property of
# the PASS, not of the row. 5_llm_resolve.R embedded a per-row enum, making every
# request a distinct grammar; the org limit is 20 grammar compilations per minute
# and a 222-request batch lost 190 requests to it. A pass that varies its schema
# per item cannot scale to 16,594 strings, so llm_spec() takes exactly one schema
# and llm_dry_run() prints its sha256 as evidence.
#
# Constrain the answer with an INDEX into a per-row candidate list plus a bounds
# check on receipt. That gives the same guarantee the enum gave — the model
# cannot invent a name — with one grammar for the whole run.
#
# R has no official Anthropic SDK, so this is raw HTTP via httr2, which is the
# documented approach for languages without one.

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(httr2)
  library(jsonlite)
  library(openssl)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

API_BASE    <- "https://api.anthropic.com"
API_VERSION <- "2023-06-01"

# fallbacks:"default" re-serves a policy decline on Anthropic's recommended
# fallback model. Two independent restrictions, and BOTH have bitten:
#
#   1. Rejected on the Batches API      -> attached to sync requests only.
#   2. Not supported by every model     -> 'claude-sonnet-5' returns
#      400 "does not support the `fallbacks` parameter".
#
# The second surfaced on a 3-request sync check and would have failed a
# 1,939-request tail batch had it gone straight to --batch. Allowlist rather
# than blocklist: a model absent from this list simply does not get the
# parameter, which costs a refusal-retry at worst, whereas guessing wrong costs
# the whole run.
FALLBACK_BETA <- "server-side-fallback-2026-07-01"
MODELS_WITH_FALLBACKS <- c("claude-opus-5", "claude-fable-5", "claude-mythos-5")
model_supports_fallbacks <- function(m) m %in% MODELS_WITH_FALLBACKS

# Minimum cacheable prefix, in tokens. NOT monotonic across generations — Opus 5
# halved Opus 4.8's, and Haiku 4.5 is eight times Opus 5's. A system prompt that
# caches on one model silently fails to cache on another, with no error and no
# cache_creation_input_tokens to notice, so llm_dry_run() checks it explicitly.
CACHE_MIN_TOKENS <- c(
  "claude-opus-5"     = 512L,
  "claude-fable-5"    = 512L,
  "claude-opus-4-8"   = 1024L,
  "claude-sonnet-5"   = 1024L,
  "claude-sonnet-4-6" = 1024L,
  "claude-opus-4-7"   = 2048L,
  "claude-opus-4-6"   = 4096L,
  "claude-haiku-4-5"  = 4096L
)

# USD per million tokens, standard (non-batch) rates. Batch halves both.
MODEL_PRICES <- list(
  "claude-opus-5"     = c(input = 5.00, output = 25.00),
  "claude-opus-4-8"   = c(input = 5.00, output = 25.00),
  "claude-sonnet-5"   = c(input = 3.00, output = 15.00),
  "claude-sonnet-4-6" = c(input = 3.00, output = 15.00),
  "claude-haiku-4-5"  = c(input = 1.00, output = 5.00)
)
# Sonnet 5 introductory pricing. Encoded with its end date rather than baked in,
# so the estimate stops being wrong by itself instead of when someone remembers.
SONNET5_INTRO_UNTIL <- as.Date("2026-08-31")
SONNET5_INTRO_PRICE <- c(input = 2.00, output = 10.00)

# effort 400s on these; send it anywhere else.
MODELS_WITHOUT_EFFORT <- c("claude-haiku-4-5", "claude-sonnet-4-5")
model_supports_effort <- function(m) !any(startsWith(m, MODELS_WITHOUT_EFFORT))

model_prices <- function(model, on = Sys.Date()) {
  p <- MODEL_PRICES[[model]]
  if (is.null(p)) return(c(input = NA_real_, output = NA_real_))
  if (identical(model, "claude-sonnet-5") && on <= SONNET5_INTRO_UNTIL) p <- SONNET5_INTRO_PRICE
  p
}

utc_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# openssl::sha256() returns a CLASSED object and as.character() keeps the class,
# so a hex string compared with identical() against a plain one fails despite
# equal bytes. Every hash in this codebase goes through here.
sha256_hex <- function(x) {
  h <- as.character(openssl::sha256(as.character(x)))
  attributes(h) <- NULL
  h
}

llm_cache_key <- function(...) sha256_hex(paste(..., sep = "|"))

# ── Auth ──────────────────────────────────────────────────────────────────────
# An unset ANTHROPIC_API_KEY does not mean there are no credentials: the `ant`
# CLI stores an OAuth profile the SDKs read automatically, and for raw HTTP we
# have to do that resolution ourselves. An OAuth token goes on
# Authorization: Bearer AND needs the oauth beta header — a header change, not a
# key swap. Getting that wrong yields an opaque 401.

llm_auth <- function() {
  key <- Sys.getenv("ANTHROPIC_API_KEY", "")
  if (nzchar(key)) {
    return(list(headers = c("x-api-key" = key), betas = character()))
  }
  # LLM_REQUIRE_API_KEY=1 refuses the CLI fallback outright. Set it on anything
  # unattended: a cron job that blocks on `ant` holds the deploy for the whole
  # day, and the failure looks like a hung batch rather than a missing key.
  if (identical(Sys.getenv("LLM_REQUIRE_API_KEY"), "1")) {
    stop("ANTHROPIC_API_KEY is unset and LLM_REQUIRE_API_KEY=1 forbids the ",
         "`ant` fallback.", call. = FALSE)
  }
  token <- tryCatch(
    suppressWarnings(system2("ant", c("auth", "print-credentials", "--access-token"),
                             stdout = TRUE, stderr = FALSE, timeout = 10)),
    error = function(e) character()
  )
  token <- token[nzchar(token)]
  if (length(token) == 0L) {
    stop("No credentials. Set ANTHROPIC_API_KEY, or run `ant auth login`.", call. = FALSE)
  }
  list(
    headers = c("Authorization" = paste("Bearer", token[[1L]])),
    betas   = "oauth-2025-04-20"
  )
}

# ── Pass specification ────────────────────────────────────────────────────────
# One schema per pass. Passing a function here is a bug, not a feature.

llm_spec <- function(model,
                     prompt_version,
                     system_prompt,
                     schema,
                     effort     = "low",
                     max_tokens = 4096L) {
  stopifnot(is.character(model), length(model) == 1L)
  # Checked before the is.list() assertion so the useful message wins: a
  # function here is the exact mistake this module exists to prevent.
  if (is.function(schema)) {
    stop("schema must be a constant list, not a function — a per-row schema is ",
         "what caused the grammar-compilation failure this module exists to prevent.",
         call. = FALSE)
  }
  stopifnot(is.list(schema))
  structure(list(
    model          = model,
    prompt_version = prompt_version,
    system_prompt  = system_prompt,
    schema         = schema,
    effort         = effort,
    max_tokens     = as.integer(max_tokens)
  ), class = "llm_spec")
}

llm_schema_sha <- function(spec) {
  sha256_hex(jsonlite::toJSON(spec$schema, auto_unbox = TRUE, null = "null"))
}

# The system block is byte-identical across every call in a pass, so it is the
# cache breakpoint; per-item content goes in the user turn, after it.
llm_body <- function(spec, content, for_batch) {
  body <- list(
    model      = spec$model,
    max_tokens = spec$max_tokens,
    system     = list(list(
      type          = "text",
      text          = spec$system_prompt,
      cache_control = list(type = "ephemeral")
    )),
    messages = list(list(role = "user", content = content)),
    output_config = if (model_supports_effort(spec$model)) {
      list(effort = spec$effort, format = list(type = "json_schema", schema = spec$schema))
    } else {
      list(format = list(type = "json_schema", schema = spec$schema))
    }
  )
  # Thinking left at its default. On Opus 5 that means adaptive thinking is ON,
  # and max_tokens covers thinking plus the JSON together. Not disabled: on
  # Opus 5 disabling it can leak <thinking> tags into the response and is
  # rejected outright above `high` effort. No temperature/top_p/top_k — all 400.
  if (!for_batch && model_supports_fallbacks(spec$model)) body$fallbacks <- "default"
  body
}

# ── HTTP ──────────────────────────────────────────────────────────────────────

llm_request <- function(path, auth, extra_betas = character()) {
  betas <- unique(c(auth$betas, extra_betas))
  r <- httr2::request(paste0(API_BASE, path)) |>
    httr2::req_headers(!!!c(
      auth$headers,
      "anthropic-version" = API_VERSION,
      "content-type"      = "application/json"
    )) |>
    httr2::req_error(is_error = function(x) FALSE)
  if (length(betas)) {
    r <- httr2::req_headers(r, "anthropic-beta" = paste(betas, collapse = ","))
  }
  r
}

llm_count_tokens <- function(spec, content, auth = llm_auth()) {
  body <- list(
    model    = spec$model,
    system   = list(list(type = "text", text = spec$system_prompt)),
    messages = list(list(role = "user", content = content))
  )
  resp <- llm_request("/v1/messages/count_tokens", auth) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_retry(max_tries = 3L) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) >= 400L) {
    stop("count_tokens failed: ", httr2::resp_body_string(resp), call. = FALSE)
  }
  httr2::resp_body_json(resp)$input_tokens
}

# ── Response handling ─────────────────────────────────────────────────────────

# Check stop_reason BEFORE reading content. A refusal returns HTTP 200 with an
# empty or partial content array, so indexing content[[1]] unconditionally is a
# crash waiting for the first declined request.
llm_parse_message <- function(msg) {
  stop_reason <- msg$stop_reason %||% NA_character_
  if (identical(stop_reason, "refusal")) {
    return(list(ok = FALSE, error = paste0(
      "refusal (", msg$stop_details$category %||% "unknown", ")"
    )))
  }
  if (identical(stop_reason, "max_tokens")) {
    return(list(ok = FALSE, error = "max_tokens — raise max_tokens on the spec"))
  }
  txt <- purrr::keep(msg$content, ~ identical(.x$type, "text"))
  if (length(txt) == 0L) {
    return(list(ok = FALSE, error = paste0("no text block (stop_reason=", stop_reason, ")")))
  }
  parsed <- tryCatch(jsonlite::fromJSON(txt[[1L]]$text), error = function(e) NULL)
  if (is.null(parsed)) return(list(ok = FALSE, error = "unparseable JSON"))
  list(ok = TRUE, value = parsed)
}

# Batch errors arrive in the standard API envelope: result.error.type is the
# literal "error" and the useful detail — rate_limit_error, invalid_request_error
# and its message — sits one level deeper. Reading the envelope discards exactly
# the field that says what to do next.
llm_result_to_outcome <- function(result) {
  switch(
    result$type,
    succeeded = llm_parse_message(result$message),
    errored   = list(ok = FALSE, error = {
      detail <- result$error$error %||% result$error
      msg    <- detail$message %||% ""
      paste0("errored: ", detail$type %||% "unknown",
             if (nzchar(msg)) paste0(": ", substr(msg, 1L, 300L)) else "")
    }),
    canceled  = list(ok = FALSE, error = "canceled"),
    expired   = list(ok = FALSE, error = "expired"),
    list(ok = FALSE, error = paste0("unknown result type: ", result$type))
  )
}

# ── Dry run ───────────────────────────────────────────────────────────────────
# Never submit a batch without this. It is offline apart from count_tokens, and
# it checks the three things that have actually gone wrong before: a schema that
# varies per row, a system prefix too short to cache on the chosen model, and a
# cost nobody estimated.

llm_dry_run <- function(spec, items, label = "pass", sample_n = 5L,
                        spend_path = NULL) {
  n <- nrow(items)
  cat(sprintf("\n=== dry run: %s ===\n", label))
  cat(sprintf("model            : %s\n", spec$model))
  cat(sprintf("prompt version   : %s\n", spec$prompt_version))
  cat(sprintf("effort           : %s\n",
              if (model_supports_effort(spec$model)) spec$effort else "(unsupported on this model)"))
  cat(sprintf("max_tokens       : %d\n", spec$max_tokens))
  cat(sprintf("requests         : %d\n", n))
  cat(sprintf("schema sha256    : %s  (ONE grammar for the whole pass)\n", llm_schema_sha(spec)))

  if (n == 0L) { cat("\nNothing to do.\n"); return(invisible(NULL)) }

  auth <- llm_auth()
  idx  <- unique(round(seq(1L, n, length.out = min(sample_n, n))))
  per  <- vapply(idx, function(i) llm_count_tokens(spec, items$content[[i]], auth), numeric(1))
  sys_tokens <- llm_count_tokens(spec, list(list(type = "text", text = "x")), auth)

  min_needed <- CACHE_MIN_TOKENS[[spec$model]] %||% NA_integer_
  cat(sprintf("\nsystem prefix    : %d tokens\n", sys_tokens))
  if (!is.na(min_needed)) {
    verdict <- if (sys_tokens >= min_needed) "caches" else "TOO SHORT TO CACHE"
    cat(sprintf("cache minimum    : %d tokens for %s -> %s\n", min_needed, spec$model, verdict))
    if (sys_tokens < min_needed) {
      cat("  The system prompt will silently not cache on this model. There is no\n",
          "  error and no cache_creation_input_tokens to notice it by.\n", sep = "")
    }
  }

  mean_in <- mean(per)

  # Output is the estimate's weak point, so calibrate it from what this pass has
  # actually cost rather than guessing. Measured: the max_tokens * 0.25 heuristic
  # was 7.9x too high for minting (assumed 2048 tokens/request, actual 260),
  # which is not a harmless error — an inflated estimate can make the budget
  # guard refuse a run that is comfortably affordable.
  est_out <- spec$max_tokens * 0.25
  calib <- NULL
  if (!is.null(spend_path) && file.exists(spend_path)) {
    hist <- llm_spend_read(spend_path)
    hist <- hist[hist$model_id == spec$model &
                   !is.na(hist$n_requests) & hist$n_requests > 0, , drop = FALSE]
    if (!is.null(label)) {
      same <- hist[startsWith(hist$pass, sub(" .*", "", label)), , drop = FALSE]
      if (nrow(same)) hist <- same
    }
    if (nrow(hist)) {
      calib <- sum(hist$output_tokens) / sum(hist$n_requests)
      est_out <- calib
    }
  }
  pr      <- model_prices(spec$model)
  in_tok  <- mean_in * n
  out_tok <- est_out * n
  cat(sprintf("\nmean input       : %.0f tokens/request (sampled %d)\n", mean_in, length(idx)))
  if (is.null(calib)) {
    cat(sprintf("assumed output   : %.0f tokens/request (max_tokens x 0.25 — no history yet,\n", est_out))
    cat("                   expect this to overshoot; it is a ceiling, not a forecast)\n")
  } else {
    cat(sprintf("assumed output   : %.0f tokens/request (measured from previous runs of this pass)\n", est_out))
  }
  if (!is.na(pr[["input"]])) {
    cat(sprintf("cost @ batch     : $%.2f in + $%.2f out = $%.2f\n",
                in_tok / 1e6 * pr[["input"]] * 0.5,
                out_tok / 1e6 * pr[["output"]] * 0.5,
                in_tok / 1e6 * pr[["input"]] * 0.5 + out_tok / 1e6 * pr[["output"]] * 0.5))
    cat(sprintf("cost @ standard  : $%.2f\n",
                in_tok / 1e6 * pr[["input"]] + out_tok / 1e6 * pr[["output"]]))
    if (identical(spec$model, "claude-sonnet-5") && Sys.Date() <= SONNET5_INTRO_UNTIL) {
      cat(sprintf("  (Sonnet 5 introductory pricing, ends %s)\n", SONNET5_INTRO_UNTIL))
    }
  } else {
    cat("cost             : unknown model, no price on file\n")
  }
  cat("\nNo requests sent.\n")
  invisible(list(
    mean_input      = mean_in,
    system_tokens   = sys_tokens,
    n               = n,
    est_cost_batch  = if (is.na(pr[["input"]])) NA_real_ else
      in_tok / 1e6 * pr[["input"]] * 0.5 + out_tok / 1e6 * pr[["output"]] * 0.5,
    est_cost_sync   = if (is.na(pr[["input"]])) NA_real_ else
      in_tok / 1e6 * pr[["input"]] + out_tok / 1e6 * pr[["output"]]
  ))
}

# ── Budget ────────────────────────────────────────────────────────────────────
# This project has a hard ceiling of USD 60 across every pass. An estimate in a
# comment does not enforce anything, so spend is recorded from the usage
# actually returned by each batch and the guard refuses a submission whose
# estimate would breach what is left.
#
# The guard is also what makes --full-registry safe to offer: it is affordable
# on a few hundred strings (~$2-23) and ruinous on all 16,594 (~$86-860), and
# rather than trusting anyone to remember which, the arithmetic simply refuses
# the second.
#
# Prompt caching DOES work inside a batch, contrary to the pessimistic reading of
# the concurrency caveat: a 497-request mint batch recorded 980,392 cache-read
# tokens against 217,535 fresh input. Cache reads bill at ~0.1x, so this is a
# large part of why actuals land well under estimate.

BUDGET_CAP_USD <- 60.00

SPEND_COLS <- c("recorded_at_utc", "pass", "batch_id", "model_id", "n_requests",
                "input_tokens", "output_tokens", "cache_read_tokens", "cost_usd")

llm_spend_read <- function(path) {
  if (!file.exists(path)) {
    return(tibble::tibble(
      recorded_at_utc = character(), pass = character(), batch_id = character(),
      model_id = character(), n_requests = numeric(),
      input_tokens = numeric(), output_tokens = numeric(),
      cache_read_tokens = numeric(), cost_usd = numeric()
    ))
  }
  readr::read_csv(path, show_col_types = FALSE, progress = FALSE, col_types = readr::cols(
    .default = readr::col_character(), n_requests = readr::col_double(),
    input_tokens = readr::col_double(), output_tokens = readr::col_double(),
    cache_read_tokens = readr::col_double(), cost_usd = readr::col_double()
  ))
}

llm_spend_total <- function(path) {
  s <- llm_spend_read(path)
  if (!nrow(s)) return(0)
  sum(s$cost_usd, na.rm = TRUE)
}

# Cache reads bill at ~0.1x the base input rate; batch halves everything.
llm_cost_of <- function(model, input_tokens, output_tokens, cache_read_tokens = 0,
                        batch = TRUE) {
  p <- model_prices(model)
  if (is.na(p[["input"]])) return(NA_real_)
  mult <- if (batch) 0.5 else 1
  (input_tokens      / 1e6 * p[["input"]]  +
   cache_read_tokens / 1e6 * p[["input"]] * 0.1 +
   output_tokens     / 1e6 * p[["output"]]) * mult
}

# Idempotent per batch_id. `llm_batch_usage()` reports the usage of the WHOLE
# batch, so calling --batch and then --poll=<same id> for the stragglers records
# the same tokens twice and overstates spend — observed: one Sonnet batch logged
# $1.70 twice, inflating the running total by 26%. A budget guard fed an inflated
# total refuses affordable runs, so this has to be exact.
llm_spend_record <- function(path, pass, batch_id, model_id,
                             input_tokens, output_tokens, cache_read_tokens = 0,
                             batch = TRUE, n_requests = NA_real_) {
  if (!is.null(batch_id) && !is.na(batch_id)) {
    prior <- llm_spend_read(path)
    if (nrow(prior) && batch_id %in% prior$batch_id) {
      message(sprintf("  batch %s already recorded ($%.2f); not double-counting",
                      batch_id, sum(prior$cost_usd[prior$batch_id == batch_id], na.rm = TRUE)))
      return(invisible(NULL))
    }
  }
  row <- tibble::tibble(
    recorded_at_utc = utc_now(), pass = pass, batch_id = batch_id %||% NA_character_,
    model_id = model_id, n_requests = n_requests,
    input_tokens = input_tokens, output_tokens = output_tokens,
    cache_read_tokens = cache_read_tokens,
    cost_usd = llm_cost_of(model_id, input_tokens, output_tokens, cache_read_tokens, batch)
  )
  out <- dplyr::bind_rows(llm_spend_read(path), row)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(out[, SPEND_COLS], path, na = "", eol = "\n")
  invisible(row)
}

# A PER-RUN ceiling, distinct from llm_budget_guard()'s cumulative project cap.
#
# The project cap answers "have we spent too much in total"; this answers "is
# tonight's work list a normal size". They fail differently: a corpus reload that
# dumps thousands of new strings is affordable against a $60 cap and still means
# something structural broke, so it wants a human rather than an unattended bill.
# Refuses the whole run — never truncates, because a silently truncated work list
# becomes a permanent backlog nobody notices.
llm_run_cap_guard <- function(estimate_usd, cap_usd, pass) {
  if (is.na(estimate_usd)) {
    stop("No cost estimate available — refusing to submit blind.", call. = FALSE)
  }
  cat(sprintf("run cap: $%.2f estimated for %s, ceiling $%.2f\n",
              estimate_usd, pass, cap_usd))
  if (estimate_usd > cap_usd) {
    stop(sprintf(
      paste0("Refusing: estimated $%.2f exceeds the $%.2f per-run ceiling.\n",
             "  This is a size guard, not a budget guard. Raise it deliberately\n",
             "  with SPONSOR_NIGHTLY_CAP_USD, or run the backlog by hand."),
      estimate_usd, cap_usd), call. = FALSE)
  }
  invisible(TRUE)
}

# Call before every submission. `estimate` comes from llm_dry_run().
llm_budget_guard <- function(estimate_usd, spend_path, pass,
                             cap = BUDGET_CAP_USD, allow_over = FALSE) {
  spent     <- llm_spend_total(spend_path)
  remaining <- cap - spent
  cat(sprintf("\nbudget: $%.2f spent of $%.2f cap, $%.2f remaining\n", spent, cap, remaining))
  cat(sprintf("        this pass (%s) estimated at $%.2f\n", pass, estimate_usd))
  if (is.na(estimate_usd)) {
    stop("No cost estimate available — refusing to submit blind.", call. = FALSE)
  }
  if (estimate_usd > remaining && !allow_over) {
    stop(sprintf(
      paste0("Refusing to submit: estimated $%.2f exceeds the $%.2f remaining.\n",
             "  Reduce scope (--limit), pick a cheaper model, or raise the cap\n",
             "  deliberately with allow_over=TRUE."),
      estimate_usd, remaining
    ), call. = FALSE)
  }
  if (estimate_usd > remaining * 0.5) {
    cat("        NOTE: this pass consumes over half the remaining budget.\n")
  }
  invisible(remaining)
}

# Usage as reported by the batch, which is what actually gets billed — the
# dry-run estimate assumes an output length and is only ever approximate.
llm_batch_usage <- function(batch_id, auth = llm_auth()) {
  resp <- tryCatch(
    llm_request(paste0("/v1/messages/batches/", batch_id, "/results"), auth) |>
      httr2::req_timeout(300) |>
      httr2::req_retry(max_tries = 5L) |>
      httr2::req_perform(),
    error = function(e) e
  )
  if (inherits(resp, "condition")) return(NULL)
  if (httr2::resp_status(resp) >= 400L) return(NULL)
  lines <- strsplit(httr2::resp_body_string(resp), "\n", fixed = TRUE)[[1L]]
  lines <- lines[nzchar(lines)]
  tot <- list(input = 0, output = 0, cache_read = 0, n = length(lines))
  for (line in lines) {
    r <- jsonlite::fromJSON(line, simplifyVector = FALSE)
    u <- r$result$message$usage
    if (is.null(u)) next
    tot$input      <- tot$input      + (u$input_tokens %||% 0)
    tot$output     <- tot$output     + (u$output_tokens %||% 0)
    tot$cache_read <- tot$cache_read + (u$cache_read_input_tokens %||% 0)
  }
  # `n` is the batch's OWN request count, so callers stop recording nrow(work).
  # Those disagree whenever a poll rebuilds a different work list, and
  # n_requests feeds the dry-run calibration (output_tokens / n_requests) — a
  # too-small n inflates every later estimate, which is the same failure mode as
  # the double-counted spend: an inflated ledger refuses runs you can afford.
  tot
}

# ── Sync ──────────────────────────────────────────────────────────────────────
# For prompt iteration and the scale gate, not for the full corpus. `parse` gets
# (outcome, item_row) and returns a one-row tibble.

# Usage is ACCUMULATED and returned on attr(rows, "usage"), so a caller can
# record what a sync run actually cost.
#
# It used to be discarded. The consequence was invisible and total: the sync
# branches of B_mint and C_assign call this, save their rows and quit, so no
# llm_budget_guard() ran before and no llm_spend_record() ran after. 373 real
# C_assign requests left NO row in llm_spend.csv — the pass looks free, and the
# $60 cap it is supposed to enforce never sees the spend. Anything running
# unattended has to be metered or the cap is decorative.
llm_sync <- function(spec, items, parse, auth = llm_auth(), verbose = TRUE) {
  usage <- list(input = 0, output = 0, cache_read = 0, n = 0L)
  rows <- purrr::map_dfr(seq_len(nrow(items)), function(i) {
    item <- items[i, , drop = FALSE]
    betas <- if (model_supports_fallbacks(spec$model)) FALLBACK_BETA else character()
    resp <- llm_request("/v1/messages", auth, betas) |>
      httr2::req_body_json(llm_body(spec, item$content[[1L]], for_batch = FALSE),
                           auto_unbox = TRUE) |>
      httr2::req_retry(max_tries = 3L) |>
      httr2::req_perform()

    outcome <- if (httr2::resp_status(resp) >= 400L) {
      body <- httr2::resp_body_string(resp)
      if (verbose) message(sprintf("  [%d] %s", httr2::resp_status(resp), substr(body, 1L, 300L)))
      list(ok = FALSE, error = paste0("http ", httr2::resp_status(resp), ": ", substr(body, 1L, 200L)))
    } else {
      msg <- httr2::resp_body_json(resp)
      u <- msg$usage
      if (!is.null(u)) {
        usage$input      <<- usage$input      + (u$input_tokens %||% 0)
        usage$output     <<- usage$output     + (u$output_tokens %||% 0)
        usage$cache_read <<- usage$cache_read + (u$cache_read_input_tokens %||% 0)
        usage$n          <<- usage$n + 1L
      }
      llm_parse_message(msg)
    }
    if (verbose) {
      message(sprintf("  %-6s %s", if (outcome$ok) "ok" else "FAIL",
                      if (outcome$ok) "" else outcome$error))
    }
    parse(outcome, item)
  })
  attr(rows, "usage") <- usage
  rows
}

# Record what a sync run cost. Separate from the batch path because sync bills at
# full rate (batch = FALSE) and has no batch_id to be idempotent on — a synthetic
# one keeps llm_spend_record's duplicate guard meaningful.
llm_spend_record_sync <- function(spend_path, pass, model_id, rows) {
  u <- attr(rows, "usage")
  if (is.null(u) || !isTRUE(u$n > 0L)) return(invisible(NULL))
  llm_spend_record(
    spend_path, pass,
    batch_id = sprintf("sync_%s_%s", pass, format(Sys.time(), "%Y%m%dT%H%M%OS3", tz = "UTC")),
    model_id = model_id, input_tokens = u$input, output_tokens = u$output,
    cache_read_tokens = u$cache_read, batch = FALSE, n_requests = u$n
  )
}

# ── Batch ─────────────────────────────────────────────────────────────────────
# 50% cheaper, up to 100k requests per batch, usually inside the hour.
# custom_id carries the cache key, so results — which arrive in ANY order — key
# straight back. Never index results positionally.

llm_batch_submit <- function(spec, items, auth = llm_auth()) {
  stopifnot(all(c("key", "content") %in% names(items)))
  # The API enforces uniqueness too, but failing here names the offending key
  # instead of returning a wall of hashes after the upload.
  if (anyDuplicated(items$key)) {
    stop("duplicate custom_id in batch: ",
         paste(unique(items$key[duplicated(items$key)]), collapse = ", "), call. = FALSE)
  }
  requests <- purrr::map(seq_len(nrow(items)), function(i) {
    list(custom_id = items$key[[i]],
         params    = llm_body(spec, items$content[[i]], for_batch = TRUE))
  })
  message(sprintf("Submitting batch of %d requests...", length(requests)))
  resp <- llm_request("/v1/messages/batches", auth) |>
    httr2::req_body_json(list(requests = requests), auto_unbox = TRUE) |>
    httr2::req_retry(max_tries = 3L) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) >= 400L) {
    stop("Batch submit failed: ", httr2::resp_body_string(resp), call. = FALSE)
  }
  id <- httr2::resp_body_json(resp)$id
  message("batch id: ", id)
  message("Resume later with --poll=", id)
  id
}

# A batch can take an hour and is allowed 24. Over that window a DNS blip or a
# dropped connection is close to certain, and the work is server-side — losing
# the poll loop must NOT lose the batch. A transient failure is logged and
# retried; only a long run of consecutive failures gives up, and it says how to
# resume when it does.
llm_batch_wait <- function(batch_id, auth = llm_auth(), interval = 60,
                           max_consecutive_failures = 20L) {
  fails <- 0L
  repeat {
    resp <- tryCatch(
      llm_request(paste0("/v1/messages/batches/", batch_id), auth) |>
        httr2::req_timeout(60) |>
        httr2::req_retry(max_tries = 5L) |>
        httr2::req_perform(),
      error = function(e) e
    )

    if (inherits(resp, "condition")) {
      fails <- fails + 1L
      message(sprintf("  poll failed (%d/%d): %s",
                      fails, max_consecutive_failures, conditionMessage(resp)))
      if (fails >= max_consecutive_failures) {
        stop(sprintf(paste0(
          "Gave up polling after %d consecutive network failures.\n",
          "  THE BATCH IS UNAFFECTED and still running. Resume with:\n",
          "    --poll=%s"), fails, batch_id), call. = FALSE)
      }
      Sys.sleep(interval)
      next
    }

    if (httr2::resp_status(resp) >= 400L) {
      stop("Batch poll failed: ", httr2::resp_body_string(resp),
           "\n  Resume with --poll=", batch_id, call. = FALSE)
    }
    fails <- 0L
    b <- httr2::resp_body_json(resp)
    message(sprintf("  status=%s  succeeded=%s errored=%s processing=%s",
                    b$processing_status,
                    b$request_counts$succeeded  %||% 0,
                    b$request_counts$errored    %||% 0,
                    b$request_counts$processing %||% 0))
    if (identical(b$processing_status, "ended")) return(invisible(b))
    Sys.sleep(interval)
  }
}

# For when the batch id has scrolled off the terminal. Batches are listed
# newest first and results are retained for 29 days.
llm_batch_list <- function(auth = llm_auth(), limit = 20L) {
  resp <- llm_request(sprintf("/v1/messages/batches?limit=%d", limit), auth) |>
    httr2::req_timeout(60) |>
    httr2::req_retry(max_tries = 5L) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) >= 400L) {
    stop("Batch list failed: ", httr2::resp_body_string(resp), call. = FALSE)
  }
  b <- httr2::resp_body_json(resp)$data
  tibble::tibble(
    batch_id   = purrr::map_chr(b, "id"),
    status     = purrr::map_chr(b, "processing_status"),
    created_at = purrr::map_chr(b, ~ .x$created_at %||% NA_character_),
    succeeded  = purrr::map_int(b, ~ as.integer(.x$request_counts$succeeded  %||% 0L)),
    errored    = purrr::map_int(b, ~ as.integer(.x$request_counts$errored    %||% 0L)),
    processing = purrr::map_int(b, ~ as.integer(.x$request_counts$processing %||% 0L))
  )
}

llm_batch_results <- function(batch_id, items, parse, auth = llm_auth()) {
  # Results can be a large download; the same transient-failure logic as polling
  # applies, and losing it here would discard a batch that has already been paid
  # for. Results are retained for 29 days, so a retry is always safe.
  resp <- llm_request(paste0("/v1/messages/batches/", batch_id, "/results"), auth) |>
    httr2::req_timeout(300) |>
    httr2::req_retry(max_tries = 5L) |>
    httr2::req_perform()
  if (httr2::resp_status(resp) >= 400L) {
    stop("Batch results failed: ", httr2::resp_body_string(resp),
         "\n  Retry with --poll=", batch_id, call. = FALSE)
  }
  lines <- strsplit(httr2::resp_body_string(resp), "\n", fixed = TRUE)[[1L]]
  lines <- lines[nzchar(lines)]

  parsed <- purrr::map(lines, jsonlite::fromJSON, simplifyVector = FALSE)
  ids     <- vapply(parsed, function(r) r$custom_id %||% NA_character_, character(1))
  n_match <- sum(ids %in% items$key)

  # A batch whose results match NOTHING in the work list is not an empty batch —
  # it is the WRONG work list, and silence here throws away a batch that has
  # already been paid for.
  #
  # The poll branch rebuilds `items` from the command line, so a poll that omits
  # a flag the submission carried rebuilds a different work list and no
  # custom_id matches. Measured 2026-08-13: a 3,857-request singleton batch was
  # polled without --singletons, the work list came back as the 83 unrelated
  # multi-member blocks, and every result was dropped by the nrow(hit) == 0
  # branch below — reported as "wrote 0 rows ... (0 assigned, 0 failed)" and a
  # recorded spend, which reads like success.
  if (length(lines) && n_match == 0L) {
    stop(sprintf(paste0(
      "Batch %s returned %d results, NONE matching the current work list (%d items).\n",
      "  The work list is rebuilt from the command line, so re-run the poll with the\n",
      "  same flags as the submission — --singletons, --head-only, --only=, --model=.\n",
      "  Results are retained for 29 days, so nothing is lost."),
      batch_id, length(lines), nrow(items)), call. = FALSE)
  }
  if (n_match < length(lines)) {
    message(sprintf("  %d of %d results matched the work list, %d ignored",
                    n_match, length(lines), length(lines) - n_match))
  }

  purrr::map_dfr(parsed, function(r) {
    hit  <- items[items$key == r$custom_id, , drop = FALSE]
    if (nrow(hit) == 0L) return(tibble::tibble())
    parse(llm_result_to_outcome(r$result), hit, batch_id)
  })
}

# ── Content-addressed cache ───────────────────────────────────────────────────
# A run answers only keys that are absent, so re-running costs nothing and only
# genuinely new work reaches the API. Bumping the model or prompt version
# changes every key, which invalidates deliberately and shows up in the diff —
# a decision is only reproducible if you know what produced it.

llm_cache_read <- function(path, coltypes = NULL) {
  if (!file.exists(path)) return(NULL)
  readr::read_csv(path, show_col_types = FALSE, progress = FALSE,
                  col_types = coltypes %||% readr::cols(.default = readr::col_character()))
}

llm_cache_write <- function(x, path, sort_by = NULL) {
  if (!is.null(sort_by)) x <- dplyr::arrange(x, dplyr::across(dplyr::all_of(sort_by)))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp")
  readr::write_csv(x, tmp, na = "NA", eol = "\n")
  invisible(file.rename(tmp, path))
}

# Replace rather than append: a retry must overwrite the failed row for a key,
# not leave two rows for the same question.
#
# The type realignment is not optional. llm_cache_read() reads every column as
# character — it has to, because a cache column can be entirely NA on the first
# run and readr would guess it as logical — while fresh rows carry declared
# integer/numeric/logical types. bind_rows() refuses to combine those and the
# run dies AFTER the API calls have been paid for, which is the worst possible
# moment. Fresh rows are authoritative, so the cached side is coerced to match.
llm_cache_merge <- function(existing, fresh, key_col = "cache_key") {
  if (is.null(existing) || nrow(existing) == 0L) return(fresh)
  keep <- existing[!existing[[key_col]] %in% fresh[[key_col]], , drop = FALSE]
  if (nrow(keep) == 0L) return(fresh)

  for (nm in intersect(names(keep), names(fresh))) {
    target <- class(fresh[[nm]])[[1L]]
    if (identical(class(keep[[nm]])[[1L]], target)) next
    keep[[nm]] <- suppressWarnings(switch(
      target,
      integer   = as.integer(keep[[nm]]),
      numeric   = as.numeric(keep[[nm]]),
      double    = as.numeric(keep[[nm]]),
      logical   = as.logical(keep[[nm]]),
      character = as.character(keep[[nm]]),
      keep[[nm]]
    ))
  }
  dplyr::bind_rows(keep, fresh)
}
