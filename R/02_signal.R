# R/02_signal.R — ② Signal: the RLum record list and signal curves of a chosen POSITION.
# This is the stage where the researcher looks at the curves and sets the signal/background integrals.
#
#   inspect_rlum_records_by_position()  per-record summary: LTYPE, DTYPE, RUN, SET, IRR_TIME, NPOINTS, ...
#   save_rlum_record_plot()             saves one record's curve as a PNG
#
# OSLdecomposition (conditional adoption) plugs in between this stage and ③ SAR.
# ---------------------------
# Fetches the metadata rows and RLum records of the chosen POSITION (+GRAIN) together
# and verifies that their 1:1 alignment actually holds.
#
# Background (important):
#   record_index is built on the premise "metadata row order == RLum record order", and
#   save_rlum_record_plot() draws obj[record_index] by that number.
#   If the premise breaks, a curve other than the one the user picked is drawn without error.
#
#   Risoe.BINfileData2RLum.Analysis() builds its result per GRAIN value, so when a
#   POSITION holds several GRAINs (single-grain) and only pos is given, it returns
#   "a list of per-grain RLum.Analysis objects", and obj[record_index] points at a grain.
#   So for single-grain files the grain must be given, and only that grain's records are taken.
#   A request for a multi-GRAIN POSITION without a grain is stopped explicitly instead of drawing a wrong curve.
#
# Why bin_data is taken directly: single-aliquot mode must take records from the object
# converted by convert_SG2MG(), not from the file.

.position_records <- function(bin_data, pos, grain = NULL) {
  metadata <- bin_data@METADATA

  pos <- as.integer(pos)
  in_pos <- metadata$POSITION == pos

  if (!any(in_pos)) {
    stop(paste0("No metadata found for POSITION: ", pos))
  }

  grains <- sort(unique(metadata$GRAIN[in_pos]))
  grains <- grains[!is.na(grains)]

  if (is.null(grain)) {
    if (length(grains) > 1) {
      stop(
        paste0(
          "POSITION ", pos, " has several GRAINs (",
          paste(grains, collapse = ", "),
          "). A GRAIN must be given for single-grain files. ",
          "Without it, record numbers and the actual curves would not match."
        )
      )
    }

    metadata_index <- which(in_pos)
    obj <- Risoe.BINfileData2RLum.Analysis(object = bin_data, pos = pos)
  } else {
    grain <- as.integer(grain)

    if (!(grain %in% grains)) {
      stop(paste0("POSITION ", pos, " has no GRAIN ", grain, "."))
    }

    metadata_index <- which(in_pos & metadata$GRAIN == grain)
    obj <- Risoe.BINfileData2RLum.Analysis(object = bin_data, pos = pos, grain = grain)
  }

  meta_pos <- metadata[metadata_index, , drop = FALSE]
  label <- if (is.null(grain)) paste0("POSITION ", pos) else paste0("POSITION ", pos, " GRAIN ", grain)

  if (length(obj) == 0) {
    stop(paste0("No RLum records found for ", label, "."))
  }

  # If the counts differ, the alignment cannot be trusted.
  if (!inherits(obj, "RLum.Analysis") || nrow(meta_pos) != length(obj)) {
    stop(
      paste0(
        "The records of ", label, " are misaligned: ",
        nrow(meta_pos), " METADATA records, ",
        length(obj), " RLum records. ",
        "Record numbers may not match the actual curves, so the analysis stops."
      )
    )
  }

  list(
    pos = pos,
    grain = if (is.null(grain)) NA_integer_ else grain,
    obj = obj,
    meta_pos = meta_pos,
    metadata_index = metadata_index
  )
}

.load_position_records <- function(path, pos, grain = NULL) {
  .position_records(load_bin_data(path)$bin_data, pos, grain)
}

# Summarizes the record list and per-record metadata of the chosen POSITION (+GRAIN for single-grain files).
inspect_rlum_records_by_position <- function(path, pos, grain = NULL) {
  found <- .load_position_records(path, pos, grain)

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
    grain = as.integer(found$grain),
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

save_rlum_record_plot <- function(path, pos, record_index, output_dir, grain = NULL) {
  # Goes through the same alignment check as inspect_rlum_records_by_position().
  # record_index is a number that function built, so it is valid only on the same premise.
  found <- .load_position_records(path, pos, grain)

  pos <- found$pos
  obj <- found$obj

  record_index <- as.integer(record_index)

  if (record_index < 1 || record_index > length(obj)) {
    stop(
      paste0(
        "No such record index: ",
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

  file_name <- if (is.na(found$grain)) {
    sprintf("position_%03d_record_%03d_rlum.png", pos, record_index)
  } else {
    sprintf("position_%03d_grain_%03d_record_%03d_rlum.png", pos, found$grain, record_index)
  }

  normalized_file_path <- .save_png(
    file.path(output_dir, file_name),
    function() plot_RLum(obj[record_index]),
    width = 1200, height = 800, res = 120, label = "Curve"
  )

  list(
    position = as.integer(pos),
    grain = as.integer(found$grain),
    record_index = as.integer(record_index),
    plot_file = as.character(normalized_file_path)
  )
}



# Returns one record's curve as chart data (the browser draws it).
# x is stimulation time (s) for OSL/IRSL and temperature (°C) for TL; record_type tells which.
get_record_curve <- function(path, pos, record_index, grain = NULL) {
  found <- .load_position_records(path, pos, grain)
  record_index <- as.integer(record_index)

  if (record_index < 1 || record_index > length(found$obj)) {
    stop("No such record index: ", record_index, " / valid range: 1:", length(found$obj))
  }

  curve <- get_RLum(found$obj, record.id = record_index)
  xy <- get_RLum(curve)

  list(
    position = found$pos,
    grain = as.integer(found$grain),
    record_index = record_index,
    record_type = as.character(curve@recordType),
    x = as.numeric(xy[, 1]),
    y = as.numeric(xy[, 2])
  )
}
