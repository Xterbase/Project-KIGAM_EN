# R/pipeline.R

library(Luminescence)

# ============================================================
# Common: loaded-file cache
# ============================================================
# load_bin_data() is called at the first line of every entry point:
# inspect_positions / inspect_rlum_records_by_position /
# save_rlum_record_plot, etc.
# Without a cache, the entire BIN file would be reparsed every time a
# record is clicked, which stalls for several seconds per click on a
# realistically sized measurement file.
#
# Cache key = normalized path + mtime + size
#   -> even for the same path, a change in file content changes the key,
#      invalidating the cache automatically.
#
# A Risoe.BINfileData object uses a lot of memory, so only the most
# recent N are kept (LRU).

.bin_cache <- new.env(parent = emptyenv())
.BIN_CACHE_MAX_ENTRIES <- 3L

.bin_cache_key <- function(normalized_path) {
  info <- file.info(normalized_path)

  paste(
    normalized_path,
    as.numeric(info$mtime),
    info$size,
    sep = "|"
  )
}

.bin_cache_get <- function(key) {
  if (!exists(key, envir = .bin_cache, inherits = FALSE)) {
    return(NULL)
  }

  entry <- get(key, envir = .bin_cache, inherits = FALSE)

  # Refresh LRU
  entry$last_used <- Sys.time()
  assign(key, entry, envir = .bin_cache)

  entry$value
}

.bin_cache_put <- function(key, value) {
  assign(
    key,
    list(value = value, last_used = Sys.time()),
    envir = .bin_cache
  )

  keys <- ls(.bin_cache, all.names = TRUE)

  if (length(keys) > .BIN_CACHE_MAX_ENTRIES) {
    last_used <- vapply(
      keys,
      function(k) as.numeric(get(k, envir = .bin_cache)$last_used),
      numeric(1)
    )

    n_drop <- length(keys) - .BIN_CACHE_MAX_ENTRIES
    drop_keys <- keys[order(last_used)][seq_len(n_drop)]

    rm(list = drop_keys, envir = .bin_cache)
  }

  invisible(value)
}

clear_bin_cache <- function() {
  rm(
    list = ls(.bin_cache, all.names = TRUE),
    envir = .bin_cache
  )

  invisible(TRUE)
}

# ============================================================
# Common: data loading
# ============================================================
# Reads a BIN/RDA/RData file and returns the Risoe.BINfileData object and
# metadata info that later analysis stages use in common.

load_bin_data <- function(path) {
  # ------------------------------------------------------------
  # 1. Validate the path input
  # ------------------------------------------------------------
  if (missing(path) || is.null(path) || length(path) != 1 || !nzchar(path)) {
    stop("The file path is empty or invalid.")
  }

  path <- as.character(path)

  # ------------------------------------------------------------
  # 2. Check the file exists
  # ------------------------------------------------------------
  if (!file.exists(path)) {
    stop(paste0("Could not find the file: ", path))
  }

  # ------------------------------------------------------------
  # 3. Normalize the path
  #    - keeps path representation consistent across
  #      Python/Streamlit/SQL/JSON storage
  # ------------------------------------------------------------
  normalized_path <- normalizePath(
    path,
    winslash = "/",
    mustWork = TRUE
  )

  file_name <- basename(normalized_path)
  ext <- tolower(tools::file_ext(normalized_path))

  # ------------------------------------------------------------
  # 3-1. Cache lookup
  #      Skip reparsing if it's the same file (path+mtime+size).
  # ------------------------------------------------------------
  cache_key <- .bin_cache_key(normalized_path)
  cached <- .bin_cache_get(cache_key)

  if (!is.null(cached)) {
    return(cached)
  }

  # ------------------------------------------------------------
  # 4. Validate the extension
  # ------------------------------------------------------------
  supported_ext <- c("bin", "rda", "rdata")

  if (!(ext %in% supported_ext)) {
    stop(
      paste0(
        "Unsupported file type: ",
        ext,
        " / Supported types: ",
        paste(supported_ext, collapse = ", ")
      )
    )
  }

  object_name <- NA_character_
  bin_data <- NULL

  # An rda/RData can hold multiple objects. This value is passed up to the
  # caller (UI) to say which one out of several was picked. bin is a
  # single-object format, so this is fixed at 1.
  n_candidates <- 1L
  ignored_objects <- character(0)

  # ------------------------------------------------------------
  # 5. Loading a BIN file
  # ------------------------------------------------------------
  if (ext == "bin") {
    bin_data <- read_BIN2R(
      file = normalized_path,
      verbose = FALSE
    )

    object_name <- "read_BIN2R_result"
  }

  # ------------------------------------------------------------
  # 6. Loading an RDA/RData file
  #    - loaded into a separate environment to avoid polluting the current one
  # ------------------------------------------------------------
  else if (ext %in% c("rda", "rdata")) {
    load_env <- new.env(parent = emptyenv())

    loaded_names <- load(
      file = normalized_path,
      envir = load_env
    )

    if (length(loaded_names) == 0) {
      stop("No objects were loaded from the RDA/RData file.")
    }

    candidates <- loaded_names[
      sapply(loaded_names, function(name) {
        obj <- get(name, envir = load_env)
        inherits(obj, "Risoe.BINfileData")
      })
    ]

    if (length(candidates) == 0) {
      stop("Could not find a Risoe.BINfileData object inside the RDA/RData file.")
    }

    # If there are multiple candidates, use the first one, but this must
    # not pass silently. The order load() returns is the order the objects
    # were given when saved, so which sample gets analyzed is decided by a
    # factor invisible to the researcher. The pick and the discards are
    # carried in the return value so the UI can warn about it.
    n_candidates <- length(candidates)
    object_name <- candidates[1]
    ignored_objects <- candidates[-1]

    bin_data <- get(object_name, envir = load_env)
  }

  # ------------------------------------------------------------
  # 7. Validate the final object type
  # ------------------------------------------------------------
  if (!inherits(bin_data, "Risoe.BINfileData")) {
    stop("The loaded object is not in Risoe.BINfileData format.")
  }

  # ------------------------------------------------------------
  # 8. Validate METADATA
  # ------------------------------------------------------------
  if (is.null(bin_data@METADATA)) {
    stop("The Risoe.BINfileData object has no METADATA slot.")
  }

  if (nrow(bin_data@METADATA) == 0) {
    stop("The Risoe.BINfileData object's METADATA is empty.")
  }

  metadata <- bin_data@METADATA
  metadata_columns <- colnames(metadata)

  # ------------------------------------------------------------
  # 9. Validate the POSITION column
  # ------------------------------------------------------------
  if (!"POSITION" %in% metadata_columns) {
    stop("Could not find a POSITION column in METADATA.")
  }

  positions <- sort(unique(metadata$POSITION))
  positions <- positions[!is.na(positions)]

  if (length(positions) == 0) {
    stop("No POSITION info was found.")
  }

  # ------------------------------------------------------------
  # 10. Basic record type summary
  # ------------------------------------------------------------
  record_types <- character(0)

  if ("LTYPE" %in% metadata_columns) {
    record_types <- sort(unique(as.character(metadata$LTYPE)))
    record_types <- record_types[!is.na(record_types)]
  }

  # ------------------------------------------------------------
  # 11. Return (load into the cache, then return)
  # ------------------------------------------------------------
  result <- list(
    bin_data = bin_data,
    metadata = metadata,

    file_path = normalized_path,
    file_name = file_name,
    file_type = ext,

    object_name = object_name,
    n_candidates = as.integer(n_candidates),
    ignored_objects = as.character(ignored_objects),

    n_metadata_rows = as.integer(nrow(metadata)),
    metadata_columns = as.character(metadata_columns),

    n_positions = as.integer(length(positions)),
    positions = as.integer(positions),

    record_types = as.character(record_types)
  )

  .bin_cache_put(cache_key, result)

  result
}

# ============================================================
# Version1: upload & position inspect
# ============================================================
# Summarizes overall POSITION info from the data loaded by load_bin_data().
# Used by the Upload & Inspect tab to check file structure, metadata, and
# the POSITION list.

inspect_positions <- function(path) {
  loaded <- load_bin_data(path)

  list(
    file = loaded$file_name,
    file_path = loaded$file_path,
    file_type = loaded$file_type,
    object_name = loaded$object_name,
    n_candidates = loaded$n_candidates,
    ignored_objects = loaded$ignored_objects,

    n_metadata_rows = loaded$n_metadata_rows,
    metadata_columns = loaded$metadata_columns,

    n_positions = loaded$n_positions,
    positions = loaded$positions,

    record_types = loaded$record_types
  )
}

# Version2: signal analysis
# ---------------------------
# Building on the file-loading/position-inspection flow implemented in
# Version1, this stage inspects the RLum record list for the POSITION the
# user selected, and saves/views the signal curve of the selected record.
#
#
# 3. inspect_rlum_records_by_position()
#    - summarizes the metadata row and RLum record info for the selected POSITION
#    - returns record_index, LTYPE, DTYPE, RUN, SET, IRR_TIME, NPOINTS, etc.
#
# 4. save_rlum_record_plot()
#    - saves a specific record from the selected POSITION as a plot
#    - lets the researcher check the signal shape and decide the signal/background integral
# ---------------------------
# Fetches the metadata row and RLum record for the selected POSITION
# together, and verifies that their 1:1 alignment actually holds.
#
# Background (important):
#   record_index is built on the premise that "metadata row order ==
#   RLum record order", and save_rlum_record_plot() draws obj[record_index]
#   using that number. If this premise breaks, a curve different from the
#   record the user picked gets drawn with no error.
#
#   And this premise really can break.
#   Because Risoe.BINfileData2RLum.Analysis() internally produces results
#   per GRAIN value, if a POSITION contains multiple GRAINs (a single-grain
#   measurement), it returns not a single RLum.Analysis but "a list of
#   RLum.Analysis, one per grain". Then length(obj) becomes the grain count
#   rather than the record count, so obj[record_index] ends up pointing at
#   a grain instead of a record.
#
# The old implementation truncated this with warning() + min(), but
#   - R's warning() never reaches the Streamlit UI, and
#   - truncating doesn't restore the alignment, it just draws a wrong curve.
# Rather than silently showing a wrong curve, this is blocked explicitly.
.load_position_records <- function(path, pos) {
  loaded <- load_bin_data(path)

  bin_data <- loaded$bin_data
  metadata <- loaded$metadata

  pos <- as.integer(pos)

  metadata_index <- which(metadata$POSITION == pos)
  meta_pos <- metadata[metadata_index, , drop = FALSE]

  if (nrow(meta_pos) == 0) {
    stop(paste0("Could not find metadata for that POSITION: ", pos))
  }

  # ------------------------------------------------------------
  # GRAIN check (the actual cause of a broken alignment)
  # ------------------------------------------------------------
  grains <- unique(meta_pos$GRAIN)
  grains <- grains[!is.na(grains)]

  if (length(grains) > 1) {
    stop(
      paste0(
        "POSITION ", pos, " has multiple GRAINs (",
        paste(sort(grains), collapse = ", "),
        "). Single-grain measurement files are not yet supported. ",
        "In this state, record numbers and their actual curves would be misaligned, so the analysis is stopped."
      )
    )
  }

  obj <- Risoe.BINfileData2RLum.Analysis(
    object = bin_data,
    pos = pos
  )

  if (length(obj) == 0) {
    stop(paste0("Could not find an RLum record for that POSITION: ", pos))
  }

  # Even with a single GRAIN, the alignment can't be trusted if the record count doesn't match.
  if (!inherits(obj, "RLum.Analysis") || nrow(meta_pos) != length(obj)) {
    stop(
      paste0(
        "POSITION ", pos, "'s records are misaligned: ",
        nrow(meta_pos), " METADATA record(s), ",
        length(obj), " RLum record(s). ",
        "The record number and its actual curve could be mismatched, so the analysis is stopped."
      )
    )
  }

  list(
    pos = pos,
    obj = obj,
    meta_pos = meta_pos,
    metadata_index = metadata_index
  )
}

inspect_rlum_records_by_position <- function(path, pos) {
  found <- .load_position_records(path, pos)

  pos <- found$pos
  meta_pos <- found$meta_pos
  metadata_index <- found$metadata_index

  n <- nrow(meta_pos)
  record_index <- seq_len(n)

  get_col <- function(df, col, default = NA) {
    if (col %in% colnames(df)) {
      return(df[[col]])
    }

    rep(default, nrow(df))
  }

  record_type <- as.character(get_col(meta_pos, "LTYPE", "UNKNOWN"))
  dtype <- as.character(get_col(meta_pos, "DTYPE", "UNKNOWN"))
  comment <- as.character(get_col(meta_pos, "COMMENT", ""))
  run <- as.integer(get_col(meta_pos, "RUN", NA))
  set <- as.integer(get_col(meta_pos, "SET", NA))
  irr_time <- as.numeric(get_col(meta_pos, "IRR_TIME", NA))
  npoints <- as.integer(get_col(meta_pos, "NPOINTS", NA))
  low <- as.numeric(get_col(meta_pos, "LOW", NA))
  high <- as.numeric(get_col(meta_pos, "HIGH", NA))
  an_temp <- as.numeric(get_col(meta_pos, "AN_TEMP", NA))
  an_time <- as.numeric(get_col(meta_pos, "AN_TIME", NA))
  light_source <- as.character(get_col(meta_pos, "LIGHTSOURCE", ""))

  record_label <- paste0(
    "#", record_index,
    " | ", record_type,
    " | ", dtype,
    " | ", comment,
    " | RUN ", run,
    " | SET ", set,
    " | IRR ", irr_time
  )

  list(
    position = as.integer(pos),
    n_records = as.integer(n),
    record_index = as.integer(record_index),
    metadata_index = as.integer(metadata_index),
    record_type = as.character(record_type),
    dtype = as.character(dtype),
    comment = as.character(comment),
    run = as.integer(run),
    set = as.integer(set),
    irr_time = as.numeric(irr_time),
    npoints = as.integer(npoints),
    low = as.numeric(low),
    high = as.numeric(high),
    an_temp = as.numeric(an_temp),
    an_time = as.numeric(an_time),
    light_source = as.character(light_source),
    record_label = as.character(record_label)
  )
}

save_rlum_record_plot <- function(path, pos, record_index, output_dir) {
  # Goes through the same alignment check as
  # inspect_rlum_records_by_position(). record_index is a number that
  # function produces, so it's only valid under the same premise.
  found <- .load_position_records(path, pos)

  pos <- found$pos
  obj <- found$obj

  record_index <- as.integer(record_index)

  if (record_index < 1 || record_index > length(obj)) {
    stop(
      paste0(
        "That record index doesn't exist: ",
        record_index,
        " / valid range: 1:",
        length(obj)
      )
    )
  }

  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  output_dir <- normalizePath(
    output_dir,
    winslash = "/",
    mustWork = TRUE
  )

  file_name <- sprintf(
    "position_%03d_record_%03d_rlum.png",
    pos,
    record_index
  )

  file_path <- file.path(output_dir, file_name)

  png(filename = file_path, width = 1200, height = 800, res = 120)

  # macOS's default png device (quartz) only writes the file to disk at
  # dev.off(). So if dev.off() is only registered via on.exit, the
  # normalizePath(mustWork = TRUE) call below would fail while the file
  # still doesn't exist.
  # -> close and flush immediately once drawing finishes; on.exit is kept
  #    only as a safety net against a leaked device on error.
  device_id <- dev.cur()
  on.exit(
    if (dev.cur() == device_id) dev.off(),
    add = TRUE
  )

  plot_RLum(obj[record_index])

  dev.off()

  if (!file.exists(file_path)) {
    stop(paste0("Failed to generate the curve image: ", file_path))
  }

  normalized_file_path <- normalizePath(
    file_path,
    winslash = "/",
    mustWork = TRUE
  )

  list(
    position = as.integer(pos),
    record_index = as.integer(record_index),
    plot_file = as.character(normalized_file_path)
  )
}


# ============================================================
# Version3: SAR analysis
# ============================================================
# Runs SAR analysis per POSITION with the signal/background integral
# decided in the Signal stage, to obtain De values. The resulting
# collection of De values is the input for the next stage (De distribution
# -> CAM/MAM/FMM).
#
# Parsing the integral string
# ---------------------
# signal_tab stores a free-form input string like "1:2". This is a trust
# boundary, so it must be validated the moment it reaches R. Leaving a
# validation failure unchecked would let analyse_SAR.CWOSL() integrate the
# wrong channels and still spit out a De with no error.
.parse_integral <- function(value, label, n_points) {
  if (is.null(value) || length(value) != 1 || is.na(value) || !nzchar(value)) {
    stop(paste0(label, " is empty. e.g. 1:2"))
  }

  parts <- strsplit(trimws(as.character(value)), "[:,-]")[[1]]
  parts <- trimws(parts[nzchar(trimws(parts))])

  if (length(parts) != 2) {
    stop(paste0(label, " has an invalid format: '", value, "' / e.g. 1:2"))
  }

  nums <- suppressWarnings(as.integer(parts))

  if (any(is.na(nums))) {
    stop(paste0(label, " contains a non-numeric value: '", value, "' / e.g. 1:2"))
  }

  if (nums[1] < 1) {
    stop(paste0(label, "'s starting channel must be at least 1: ", nums[1]))
  }

  if (nums[1] > nums[2]) {
    stop(
      paste0(
        label, "'s start is greater than its end: ", nums[1], ":", nums[2],
        " / e.g. ", nums[2], ":", nums[1]
      )
    )
  }

  if (!is.na(n_points) && nums[2] > n_points) {
    stop(
      paste0(
        label, " exceeds the number of measured channels: ", nums[1], ":", nums[2],
        " / this file's channel count (NPOINTS): ", n_points
      )
    )
  }

  as.integer(nums)
}


# Runs SAR for a single POSITION and extracts only the values that are needed.
#
# If plot_dir is given, the dose-response plot is saved as a PNG.
# analyse_SAR.CWOSL() is not called twice for this.
#   Running it once with plot=TRUE inside a png device gets both the return
#   object and the PNG at the same time.
#   (Extracting the table with plot=FALSE and then redrawing with plot=TRUE
#    would run the same computation twice.)
.run_sar_one <- function(path, pos, signal_integral, background_integral,
                         plot_dir = NULL) {
  found <- .load_position_records(path, pos)

  plot_file <- NA_character_
  want_plot <- !is.null(plot_dir) && !is.na(plot_dir) && nzchar(plot_dir)

  if (want_plot) {
    plot_file <- file.path(
      plot_dir,
      sprintf("position_%03d_dose_response.png", pos)
    )

    png(filename = plot_file, width = 1400, height = 1000, res = 150)

    # macOS quartz only writes the file at dev.off(). It's closed
    # explicitly below; on.exit here only prevents a device leak if this
    # exits via an error.
    device_id <- dev.cur()
    on.exit(
      if (dev.cur() == device_id) dev.off(),
      add = TRUE
    )
  }

  res <- analyse_SAR.CWOSL(
    object = found$obj,
    signal_integral = signal_integral,
    background_integral = background_integral,
    plot = want_plot,
    verbose = FALSE
  )

  if (want_plot) {
    dev.off()

    if (!file.exists(plot_file)) {
      stop(paste0("Failed to generate the dose-response plot: ", plot_file))
    }

    plot_file <- normalizePath(plot_file, winslash = "/", mustWork = TRUE)
  }

  if (is.null(res)) {
    stop("SAR analysis did not return a result.")
  }

  data <- get_RLum(res, "data")

  if (is.null(data) || nrow(data) == 0) {
    stop("The SAR result contains no De value.")
  }

  # Quality metrics come in as Criteria/Value rows in the
  # rejection.criteria table. The recycling ratio / recuperation the
  # planning doc requires are pulled out here by name.
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

  # Passing along only the 2 extracted metrics would drop the remaining
  # criteria (testdose error, S/N, etc.). The researcher needs every
  # criterion to judge why something is FAILED, so the whole table is
  # passed through.
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
    plot_file = as.character(plot_file),

    qc_criteria = qc_criteria,
    qc_value = qc_value,
    qc_threshold = qc_threshold,
    qc_status = qc_status
  )
}


# Runs SAR in batch over multiple POSITIONs.
#
# One POSITION failing doesn't abort the whole run.
#   Building a De distribution needs multiple aliquots, and if one is
#   blocked by a fit failure or multi-GRAIN, discarding the rest of the
#   otherwise-valid results would make analysis impossible. Failed
#   POSITIONs are collected separately along with the reason, for the UI
#   to display.
run_sar_analysis <- function(path, positions, signal_integral, background_integral,
                             plot_dir = NULL) {
  loaded <- load_bin_data(path)

  if (is.null(positions) || length(positions) == 0) {
    stop("No POSITIONs were selected for analysis.")
  }

  positions <- sort(unique(as.integer(positions)))

  unknown <- setdiff(positions, loaded$positions)

  if (length(unknown) > 0) {
    stop(
      paste0(
        "These POSITIONs are not in the file: ",
        paste(unknown, collapse = ", ")
      )
    )
  }

  metadata <- loaded$metadata

  n_points <- if ("NPOINTS" %in% colnames(metadata)) {
    suppressWarnings(max(as.integer(metadata$NPOINTS), na.rm = TRUE))
  } else {
    NA_integer_
  }

  if (!is.finite(n_points)) {
    n_points <- NA_integer_
  }

  sig <- .parse_integral(signal_integral, "Signal integral", n_points)
  bg <- .parse_integral(background_integral, "Background integral", n_points)

  if (!is.null(plot_dir) && nzchar(plot_dir)) {
    if (!dir.exists(plot_dir)) {
      dir.create(plot_dir, recursive = TRUE)
    }

    plot_dir <- normalizePath(plot_dir, winslash = "/", mustWork = TRUE)
  }

  ok_position <- integer(0)
  ok_de <- numeric(0)
  ok_de_error <- numeric(0)
  ok_rc_status <- character(0)
  ok_fit <- character(0)
  ok_n_n <- numeric(0)
  ok_recycling <- numeric(0)
  ok_recuperation <- numeric(0)
  ok_plot_file <- character(0)

  # The QC table has multiple rows per POSITION, so a position column is
  # attached and rows are stacked long-form.
  qc_position <- integer(0)
  qc_criteria <- character(0)
  qc_value <- numeric(0)
  qc_threshold <- numeric(0)
  qc_status <- character(0)

  failed_position <- integer(0)
  failed_reason <- character(0)

  for (pos in positions) {
    one <- try(
      .run_sar_one(path, pos, sig, bg, plot_dir),
      silent = TRUE
    )

    if (inherits(one, "try-error")) {
      failed_position <- c(failed_position, pos)
      failed_reason <- c(
        failed_reason,
        trimws(as.character(attr(one, "condition")$message))
      )

      # Delete any leftover empty PNG from a device that opened and closed
      # during the failure. Leaving it behind could be mistaken for "a plot
      # exists, so it succeeded".
      if (!is.null(plot_dir) && nzchar(plot_dir)) {
        stale <- file.path(
          plot_dir,
          sprintf("position_%03d_dose_response.png", pos)
        )

        if (file.exists(stale)) {
          unlink(stale)
        }
      }

      next
    }

    ok_position <- c(ok_position, pos)
    ok_de <- c(ok_de, one$de)
    ok_de_error <- c(ok_de_error, one$de_error)
    ok_rc_status <- c(ok_rc_status, one$rc_status)
    ok_fit <- c(ok_fit, one$fit)
    ok_n_n <- c(ok_n_n, one$n_n)
    ok_recycling <- c(ok_recycling, one$recycling_ratio)
    ok_recuperation <- c(ok_recuperation, one$recuperation)
    ok_plot_file <- c(ok_plot_file, one$plot_file)

    n_rows <- length(one$qc_criteria)

    if (n_rows > 0) {
      qc_position <- c(qc_position, rep(pos, n_rows))
      qc_criteria <- c(qc_criteria, one$qc_criteria)
      qc_value <- c(qc_value, one$qc_value)
      qc_threshold <- c(qc_threshold, one$qc_threshold)
      qc_status <- c(qc_status, one$qc_status)
    }
  }

  if (length(ok_position) == 0) {
    stop(
      paste0(
        "SAR analysis failed for all ", length(positions), " selected POSITION(s). ",
        "First reason: ",
        if (length(failed_reason) > 0) failed_reason[1] else "(no reason given)"
      )
    )
  }

  list(
    signal_integral = as.integer(sig),
    background_integral = as.integer(bg),

    n_requested = as.integer(length(positions)),
    n_success = as.integer(length(ok_position)),
    n_failed = as.integer(length(failed_position)),

    position = as.integer(ok_position),
    de = as.numeric(ok_de),
    de_error = as.numeric(ok_de_error),
    rc_status = as.character(ok_rc_status),
    fit = as.character(ok_fit),
    n_n = as.numeric(ok_n_n),
    recycling_ratio = as.numeric(ok_recycling),
    recuperation = as.numeric(ok_recuperation),
    plot_file = as.character(ok_plot_file),

    qc_position = as.integer(qc_position),
    qc_criteria = as.character(qc_criteria),
    qc_value = as.numeric(qc_value),
    qc_threshold = as.numeric(qc_threshold),
    qc_status = as.character(qc_status),

    failed_position = as.integer(failed_position),
    failed_reason = as.character(failed_reason)
  )
}


# ============================================================
# Version4: De distribution analysis
# ============================================================
# Takes the De collection from SAR (De values + errors), computes
# distribution characteristics, and saves radial/abanico plots as PNGs.
# The resulting metrics (OD, skewness, multimodality) are the input for
# the next stage (CAM/MAM/FMM recommendation).
#
# The statistics use the Luminescence package's own functions as-is
# (project principle: don't reimplement them):
#   - OD (overdispersion) : calc_CentralDose (CAM). the summary's OD(Gy) / rel_OD(%)
#   - Skewness/kurtosis    : calc_Statistics. weighted/unweighted skewness, kurtosis
#
# Determining multimodality (whether to apply FMM) is not done here. The
# standard in the OSL literature is to fit across different component
# counts and compare BIC (calc_FiniteMixture), not to count KDE modes.
# Fixture testing (BT998, n=25) confirmed that KDE mode count is
# unreliable, swinging between 3-4 depending on bandwidth on a small
# sample. So the multimodality determination is handled by the proper
# method in the next stage (model recommendation); this function only
# produces robust metrics like OD/skewness/kurtosis.

# Saves one plot as a PNG. Since macOS quartz only writes the file at
# dev.off() (see the comment in save_rlum_record_plot), it's closed
# explicitly right after drawing and its existence is checked.
.save_de_plot <- function(file_path, draw) {
  png(filename = file_path, width = 1400, height = 1000, res = 150)

  device_id <- dev.cur()
  on.exit(
    if (dev.cur() == device_id) dev.off(),
    add = TRUE
  )

  draw()

  dev.off()

  if (!file.exists(file_path)) {
    stop(paste0("Failed to generate the De distribution plot image: ", file_path))
  }

  normalizePath(file_path, winslash = "/", mustWork = TRUE)
}

# If output_dir is given, radial/abanico PNGs are saved. If not, only the
# metrics are computed (for calls that don't need plots, like the
# r_runner self-check).
analyse_de_distribution <- function(de, de_error, output_dir = NULL, prefix = "de_dist") {
  # --- Input validation ---
  de <- as.numeric(de)
  de_error <- as.numeric(de_error)

  if (length(de) == 0) {
    stop("The De values are empty.")
  }

  if (length(de) != length(de_error)) {
    stop(
      paste0(
        "The number of De values and errors differ: ",
        length(de), " vs ", length(de_error)
      )
    )
  }

  # A mix of NA/non-finite values makes the statistical functions fail, so
  # they're filtered out. How many were dropped is carried in the return
  # value so the UI can show it.
  ok <- is.finite(de) & is.finite(de_error)
  n_dropped <- sum(!ok)
  de <- de[ok]
  de_error <- de_error[ok]

  n <- length(de)

  if (n < 3) {
    stop(
      paste0(
        "De distribution analysis requires at least 3 valid De values (currently ", n, ")."
      )
    )
  }

  # A negative/zero De cannot go through a log-based model (CAM/MAM/FMM).
  # With its default log=TRUE, calc_CentralDose silently falls back to
  # linear mode on a negative value, only leaving a console warning, and
  # produces an OD that can't be compared against log-domain thresholds.
  # This is blocked explicitly before that happens. By convention, a
  # negative De is not discarded but handled with an unlogged model
  # instead (Galbraith & Roberts 2012), but the unlogged path is not
  # supported yet, so it's stopped here for now.
  # ponytail: a hard stop. Add the unlogged MAM/CAM path once single-grain
  # (where negative De is common) support is added.
  n_nonpositive <- sum(de <= 0)
  if (n_nonpositive > 0) {
    stop(
      paste0(
        "There are ", n_nonpositive, " negative or zero De value(s), which prevents applying a log-based model ",
        "(CAM/MAM/FMM). A negative De should be handled with an unlogged model, ",
        "but that is not supported yet."
      )
    )
  }

  # Luminescence's functions take the first two columns positionally (names don't matter).
  data <- data.frame(De = de, De.Error = de_error)

  # --- OD: CAM ---
  cam <- calc_CentralDose(data, verbose = FALSE, plot = FALSE)
  cam_summary <- get_RLum(cam, "summary")

  # --- Skewness/kurtosis ---
  stats <- calc_Statistics(data)

  # --- Save plots (only when output_dir is given) ---
  radial_file <- NA_character_
  abanico_file <- NA_character_

  if (!is.null(output_dir) && !is.na(output_dir) && nzchar(output_dir)) {
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }

    output_dir <- normalizePath(output_dir, winslash = "/", mustWork = TRUE)

    radial_file <- .save_de_plot(
      file.path(output_dir, paste0(prefix, "_radial.png")),
      function() plot_RadialPlot(data)
    )

    abanico_file <- .save_de_plot(
      file.path(output_dir, paste0(prefix, "_abanico.png")),
      function() plot_AbanicoPlot(data)
    )
  }

  list(
    n = as.integer(n),
    n_dropped = as.integer(n_dropped),

    # CAM / overdispersion
    central_de = as.numeric(cam_summary$de),
    central_de_error = as.numeric(cam_summary$de_err),
    od_abs = as.numeric(cam_summary$OD),
    od_abs_error = as.numeric(cam_summary$OD_err),
    od_rel = as.numeric(cam_summary$rel_OD),
    od_rel_error = as.numeric(cam_summary$rel_OD_err),

    # Shape
    skewness = as.numeric(stats$unweighted$skewness),
    skewness_weighted = as.numeric(stats$weighted$skewness),
    kurtosis = as.numeric(stats$unweighted$kurtosis),

    # Spread
    mean_de = as.numeric(stats$unweighted$mean),
    median_de = as.numeric(stats$unweighted$median),
    sd_rel = as.numeric(stats$unweighted$sd.rel),

    radial_plot_file = as.character(radial_file),
    abanico_plot_file = as.character(abanico_file)
  )
}


# ------------------------------------------------------------
# BIC comparison for the FMM multimodality determination
# ------------------------------------------------------------
# Fits component counts k=2..max_k with calc_FiniteMixture and compares
# their BIC against the single-component (k=1) fit. The determination of
# "this is multimodal" itself is not made here — that threshold belongs to
# the recommendation logic (model_recommend.py); this function only
# produces the BIC values needed for the comparison. Choosing discrete
# mixtures via per-component-count BIC is the standard in the OSL
# literature (Galbraith & Green 1990; Roberts et al. 2000; David et al. 2007).
#
# The result is sensitive to sigmab (the assumed within-component
# overdispersion). In the CA1 fixture, sigmab of 0.15 flips the
# determination to multi-component, while 0.30 flips it to
# single-component. So sigmab is taken as an argument and carried in the
# return value, recording which value the determination was made with.
fit_finite_mixture <- function(de, de_error, sigmab = 0.15, max_k = 4L) {
  de <- as.numeric(de)
  de_error <- as.numeric(de_error)

  ok <- is.finite(de) & is.finite(de_error)
  de <- de[ok]
  de_error <- de_error[ok]

  n <- length(de)

  # The component count can't exceed the sample size. Reduce max_k if n is small.
  max_k <- min(as.integer(max_k), n - 1L)

  if (n < 4 || max_k < 2L) {
    stop(paste0("Fitting FMM requires at least 4 valid De values (currently ", n, ")."))
  }

  data <- data.frame(De = de, De.Error = de_error)

  res <- calc_FiniteMixture(
    data,
    sigmab = sigmab,
    n.components = 2:max_k,
    verbose = FALSE,
    plot = FALSE
  )

  bic <- res@data$BIC                         # cols: n.components, BIC
  single_bic <- as.numeric(res@data$single.comp$BIC)
  best_i <- which.min(bic$BIC)

  list(
    sigmab = as.numeric(sigmab),
    single_bic = single_bic,
    k = as.integer(bic$n.components),
    bic = as.numeric(bic$BIC),
    best_k = as.integer(bic$n.components[best_i]),
    best_bic = as.numeric(bic$BIC[best_i]),

    # >0 means the multi-component fit (k>=2) has a lower (better) BIC than the single-component fit.
    delta_bic = as.numeric(single_bic - min(bic$BIC))
  )
}

