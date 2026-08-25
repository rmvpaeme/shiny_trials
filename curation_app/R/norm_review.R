# ══════════════════════════════════════════════════════════════════════════════
# TAB 2 — NORMALISATION REVIEW
# ══════════════════════════════════════════════════════════════════════════════
#
# The sponsor and substance queues. Both have the same shape, so one module
# serves both — v1 needed 641 lines of tier dispatch because its ten queues did
# not.
#
#   raw_sponsor|raw_substance, proposed, confidence, n_trials, review_reason,
#   reason, channel, model_id
#
# A decision here becomes decided_by = "human" in the registry, which every
# downstream pass already honours: pinned assignments survive a re-run, merges
# of human entities are refused, and route_for_review() drops human rows so the
# string leaves the queue by construction. The pipeline has had that contract on
# the read side since v0.20 with nothing writing to it.

DOMAIN_SPEC <- list(
  sponsor = list(
    raw_col   = "raw_sponsor",
    queue     = "config/sponsor_norm_v2/E_review_queue.csv",
    registry  = "config/sponsor_norm_v2/registry.csv",
    trial_raw = "data/trial_sponsors_raw.csv",
    label     = "Sponsor",
    # Sponsors have no not-a-substance analogue: every sponsor string names
    # something, even when the model cannot say what.
    actions   = c("accept", "edit", "reject", "skip")
  ),
  substance = list(
    raw_col   = "raw_substance",
    queue     = "config/substance_norm_v2/E_review_queue.csv",
    registry  = "config/substance_norm_v2/registry.csv",
    trial_raw = "data/trial_substances_raw.csv",
    label     = "Substance",
    # The substance pipeline has a third match_status ("rejected") fed by the
    # not-a-substance lists, so a reviewer can say "this is dosage language,
    # not a drug" — distinct from "this is a drug and the mapping is wrong".
    actions   = c("accept", "edit", "reject", "not_a_substance", "skip")
  )
)

# ── Loading ───────────────────────────────────────────────────────────────────

norm_queue_load <- function(snap, domain) {
  spec <- DOMAIN_SPEC[[domain]]
  p <- snapshot_file(spec$queue, snap)
  if (is.na(p)) return(NULL)
  q <- tryCatch(readr::read_csv(p, show_col_types = FALSE, progress = FALSE),
                error = function(e) NULL)
  if (is.null(q) || !nrow(q)) return(NULL)
  q$raw_value <- q[[spec$raw_col]]
  q
}

# Only LIVE entities may be offered.
#
# registry_live() lives in helper_scripts/llm_norm/registry.R, which this app
# deliberately does not have: the snapshot fetches DATA ONLY, never code, and
# sourcing R from a branch at runtime would be a remote execution path. The rule
# is one line and is restated here rather than imported.
#
# A merged entity keeps its row and gains merged_into — merges never delete —
# so offering the whole registry would let a reviewer pin an assignment to an
# entity that has already been folded into another.
norm_registry_load <- function(snap, domain) {
  spec <- DOMAIN_SPEC[[domain]]
  p <- snapshot_file(spec$registry, snap)
  if (is.na(p)) return(NULL)
  r <- tryCatch(readr::read_csv(p, show_col_types = FALSE, progress = FALSE),
                error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NULL)
  if (!"merged_into" %in% names(r)) r$merged_into <- NA_character_
  r[is.na(r$merged_into) | !nzchar(as.character(r$merged_into)), , drop = FALSE]
}

# ── The queue a reviewer should actually see ─────────────────────────────────
#
# The fetched queue is a snapshot from the last nightly, so it still contains
# every row anyone has decided since. Without this a reviewer re-decides rows
# that are already pinned, and two reviewers working at once collide constantly.
#
# Pure, so it is testable without a database or a snapshot.
norm_pending <- function(queue, decided, domain) {
  if (is.null(queue) || !nrow(queue)) return(queue)
  if (is.null(decided) || !nrow(decided)) return(queue)
  d <- decided[decided$domain == domain, , drop = FALSE]
  if (!nrow(d)) return(queue)
  queue[!queue$raw_value %in% d$raw_value, , drop = FALSE]
}

# Trials carrying this raw string, for the evidence panel.
norm_trial_refs <- function(snap, domain, raw_value, cache = NULL, limit = 25L) {
  spec <- DOMAIN_SPEC[[domain]]
  p <- snapshot_file(spec$trial_raw, snap)
  if (is.na(p)) return(NULL)
  tr <- tryCatch(readr::read_csv(p, show_col_types = FALSE, progress = FALSE),
                 error = function(e) NULL)
  if (is.null(tr)) return(NULL)
  ids <- tr$`_id`[tr[[spec$raw_col]] %in% raw_value]
  if (!length(ids)) return(NULL)
  head(unique(ids), limit)
}

# Other raw strings already mapped to the same canonical.
#
# Derived from trials_cache.rds rather than assignments.csv, which is 7.4 MB
# across the two domains and is not fetched. For sponsors this is exact: the
# cache carries sponsor_name_raw beside sponsor_clean. For substances it is
# approximate, because substance_label is a " / "-joined multi-substance string
# — acceptable for a supporting panel, and the alternative costs 4.8 MB per
# process for something a reviewer glances at.
norm_siblings <- function(cache, domain, canonical, limit = 15L) {
  if (is.null(cache) || is.null(canonical) || !nzchar(canonical)) return(NULL)
  if (identical(domain, "sponsor")) {
    if (!all(c("sponsor_clean", "sponsor_name_raw") %in% names(cache))) return(NULL)
    hit <- cache$sponsor_clean %in% canonical
    if (!any(hit)) return(NULL)
    head(sort(unique(cache$sponsor_name_raw[hit])), limit)
  } else {
    if (!"substance_label" %in% names(cache)) return(NULL)
    hit <- grepl(canonical, cache$substance_label %||% "", fixed = TRUE)
    if (!any(hit)) return(NULL)
    head(sort(unique(cache$DIMP_inn_name_raw[hit])), limit)
  }
}

# ── UI ────────────────────────────────────────────────────────────────────────

norm_review_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 320, position = "right",
      shiny::radioButtons(ns("domain"), "Queue",
                          choices = c("Sponsor" = "sponsor", "Substance" = "substance"),
                          selected = "sponsor"),
      shiny::selectInput(ns("reason"), "Review reason", choices = "All", selected = "All"),
      shiny::sliderInput(ns("min_trials"), "Minimum trials", min = 0, max = 50, value = 0),
      shiny::hr(),
      shiny::uiOutput(ns("actions")),
      shiny::hr(),
      shiny::uiOutput(ns("progress"))
    ),
    shiny::div(
      class = "p-2",
      shiny::uiOutput(ns("card")),
      shiny::h6("Queue", class = "mt-3"),
      DT::DTOutput(ns("queue"))
    )
  )
}

# ── Server ────────────────────────────────────────────────────────────────────

norm_review_server <- function(id, db, session_user, snapshot = snapshot_current,
                               cache = NULL) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    domain <- shiny::reactive(input$domain %||% "sponsor")
    spec   <- shiny::reactive(DOMAIN_SPEC[[domain()]])

    snap <- shiny::reactive(snapshot())

    queue_raw <- shiny::reactive({
      shiny::req(snap())
      norm_queue_load(snap(), domain())
    })

    registry <- shiny::reactive({
      shiny::req(snap())
      norm_registry_load(snap(), domain())
    })

    # Re-read on every decision, and poll so a second reviewer's work shows up
    # without a reload. One scalar on an already-open pool connection.
    decided_tick <- shiny::reactiveVal(0)
    decided <- shiny::reactive({
      decided_tick()
      shiny::invalidateLater(60000, session)
      if (is.null(db)) return(NULL)
      tryCatch(latest_norm_decisions(db, domain()), error = function(e) NULL)
    })

    pending <- shiny::reactive({
      q <- norm_pending(queue_raw(), decided(), domain())
      if (is.null(q) || !nrow(q)) return(q)
      if (!identical(input$reason, "All") && !is.null(input$reason)) {
        q <- q[q$review_reason %in% input$reason, , drop = FALSE]
      }
      n <- input$min_trials %||% 0
      if (n > 0) q <- q[!is.na(q$n_trials) & q$n_trials >= n, , drop = FALSE]
      q[order(-q$n_trials, q$confidence), , drop = FALSE]
    })

    shiny::observeEvent(queue_raw(), {
      rs <- sort(unique(stats::na.omit(queue_raw()$review_reason)))
      shiny::updateSelectInput(session, "reason", choices = c("All", rs), selected = "All")
    })

    # Server-side, because the canonical pools are 6,954 and 19,645 names and
    # neither belongs in a browser payload.
    shiny::observeEvent(registry(), {
      shiny::updateSelectizeInput(session, "canonical",
        choices = sort(unique(registry()$canonical)), server = TRUE, selected = "")
    })

    selected <- shiny::reactive({
      i <- input$queue_rows_selected
      p <- pending()
      if (is.null(i) || !length(i) || is.null(p) || !nrow(p)) return(NULL)
      p[i[1], , drop = FALSE]
    })

    # Time on the card. Feeds the median seconds/decision in tab 3, which is how
    # rubber-stamping shows up.
    shown_at <- shiny::reactiveVal(Sys.time())
    shiny::observeEvent(selected(), shown_at(Sys.time()))

    output$queue <- DT::renderDT({
      p <- pending()
      shiny::validate(shiny::need(!is.null(p) && nrow(p), "Nothing left in this queue."))
      cols <- intersect(c("raw_value", "proposed", "confidence", "n_trials",
                          "review_reason", "channel"), names(p))
      DT::datatable(p[, cols, drop = FALSE], selection = "single",
                    rownames = FALSE, filter = "top",
                    options = list(pageLength = 15, scrollX = TRUE))
    })

    output$card <- shiny::renderUI({
      row <- selected()
      if (is.null(row)) return(shiny::div(class = "text-muted p-3",
                                          "Select a row to review it."))
      refs <- norm_trial_refs(snap(), domain(), row$raw_value)
      sibs <- norm_siblings(cache, domain(), row$proposed)
      bslib::layout_columns(
        col_widths = c(6, 6),
        bslib::card(
          bslib::card_header("The register's string"),
          shiny::div(class = "p-2",
            shiny::tags$code(style = "font-size:1.05rem;", row$raw_value),
            shiny::p(class = "text-muted small mt-2",
              sprintf("%s trial(s) · %s · confidence %s",
                      fmt_int(row$n_trials %||% 0),
                      row$review_reason %||% "?",
                      if (is.na(row$confidence)) "none" else format(round(row$confidence, 2)))))
        ),
        bslib::card(
          bslib::card_header("What the pipeline proposed"),
          shiny::div(class = "p-2",
            shiny::strong(row$proposed %||% "— nothing —"),
            # The model's own prose, verbatim. On merge proposals this is the
            # only thing that caught a wrong one at 0.90 confidence — the
            # reasoning contradicted the index while the number looked fine.
            if (!is.na(row$reason %||% NA))
              shiny::p(class = "small text-muted mt-2 fst-italic", row$reason))
        ),
        bslib::card(
          bslib::card_header("Trials using this string"),
          shiny::div(class = "p-2 small",
            if (is.null(refs)) shiny::span(class = "text-muted", "none found")
            else shiny::tagList(lapply(refs, function(id)
              shiny::div(shiny::tags$code(id)))))
        ),
        bslib::card(
          bslib::card_header("Other strings on this canonical"),
          shiny::div(class = "p-2 small",
            if (is.null(sibs)) shiny::span(class = "text-muted", "none found")
            else shiny::tagList(lapply(sibs, function(s) shiny::div(s))))
        )
      )
    })

    output$actions <- shiny::renderUI({
      row <- selected()
      if (is.null(row)) return(NULL)
      acts <- spec()$actions
      shiny::tagList(
        shiny::selectizeInput(ns("canonical"), "Canonical",
                              choices = NULL, options = list(create = TRUE,
                                                             placeholder = "type to search")),
        shiny::uiOutput(ns("new_warning")),
        shiny::textAreaInput(ns("comment"), "Comment", rows = 2),
        shiny::div(
          class = "d-grid gap-2",
          shiny::actionButton(ns("accept"), "Accept proposal", class = "btn-success btn-sm"),
          shiny::actionButton(ns("edit"),   "Save edit",       class = "btn-primary btn-sm"),
          shiny::actionButton(ns("reject"), "Reject",          class = "btn-danger btn-sm"),
          if ("not_a_substance" %in% acts)
            shiny::actionButton(ns("not_sub"), "Not a substance", class = "btn-warning btn-sm"),
          shiny::actionButton(ns("skip"),   "Skip",            class = "btn-light btn-sm")
        )
      )
    })

    # Minting a canonical is the single most consequential thing a reviewer can
    # do here — it is how near-duplicate canonicals accumulated in the first
    # place — so it is never silent.
    output$new_warning <- shiny::renderUI({
      cn <- input$canonical
      if (is.null(cn) || !nzchar(cn)) return(NULL)
      if (cn %in% registry()$canonical) return(NULL)
      shiny::div(class = "alert alert-warning py-2 small mb-2",
        shiny::strong("New canonical. "),
        "This name is not in the registry and will be created.")
    })

    output$progress <- shiny::renderUI({
      q <- queue_raw(); p <- pending()
      if (is.null(q)) return(NULL)
      shiny::div(class = "small text-muted",
        sprintf("%s of %s remaining", fmt_int(nrow(p %||% q)), fmt_int(nrow(q))))
    })

    record <- function(action, final = NA_character_) {
      row <- selected()
      if (is.null(row) || is.null(db)) return(invisible(NULL))
      u <- session_user()
      if (is.null(u)) return(invisible(NULL))
      is_new <- !is.na(final) && nzchar(final) && !final %in% registry()$canonical
      ent <- NA_character_
      if (!is.na(final) && nzchar(final)) {
        m <- match(final, registry()$canonical)
        if (!is.na(m)) ent <- registry()$entity_id[m]
      }
      ok <- tryCatch({
        append_norm_decision(
          db, domain = domain(), raw_value = row$raw_value, action = action,
          reviewer = u$username, snapshot_sha = snap()$sha,
          proposed = row$proposed, final_canonical = final, final_entity_id = ent,
          new_canonical = is_new,
          n_trials_shown = row$n_trials, confidence_shown = row$confidence,
          review_reason = row$review_reason,
          comment = input$comment %||% NA_character_,
          decision_ms = as.integer(difftime(Sys.time(), shown_at(), units = "secs") * 1000),
          app_version = APP_VERSION)
        TRUE
      }, error = function(e) { shiny::showNotification(
          paste("Could not save:", conditionMessage(e)), type = "error"); FALSE })
      if (ok) {
        shiny::updateTextAreaInput(session, "comment", value = "")
        decided_tick(decided_tick() + 1)
      }
      invisible(ok)
    }

    shiny::observeEvent(input$accept,  record("accept", selected()$proposed))
    shiny::observeEvent(input$edit,    record("edit",   input$canonical))
    shiny::observeEvent(input$reject,  record("reject"))
    shiny::observeEvent(input$skip,    record("skip"))
    shiny::observeEvent(input$not_sub, {
      # Refused for sponsors in store.R too — the guard is not only in the UI.
      if (!identical(domain(), "substance")) return()
      record("not_a_substance")
    })

    list(pending = pending, decided_tick = decided_tick)
  })
}
