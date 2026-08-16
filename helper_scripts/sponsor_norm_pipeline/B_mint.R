#!/usr/bin/env Rscript
# Pass B — mint canonical names, one block at a time.
#
# The block is the unit, not the string. A block's variants go into ONE request
# so the model names each cluster once with every variant visible; that is what
# stops "UZ Gent", "Ghent University Hospital" and "Universitair Ziekenhuis
# Gent" becoming three canonicals. Naming strings independently and reconciling
# afterwards is the failure mode the old 2,000-line rule layer existed to clean
# up after.
#
# The model may split a block. Blocking is recall-oriented and deliberately
# over-groups, so "Universität Basel" and "Universitätsspital Basel" can land
# together; the model is told to return them as two clusters. Every string must
# appear in exactly one cluster, and R checks that on receipt.
#
# COST SPLIT. Opus 5 on the highest-impact blocks, Sonnet 5 on the rest. Naming
# is the one judgement in the pipeline that is hard to undo — a drifted
# canonical propagates to every string later assigned to it — so the blocks
# carrying most trials get the better model, and the long tail of 2-member
# punctuation-variant blocks does not need it.
#
# SINGLETONS ARE A SEPARATE RUN. By default this pass mints multi-member blocks
# only. One-member blocks need --singletons, because without them pass C has no
# registry entry to match and can only abstain — see the work-list section for
# the measurement that forced this.
#
# Usage
#   Rscript .../B_mint.R --dry-run
#   Rscript .../B_mint.R --sync --limit=5        # prompt iteration
#   Rscript .../B_mint.R --batch                 # full run
#   Rscript .../B_mint.R --batch --poll=<id>
#   Rscript .../B_mint.R --batch --head-only     # top blocks (Opus 5) only
#   Rscript .../B_mint.R --sync --singletons --limit=20      # gate it first
#   Rscript .../B_mint.R --batch --singletons \
#     --only=config/sponsor_norm_v2/C_abstained.csv          # only what C could not place

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
source(pp("helper_scripts", "llm_norm", "registry.R"))

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
dry_run   <- "--dry-run"   %in% args
do_sync   <- "--sync"      %in% args
do_batch  <- "--batch"     %in% args
head_only <- "--head-only" %in% args
singletons <- "--singletons" %in% args
retry_failed <- "--retry-failed" %in% args
limit      <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch <- arg_value("--poll")
only_path  <- arg_value("--only")
model_override <- arg_value("--model")

# --model rewrites the model for EVERY block in the work list, and the model is
# part of the cache key — so on an unrestricted run it invalidates all 2,900
# cached blocks and re-mints the entire corpus at the new price. Refuse that
# outright; it is only ever wanted alongside a restricting flag.
if (!is.na(model_override) && !retry_failed && is.na(only_path) &&
    (is.na(limit) || limit <= 0L)) {
  stop("--model changes the cache key for every block, which would re-mint the\n",
       "  whole corpus. Combine it with --retry-failed, --only= or --limit=.",
       call. = FALSE)
}

if (!dry_run && !do_sync && !do_batch && is.na(poll_batch)) {
  stop("Pick a mode: --dry-run, --sync, --batch, or --batch --poll=<id>", call. = FALSE)
}

# ── Pinned identity ───────────────────────────────────────────────────────────

# v2: canonical is the GROUP/BRAND, not the legal entity.
#
# v1 asked for the legal entity and set `parent` on subsidiaries. Measured on
# the first 499 blocks that produced 1,563 entities — 28 canonicals for
# Novartis, 21 for Sanofi, 14 each for Pfizer/Roche/Janssen — because a family
# spread over ten blocks gets named ten times, and cluster-at-a-time only
# prevents drift WITHIN a block. D_consolidate could not repair it: its prompt
# correctly refuses to merge a parent with a subsidiary, so the split survived
# by design.
#
# app.R displays sponsor_clean in the Top Sponsors chart and the sponsor filter,
# and the old pipeline collapsed all 87 Novartis strings to "Novartis". So the
# canonical must be the brand. legal_entity keeps the detail v1 was capturing,
# which is strictly more than the old pipeline retained.
#
# Bumping the version invalidates every v1 cache key, which is the point: the
# two granularities must not mix in one registry.
PROMPT_VERSION <- "sponsor-mint-v2"
HEAD_MODEL     <- "claude-opus-5"
TAIL_MODEL     <- "claude-sonnet-5"
HEAD_BLOCKS    <- 500L    # by trial impact; ~63% of all trial rows
MAX_TOKENS     <- 8192L   # covers thinking plus the JSON for a 40-member block

# See C_assign.R for why SPONSOR_V2_DIR and --blocks exist. Defaults unchanged.
V2_DIR        <- Sys.getenv("SPONSOR_V2_DIR", unset = pp("config", "sponsor_norm_v2"))
BLOCKS_PATH   <- arg_value("--blocks", pp("data", "sponsor_blocks.csv"))
CACHE_PATH    <- file.path(V2_DIR, "B_mint_clusters.csv")
SPEND_PATH    <- file.path(V2_DIR, "llm_spend.csv")

if (!file.exists(BLOCKS_PATH)) stop("Run A_block.R first.", call. = FALSE)

# ── Schema: ONE grammar for the whole pass ────────────────────────────────────
# member_index refers to the numbered list in the request; it is an integer, not
# an enum of that block's strings, so every request compiles the same grammar.
# A per-row enum is what cost 190 of 222 requests in 5_llm_resolve.R.

MINT_SCHEMA <- list(
  type = "object",
  additionalProperties = FALSE,
  required = list("clusters"),
  properties = list(
    clusters = list(
      type = "array",
      items = list(
        type = "object",
        additionalProperties = FALSE,
        required = list("canonical", "member_indices", "entity_type", "confidence"),
        properties = list(
          canonical      = list(type = "string"),
          legal_entity   = list(type = "string"),
          parent         = list(type = "string"),
          entity_type    = list(type = "string", enum = list(
            "industry", "academic", "hospital", "cooperative_group", "foundation",
            "public_body", "charity", "network", "individual", "unknown")),
          member_indices = list(type = "array", items = list(type = "integer")),
          confidence     = list(type = "number"),
          reason         = list(type = "string")
        )
      )
    )
  )
)

# ── Prompt ────────────────────────────────────────────────────────────────────
# Constant across every request, so it is the cache breakpoint. The four rules
# are the domain knowledge worth keeping from the old pipeline's README — they
# encode distinctions the corpus genuinely contains and a model will otherwise
# collapse.

SYSTEM_PROMPT <- paste(
  "You group variant names of clinical-trial sponsors and give each group one canonical name.",
  "",
  "You receive a numbered list of raw sponsor strings drawn from EU trial registries.",
  "They were grouped by a text-similarity step that favours recall, so the list may",
  "contain more than one organisation. Split it into clusters, one per organisation.",
  "",
  "RULES",
  "",
  "1. A university and its university hospital are DIFFERENT organisations.",
  "   'Universitat Basel' and 'Universitatsspital Basel' are two clusters.",
  "   The same holds for a faculty and its teaching hospital.",
  "",
  "2. MSD / Merck Sharp & Dohme (US) and Merck KGaA (Darmstadt) are DIFFERENT companies.",
  "   Never merge them. 'Merck & Co.' is the US one; 'Merck KGaA' and 'Merck Serono' are German.",
  "",
  "3. A department, clinic, ward or laboratory resolves to its PARENT institution.",
  "   'Abteilung fur Augenheilkunde, AKH Linz' has canonical 'Kepler Universitatsklinikum',",
  "   not the department. Never make a department the canonical.",
  "",
  "4. A named person is not an organisation. If a string is a person and an institution",
  "   ('Prof. Dr. Milos Opravil, Universitatsspital Zurich'), cluster it with the institution.",
  "   If a string is ONLY a person, give it its own cluster with entity_type 'individual'.",
  "",
  "CANONICAL NAME — THE BRAND, NOT THE LEGAL ENTITY",
  "",
  "This is the single most important instruction. 'canonical' is the name a reader",
  "would recognise on a chart of trial sponsors: the GROUP or BRAND, not the",
  "national subsidiary or legal entity.",
  "",
  "  'Novartis Pharma AG'                      -> canonical 'Novartis'",
  "  'Novartis Farma S.p.A.'                   -> canonical 'Novartis'",
  "  'Novartis Vaccines and Diagnostics GmbH'  -> canonical 'Novartis'",
  "  'Sanofi-Aventis Deutschland GmbH'         -> canonical 'Sanofi'",
  "  'F. Hoffmann-La Roche Ltd'                -> canonical 'Roche'",
  "  'Janssen-Cilag International NV'          -> canonical 'Janssen'",
  "",
  "Put the specific entity in 'legal_entity' instead, verbatim enough to identify it",
  "('Novartis Farma S.p.A.'). Leave legal_entity empty when the cluster is already",
  "just the brand.",
  "",
  "So: national subsidiaries, divisions and legal variants of ONE company belong in",
  "ONE cluster with ONE canonical. Do not split them.",
  "",
  "- Drop legal suffixes (AG, GmbH, Ltd, S.A., S.p.A., S.r.l., S.A.S., A/S, NV, BV,",
  "  Inc, PLC, AoR, KGaA) from the canonical. ALWAYS. The suffix belongs in",
  "  legal_entity, never in canonical.",
  "- Drop addresses, postcodes, countries, and department names.",
  "- Do NOT invent an English translation. 'Hospices Civils de Lyon' stays as it is.",
  "",
  "EXCEPTIONS — these DO get their own cluster and their own canonical:",
  "",
  "- A company with its own established brand identity, even when owned by a larger",
  "  group: Genentech (Roche), Genzyme (Sanofi), MedImmune (AstraZeneca),",
  "  Sandoz (Novartis). Set 'parent' to the owning group.",
  "- An acquisition that still trades under its own name in these trials.",
  "- Hospitals and universities: these are NOT brands. Keep each institution",
  "  separate — 'Universitatsklinikum Koln' and 'Universitatsklinikum Bonn' are two",
  "  organisations, and neither rolls up to anything.",
  "",
  "The brand rule is about COMMERCIAL groups. For academic and public bodies, the",
  "institution itself is the canonical.",
  "",
  "IMPORTANT: some strings have had accented characters DELETED by the source registry,",
  "so 'Universitatsklinikum Munchen' may appear as 'Universittsklinikum Mnchen' and",
  "'Charite' as 'Charit'. Treat these as the same organisation as their intact spelling,",
  "and give the canonical its CORRECT spelling with accents restored.",
  "",
  "OUTPUT",
  "",
  "- Every member index must appear in exactly one cluster. Do not omit or repeat one.",
  "- confidence is 0-1: how sure you are the cluster is one organisation with that name.",
  "- Use confidence below 0.7 when the strings are too vague to identify.",
  sep = "\n"
)

block_content <- function(members) {
  lines <- sprintf("%d. %s  [%d trial%s]",
                   seq_len(nrow(members)), members$raw_sponsor,
                   members$n_trials, ifelse(members$n_trials == 1L, "", "s"))
  # A one-string block is still one cluster covering member index 1, so the
  # schema and the parser are untouched. Only the framing changes: "group these
  # 1 sponsor strings" invites the model to look for a split that cannot exist.
  head_line <- if (nrow(members) == 1L) {
    paste0("Name the organisation behind this sponsor string.\n",
           "It is the only string in its group, so return exactly one cluster ",
           "containing member 1.\n\n")
  } else {
    paste0("Group these ", nrow(members), " sponsor strings.\n\n")
  }
  list(list(type = "text", text = paste0(head_line, paste(lines, collapse = "\n"))))
}

# ── Work list ─────────────────────────────────────────────────────────────────

blocks <- read_csv(BLOCKS_PATH, show_col_types = FALSE, progress = FALSE)

# --singletons mints the one-member blocks, which the default run excludes.
#
# WHY THEY MUST BE MINTED. A singleton has no lexical neighbour above the
# blocking threshold, so it is never minted, so no registry entry exists for it,
# so pass C can only abstain — forever. Measured on the first 200-request C gate:
# 147 abstentions, 120 of them singleton-block strings, with the model correctly
# reporting "not listed among the candidates". 3,837 of the 4,084 unassigned
# strings are in this state. The round-2 re-block at a lower threshold does not
# reach them: a string with no neighbour at 0.50 has none at 0.30 either, and
# grouping it with noise would mint a WRONG canonical, which is worse than none.
#
# A singleton is simply its own organisation, and the existing prompt already
# does the right thing with one string: rule 3 resolves a department to its
# parent institution, so 'Abteilung fur Augenheilkunde, AKH Linz' mints as
# 'Kepler Universitatsklinikum' — the same canonical the parent already has.
# That is what rescues the case retrieval cannot reach: a sub-unit sharing no
# token with its parent gets the parent's NAME from the model's own knowledge,
# and the exact-canonical collapse in registry_from_clusters folds the two
# together for free. No second prompt, no second schema, one grammar.
if (singletons) {
  blocks <- blocks |> filter(block_size == 1L)
} else {
  blocks <- blocks |> filter(block_size > 1L)
}

# --only=<csv with a raw_sponsor column> narrows to specific strings, so the
# abstainers from a C pass can be minted without re-minting the whole tail.
if (!is.na(only_path)) {
  keep <- read_csv(only_path, show_col_types = FALSE, progress = FALSE)
  if (!"raw_sponsor" %in% names(keep)) {
    stop("--only file needs a raw_sponsor column: ", only_path, call. = FALSE)
  }
  before <- nrow(blocks)
  blocks <- blocks |> filter(raw_sponsor %in% keep$raw_sponsor)
  message(sprintf("--only: %d of %d strings kept (%d in the file)",
                  nrow(blocks), before, nrow(keep)))
}

if (!nrow(blocks)) { message("No blocks match this selection."); quit(save = "no", status = 0L) }

impact <- blocks |>
  group_by(block_id) |>
  summarise(trials = sum(n_trials), size = dplyr::n(), .groups = "drop") |>
  arrange(desc(trials))

# --retry-failed re-mints only the blocks already in the cache with canonical=NA.
#
# Those are the blocks where the model returned a member_index outside the block
# it was sent — R rejected the response rather than storing a wrong cluster. They
# retry on any run, but at the SAME model, which is the problem: measured on the
# v2 mint, Sonnet failed 83 of ~2,431 blocks (3.4%) and Opus 1 of ~500 (0.2%),
# and 40 of the 84 failures were TWO-member blocks answered with an index above
# 2. Retrying Sonnet on a prompt Sonnet already mishandled mostly reproduces it.
#
# This matters more than 84 blocks suggests: they were the ONLY thing left
# unassigned after the singleton mint — 165 strings, 256 trial rows, and all 177
# `accepted -> unknown` regressions in the E_emit gate.
if (retry_failed) {
  prior <- llm_cache_read(CACHE_PATH)
  if (is.null(prior)) stop("--retry-failed: no cache at ", CACHE_PATH, call. = FALSE)
  bad <- prior |> filter(is.na(canonical)) |> distinct(block_id) |> pull(block_id)
  impact <- impact |> filter(block_id %in% bad)
  message(sprintf("--retry-failed: %d block(s) previously failed to mint", nrow(impact)))
  if (!nrow(impact)) { message("Nothing to retry."); quit(save = "no", status = 0L) }
}

# Singletons are one string each and carry a median of 1 trial, so the Opus head
# buys nothing there — route the whole selection to the cheap model.
impact$model <- if (!is.na(model_override)) model_override else if (singletons) TAIL_MODEL else {
  ifelse(seq_len(nrow(impact)) <= HEAD_BLOCKS, HEAD_MODEL, TAIL_MODEL)
}
if (head_only) impact <- impact |> filter(model == HEAD_MODEL)

# cache_key covers the block's exact membership, so re-blocking with different
# thresholds re-mints only the blocks that actually changed.
work <- impact |>
  rowwise() |>
  mutate(members_sha = sha256_hex(paste(sort(blocks$raw_sponsor[blocks$block_id == block_id]),
                                        collapse = "\n"))) |>
  ungroup() |>
  mutate(key = purrr::map2_chr(members_sha, model, ~ llm_cache_key(.x, PROMPT_VERSION, .y)))

cache <- llm_cache_read(CACHE_PATH)
done  <- if (is.null(cache)) character() else unique(cache$cache_key[!is.na(cache$canonical)])
work  <- work |> filter(!key %in% done)
if (!is.na(limit) && limit > 0L) work <- head(work, limit)

message(sprintf("blocks to mint: %d (%d already cached)",
                nrow(work), length(done)))
if (nrow(work) == 0L) { message("Nothing to mint."); quit(save = "no", status = 0L) }

work <- work |>
  mutate(content = purrr::map(block_id, ~ block_content(
    blocks |> filter(block_id == .x) |> arrange(desc(n_trials))
  )))

# ── Parse ─────────────────────────────────────────────────────────────────────
# The model returns member INDICES; R validates them against the block it was
# actually sent. An index outside range, a duplicate, or a missing member is a
# rejected response, not a silently wrong cluster.

parse_clusters <- function(outcome, item, batch_id = NA_character_, members = NULL) {
  # `members` is injectable so the validation can be tested without a corpus or
  # a network call; in normal use it is looked up from the block table.
  if (is.null(members)) {
    members <- blocks |> filter(block_id == item$block_id[[1L]]) |> arrange(desc(n_trials))
  }
  fail <- function(msg) tibble::tibble(
    cache_key = item$key[[1L]], block_id = item$block_id[[1L]], model_id = item$model[[1L]],
    prompt_version = PROMPT_VERSION, cluster_no = NA_integer_, canonical = NA_character_,
    legal_entity = NA_character_,
    parent = NA_character_, entity_type = NA_character_, raw_sponsor = NA_character_,
    confidence = NA_real_, reason = msg, decided_at_utc = utc_now(), batch_id = batch_id
  )
  if (!outcome$ok) return(fail(outcome$error))

  cl <- outcome$value$clusters
  if (is.null(cl) || (is.data.frame(cl) && !nrow(cl)) || (!is.data.frame(cl) && !length(cl))) {
    return(fail("no clusters returned"))
  }
  # jsonlite simplifies an array of objects to a data.frame; normalise to a list
  # so both shapes are handled without branching further down.
  if (is.data.frame(cl)) cl <- purrr::transpose(as.list(cl))

  idx_all <- unlist(purrr::map(cl, ~ as.integer(unlist(.x$member_indices))), use.names = FALSE)
  if (anyNA(idx_all)) return(fail("non-integer member index"))
  if (any(idx_all < 1L | idx_all > nrow(members))) {
    return(fail(sprintf("member index out of range 1..%d", nrow(members))))
  }
  if (anyDuplicated(idx_all)) return(fail("a member appears in more than one cluster"))
  if (!setequal(idx_all, seq_len(nrow(members)))) {
    return(fail(sprintf("clusters cover %d of %d members", length(idx_all), nrow(members))))
  }

  purrr::imap_dfr(cl, function(c1, i) {
    idx <- as.integer(unlist(c1$member_indices))
    tibble::tibble(
      cache_key = item$key[[1L]], block_id = item$block_id[[1L]],
      model_id = item$model[[1L]], prompt_version = PROMPT_VERSION,
      cluster_no = as.integer(i),
      canonical = c1$canonical %||% NA_character_,
      legal_entity = c1$legal_entity %||% NA_character_,
      parent = c1$parent %||% NA_character_,
      entity_type = c1$entity_type %||% NA_character_,
      raw_sponsor = members$raw_sponsor[idx],
      confidence = as.numeric(c1$confidence %||% NA_real_),
      reason = c1$reason %||% NA_character_,
      decided_at_utc = utc_now(), batch_id = batch_id
    )
  })
}

CACHE_COLS <- c("cache_key", "block_id", "model_id", "prompt_version", "cluster_no",
                "canonical", "legal_entity", "parent", "entity_type", "raw_sponsor",
                "confidence", "reason", "decided_at_utc", "batch_id")

save_rows <- function(rows) {
  merged <- llm_cache_merge(cache, rows, key_col = "cache_key")
  llm_cache_write(merged[, CACHE_COLS], CACHE_PATH, sort_by = c("block_id", "cluster_no"))
  ok <- sum(!is.na(rows$canonical))
  message(sprintf("wrote %d rows to %s (%d assigned, %d failed)",
                  nrow(rows), basename(CACHE_PATH), ok, sum(is.na(rows$canonical))))
}

# ── Modes ─────────────────────────────────────────────────────────────────────
# Head and tail are separate specs (different models), so each is dry-run,
# budget-checked and submitted separately.

specs <- list()
for (m in unique(work$model)) {
  specs[[m]] <- llm_spec(model = m, prompt_version = PROMPT_VERSION,
                         system_prompt = SYSTEM_PROMPT, schema = MINT_SCHEMA,
                         effort = "low", max_tokens = MAX_TOKENS)
}

if (dry_run) {
  total <- 0
  for (m in names(specs)) {
    est <- llm_dry_run(specs[[m]], work |> filter(model == m),
                       label = paste("B_mint /", m), spend_path = SPEND_PATH)
    if (!is.null(est) && !is.na(est$est_cost_batch)) total <- total + est$est_cost_batch
  }
  cat(sprintf("\ncombined batch estimate: $%.2f\n", total))
  llm_budget_guard(total, SPEND_PATH, "B_mint")
  quit(save = "no", status = 0L)
}

if (do_sync) {
  # Guard and meter, as the batch path does. One spend row per model, because
  # pricing differs between the Opus head and the Sonnet tail.
  for (m in names(specs)) {
    w <- work |> filter(model == m)
    if (!nrow(w)) next
    est <- llm_dry_run(specs[[m]], w, label = paste("B_mint /", m), spend_path = SPEND_PATH)
    llm_budget_guard(est$est_cost_sync %||% est$est_cost_batch, SPEND_PATH, "B_mint")
  }
  rows <- purrr::map_dfr(names(specs), function(m) {
    w <- work |> filter(model == m)
    if (!nrow(w)) return(tibble::tibble())
    r <- llm_sync(specs[[m]], w, parse = function(o, it) parse_clusters(o, it))
    llm_spend_record_sync(SPEND_PATH, "B_mint", m, r)
    r
  })
  save_rows(rows)
  message(sprintf("recorded sync spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  quit(save = "no", status = 0L)
}

# Batch. One batch per model.
auth <- llm_auth()
if (!is.na(poll_batch)) {
  llm_batch_wait(poll_batch, auth)
  rows <- llm_batch_results(poll_batch, work, parse = parse_clusters, auth)
  save_rows(rows)
  u <- llm_batch_usage(poll_batch, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "B_mint", poll_batch, work$model[[1L]],
                     u$input, u$output, u$cache_read,
                     n_requests = u$n %||% nrow(work))
    message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  }
  quit(save = "no", status = 0L)
}

for (m in names(specs)) {
  w <- work |> filter(model == m)
  if (!nrow(w)) next
  est <- llm_dry_run(specs[[m]], w, label = paste("B_mint /", m),
                     spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, paste("B_mint /", m))
  bid <- llm_batch_submit(specs[[m]], w, auth)
  llm_batch_wait(bid, auth)
  rows <- llm_batch_results(bid, w, parse = parse_clusters, auth)
  save_rows(rows)
  cache <- llm_cache_read(CACHE_PATH)
  u <- llm_batch_usage(bid, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "B_mint", bid, m, u$input, u$output, u$cache_read,
                     n_requests = u$n %||% nrow(w))
    message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  }
}
message("Minted. Nothing applied to any label — E_emit.R does that.")
