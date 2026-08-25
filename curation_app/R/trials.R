# ══════════════════════════════════════════════════════════════════════════════
# TAB 1 — TRIAL VALIDATION
# ══════════════════════════════════════════════════════════════════════════════
#
# Browse every trial, see what the register said beside what the dashboard
# shows, and correct it. The catalogue is curation_app/R/field_spec.R, the same
# list the dashboard renders read-only in its trial-detail modal — so a field
# cannot appear in one and be forgotten in the other.
#
# ── The routing split is the whole design ─────────────────────────────────────
#
# A sponsor or substance correction is keyed on the RAW STRING and goes to the
# registry, so it fixes every trial carrying that string — correcting "Novartis
# Pharma AG" on one trial and leaving the other 400 wrong is not a fix. Every
# other field has no registry to generalise through, so it becomes a per-trial
# override.
#
# The reviewer is told which is which, per field, before they save. That is what
# the spec's `note` is for, and it is the entire UX of the split.

TRIAL_TABLE_COLS <- c("_id", "CT_number", "register", "Full_title", "sponsor_label",
                      "substance_label", "MEDDRA_term", "phase", "status",
                      "Member_state", "year", "participants_n")

# ── UI ────────────────────────────────────────────────────────────────────────

trials_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 380, position = "right",
      shiny::uiOutput(ns("detail_header")),
      shiny::uiOutput(ns("form")),
      shiny::hr(),
      shiny::uiOutput(ns("save_controls"))
    ),
    shiny::div(
      class = "p-2",
      shiny::uiOutput(ns("filters")),
      DT::DTOutput(ns("table"))
    )
  )
}

# ── Server ────────────────────────────────────────────────────────────────────

trials_server <- function(id, db, session_user, cache, snapshot = snapshot_current) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    snap <- shiny::reactive(snapshot())

    editable_fields <- Filter(function(f) isTRUE(f$editable), TRIAL_FIELD_SPEC)

    output$filters <- shiny::renderUI({
      shiny::req(!is.null(cache))
      shiny::div(
        class = "d-flex gap-2 align-items-end mb-2",
        shiny::textInput(ns("search"), "Search title, sponsor, substance or CT number",
                         width = "420px"),
        shiny::selectInput(ns("register"), "Register",
                           choices = c("All", sort(unique(stats::na.omit(cache$register)))),
                           width = "140px"),
        shiny::checkboxInput(ns("only_undecided"), "Hide trials I have already reviewed",
                             value = FALSE)
      )
    })

    reviewed_tick <- shiny::reactiveVal(0)
    my_reviews <- shiny::reactive({
      reviewed_tick()
      if (is.null(db)) return(character())
      tryCatch(latest_trial_reviews(db)$trial_id, error = function(e) character())
    })

    filtered <- shiny::reactive({
      d <- cache
      shiny::req(!is.null(d))
      q <- shiny::isolate(input$search)
      q <- input$search %||% ""
      if (nzchar(q)) {
        # Deliberately a few named columns rather than everything: a grepl across
        # 81 columns of 51k rows on every keystroke is not interactive.
        hit <- Reduce(`|`, lapply(c("Full_title", "sponsor_label", "substance_label", "CT_number"),
          function(cn) if (cn %in% names(d)) grepl(q, d[[cn]] %||% "", ignore.case = TRUE, fixed = FALSE)
                       else rep(FALSE, nrow(d))))
        d <- d[which(hit), , drop = FALSE]
      }
      if (!identical(input$register, "All") && !is.null(input$register)) {
        d <- d[d$register %in% input$register, , drop = FALSE]
      }
      if (isTRUE(input$only_undecided)) d <- d[!d$`_id` %in% my_reviews(), , drop = FALSE]
      d
    })

    output$table <- DT::renderDT({
      d <- filtered()
      shiny::validate(shiny::need(!is.null(d) && nrow(d), "No trials match."))
      cols <- intersect(TRIAL_TABLE_COLS, names(d))
      DT::datatable(head(d[, cols, drop = FALSE], 5000), selection = "single",
                    rownames = FALSE, filter = "top",
                    options = list(pageLength = 12, scrollX = TRUE))
    })

    row <- shiny::reactive({
      i <- input$table_rows_selected
      d <- filtered()
      if (is.null(i) || !length(i) || is.null(d) || !nrow(d)) return(NULL)
      d[i[1], , drop = FALSE]
    })

    shown_at <- shiny::reactiveVal(Sys.time())
    shiny::observeEvent(row(), shown_at(Sys.time()))

    output$detail_header <- shiny::renderUI({
      r <- row()
      if (is.null(r)) return(shiny::div(class = "text-muted", "Select a trial."))
      shiny::div(
        shiny::tags$strong(show_val(r$CT_number)),
        shiny::tags$a(" open", href = trial_link(r), target = "_blank", class = "small"),
        shiny::p(class = "small text-muted mb-2", show_val(r$Full_title))
      )
    })

    # One input per editable field, pre-filled with the CURRENT value. The raw
    # is shown beside it, because "is this recoding right" is unanswerable
    # without what the register actually sent.
    output$form <- shiny::renderUI({
      r <- row()
      if (is.null(r)) return(NULL)
      rows <- field_rows(r)
      by_id <- stats::setNames(rows, vapply(rows, function(x) x$id, character(1)))
      shiny::tagList(lapply(editable_fields, function(f) {
        cur <- by_id[[f$id]]
        val <- cur$norm
        ctl <- switch(f$control,
          select = shiny::selectInput(ns(paste0("f_", f$id)), f$label,
                     choices = unique(c("", f$vocab, if (!is.na(val)) val)),
                     selected = val %||% ""),
          number = shiny::numericInput(ns(paste0("f_", f$id)), f$label,
                     value = suppressWarnings(as.numeric(val))),
          date   = shiny::dateInput(ns(paste0("f_", f$id)), f$label,
                     value = suppressWarnings(as.Date(val))),
          bool   = shiny::selectInput(ns(paste0("f_", f$id)), f$label,
                     choices = c("Yes", "No", "Unknown"),
                     selected = if (identical(val, "TRUE")) "Yes"
                                else if (identical(val, "FALSE")) "No" else "Unknown"),
          entity = shiny::selectizeInput(ns(paste0("f_", f$id)), f$label,
                     choices = NULL, selected = val,
                     options = list(create = TRUE, placeholder = "type to search")),
          shiny::textInput(ns(paste0("f_", f$id)), f$label, value = val %||% ""))
        shiny::div(
          class = "mb-2",
          ctl,
          shiny::div(class = "small text-muted",
            shiny::span(shiny::tags$em("register: "), show_val(cur$raw))),
          # The scope warning. A registry edit is not a per-trial edit and the
          # reviewer has to know before they press save, not after.
          if (f$route %in% c("sponsor_registry", "substance_registry"))
            shiny::div(class = "small text-warning", shiny::tags$strong("↗ "), f$note)
          else shiny::div(class = "small text-muted", f$note)
        )
      }))
    })

    output$save_controls <- shiny::renderUI({
      if (is.null(row())) return(NULL)
      shiny::tagList(
        shiny::textAreaInput(ns("comment"), "Comment", rows = 2),
        shiny::div(class = "d-grid gap-2",
          shiny::actionButton(ns("save"), "Save changes", class = "btn-primary btn-sm"),
          shiny::actionButton(ns("validate"), "Mark validated (no change)", class = "btn-success btn-sm"),
          shiny::actionButton(ns("flag"), "Flag for another reviewer", class = "btn-warning btn-sm")),
        shiny::uiOutput(ns("save_note"))
      )
    })

    # What changed, compared against what was on screen. Only changed fields are
    # written: saving a form of 18 unchanged values as 18 decisions would bury
    # the real ones and make the per-field change rate meaningless.
    changed_fields <- function(r) {
      rows <- field_rows(r)
      by_id <- stats::setNames(rows, vapply(rows, function(x) x$id, character(1)))
      out <- list()
      for (f in editable_fields) {
        new <- input[[paste0("f_", f$id)]]
        if (is.null(new)) next
        new <- if (identical(f$control, "bool"))
                 switch(new, Yes = "TRUE", No = "FALSE", NA_character_)
               else as.character(new)
        old <- by_id[[f$id]]$norm
        same <- (is.na(old) && (is.na(new) || !nzchar(new))) || identical(as.character(old), new)
        if (!same) out[[f$id]] <- list(field = f, old = old, new = new,
                                       raw = by_id[[f$id]]$raw)
      }
      out
    }

    output$save_note <- shiny::renderUI({
      r <- row(); if (is.null(r)) return(NULL)
      ch <- changed_fields(r)
      if (!length(ch)) return(shiny::div(class = "small text-muted mt-2", "No changes."))
      reg <- Filter(function(x) x$field$route != "trial_override", ch)
      shiny::div(class = "small mt-2",
        sprintf("%d change(s) to save.", length(ch)),
        if (length(reg))
          shiny::div(class = "text-warning",
            sprintf("%d of them affect every trial with the same raw string.", length(reg))))
    })

    shiny::observeEvent(input$save, {
      r <- row(); u <- session_user()
      if (is.null(r) || is.null(u) || is.null(db)) return()
      ch <- changed_fields(r)
      if (!length(ch)) { shiny::showNotification("Nothing changed.", type = "message"); return() }
      ms  <- as.integer(difftime(Sys.time(), shown_at(), units = "secs") * 1000)
      sha <- snap()$sha %||% NA_character_
      n_ok <- 0L
      for (x in ch) {
        f <- x$field
        ok <- tryCatch({
          if (identical(f$route, "trial_override")) {
            append_trial_decision(db, trial_id = r$`_id`, field_id = f$id,
              action = "override", reviewer = u$username, snapshot_sha = sha,
              raw_shown = x$raw, norm_shown = x$old, final_value = x$new,
              value_type = spec_value_type(f), comment = input$comment %||% NA_character_,
              decision_ms = ms, app_version = APP_VERSION)
          } else {
            # Keyed on the RAW STRING, not the trial: that is what makes it
            # generalise. A registry edit made from this screen is the same kind
            # of decision as one made in tab 2 and lands in the same table.
            dom <- if (identical(f$route, "sponsor_registry")) "sponsor" else "substance"
            raw <- if (dom == "sponsor") row_val(r, "sponsor_name_raw") else x$raw
            if (is.na(raw) || !nzchar(raw)) stop("no raw string to key the decision on")
            append_norm_decision(db, domain = dom, raw_value = raw, action = "edit",
              reviewer = u$username, snapshot_sha = sha,
              proposed = x$old, final_canonical = x$new,
              comment = input$comment %||% NA_character_,
              decision_ms = ms, app_version = APP_VERSION)
          }
          TRUE
        }, error = function(e) {
          shiny::showNotification(sprintf("%s: %s", f$label, conditionMessage(e)), type = "error")
          FALSE
        })
        if (isTRUE(ok)) n_ok <- n_ok + 1L
      }
      if (n_ok) {
        shiny::showNotification(sprintf("Saved %d change(s). Live after tonight's rebuild.",
                                        n_ok), type = "message")
        shiny::updateTextAreaInput(session, "comment", value = "")
        reviewed_tick(reviewed_tick() + 1)
      }
    })

    shiny::observeEvent(input$validate, sign_off("validated"))
    shiny::observeEvent(input$flag,     sign_off("flagged"))

    sign_off <- function(status) {
      r <- row(); u <- session_user()
      if (is.null(r) || is.null(u) || is.null(db)) return()
      ok <- tryCatch({
        append_trial_review(db, trial_id = r$`_id`, status = status,
                            reviewer = u$username, snapshot_sha = snap()$sha %||% NA_character_,
                            comment = input$comment %||% NA_character_)
        TRUE
      }, error = function(e) {
        shiny::showNotification(conditionMessage(e), type = "error"); FALSE })
      if (ok) {
        shiny::showNotification(sprintf("Trial marked %s.", status), type = "message")
        reviewed_tick(reviewed_tick() + 1)
      }
    }

    list(filtered = filtered, reviewed_tick = reviewed_tick)
  })
}

# The cache is typed, so an override has to say what type it is carrying —
# casting from a bare string is how "12" ends up in a numeric column.
spec_value_type <- function(f) {
  switch(f$control, number = "numeric", date = "date", bool = "logical", "character")
}
