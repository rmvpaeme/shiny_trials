# ══════════════════════════════════════════════════════════════════════════════
# TAB 1 — TRIAL VALIDATION
# ══════════════════════════════════════════════════════════════════════════════
#
# The SAME raw-vs-normalised overview the dashboard shows in its trial-detail
# modal, with each field clickable to correct it.
#
# The first version put eighteen input widgets in a sidebar. That is a form, not
# a review: it asks the reviewer to scan eighteen controls to find the one thing
# that is wrong, and it looks nothing like the screen they already know. Reading
# comes first — raw beside normalised, one row per field — and editing is what
# happens when a row looks wrong.
#
# ── The routing split ─────────────────────────────────────────────────────────
#
# Sponsor and substance corrections are keyed on the RAW STRING and go to the
# registry, so they fix every trial carrying it. Everything else becomes a
# per-trial override. The editor says which, every time, before saving.

TRIAL_TABLE_COLS <- c("_id", "CT_number", "register", "Full_title", "sponsor_label",
                      "substance_label", "MEDDRA_term", "phase", "status",
                      "Member_state", "year", "participants_n")

trials_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_sidebar(
    sidebar = bslib::sidebar(
      width = 330, position = "right",
      shiny::uiOutput(ns("detail_header")),
      shiny::hr(),
      shiny::uiOutput(ns("sign_off"))
    ),
    shiny::div(
      class = "p-2",
      shiny::uiOutput(ns("filters")),
      DT::DTOutput(ns("table")),
      shiny::hr(),
      shiny::uiOutput(ns("detail"))
    )
  )
}

trials_server <- function(id, db, session_user, cache, snapshot = snapshot_current) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    snap <- shiny::reactive(snapshot())

    editable_fields <- Filter(function(f) isTRUE(f$editable), TRIAL_FIELD_SPEC)

    output$filters <- shiny::renderUI({
      shiny::req(!is.null(cache))
      shiny::div(class = "d-flex gap-2 align-items-end mb-2",
        shiny::textInput(ns("search"), "Search title, sponsor, substance or CT number",
                         width = "420px"),
        shiny::selectInput(ns("register"), "Register",
                           choices = c("All", sort(unique(stats::na.omit(cache$register)))),
                           width = "130px"),
        shiny::checkboxInput(ns("only_undecided"), "Hide trials already reviewed", value = FALSE))
    })

    reviewed_tick <- shiny::reactiveVal(0)
    my_reviews <- shiny::reactive({
      reviewed_tick()
      if (is.null(db)) return(character())
      tryCatch(latest_trial_reviews(db)$trial_id, error = function(e) character())
    })

    filtered <- shiny::reactive({
      d <- cache; shiny::req(!is.null(d))
      q <- input$search %||% ""
      if (nzchar(q)) {
        # A few named columns, not all 81: a grepl across the whole frame on
        # every keystroke is not interactive at 51k rows.
        hit <- Reduce(`|`, lapply(c("Full_title", "sponsor_label", "substance_label", "CT_number"),
          function(cn) if (cn %in% names(d)) grepl(q, d[[cn]] %||% "", ignore.case = TRUE)
                       else rep(FALSE, nrow(d))))
        d <- d[which(hit), , drop = FALSE]
      }
      if (!identical(input$register, "All") && !is.null(input$register))
        d <- d[d$register %in% input$register, , drop = FALSE]
      if (isTRUE(input$only_undecided)) d <- d[!d$`_id` %in% my_reviews(), , drop = FALSE]
      d
    })

    output$table <- DT::renderDT({
      d <- filtered()
      shiny::validate(shiny::need(!is.null(d) && nrow(d), "No trials match."))
      DT::datatable(head(d[, intersect(TRIAL_TABLE_COLS, names(d)), drop = FALSE], 5000),
                    selection = "single", rownames = FALSE, filter = "top",
                    options = list(pageLength = 8, scrollX = TRUE))
    })

    row <- shiny::reactive({
      i <- input$table_rows_selected; d <- filtered()
      if (is.null(i) || !length(i) || is.null(d) || !nrow(d)) return(NULL)
      d[i[1], , drop = FALSE]
    })

    shown_at <- shiny::reactiveVal(Sys.time())
    shiny::observeEvent(row(), shown_at(Sys.time()))

    saved_tick <- shiny::reactiveVal(0)
    # A reviewer's own pending edits, so the screen shows what they already did
    # rather than the pipeline value they have just corrected. Labelled pending,
    # because it is not live until the nightly runs.
    pending <- shiny::reactive({
      saved_tick()
      r <- row(); if (is.null(r) || is.null(db)) return(NULL)
      tryCatch(latest_trial_decisions(db, r$`_id`), error = function(e) NULL)
    })

    output$detail_header <- shiny::renderUI({
      r <- row()
      if (is.null(r)) return(shiny::div(class = "text-muted", "Select a trial below."))
      shiny::div(
        shiny::tags$strong(show_val(r$CT_number)),
        shiny::tags$a(" open ↗", href = trial_link(r), target = "_blank", class = "small"),
        shiny::p(class = "small text-muted mt-1 mb-0", show_val(r$Full_title)))
    })

    # ── The overview: raw beside normalised, one row per field ────────────────
    #
    # Same shape as the dashboard's trial-detail modal, so a reviewer is reading
    # a screen they already know. The only addition is that an editable row is a
    # link.
    render_group <- function(r, group, header) {
      rows <- field_rows(r, group = group)
      pend <- pending()
      spec_by_id <- stats::setNames(TRIAL_FIELD_SPEC,
                                    vapply(TRIAL_FIELD_SPEC, function(f) f$id, character(1)))
      shiny::tagList(
        shiny::h6(header, class = "mt-3"),
        shiny::tags$table(
          class = "table table-sm table-bordered align-middle",
          style = "font-size:12px;",
          shiny::tags$thead(shiny::tags$tr(
            shiny::tags$th(style = "width:22%;", "Field"),
            shiny::tags$th(style = "width:34%;", "Registry raw / source value"),
            shiny::tags$th(style = "width:34%;", "Normalised dashboard value"),
            shiny::tags$th(style = "width:10%;", ""))),
          shiny::tags$tbody(lapply(rows, function(x) {
            f <- spec_by_id[[x$id]]
            p <- if (!is.null(pend) && nrow(pend)) pend[pend$field_id == x$id, ] else NULL
            has_pending <- !is.null(p) && nrow(p) && identical(p$action[[1]], "override")
            shiny::tags$tr(
              shiny::tags$th(x$label),
              shiny::tags$td(show_val(x$raw)),
              shiny::tags$td(
                if (has_pending)
                  shiny::tagList(
                    shiny::tags$span(p$final_value[[1]]),
                    shiny::tags$span(class = "badge bg-warning text-dark ms-1",
                                     title = "saved, live after tonight's rebuild", "pending"))
                else show_val(x$norm)),
              shiny::tags$td(
                if (isTRUE(f$editable))
                  shiny::actionLink(ns(paste0("edit_", x$id)), "edit", class = "small")
                else shiny::tags$span(class = "text-muted small", "—")))
          }))))
    }

    output$detail <- shiny::renderUI({
      require_role(session)
      r <- row()
      if (is.null(r)) return(shiny::div(class = "text-muted p-2",
        "Select a trial to see how it was recoded."))
      shiny::div(
        render_group(r, "entities", "Registry raw values vs normalised values"),
        render_group(r, "status", "Dates, status and results"))
    })

    # ── One editor, one field ─────────────────────────────────────────────────
    #
    # The observers are created ONCE, here, from a static field list — not
    # inside the renderUI. Shiny cannot observe inputs that are re-created on
    # every render, and the legacy app hit exactly this: it needed a fixed pool
    # of observers for the same reason. lapply + force, never a for loop, or
    # every link edits the last field.
    editing <- shiny::reactiveVal(NULL)
    lapply(editable_fields, function(f) {
      force(f)
      shiny::observeEvent(input[[paste0("edit_", f$id)]], {
        r <- row(); if (is.null(r)) return()
        editing(f$id)
        cur <- Filter(function(x) x$id == f$id, field_rows(r))[[1]]
        registry_scope <- f$route %in% c("sponsor_registry", "substance_registry")
        shiny::showModal(shiny::modalDialog(
          title = paste("Edit:", f$label),
          size = "m", easyClose = TRUE,
          shiny::div(class = "small text-muted mb-1", shiny::tags$em("The register sent: "),
                     show_val(cur$raw)),
          shiny::div(class = "small text-muted mb-3", shiny::tags$em("Currently shown as: "),
                     show_val(cur$norm)),
          switch(f$control,
            select = shiny::selectInput(ns("edit_value"), f$label,
                       choices = unique(c("", f$vocab, if (!is.na(cur$norm)) cur$norm)),
                       selected = cur$norm %||% ""),
            number = shiny::numericInput(ns("edit_value"), f$label,
                       value = suppressWarnings(as.numeric(cur$norm))),
            date   = shiny::dateInput(ns("edit_value"), f$label,
                       value = suppressWarnings(as.Date(cur$norm))),
            bool   = shiny::selectInput(ns("edit_value"), f$label,
                       choices = c("Yes", "No", "Unknown"),
                       selected = if (identical(cur$norm, "TRUE")) "Yes"
                                  else if (identical(cur$norm, "FALSE")) "No" else "Unknown"),
            shiny::textInput(ns("edit_value"), f$label, value = cur$norm %||% "")),
          shiny::textAreaInput(ns("edit_comment"), "Comment (optional)", rows = 2),
          # Scope, stated before the save and not after. This is the entire UX
          # of the routing split.
          if (registry_scope)
            shiny::div(class = "alert alert-warning py-2 small mb-0",
              shiny::strong("This is not a per-trial edit. "), f$note)
          else shiny::div(class = "text-muted small", f$note),
          footer = shiny::tagList(
            shiny::modalButton("Cancel"),
            shiny::actionButton(ns("edit_save"), "Save", class = "btn-primary"))))
      }, ignoreInit = TRUE)
    })

    shiny::observeEvent(input$edit_save, {
      fid <- editing(); r <- row(); u <- session_user()
      if (is.null(fid) || is.null(r) || is.null(u) || is.null(db)) return()
      f <- Filter(function(x) identical(x$id, fid), TRIAL_FIELD_SPEC)[[1]]
      cur <- Filter(function(x) x$id == fid, field_rows(r))[[1]]
      new <- input$edit_value
      new <- if (identical(f$control, "bool"))
               switch(as.character(new), Yes = "TRUE", No = "FALSE", NA_character_)
             else as.character(new)
      if (identical(as.character(cur$norm), new) ||
          (is.na(cur$norm) && (is.na(new) || !nzchar(new)))) {
        shiny::showNotification("Unchanged — nothing saved.", type = "message")
        shiny::removeModal(); return()
      }
      ms  <- as.integer(difftime(Sys.time(), shown_at(), units = "secs") * 1000)
      sha <- snap()$sha %||% NA_character_
      ok <- tryCatch({
        if (identical(f$route, "trial_override")) {
          append_trial_decision(db, trial_id = r$`_id`, field_id = f$id, action = "override",
            reviewer = u$username, snapshot_sha = sha, raw_shown = cur$raw,
            norm_shown = cur$norm, final_value = new, value_type = spec_value_type(f),
            comment = input$edit_comment %||% NA_character_,
            decision_ms = ms, app_version = APP_VERSION)
        } else {
          dom <- if (identical(f$route, "sponsor_registry")) "sponsor" else "substance"
          raw <- if (dom == "sponsor") row_val(r, "sponsor_name_raw") else cur$raw
          if (is.na(raw) || !nzchar(raw)) stop("no raw string to key this decision on")
          append_norm_decision(db, domain = dom, raw_value = raw, action = "edit",
            reviewer = u$username, snapshot_sha = sha, proposed = cur$norm,
            final_canonical = new, comment = input$edit_comment %||% NA_character_,
            decision_ms = ms, app_version = APP_VERSION)
        }
        TRUE
      }, error = function(e) {
        shiny::showNotification(conditionMessage(e), type = "error"); FALSE })
      if (isTRUE(ok)) {
        shiny::showNotification(
          if (identical(f$route, "trial_override")) "Saved. Live after tonight's rebuild."
          else "Saved to the registry — applies to every trial with this string.",
          type = "message")
        saved_tick(saved_tick() + 1)
        shiny::removeModal()
      }
    })

    output$sign_off <- shiny::renderUI({
      if (is.null(row())) return(NULL)
      shiny::tagList(
        shiny::textAreaInput(ns("comment"), "Comment", rows = 2),
        shiny::div(class = "d-grid gap-2",
          shiny::actionButton(ns("validate"), "Mark validated", class = "btn-success btn-sm"),
          shiny::actionButton(ns("flag"), "Flag for another reviewer", class = "btn-warning btn-sm")))
    })

    sign_off <- function(status) {
      r <- row(); u <- session_user()
      if (is.null(r) || is.null(u) || is.null(db)) return()
      ok <- tryCatch({
        append_trial_review(db, trial_id = r$`_id`, status = status, reviewer = u$username,
                            snapshot_sha = snap()$sha %||% NA_character_,
                            comment = input$comment %||% NA_character_)
        TRUE
      }, error = function(e) { shiny::showNotification(conditionMessage(e), type = "error"); FALSE })
      if (ok) {
        shiny::showNotification(sprintf("Trial marked %s.", status), type = "message")
        shiny::updateTextAreaInput(session, "comment", value = "")
        reviewed_tick(reviewed_tick() + 1)
      }
    }
    shiny::observeEvent(input$validate, sign_off("validated"))
    shiny::observeEvent(input$flag,     sign_off("flagged"))

    list(filtered = filtered, reviewed_tick = reviewed_tick, saved_tick = saved_tick)
  })
}

# The cache is typed, so an override must declare what it carries — casting
# from a bare string is how "12" ends up in a numeric column.
spec_value_type <- function(f) {
  switch(f$control, number = "numeric", date = "date", bool = "logical", "character")
}
