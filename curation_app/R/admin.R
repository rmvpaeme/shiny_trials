# ══════════════════════════════════════════════════════════════════════════════
# ADMIN PANEL
# ══════════════════════════════════════════════════════════════════════════════
#
# EVERY output and EVERY observer in this file opens with
# require_role(session, "admin"). Not one of them relies on the nav item being
# hidden: a Shiny client can subscribe to any output over the websocket and set
# any input with Shiny.setInputValue() from the console, so an invisible panel
# stops nobody. Hiding it is cosmetic; these guards are the access control.
#
# Every privileged write also appends to admin_audit — including the ones that
# fail — so "who reset whose password" is answerable later.

admin_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::div(
    class = "p-3",
    bslib::navset_tab(
      bslib::nav_panel("Accounts",
        shiny::div(class = "mt-3"),
        DT::DTOutput(ns("accounts")),
        shiny::hr(),
        bslib::layout_columns(
          col_widths = c(6, 6),
          bslib::card(
            bslib::card_header("Change a password"),
            shiny::div(class = "p-3",
              shiny::selectInput(ns("pw_user"), "Account", choices = NULL),
              shiny::passwordInput(ns("pw_new"), "New password"),
              shiny::passwordInput(ns("pw_confirm"), "Confirm"),
              shiny::actionButton(ns("pw_go"), "Set password", class = "btn-primary btn-sm"),
              shiny::div(class = "form-text",
                "At least 12 characters. Stored as a salted scrypt hash; the ",
                "password itself is never written down, logged or recoverable."))),
          bslib::card(
            bslib::card_header("Add a reviewer"),
            shiny::div(class = "p-3",
              shiny::textInput(ns("new_user"), "Username"),
              shiny::textInput(ns("new_name"), "Display name"),
              shiny::selectInput(ns("new_role"), "Role",
                                 choices = c("reviewer", "admin")),
              shiny::passwordInput(ns("new_pw"), "Initial password"),
              shiny::actionButton(ns("new_go"), "Create", class = "btn-primary btn-sm")))
        ),
        shiny::hr(),
        bslib::card(
          bslib::card_header("Enable or disable"),
          shiny::div(class = "p-3 d-flex gap-2 align-items-end",
            shiny::selectInput(ns("act_user"), "Account", choices = NULL, width = "220px"),
            shiny::actionButton(ns("act_off"), "Deactivate", class = "btn-warning btn-sm"),
            shiny::actionButton(ns("act_on"), "Reactivate", class = "btn-success btn-sm"),
            shiny::div(class = "form-text ms-2",
              "Accounts are never deleted — decisions reference them.")))
      ),
      bslib::nav_panel("Review sample",
        shiny::div(class = "mt-3"),
        shiny::p(class = "small text-muted",
          "51,311 trials will never all be validated. A stratified sample is ",
          "drawn once and split across the reviewers; the error rate measured ",
          "on it is what generalises to the corpus."),
        shiny::div(class = "d-flex gap-3 align-items-end",
          shiny::numericInput(ns("smp_n"), "Trials in the sample", value = 300,
                              min = 10, max = 5000, step = 10, width = "180px"),
          shiny::numericInput(ns("smp_overlap"), "Double-assigned %", value = 10,
                              min = 0, max = 100, step = 5, width = "160px"),
          shiny::actionButton(ns("smp_draw"), "Draw sample", class = "btn-primary btn-sm")),
        shiny::div(class = "form-text",
          "Stratified by register and era, allocated proportionally. The ",
          "double-assigned share is what makes inter-rater agreement ",
          "measurable — with none, no two reviewers ever see the same trial."),
        shiny::hr(),
        shiny::h6("Progress"), DT::DTOutput(ns("smp_progress")),
        shiny::h6("How closely the draw mirrors the corpus", class = "mt-3"),
        DT::DTOutput(ns("smp_rep"))),
      bslib::nav_panel("Snapshot",
        shiny::div(class = "mt-3"),
        shiny::uiOutput(ns("snapshot_info")),
        shiny::actionButton(ns("refresh"), "Refresh from GitHub", class = "btn-primary btn-sm"),
        shiny::div(class = "form-text mt-2",
          "Re-resolves the branch and re-fetches every file at that commit. ",
          "A failure keeps the snapshot currently loaded.")),
      bslib::nav_panel("Export status",
        shiny::div(class = "mt-3"),
        shiny::uiOutput(ns("lag")),
        shiny::h6("Recent exports", class = "mt-3"),
        DT::DTOutput(ns("exports"))),
      bslib::nav_panel("Download",
        shiny::div(class = "mt-3"),
        shiny::p(class = "small text-muted",
          "Every decision, both kinds, flattened. Contains reviewer usernames ",
          "and comments — treat it as personal data."),
        shiny::downloadButton(ns("dl"), "Decisions CSV", class = "btn-sm")),
      bslib::nav_panel("Audit",
        shiny::div(class = "mt-3"),
        shiny::p(class = "small text-muted", "Every privileged action taken in this panel."),
        DT::DTOutput(ns("audit")))
    )
  )
}

admin_server <- function(id, db, session_user, snapshot = snapshot_current,
                         refresh = snapshot_refresh, cache = NULL) {
  shiny::moduleServer(id, function(input, output, session) {
    tick <- shiny::reactiveVal(0)
    sample_tick <- shiny::reactiveVal(0)
    last_rep <- shiny::reactiveVal(NULL)

    # One helper so no output can accidentally be written without the guard.
    admin_q <- function(f, ...) {
      require_role(session, "admin")
      if (is.null(db)) return(NULL)
      tryCatch(f(db, ...), error = function(e) NULL)
    }

    accounts <- shiny::reactive({ tick(); admin_q(reviewer_list) })

    output$accounts <- DT::renderDT({
      a <- accounts()
      shiny::validate(shiny::need(!is.null(a) && nrow(a), "No accounts."))
      DT::datatable(a, rownames = FALSE, selection = "none",
                    options = list(pageLength = 10, dom = "t"))
    })

    shiny::observe({
      a <- accounts(); if (is.null(a)) return()
      for (i in c("pw_user", "act_user"))
        shiny::updateSelectInput(session, i, choices = a$username)
    })

    # Audits the attempt as well as the success: a refused privileged action is
    # exactly the thing worth having a record of.
    note <- function(action, target = NA, detail = NULL) {
      u <- auth_user(session)
      if (is.null(u) || is.null(db)) return(invisible(NULL))
      try(admin_audit_log(db, u$username, action, target, detail), silent = TRUE)
    }

    shiny::observeEvent(input$pw_go, {
      u <- auth_user(session)
      if (is.null(u) || !identical(u$role, "admin") || is.null(db)) return()
      target <- input$pw_user
      if (!nzchar(input$pw_new %||% "")) {
        shiny::showNotification("Enter a password.", type = "warning"); return() }
      if (!identical(input$pw_new, input$pw_confirm)) {
        shiny::showNotification("The two passwords do not match.", type = "error")
        note("reset_pw_refused", target, list(reason = "mismatch")); return() }
      if (nchar(input$pw_new) < 12) {
        shiny::showNotification("Use at least 12 characters.", type = "error")
        note("reset_pw_refused", target, list(reason = "too short")); return() }
      ok <- tryCatch({ reviewer_set_password(db, target, input$pw_new); TRUE },
                     error = function(e) { shiny::showNotification(conditionMessage(e),
                       type = "error"); FALSE })
      if (ok) {
        # The audit records WHO and WHOM. Never the password, and never a hash.
        note("reset_pw", target)
        shiny::updateTextInput(session, "pw_new", value = "")
        shiny::updateTextInput(session, "pw_confirm", value = "")
        shiny::showNotification(sprintf("Password changed for %s.", target), type = "message")
      }
    })

    shiny::observeEvent(input$new_go, {
      u <- auth_user(session)
      if (is.null(u) || !identical(u$role, "admin") || is.null(db)) return()
      ok <- tryCatch({
        reviewer_create(db, input$new_user, input$new_name %||% input$new_user,
                        input$new_pw, input$new_role)
        TRUE
      }, error = function(e) {
        shiny::showNotification(conditionMessage(e), type = "error")
        note("create_user_refused", input$new_user, list(reason = conditionMessage(e)))
        FALSE })
      if (ok) {
        note("create_user", input$new_user, list(role = input$new_role))
        shiny::updateTextInput(session, "new_user", value = "")
        shiny::updateTextInput(session, "new_name", value = "")
        shiny::updateTextInput(session, "new_pw", value = "")
        tick(tick() + 1)
        shiny::showNotification("Reviewer created.", type = "message")
      }
    })

    set_active <- function(active) {
      u <- auth_user(session)
      if (is.null(u) || !identical(u$role, "admin") || is.null(db)) return()
      target <- input$act_user
      # Two refusals worth having: locking yourself out, and removing the last
      # admin. Either leaves nobody able to fix it through the app.
      if (!active && identical(target, u$username)) {
        shiny::showNotification("You cannot deactivate your own account.", type = "error")
        note("deactivate_refused", target, list(reason = "self")); return() }
      if (!active) {
        a <- accounts()
        is_admin <- !is.null(a) && identical(a$role[a$username == target][1], "admin")
        if (is_admin && admin_count(db) <= 1) {
          shiny::showNotification("That is the last active admin.", type = "error")
          note("deactivate_refused", target, list(reason = "last admin")); return() }
      }
      ok <- tryCatch({ reviewer_set_active(db, target, active); TRUE },
                     error = function(e) FALSE)
      if (ok) {
        note(if (active) "reactivate_user" else "deactivate_user", target)
        tick(tick() + 1)
        shiny::showNotification(sprintf("%s %s.", target,
          if (active) "reactivated" else "deactivated"), type = "message")
      }
    }
    shiny::observeEvent(input$act_off, set_active(FALSE))
    shiny::observeEvent(input$act_on,  set_active(TRUE))

    shiny::observeEvent(input$smp_draw, {
      u <- auth_user(session)
      if (is.null(u) || !identical(u$role, "admin") || is.null(db)) return()
      if (is.null(cache)) {
        shiny::showNotification("No trials cache loaded.", type = "error"); return() }
      a <- accounts()
      revs <- a$username[a$active]
      if (!length(revs)) { shiny::showNotification("No active reviewers.", type = "error"); return() }
      sid <- format(Sys.time(), "sample-%Y%m%d-%H%M%S", tz = "UTC")
      ok <- tryCatch({
        picked <- draw_review_sample(cache, revs, n = as.integer(input$smp_n),
                                     overlap = (input$smp_overlap %||% 10) / 100,
                                     sample_id = sid)
        sample_store(db, picked)
        last_rep(sample_representativeness(cache, picked))
        TRUE
      }, error = function(e) {
        shiny::showNotification(conditionMessage(e), type = "error")
        note("draw_sample_failed", sid, list(reason = conditionMessage(e))); FALSE })
      if (ok) {
        note("draw_sample", sid, list(n = input$smp_n, overlap_pct = input$smp_overlap,
                                      reviewers = length(revs)))
        sample_tick(sample_tick() + 1)
        shiny::showNotification("Sample drawn and assigned.", type = "message")
      }
    })

    output$smp_progress <- DT::renderDT({
      sample_tick()
      p <- admin_q(sample_progress)
      shiny::validate(shiny::need(!is.null(p) && nrow(p), "No sample drawn yet."))
      DT::datatable(p, rownames = FALSE, options = list(dom = "t"))
    })

    output$smp_rep <- DT::renderDT({
      require_role(session, "admin")
      r <- last_rep()
      shiny::validate(shiny::need(!is.null(r), "Draw a sample to see this."))
      DT::datatable(r, rownames = FALSE, options = list(dom = "t"))
    })

    output$snapshot_info <- shiny::renderUI({
      require_role(session, "admin")
      s <- snapshot()
      if (is.null(s)) return(shiny::div(class = "alert alert-danger py-2",
        "No snapshot loaded."))
      shiny::tags$dl(class = "row small",
        shiny::tags$dt(class = "col-3", "Commit"),   shiny::tags$dd(class = "col-9", s$sha),
        shiny::tags$dt(class = "col-3", "Committed"), shiny::tags$dd(class = "col-9", s$committed_at %||% "?"),
        shiny::tags$dt(class = "col-3", "Fetched"),   shiny::tags$dd(class = "col-9",
          format(s$fetched_at, "%Y-%m-%d %H:%M:%S UTC")),
        shiny::tags$dt(class = "col-3", "Files"),     shiny::tags$dd(class = "col-9",
          paste(length(s$files), "fetched",
                if (length(s$missing_optional))
                  sprintf("(%s absent)", paste(basename(s$missing_optional), collapse = ", ")) else "")),
        shiny::tags$dt(class = "col-3", "State"),     shiny::tags$dd(class = "col-9",
          if (isTRUE(s$degraded)) shiny::span(class = "text-warning",
            "degraded — ", s$degraded_reason %||% "") else "current"))
    })

    shiny::observeEvent(input$refresh, {
      u <- auth_user(session)
      if (is.null(u) || !identical(u$role, "admin")) return()
      refresh()
      note("refresh_snapshot", snapshot()$sha %||% NA)
      shiny::showNotification("Snapshot refreshed.", type = "message")
    })

    output$lag <- shiny::renderUI({
      require_role(session, "admin")
      l <- admin_q(export_lag); if (is.null(l)) return(NULL)
      pend <- (as.numeric(l$max_norm) - as.numeric(l$exported_norm)) +
              (as.numeric(l$max_trial) - as.numeric(l$exported_trial))
      shiny::div(
        shiny::p(sprintf("%s decision(s) recorded but not yet exported.", fmt_int(pend))),
        shiny::p(class = "small text-muted",
          if (is.na(l$last_ok[[1]])) "No export has ever completed."
          else paste("Last successful export:", format(l$last_ok[[1]], "%Y-%m-%d %H:%M UTC"))))
    })

    output$exports <- DT::renderDT({
      e <- admin_q(export_runs_recent)
      shiny::validate(shiny::need(!is.null(e) && nrow(e), "No export has run yet."))
      DT::datatable(e, rownames = FALSE, options = list(pageLength = 10, scrollX = TRUE))
    })

    output$audit <- DT::renderDT({
      a <- admin_q(admin_audit_recent)
      shiny::validate(shiny::need(!is.null(a) && nrow(a), "Nothing yet."))
      DT::datatable(a, rownames = FALSE, options = list(pageLength = 15, scrollX = TRUE))
    })

    output$dl <- shiny::downloadHandler(
      filename = function() sprintf("curation_decisions_%s.csv", Sys.Date()),
      content = function(file) {
        # The guard belongs INSIDE the handler. A download URL is just a URL;
        # it can be requested without the button ever having been rendered.
        require_role(session, "admin")
        d <- admin_q(decisions_export)
        note("download_decisions", NA, list(rows = if (is.null(d)) 0L else nrow(d)))
        readr::write_csv(d %||% data.frame(), file, na = "")
      })
  })
}
