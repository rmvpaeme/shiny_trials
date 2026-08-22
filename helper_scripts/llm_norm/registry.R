# The canonical entity registry, and the assignment of raw strings to it.
#
# This replaces the 16,545-row alias index. The difference is not size but
# provenance: every row here records which model and prompt version produced it
# and how confident it was, so a decision can be re-derived, superseded, or
# audited. The old index recorded a `source` string and nothing else, which is
# why it could hold 16,545 rows without a single human-verified one.
#
# Two tables:
#
#   registry     one row per organisation. Minted by pass B, merged by pass D.
#   assignments  one row per raw string, pointing at an entity.
#
# Merges never delete. A merged entity keeps its row and gains `merged_into`, so
# the registry stays an append-mostly log and "why is this string labelled X?"
# is answerable by following the chain rather than guessing.
#
# HUMAN DECISIONS OUTRANK MODEL DECISIONS AND ARE NEVER OVERWRITTEN. A row with
# decided_by = "human" is pinned: re-running a pass leaves it alone. That is the
# property that makes review cumulative instead of Sisyphean.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tibble)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

# `legal_entity` and `parent` model the sponsor hierarchy (brand vs legal entity
# vs subsidiary). `salt_form` and `brand` are their substance counterparts:
# canonical is the INN base, so "methotrexate sodium" resolves to Methotrexate
# with salt_form = "sodium", and "Metoject" with brand = "Metoject".
#
# Both domains share one column set rather than each getting its own, because
# write_table_atomic() back-fills any column a caller does not supply (see
# below). Sponsors leave the substance columns NA and vice versa, and neither
# pipeline needs to know the other's schema.
REGISTRY_COLS <- c(
  "entity_id", "canonical", "legal_entity", "parent", "entity_type",
  "salt_form", "brand",
  "confidence", "decided_by", "decided_at_utc",
  "model_id", "prompt_version", "merged_into", "note"
)

# The raw-string column is the one genuinely domain-specific name in this file.
# Every function that touches it takes `raw_col`, defaulting to the sponsor
# name so existing callers are unaffected.
assignment_cols <- function(raw_col = "raw_sponsor") {
  c(raw_col, "entity_id", "confidence", "channel", "reason",
    "decided_by", "decided_at_utc", "model_id", "prompt_version")
}

ASSIGNMENT_COLS <- assignment_cols()

utc_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# ── Empty / IO ────────────────────────────────────────────────────────────────

# Every column REGISTRY_COLS names is created here. An earlier version omitted
# legal_entity, which round-tripped fine only because write_table_atomic()
# back-fills it — leaving a fresh in-memory registry with a schema that
# disagreed with its own column contract.
registry_empty <- function() {
  tibble::tibble(
    entity_id = character(), canonical = character(), legal_entity = character(),
    parent = character(), entity_type = character(),
    salt_form = character(), brand = character(),
    confidence = numeric(), decided_by = character(),
    decided_at_utc = character(), model_id = character(),
    prompt_version = character(), merged_into = character(), note = character()
  )
}

assignments_empty <- function(raw_col = "raw_sponsor") {
  out <- tibble::tibble(
    entity_id = character(), confidence = numeric(),
    channel = character(), reason = character(), decided_by = character(),
    decided_at_utc = character(), model_id = character(), prompt_version = character()
  )
  out[[raw_col]] <- character()
  out[, assignment_cols(raw_col)]
}

registry_read <- function(path) {
  if (!file.exists(path)) return(registry_empty())
  readr::read_csv(path, show_col_types = FALSE, progress = FALSE, col_types = readr::cols(
    .default = readr::col_character(), confidence = readr::col_double()
  ))
}

assignments_read <- function(path, raw_col = "raw_sponsor") {
  if (!file.exists(path)) return(assignments_empty(raw_col))
  readr::read_csv(path, show_col_types = FALSE, progress = FALSE, col_types = readr::cols(
    .default = readr::col_character(), confidence = readr::col_double()
  ))
}

# Atomic: a half-written registry is worse than none, and these are the files
# every later pass reads.
write_table_atomic <- function(x, path, cols, sort_by) {
  missing <- setdiff(cols, names(x))
  for (m in missing) x[[m]] <- NA
  x <- x |>
    dplyr::select(dplyr::all_of(cols)) |>
    dplyr::arrange(dplyr::across(dplyr::all_of(sort_by)))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp")
  readr::write_csv(x, tmp, na = "", eol = "\n")
  invisible(file.rename(tmp, path))
}

registry_write    <- function(x, path) write_table_atomic(x, path, REGISTRY_COLS, "entity_id")
assignments_write <- function(x, path, raw_col = "raw_sponsor") {
  write_table_atomic(x, path, assignment_cols(raw_col), raw_col)
}

# ── Minting ───────────────────────────────────────────────────────────────────
# Sequential IDs, never reused. A content hash of the canonical was the
# alternative and is worse: consolidation edits canonicals, and an ID that moves
# when its label is corrected cannot anchor an assignment.

next_entity_id <- function(reg) {
  if (!nrow(reg)) return("ent_000001")
  n <- suppressWarnings(max(as.integer(sub("^ent_", "", reg$entity_id)), na.rm = TRUE))
  if (!is.finite(n)) n <- 0L
  sprintf("ent_%06d", n + 1L)
}

registry_add <- function(reg, canonical, legal_entity = NA_character_, parent = NA_character_,
                         entity_type = NA_character_, salt_form = NA_character_,
                         brand = NA_character_, confidence = NA_real_,
                         decided_by = "model", model_id = NA_character_,
                         prompt_version = NA_character_, note = NA_character_) {
  # IDs are allocated in one shot. The obvious loop — call next_entity_id(),
  # bind_rows the new entity, repeat — is O(n^2) in tibble allocations. It was
  # fine while only B_mint called this, a few thousand entities in block-sized
  # chunks, but A_resolve mints the whole 17,272-entry ChEMBL vocabulary in a
  # single call and the loop did not finish in two minutes. Sequential numbering
  # makes the batch form exactly equivalent.
  start <- if (!nrow(reg)) {
    0L
  } else {
    n <- suppressWarnings(max(as.integer(sub("^ent_", "", reg$entity_id)), na.rm = TRUE))
    if (!is.finite(n)) 0L else n
  }
  ids <- sprintf("ent_%06d", start + seq_along(canonical))
  new <- tibble::tibble(
    entity_id = ids, canonical = canonical, legal_entity = legal_entity,
    parent = parent, entity_type = entity_type,
    salt_form = salt_form, brand = brand,
    confidence = confidence, decided_by = decided_by,
    decided_at_utc = utc_now(), model_id = model_id,
    prompt_version = prompt_version, merged_into = NA_character_, note = note
  )
  list(registry = dplyr::bind_rows(reg, new), entity_ids = ids)
}

# ── Materialising from mint output ────────────────────────────────────────────
# Pass B writes clusters, not a registry. This turns them into one, and it is
# deliberately re-runnable: minting more blocks and calling this again extends
# the registry rather than rebuilding it.
#
# Two entities minted with the SAME canonical in different blocks are collapsed
# here. That happens routinely — a sponsor with more than max_block variants
# spills into a second block, and both blocks name it identically. Merging on an
# exact canonical match is safe; anything subtler is pass D's job.

registry_from_clusters <- function(clusters, reg = registry_empty(),
                                   assignments = assignments_empty(raw_col),
                                   raw_col = "raw_sponsor") {
  # Tolerate a cache written by an earlier prompt version that lacks newer
  # columns. Bumping PROMPT_VERSION invalidates cache KEYS but the old CSV is
  # still read, and a missing column here would abort the run rather than
  # degrade — losing a batch that has already been paid for.
  for (col in c("legal_entity", "parent", "entity_type", "salt_form", "brand",
                "reason", "model_id", "prompt_version", "confidence")) {
    if (!col %in% names(clusters)) clusters[[col]] <- NA
  }

  cl <- clusters |>
    dplyr::filter(!is.na(canonical), nzchar(canonical), !is.na(.data[[raw_col]]))
  if (!nrow(cl)) return(list(registry = reg, assignments = assignments))

  # One row per (block, cluster, canonical). Grouping by (block, cluster) alone
  # and taking first(canonical) would silently DROP an entity if a cluster ever
  # carried two canonicals — B_mint cannot produce that shape, but losing an
  # organisation without a trace is the wrong way to find out it did.
  dupes <- cl |>
    dplyr::distinct(block_id, cluster_no, canonical) |>
    dplyr::count(block_id, cluster_no, name = "n_canon") |>
    dplyr::filter(n_canon > 1L)
  if (nrow(dupes)) {
    warning(sprintf(
      "%d cluster(s) carry more than one canonical; each becomes its own entity rather than being dropped: %s",
      nrow(dupes), paste(head(dupes$block_id, 5), collapse = ", ")), call. = FALSE)
  }

  minted <- cl |>
    dplyr::group_by(block_id, cluster_no, canonical) |>
    dplyr::summarise(
      legal_entity   = dplyr::first(legal_entity),
      parent         = dplyr::first(parent),
      entity_type    = dplyr::first(entity_type),
      salt_form      = dplyr::first(salt_form),
      brand          = dplyr::first(brand),
      confidence     = suppressWarnings(as.numeric(dplyr::first(confidence))),
      model_id       = dplyr::first(model_id),
      prompt_version = dplyr::first(prompt_version),
      .groups        = "drop"
    )

  # Canonical -> TERMINAL entity, over EVERY registry row rather than only live
  # ones, with live rows winning ties.
  #
  # Keying on live rows alone resurrects consolidation. A canonical whose entity
  # was merged away is not "known", so it is minted again as a fresh live entity
  # and its raw strings are re-pointed at the duplicate. Measured on the real
  # 7,238-row registry, ONE re-materialisation added 284 entities — exactly the
  # merged set — and re-pointed 527 assignments, undoing every
  # `D_consolidate --apply`. Nothing errored, and nothing in the output looked
  # wrong: the registry simply grew back.
  #
  # This matters far beyond the obvious case, because `C_assign.R` re-materialises
  # the WHOLE mint cache on every invocation, so the damage lands on any re-run —
  # by hand or unattended. Idempotent materialisation is the precondition for
  # running this pipeline on a schedule. tests/sponsor_v2_idempotence.R pins it.
  term <- tibble::tibble(
    canonical = reg$canonical,
    entity_id = resolve_entity(reg, reg$entity_id),
    is_live   = is.na(reg$merged_into)
  ) |>
    dplyr::filter(!is.na(canonical), nzchar(canonical), !is.na(entity_id)) |>
    dplyr::arrange(dplyr::desc(is_live)) |>
    dplyr::distinct(canonical, .keep_all = TRUE)
  known <- setNames(term$entity_id, term$canonical)

  fresh <- minted |> dplyr::filter(!canonical %in% names(known))
  # Distinct canonical, best confidence wins the attributes.
  fresh1 <- fresh |>
    dplyr::arrange(canonical, dplyr::desc(dplyr::coalesce(confidence, 0))) |>
    dplyr::distinct(canonical, .keep_all = TRUE)

  if (nrow(fresh1)) {
    added <- registry_add(
      reg, canonical = fresh1$canonical, legal_entity = fresh1$legal_entity,
      parent = fresh1$parent,
      entity_type = fresh1$entity_type, salt_form = fresh1$salt_form,
      brand = fresh1$brand, confidence = fresh1$confidence,
      decided_by = "model", model_id = fresh1$model_id,
      prompt_version = fresh1$prompt_version
    )
    reg <- added$registry
    known <- c(known, setNames(added$entity_ids, fresh1$canonical))
  }

  new_assign <- cl |>
    dplyr::transmute(
      !!raw_col      := .data[[raw_col]],
      entity_id      = unname(known[canonical]),
      confidence     = suppressWarnings(as.numeric(confidence)),
      channel        = "mint",
      reason         = reason,
      decided_by     = "model",
      decided_at_utc = utc_now(),
      model_id, prompt_version
    ) |>
    dplyr::filter(!is.na(entity_id)) |>
    dplyr::distinct(.data[[raw_col]], .keep_all = TRUE)

  # Human assignments are never overwritten by a re-run.
  pinned <- assignments |> dplyr::filter(decided_by %in% "human")
  keep   <- assignments |> dplyr::filter(!decided_by %in% "human",
                                         !.data[[raw_col]] %in% new_assign[[raw_col]])
  new_assign <- new_assign |> dplyr::filter(!.data[[raw_col]] %in% pinned[[raw_col]])

  list(registry = reg,
       assignments = dplyr::bind_rows(pinned, keep, new_assign))
}

# ── Merge resolution ──────────────────────────────────────────────────────────
# merged_into can chain (A -> B -> C) if consolidation runs more than once.
# Resolving to the terminal entity is what every consumer actually wants, and
# doing it in one place stops each caller inventing a different half-correct
# version. Cycles are broken rather than hung on: a bad merge should degrade,
# not spin.

resolve_entity <- function(reg, ids) {
  map <- setNames(reg$merged_into, reg$entity_id)
  vapply(ids, function(id) {
    seen <- character()
    cur <- id
    while (!is.na(cur) && cur %in% names(map) && !is.na(map[[cur]])) {
      if (cur %in% seen) break            # cycle
      seen <- c(seen, cur)
      cur <- map[[cur]]
    }
    cur %||% NA_character_
  }, character(1), USE.NAMES = FALSE)
}

registry_live <- function(reg) reg |> dplyr::filter(is.na(merged_into))

# Apply pass D's decisions. `merges` is tibble(loser_id, winner_id, reason).
# A merge involving a human-pinned entity is refused rather than applied
# silently — the point of pinning is that a later automated pass cannot undo it.
registry_apply_merges <- function(reg, assignments, merges, model_id = NA_character_,
                                  prompt_version = NA_character_) {
  if (!nrow(merges)) return(list(registry = reg, assignments = assignments, applied = 0L, refused = 0L))

  pinned <- reg$entity_id[reg$decided_by %in% "human"]
  blocked <- merges$loser_id %in% pinned
  if (any(blocked)) {
    message(sprintf("  refusing %d merge(s) of human-decided entities", sum(blocked)))
  }
  m <- merges[!blocked, , drop = FALSE]
  m <- m[m$loser_id != m$winner_id, , drop = FALSE]
  if (!nrow(m)) return(list(registry = reg, assignments = assignments, applied = 0L,
                            refused = sum(blocked)))

  reg2 <- reg |>
    dplyr::left_join(m |> dplyr::select(loser_id, winner_id, merge_reason = reason),
                     by = c("entity_id" = "loser_id")) |>
    dplyr::mutate(
      merged_into = dplyr::coalesce(merged_into, winner_id),
      note = dplyr::coalesce(note, merge_reason)
    ) |>
    dplyr::select(-winner_id, -merge_reason)

  # Re-point assignments at the terminal entity, but never a human-decided one.
  moved <- resolve_entity(reg2, assignments$entity_id)
  keep_human <- assignments$decided_by %in% "human"
  assignments2 <- assignments |>
    dplyr::mutate(entity_id = ifelse(keep_human, entity_id, moved))

  list(registry = reg2, assignments = assignments2, applied = nrow(m), refused = sum(blocked))
}

# ── Surface forms for indexing ────────────────────────────────────────────────
# The retrieval vocabulary is the canonicals PLUS every raw string already
# assigned to one. Indexing only canonicals would mean a new variant is compared
# against an idealised name it may share little with; indexing the observed
# variants is what lets "AKH Wien" pull in the entity someone already reached
# through "Allgemeines Krankenhaus Wien".

registry_surface_forms <- function(reg, assignments, raw_col = "raw_sponsor") {
  live <- registry_live(reg)
  from_canonical <- live |> dplyr::transmute(entity_id, label = canonical)
  from_assigned <- assignments |>
    dplyr::filter(!is.na(entity_id)) |>
    dplyr::transmute(entity_id = resolve_entity(reg, entity_id),
                     label = .data[[raw_col]]) |>
    dplyr::filter(entity_id %in% live$entity_id)
  dplyr::bind_rows(from_canonical, from_assigned) |>
    dplyr::filter(!is.na(label), nzchar(trimws(label))) |>
    dplyr::distinct(entity_id, label)
}

# ── Confidence routing ────────────────────────────────────────────────────────
# Only low-confidence rows reach the reviewer. The n_trials clause is the one
# that matters in practice: a wrong label on a 200-trial sponsor is visible on
# the dashboard's first screen, while the same error on a 1-trial string is not
# worth a person's attention.

route_for_review <- function(assignments, impact = NULL,
                             min_confidence = 0.75,
                             high_impact_trials = 20L,
                             high_impact_confidence = 0.90,
                             raw_col = "raw_sponsor") {
  a <- assignments
  if (!is.null(impact)) {
    a <- dplyr::left_join(a, impact, by = raw_col)
  } else {
    a$n_trials <- NA_integer_
  }
  a |>
    dplyr::filter(!decided_by %in% "human") |>
    dplyr::mutate(review_reason = dplyr::case_when(
      is.na(entity_id)                                   ~ "unassigned",
      is.na(confidence)                                  ~ "no confidence recorded",
      confidence < min_confidence                        ~ "low confidence",
      !is.na(n_trials) & n_trials >= high_impact_trials &
        confidence < high_impact_confidence              ~ "high impact, middling confidence",
      TRUE                                               ~ NA_character_
    )) |>
    dplyr::filter(!is.na(review_reason)) |>
    dplyr::arrange(dplyr::desc(dplyr::coalesce(n_trials, 0L)), confidence)
}

# ── Emit ──────────────────────────────────────────────────────────────────────
# Resolves assignments through any merge chain and joins the canonical, which is
# the shape data/trial_sponsor_labels.csv needs.
#
# `cols` maps output name -> registry column, so each domain names its own
# emitted columns. The default is the sponsor shape E_emit.R already expects;
# substances pass c(substance_clean = "canonical", substance_salt = "salt_form",
# substance_type = "entity_type").
registry_resolve_labels <- function(reg, assignments,
                                    cols = c(sponsor_clean  = "canonical",
                                             sponsor_parent = "parent",
                                             sponsor_type   = "entity_type")) {
  live <- registry_live(reg)
  missing <- setdiff(unname(cols), names(live))
  for (m in missing) live[[m]] <- NA_character_
  assignments |>
    dplyr::mutate(entity_id = resolve_entity(reg, entity_id)) |>
    dplyr::left_join(
      live |> dplyr::select(entity_id, dplyr::all_of(cols)),
      by = "entity_id"
    )
}
