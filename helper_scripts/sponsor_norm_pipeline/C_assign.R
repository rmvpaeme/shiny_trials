#!/usr/bin/env Rscript
# Pass C — assign every remaining raw string to a registry entity.
#
# The model PICKS FROM A LIST. It never writes a name: it returns an integer
# index into that row's candidates, and R bounds-checks it on receipt. A model
# that can only choose cannot introduce a spelling, drift a canonical, or invent
# an organisation — the same guarantee an enum would give, without a per-row
# grammar. See client.R for why that distinction is load-bearing.
#
# Index 0 means "none of these". Abstentions are not failures; they are the
# signal that an entity is missing from the registry, and they feed the next
# minting round.
#
# THE ROUND-2 RE-BLOCK. A string whose only lexical neighbours are themselves
# unassigned has nothing in the registry to match, so it abstains, and if the
# next mint round re-blocks it identically it abstains again forever. Measured
# on this corpus that is ~316 strings. On round 2 and later, abstainers are
# re-blocked at a LOWER threshold: by then the registry exists, so a permissive
# group costs little — the model is deciding, not the threshold.
#
# Usage
#   Rscript .../C_assign.R --dry-run
#   Rscript .../C_assign.R --sync --limit=200      # THE SCALE GATE: run this
#                                                  # before any full batch
#   Rscript .../C_assign.R --batch
#   Rscript .../C_assign.R --batch --poll=<id>
#   Rscript .../C_assign.R --dry-run --full-registry --gold-only
#
# --full-registry puts every canonical in the cached prefix instead of
# retrieving ten. It removes retrieval recall as a failure mode and costs
# 4-40x more; the budget guard permits it on a subset and refuses it on the
# full corpus, which is the intended use — settle the design by running both on
# the same strings and diffing, not by argument.
#
# --gold-only restricts to the frozen sample in tests/gold/fixtures. Those cases
# are a stratified draw across trial-count band, register, text form and the
# known adversarial families, which makes them a good cheap subset for exactly
# that A/B. They do NOT need to be adjudicated for this purpose — you are
# comparing two candidate sources against each other, not against truth.

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(purrr); library(jsonlite)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "client.R"))
source(pp("helper_scripts", "llm_norm", "retrieve.R"))
source(pp("helper_scripts", "llm_norm", "registry.R"))

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
dry_run       <- "--dry-run"       %in% args
do_sync       <- "--sync"          %in% args
do_batch      <- "--batch"         %in% args
full_registry <- "--full-registry" %in% args
gold_only     <- "--gold-only"     %in% args
limit      <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch <- arg_value("--poll")
round_no   <- suppressWarnings(as.integer(arg_value("--round", "1")))

if (!dry_run && !do_sync && !do_batch && is.na(poll_batch)) {
  stop("Pick a mode: --dry-run, --sync, --batch, or --batch --poll=<id>", call. = FALSE)
}

MODEL_ID       <- arg_value("--model", "claude-sonnet-5")
PROMPT_VERSION <- "sponsor-assign-v1"
MAX_TOKENS     <- 2048L
MAX_CANDIDATES <- 10L

# SPONSOR_V2_DIR relocates the mutable registry state. Default unchanged, so
# local and manual runs behave exactly as before. On the nightly server it points
# outside the git work tree, because the deploy script runs
# `git reset --hard origin/main` at the START of every run — anything the nightly
# writes under config/ would be discarded before the next one, so the same
# strings would be re-sent to the API every night and llm_spend.csv would reset,
# leaving the budget cap permanently unreachable.
V2         <- Sys.getenv("SPONSOR_V2_DIR", unset = pp("config", "sponsor_norm_v2"))
MINT_PATH  <- file.path(V2, "B_mint_clusters.csv")
REG_PATH   <- file.path(V2, "registry.csv")
ASG_PATH   <- file.path(V2, "assignments.csv")
CACHE_PATH <- file.path(V2, "C_assign_decisions.csv")
SPEND_PATH <- file.path(V2, "llm_spend.csv")
# --blocks= lets the nightly hand in its own singleton work list without
# touching data/sponsor_blocks.csv, which is B_mint's members_sha cache-key
# input: re-blocking the frozen corpus would trigger paid re-mints of unrelated
# blocks.
BLOCKS_PATH <- arg_value("--blocks", pp("data", "sponsor_blocks.csv"))

# ── Schema: ONE grammar for the whole pass ────────────────────────────────────

ASSIGN_SCHEMA <- list(
  type = "object",
  additionalProperties = FALSE,
  required = list("chosen_index", "confidence", "reason"),
  properties = list(
    chosen_index = list(type = "integer"),
    confidence   = list(type = "number"),
    reason       = list(type = "string")
  )
)

SYSTEM_PROMPT <- paste(
  "You match a raw clinical-trial sponsor string to one organisation from a numbered list.",
  "",
  "Reply with the NUMBER of the matching organisation, or 0 if none of them is the",
  "same organisation as the raw string. Never invent a name; you can only choose.",
  "",
  "The raw string comes from an EU trial registry. It may be a department, a clinic,",
  "a subsidiary, an abbreviation, a misspelling, or a person's name attached to an",
  "institution. Some strings have had accented characters DELETED by the source",
  "registry, so 'Universitatsklinikum Munchen' may appear as 'Universittsklinikum",
  "Mnchen' and 'Charite' as 'Charit'. Treat those as the intact spelling.",
  "",
  "RULES",
  "",
  "1. A department, clinic, ward or laboratory matches its PARENT institution.",
  "   'Abteilung fur Augenheilkunde, AKH Linz' matches 'Kepler Universitatsklinikum'.",
  "",
  "2. A university and its university hospital are DIFFERENT organisations.",
  "   Do not match 'Universitat Basel' to 'Universitatsspital Basel'.",
  "",
  "3. MSD / Merck Sharp & Dohme (US) and Merck KGaA (Darmstadt) are DIFFERENT companies.",
  "",
  "4. A subsidiary matches its own entry if one exists, otherwise answer 0 —",
  "   do NOT match it to the parent group unless the list has no better option",
  "   and you are confident they are operationally the same sponsor.",
  "",
  "5. If the raw string is ONLY a person's name with no institution, answer 0.",
  "",
  "ANSWER 0 WHENEVER YOU ARE NOT SURE. A wrong match silently mislabels every trial",
  "for that sponsor; a 0 just sends the string to be reviewed. 0 is the safe answer.",
  "",
  "confidence is 0-1 and describes how sure you are of the number you chose",
  "(including when you choose 0).",
  sep = "\n"
)

candidate_content <- function(raw, cands) {
  lines <- sprintf("%d. %s%s", seq_len(nrow(cands)), cands$label,
                   ifelse(is.na(cands$parent) | !nzchar(cands$parent), "",
                          sprintf("  (part of %s)", cands$parent)))
  list(list(type = "text", text = paste0(
    "Raw sponsor string:\n  ", raw,
    "\n\nCandidate organisations:\n", paste(lines, collapse = "\n"),
    "\n\nWhich number is the same organisation? 0 if none."
  )))
}

# ── Registry ──────────────────────────────────────────────────────────────────

if (!file.exists(MINT_PATH)) stop("Run B_mint.R first — no clusters at ", MINT_PATH, call. = FALSE)

clusters <- read_csv(MINT_PATH, show_col_types = FALSE, progress = FALSE)

# Keep only the newest mint prompt version present. Bumping PROMPT_VERSION in
# B_mint changes cache KEYS, so a re-mint appends rather than replaces and the
# file ends up holding two generations at once. Materialising both would put two
# granularities in one registry — v1 minted "Novartis Farma S.p.A." as its own
# entity, v2 rolls it into "Novartis" — and the mixture is silent.
if ("prompt_version" %in% names(clusters) && nrow(clusters)) {
  versions <- sort(unique(stats::na.omit(clusters$prompt_version)))
  if (length(versions) > 1L) {
    newest <- versions[[length(versions)]]
    dropped <- sum(clusters$prompt_version != newest, na.rm = TRUE)
    message(sprintf("mint cache holds %d prompt versions (%s); using %s and ignoring %d older rows",
                    length(versions), paste(versions, collapse = ", "), newest, dropped))
    clusters <- clusters |> filter(prompt_version == newest)
  }
}
built <- registry_from_clusters(clusters, registry_read(REG_PATH), assignments_read(ASG_PATH))
registry_write(built$registry, REG_PATH)
assignments_write(built$assignments, ASG_PATH)
reg <- built$registry
asg <- built$assignments

live <- registry_live(reg)
message(sprintf("registry: %d live entities, %d assignments so far",
                nrow(live), nrow(asg)))
if (!nrow(live)) stop("Registry is empty — B_mint.R produced no clusters.", call. = FALSE)

# ── Work list ─────────────────────────────────────────────────────────────────

blocks <- read_csv(BLOCKS_PATH, show_col_types = FALSE, progress = FALSE)
todo <- blocks |>
  distinct(raw_sponsor, n_trials) |>
  filter(!raw_sponsor %in% asg$raw_sponsor) |>
  arrange(desc(n_trials))

if (gold_only) {
  gold_path <- pp("tests", "gold", "fixtures", "sponsor_gold_v1_cases_round1.csv")
  if (!file.exists(gold_path)) stop("No gold fixture at ", gold_path, call. = FALSE)
  gold <- read_csv(gold_path, show_col_types = FALSE, progress = FALSE)
  todo <- todo |> filter(raw_sponsor %in% gold$raw_sponsor)
  message(sprintf("--gold-only: restricted to %d of the %d frozen sample cases",
                  nrow(todo), nrow(gold)))
}

message(sprintf("strings to assign: %d", nrow(todo)))
if (!nrow(todo)) { message("Nothing to assign."); quit(save = "no", status = 0L) }

# ── Candidates ────────────────────────────────────────────────────────────────

surface <- registry_surface_forms(reg, asg)
idx <- build_index(surface$label, ids = match(surface$entity_id, live$entity_id))

ev_path <- pp("data", "sponsor_structured_evidence.csv")
evidence <- if (file.exists(ev_path)) {
  read_csv(ev_path, show_col_types = FALSE, progress = FALSE)
} else NULL

# Round 2+ widens retrieval rather than the blocking threshold: by now the
# registry exists, so a weak candidate is a question for the model, not a merge.
min_score <- if (round_no >= 2L) 0.05 else 0.15

message(sprintf("building candidates (%s, min_score %.2f)...",
                if (full_registry) "FULL REGISTRY" else "retrieval", min_score))

cand_for <- function(raw) {
  if (full_registry) {
    return(live |> transmute(entity_id, label = canonical, parent, score = NA_real_,
                             channel = "full_registry"))
  }
  hits <- retrieve(raw, idx, evidence = evidence, k = MAX_CANDIDATES)
  if (!nrow(hits)) return(tibble::tibble())
  hits |>
    mutate(entity_id = live$entity_id[label_id]) |>
    left_join(live |> select(entity_id, canonical, parent), by = "entity_id") |>
    transmute(entity_id, label = canonical, parent, score, channel) |>
    distinct(entity_id, .keep_all = TRUE)
}

work <- todo |>
  mutate(cands = purrr::map(raw_sponsor, cand_for)) |>
  mutate(n_cands = purrr::map_int(cands, nrow))

# A string with no candidate at all cannot be asked anything useful — asking
# costs a request to receive a guaranteed 0. Record the abstention directly.
no_cands <- work |> filter(n_cands == 0L)
work     <- work |> filter(n_cands > 0L)
message(sprintf("  %d strings have candidates, %d have none (auto-abstain)",
                nrow(work), nrow(no_cands)))

cache <- llm_cache_read(CACHE_PATH)
work <- work |>
  mutate(
    cands_sha = purrr::map_chr(cands, ~ sha256_hex(paste(.x$entity_id, collapse = "\n"))),
    key       = purrr::map2_chr(raw_sponsor, cands_sha,
                                ~ llm_cache_key(.x, PROMPT_VERSION, MODEL_ID, .y))
  )
done <- if (is.null(cache)) character() else unique(cache$cache_key[!is.na(cache$chosen_index)])
work <- work |> filter(!key %in% done)
if (!is.na(limit) && limit > 0L) work <- head(work, limit)
message(sprintf("  %d to ask (%d already cached)", nrow(work), length(done)))
if (!nrow(work)) { message("Nothing to ask."); quit(save = "no", status = 0L) }

work <- work |>
  mutate(content = purrr::map2(raw_sponsor, cands, candidate_content))

# ── Parse ─────────────────────────────────────────────────────────────────────
# Independent of output_config.format. If the schema ever fails to constrain,
# an out-of-range index stops here rather than becoming a wrong label.

parse_choice <- function(outcome, item, batch_id = NA_character_) {
  cands <- item$cands[[1L]]
  base <- tibble::tibble(
    cache_key = item$key[[1L]], raw_sponsor = item$raw_sponsor[[1L]],
    model_id = MODEL_ID, prompt_version = PROMPT_VERSION,
    candidates_sha256 = item$cands_sha[[1L]], n_candidates = nrow(cands),
    chosen_index = NA_integer_, entity_id = NA_character_, confidence = NA_real_,
    channel = NA_character_, reason = NA_character_,
    decided_at_utc = utc_now(), batch_id = batch_id
  )
  if (!outcome$ok) { base$reason <- outcome$error; return(base) }

  i <- suppressWarnings(as.integer(outcome$value$chosen_index))
  if (length(i) != 1L || is.na(i)) { base$reason <- "no chosen_index"; return(base) }
  if (i < 0L || i > nrow(cands)) {
    base$reason <- sprintf("index %d out of range 0..%d", i, nrow(cands))
    return(base)
  }
  base$chosen_index <- i
  base$confidence   <- suppressWarnings(as.numeric(outcome$value$confidence %||% NA_real_))
  base$reason       <- outcome$value$reason %||% NA_character_
  if (i > 0L) {
    base$entity_id <- cands$entity_id[[i]]
    base$channel   <- cands$channel[[i]]
  }
  base
}

CACHE_COLS <- c("cache_key", "raw_sponsor", "model_id", "prompt_version",
                "candidates_sha256", "n_candidates", "chosen_index", "entity_id",
                "confidence", "channel", "reason", "decided_at_utc", "batch_id")

save_rows <- function(rows) {
  merged <- llm_cache_merge(cache, rows, key_col = "cache_key")
  llm_cache_write(merged[, CACHE_COLS], CACHE_PATH, sort_by = "raw_sponsor")

  matched   <- sum(!is.na(rows$entity_id))
  abstained <- sum(rows$chosen_index %in% 0L)
  failed    <- sum(is.na(rows$chosen_index))
  message(sprintf("wrote %d rows (%d matched, %d abstained, %d failed)",
                  nrow(rows), matched, abstained, failed))

  ok <- rows |> filter(!is.na(entity_id))
  if (nrow(ok)) {
    new_asg <- ok |>
      transmute(raw_sponsor, entity_id, confidence, channel, reason,
                decided_by = "model", decided_at_utc, model_id, prompt_version)
    cur <- assignments_read(ASG_PATH)
    pinned <- cur |> filter(decided_by %in% "human")
    keep   <- cur |> filter(!decided_by %in% "human",
                            !raw_sponsor %in% new_asg$raw_sponsor)
    new_asg <- new_asg |> filter(!raw_sponsor %in% pinned$raw_sponsor)
    assignments_write(bind_rows(pinned, keep, new_asg), ASG_PATH)
    message(sprintf("  assignments now %d", nrow(pinned) + nrow(keep) + nrow(new_asg)))
  }

  # Abstentions are the input to the next mint round, not an error.
  ab <- bind_rows(
    rows |> filter(chosen_index %in% 0L) |> select(raw_sponsor),
    no_cands |> select(raw_sponsor)
  ) |> distinct()
  if (nrow(ab)) {
    ab_path <- file.path(V2, "C_abstained.csv")
    write_csv(ab, ab_path, na = "", eol = "\n")
    message(sprintf("  %d abstentions -> %s", nrow(ab), basename(ab_path)))
    message("  re-block these at a lower threshold and mint them:")
    message("    Rscript .../A_block.R --threshold=0.30 --only=config/sponsor_norm_v2/C_abstained.csv")
  }
}

# ── Modes ─────────────────────────────────────────────────────────────────────

spec <- llm_spec(model = MODEL_ID, prompt_version = PROMPT_VERSION,
                 system_prompt = SYSTEM_PROMPT, schema = ASSIGN_SCHEMA,
                 effort = "low", max_tokens = MAX_TOKENS)

if (dry_run) {
  est <- llm_dry_run(
    spec, work,
    label = paste0("C_assign", if (full_registry) " --full-registry" else "",
                   " / ", MODEL_ID),
    spend_path = SPEND_PATH)
  if (full_registry) {
    cat("\nNOTE: --full-registry puts all ", nrow(live), " canonicals in every request.\n", sep = "")
    cat("      Affordable on a subset, not on the full corpus. The budget\n")
    cat("      guard below is what decides, not this note.\n")
  }
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, "C_assign")
  quit(save = "no", status = 0L)
}

auth <- llm_auth()

if (do_sync) {
  # Sync bills at full rate and used to be entirely unmetered — guard before,
  # record after, exactly as the batch path does.
  est <- llm_dry_run(spec, work, label = paste("C_assign /", MODEL_ID),
                     spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_sync %||% est$est_cost_batch, SPEND_PATH, "C_assign")
  rows <- llm_sync(spec, work, parse = function(o, it) parse_choice(o, it), auth = auth)
  save_rows(rows)
  llm_spend_record_sync(SPEND_PATH, "C_assign", MODEL_ID, rows)
  message(sprintf("recorded sync spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  cat("\nSCALE GATE: check for 'grammar compilation rate limit' above. There should\n")
  cat("be none — the schema is constant. If any appear, do NOT submit the batch.\n")
  quit(save = "no", status = 0L)
}

if (!is.na(poll_batch)) {
  llm_batch_wait(poll_batch, auth)
  rows <- llm_batch_results(poll_batch, work, parse = parse_choice, auth = auth)
  save_rows(rows)
  u <- llm_batch_usage(poll_batch, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "C_assign", poll_batch, MODEL_ID, u$input, u$output, u$cache_read,
                     n_requests = u$n %||% nrow(work))
    message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  }
  quit(save = "no", status = 0L)
}

est <- llm_dry_run(spec, work, label = paste("C_assign /", MODEL_ID),
                   spend_path = SPEND_PATH)
llm_budget_guard(est$est_cost_batch, SPEND_PATH, "C_assign")
bid  <- llm_batch_submit(spec, work, auth)
llm_batch_wait(bid, auth)
rows <- llm_batch_results(bid, work, parse = parse_choice, auth = auth)
save_rows(rows)
u <- llm_batch_usage(bid, auth)
if (!is.null(u)) {
  llm_spend_record(SPEND_PATH, "C_assign", bid, MODEL_ID, u$input, u$output, u$cache_read,
                     n_requests = u$n %||% nrow(work))
  message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
}
message("Assigned. Nothing applied to any label — E_emit.R does that.")
