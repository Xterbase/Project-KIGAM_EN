# R/02_signal.R — ② Signal: the RLum record list and signal curves of a chosen POSITION.
# This is the stage where the researcher looks at the curves and sets the signal/background integrals.
#
#   get_record_curve()  returns one record's curve as chart data (the browser draws it)
#
# OSLdecomposition (conditional adoption) plugs in between this stage and ③ SAR.
# ---------------------------
# Fetches the metadata rows and RLum records of the chosen POSITION (+GRAIN) together
# and verifies that their 1:1 alignment actually holds.
#
# Background (important):
#   record_index is built on the premise "metadata row order == RLum record order", and
#   get_record_curve() takes the record out by that number.
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
