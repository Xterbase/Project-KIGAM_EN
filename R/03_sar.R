# R/03_sar.R — ③ SAR: per-POSITION SAR gives De and a QC verdict.
# The source dose rate (dose_rate_source, seconds -> Gy) enters as an analyse_SAR.CWOSL argument in this stage.
# ============================================================
# Runs SAR per POSITION with the signal/background integrals set in the Signal stage
# to get De values. The collected De values are the input of the next stage (De distribution -> CAM/MAM/FMM).
#
# Parsing the integral strings
# ---------------------
# The caller (UI) passes free-text strings such as "1:2". This is a trust boundary, so
# it must be validated when it reaches R. If validation failures were let through,
# analyse_SAR.CWOSL() would integrate the wrong channels and still return a De without error.
.parse_integral <- function(value, label, n_points) {
  if (is.null(value) || length(value) != 1 || is.na(value) || !nzchar(value)) {
    stop(paste0(label, " is empty. Example: 1:2"))
  }

  parts <- strsplit(trimws(as.character(value)), "[:,-]")[[1]]
  parts <- trimws(parts[nzchar(trimws(parts))])

  if (length(parts) != 2) {
    stop(paste0(label, " has an invalid format: '", value, "' / example: 1:2"))
  }

  nums <- suppressWarnings(as.integer(parts))

  if (any(is.na(nums))) {
    stop(paste0(label, " contains a non-numeric value: '", value, "' / example: 1:2"))
  }

  if (nums[1] < 1) {
    stop(paste0(label, " must start at channel 1 or higher: ", nums[1]))
  }

  if (nums[1] > nums[2]) {
    stop(
      paste0(
        label, " starts after it ends: ", nums[1], ":", nums[2],
        " / example: ", nums[2], ":", nums[1]
      )
    )
  }

  if (!is.na(n_points) && nums[2] > n_points) {
    stop(
      paste0(
        label, " exceeds the number of measured channels: ", nums[1], ":", nums[2],
        " / channels in this file (NPOINTS): ", n_points
      )
    )
  }

  as.integer(nums)
}


# Runs SAR for one analysis unit (single-aliquot: POSITION, single-grain: POSITION+GRAIN)
# and extracts only the needed values. found is the return value of .position_records().
.run_sar_one <- function(found, signal_integral, background_integral) {

  # signal_integral/background_integral are c(start, end). analyse_SAR.CWOSL() takes "a vector
  # of the channels to integrate", so passing c(900, 1000) integrates only channels 900 and 1000.
  # Always pass the full start:end.
  res <- analyse_SAR.CWOSL(
    object = found$obj,
    signal_integral = seq(signal_integral[1], signal_integral[2]),
    background_integral = seq(background_integral[1], background_integral[2]),
    plot = FALSE,
    verbose = FALSE
  )

  if (is.null(res)) {
    stop("The SAR analysis returned no result.")
  }

  data <- get_RLum(res, "data")

  if (is.null(data) || nrow(data) == 0) {
    stop("The SAR result contains no De value.")
  }

  # Quality indicators arrive as Criteria/Value rows of the rejection.criteria table.
  # The recycling ratio / recuperation the proposal asks for are looked up by name.
  rc <- try(get_RLum(res, "rejection.criteria"), silent = TRUE)

  pick_rc <- function(pattern) {
    if (inherits(rc, "try-error") || is.null(rc) || nrow(rc) == 0) {
      return(NA_real_)
    }

    hit <- grep(pattern, rc$Criteria, ignore.case = TRUE)

    if (length(hit) == 0) {
      return(NA_real_)
    }

    as.numeric(rc$Value[hit[1]])
  }

  get_one <- function(col) {
    if (col %in% colnames(data)) data[[col]][1] else NA
  }

  # Passing only the 2 extracted indicators would lose the other criteria (testdose error, S/N, ...).
  # A researcher needs every row to judge why a unit FAILED, so the whole table is passed on.
  if (inherits(rc, "try-error") || is.null(rc) || nrow(rc) == 0) {
    qc_criteria <- character(0)
    qc_value <- numeric(0)
    qc_threshold <- numeric(0)
    qc_status <- character(0)
  } else {
    qc_criteria <- as.character(rc$Criteria)
    qc_value <- suppressWarnings(as.numeric(rc$Value))
    qc_threshold <- suppressWarnings(as.numeric(rc$Threshold))
    qc_status <- as.character(rc$Status)
  }

  list(
    de = as.numeric(get_one("De")),
    de_error = as.numeric(get_one("De.Error")),
    rc_status = as.character(get_one("RC.Status")),
    fit = as.character(get_one("Fit")),
    n_n = as.numeric(get_one("n_N")),
    recycling_ratio = pick_rc("Recycling ratio"),
    recuperation = pick_rc("Recuperation"),
    qc_criteria = qc_criteria,
    qc_value = qc_value,
    qc_threshold = qc_threshold,
    qc_status = qc_status,

    res = res
  )
}



# Validates and converts the integral strings against the file's channel count (max NPOINTS).
.parse_integrals <- function(loaded, signal_integral, background_integral) {
  metadata <- loaded$metadata

  n_points <- if ("NPOINTS" %in% colnames(metadata)) {
    suppressWarnings(max(as.integer(metadata$NPOINTS), na.rm = TRUE))
  } else {
    NA_integer_
  }

  if (!is.finite(n_points)) {
    n_points <- NA_integer_
  }

  list(
    sig = .parse_integral(signal_integral, "Signal integral", n_points),
    bg = .parse_integral(background_integral, "Background integral", n_points)
  )
}

# The data to analyse for the mode. In single-aliquot mode a single-grain file is first
# passed through convert_SG2MG(), which sums the grain signals per disc (not a De average).
.mode_bin_data <- function(loaded, mode) {
  if (mode == "single_grain") {
    if (!loaded$single_grain) {
      stop(
        "single-grain mode is only possible for files with GRAIN numbers recorded. ",
        "This file is a single-aliquot measurement."
      )
    }

    return(loaded$bin_data)
  }

  if (loaded$single_grain) convert_SG2MG(loaded$bin_data) else loaded$bin_data
}

# Writes progress to a JSON file. The web layer (PHP) reads it to draw the progress bar.
# It writes to a temp file and renames it, so a reader never sees a half-written file.
.write_progress <- function(progress_file, done, total) {
  if (is.null(progress_file)) {
    return(invisible(NULL))
  }

  tmp <- paste0(progress_file, ".tmp")
  writeLines(sprintf('{"done": %d, "total": %d}', as.integer(done), as.integer(total)), tmp)
  file.rename(tmp, progress_file)

  invisible(NULL)
}


# Runs SAR in batch for the chosen POSITIONs.
#
# mode:
#   "single_aliquot"  one De per disc (POSITION). A single-grain file is first passed through
#                     convert_SG2MG(), which sums the grain signals per disc (not a De average).
#   "single_grain"    one De per grain (POSITION+GRAIN). Only for files with GRAIN numbers.
#
#   One failing unit does not stop the whole run.
#   A De distribution needs many De values; throwing away the good results because one
#   unit failed to fit would make the analysis impossible.
#   Failed units are collected with their reasons and returned so the UI can show them.
#
# With progress_file, {"done": i, "total": n} is written after each unit.
#
# seed: analyse_SAR.CWOSL() estimates the De error by Monte Carlo, and the QC "Palaeodose error"
# criterion judges by that error. Unseeded, a borderline grain flips between pass and fail on
# the same input (measured: 1 of 49 grains flipped with the seed). Every unit gets the same
# seed, so a verdict is reproducible regardless of which other units were selected; it is stamped on the result.
run_sar_analysis <- function(path, positions, signal_integral, background_integral,
                             mode = "single_aliquot",
                             progress_file = NULL, seed = 1L) {
  loaded <- load_bin_data(path)

  mode <- match.arg(mode, c("single_aliquot", "single_grain"))

  if (is.null(positions) || length(positions) == 0) {
    stop("No POSITION was selected for analysis.")
  }

  positions <- sort(unique(as.integer(positions)))

  unknown <- setdiff(positions, loaded$positions)

  if (length(unknown) > 0) {
    stop(
      paste0(
        "POSITION not in the file: ",
        paste(unknown, collapse = ", ")
      )
    )
  }

  integrals <- .parse_integrals(loaded, signal_integral, background_integral)
  sig <- integrals$sig
  bg <- integrals$bg


  # ------------------------------------------------------------
  # Build the analysis units
  # ------------------------------------------------------------
  bin_data <- .mode_bin_data(loaded, mode)

  if (mode == "single_grain") {
    keep <- loaded$grain_position %in% positions
    unit_pos <- loaded$grain_position[keep]
    unit_grain <- loaded$grain[keep]
  } else {
    unit_pos <- positions
    unit_grain <- rep(NA_integer_, length(positions))
  }

  n_units <- length(unit_pos)

  ok_position <- integer(0)
  ok_grain <- integer(0)
  ok_de <- numeric(0)
  ok_de_error <- numeric(0)
  ok_rc_status <- character(0)
  ok_fit <- character(0)
  ok_n_n <- numeric(0)
  ok_recycling <- numeric(0)
  ok_recuperation <- numeric(0)
  ok_warning <- character(0)

  # The QC table has several rows per unit, so it is stacked long with position/grain columns.
  qc_position <- integer(0)
  qc_grain <- integer(0)
  qc_criteria <- character(0)
  qc_value <- numeric(0)
  qc_threshold <- numeric(0)
  qc_status <- character(0)

  failed_position <- integer(0)
  failed_grain <- integer(0)
  failed_reason <- character(0)

  .write_progress(progress_file, 0L, n_units)

  for (i in seq_len(n_units)) {
    pos <- unit_pos[i]
    grain <- unit_grain[i]

    # Warnings are only printed to the console and lost, so they are collected per unit into the result.
    # (The integral format error also showed up only as a warning.)
    unit_warnings <- character(0)

    set.seed(seed)
    one <- try(
      withCallingHandlers(
        .run_sar_one(
          .position_records(bin_data, pos, if (is.na(grain)) NULL else grain),
          sig, bg
        ),
        warning = function(w) {
          unit_warnings <<- c(unit_warnings, conditionMessage(w))
          invokeRestart("muffleWarning")
        }
      ),
      silent = TRUE
    )

    .write_progress(progress_file, i, n_units)

    if (inherits(one, "try-error")) {
      failed_position <- c(failed_position, pos)
      failed_grain <- c(failed_grain, grain)
      failed_reason <- c(
        failed_reason,
        trimws(as.character(attr(one, "condition")$message))
      )

      next
    }

    ok_position <- c(ok_position, pos)
    ok_grain <- c(ok_grain, grain)
    ok_de <- c(ok_de, one$de)
    ok_de_error <- c(ok_de_error, one$de_error)
    ok_rc_status <- c(ok_rc_status, one$rc_status)
    ok_fit <- c(ok_fit, one$fit)
    ok_n_n <- c(ok_n_n, one$n_n)
    ok_recycling <- c(ok_recycling, one$recycling_ratio)
    ok_recuperation <- c(ok_recuperation, one$recuperation)
    ok_warning <- c(ok_warning, paste(unique(unit_warnings), collapse = " | "))

    n_rows <- length(one$qc_criteria)

    if (n_rows > 0) {
      qc_position <- c(qc_position, rep(pos, n_rows))
      qc_grain <- c(qc_grain, rep(grain, n_rows))
      qc_criteria <- c(qc_criteria, one$qc_criteria)
      qc_value <- c(qc_value, one$qc_value)
      qc_threshold <- c(qc_threshold, one$qc_threshold)
      qc_status <- c(qc_status, one$qc_status)
    }
  }

  if (length(ok_position) == 0) {
    stop(
      paste0(
        "All ", n_units, " selected analysis units failed SAR analysis. ",
        "First reason: ",
        if (length(failed_reason) > 0) failed_reason[1] else "(no reason)"
      )
    )
  }

  # Per-disc summary: number of analysis units (grains for single-grain) and number passing QC.
  disc <- sort(unique(unit_pos))
  disc_n_units <- as.integer(table(factor(unit_pos, levels = disc)))
  disc_n_accepted <- as.integer(table(factor(ok_position[ok_rc_status == "OK"], levels = disc)))

  list(
    mode = mode,
    seed = as.integer(seed),
    signal_integral = as.integer(sig),
    background_integral = as.integer(bg),

    n_requested = as.integer(n_units),
    n_success = as.integer(length(ok_position)),
    n_failed = as.integer(length(failed_position)),

    position = as.integer(ok_position),
    grain = as.integer(ok_grain),
    de = as.numeric(ok_de),
    de_error = as.numeric(ok_de_error),
    rc_status = as.character(ok_rc_status),
    fit = as.character(ok_fit),
    n_n = as.numeric(ok_n_n),
    recycling_ratio = as.numeric(ok_recycling),
    recuperation = as.numeric(ok_recuperation),
    warning = as.character(ok_warning),

    qc_position = as.integer(qc_position),
    qc_grain = as.integer(qc_grain),
    qc_criteria = as.character(qc_criteria),
    qc_value = as.numeric(qc_value),
    qc_threshold = as.numeric(qc_threshold),
    qc_status = as.character(qc_status),

    failed_position = as.integer(failed_position),
    failed_grain = as.integer(failed_grain),
    failed_reason = as.character(failed_reason),

    disc_position = as.integer(disc),
    disc_n_units = disc_n_units,
    disc_n_accepted = disc_n_accepted
  )
}


# Returns the dose-response curve of one analysis unit as chart data (the browser draws it).
# It uses the same data and the same seed as run_sar_analysis(), so De matches the table.
#
# points: SAR measurement points. Natural (natural signal), R1.. (regeneration doses), Repeated=TRUE (recycling point),
#         Dose-0 regeneration point (recuperation). The dose unit is the file's IRR_TIME as is (seconds for now).
# curve : the fitted Formula evaluated on a grid. Luminescence rounds the Formula coefficients
#         to 3 significant digits, so this is for display (~0.03% off at De, checked).
#         The De value itself comes from the unrounded fit.
get_dose_response <- function(path, pos, signal_integral, background_integral,
                              grain = NULL, mode = "single_aliquot", seed = 1L,
                              n_curve = 100L) {
  loaded <- load_bin_data(path)
  mode <- match.arg(mode, c("single_aliquot", "single_grain"))
  integrals <- .parse_integrals(loaded, signal_integral, background_integral)
  bin_data <- .mode_bin_data(loaded, mode)

  if (mode == "single_grain" && is.null(grain)) {
    stop("A GRAIN must be given in single-grain mode.")
  }

  if (mode == "single_aliquot") {
    grain <- NULL
  }

  set.seed(seed)
  one <- .run_sar_one(.position_records(bin_data, pos, grain), integrals$sig, integrals$bg)

  tab <- get_RLum(one$res, "LnLxTnTx.table")
  formula <- one$res@data$Formula

  curve_x <- numeric(0)
  curve_y <- numeric(0)

  if (is.expression(formula) && length(tab$Dose) > 0) {
    x_max <- max(c(tab$Dose, one$de), na.rm = TRUE) * 1.1
    x <- seq(0, x_max, length.out = n_curve)
    y <- try(eval(formula[[1]], list(x = x)), silent = TRUE)

    if (!inherits(y, "try-error") && length(y) == length(x)) {
      curve_x <- x
      curve_y <- as.numeric(y)
    }
  }

  list(
    position = as.integer(pos),
    grain = if (is.null(grain)) NA_integer_ else as.integer(grain),
    mode = mode,
    seed = as.integer(seed),
    signal_integral = as.integer(integrals$sig),
    background_integral = as.integer(integrals$bg),
    de = one$de,
    de_error = one$de_error,
    rc_status = one$rc_status,
    fit = one$fit,
    formula = if (is.expression(formula)) paste(deparse(formula[[1]]), collapse = "") else NA_character_,
    points = data.frame(
      name = as.character(tab$Name),
      dose = as.numeric(tab$Dose),
      lxtx = as.numeric(tab$LxTx),
      lxtx_error = as.numeric(tab$LxTx.Error),
      repeated = as.logical(tab$Repeated)
    ),
    curve_x = curve_x,
    curve_y = curve_y
  )
}
