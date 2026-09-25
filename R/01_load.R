# R/01_load.R — ① Load: file path -> Risoe.BINfileData.
# The file cache shared by every stage also lives here.

# ============================================================
# Common: cache of loaded files
# ============================================================
# load_bin_data() is called on the first line of every entry point, such as
# inspect_positions / get_record_curve / run_sar_analysis.
# Without a cache, every click on a record re-parses the whole BIN file, so with a
# real-sized measurement file each click stalls for several seconds.
#
# Cache key = normalized path + mtime + size
#   → even for the same path, a change in file content changes the key and invalidates it.
#
# Risoe.BINfileData objects use a lot of memory, so only the most recent N are kept (LRU).

.bin_cache <- new.env(parent = emptyenv())  # so the same .bin file is not parsed twice
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
# The actual key built by lines 20-29 looks like
# /Users/.../R/01_load.R|1790251574.50434|10194
#           path        | modified time (s) | size (bytes)

.bin_cache_get <- function(key) {
  if (!exists(key, envir = .bin_cache, inherits = FALSE)) {
    return(NULL)
  }

  entry <- get(key, envir = .bin_cache, inherits = FALSE)

  # Update LRU (Least Recently Used) bookkeeping
  entry$last_used <- Sys.time()
  assign(key, entry, envir = .bin_cache)

  entry$value
}

.bin_cache_put <- function(key, value) {  # Store value and last_used in .bin_cache under key (path+mtime+size). Old entries are evicted by LRU.
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


# ============================================================
# Common: data loading
# ============================================================
# Reads a BIN/RDA/RData file and returns the Risoe.BINfileData object and metadata
# that the later analysis stages share.

load_bin_data <- function(path) {
  # ------------------------------------------------------------
  # 1. Validate the path input
  # ------------------------------------------------------------
  if (missing(path) || is.null(path) || length(path) != 1 || !nzchar(path)) {
    stop("The file path is empty or invalid.")
  }

  path <- as.character(path)

  # ------------------------------------------------------------
  # 2. Check that the file exists
  # ------------------------------------------------------------
  if (!file.exists(path)) {
    stop(paste0("File not found: ", path))
  }

  # ------------------------------------------------------------
  # 3. Normalize the path
  #    - keeps paths consistent when stored by Python/Streamlit/SQL/JSON
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
  #      The same file (path+mtime+size) is not parsed again.
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
        " / supported: ",
        paste(supported_ext, collapse = ", ")
      )
    )
  }

  object_name <- NA_character_
  bin_data <- NULL

  # An rda/RData file can hold several objects. These values carry which one was
  # picked out of how many up to the caller (UI). A bin file holds one object, so 1.
  n_candidates <- 1L
  ignored_objects <- character(0)

  # ------------------------------------------------------------
  # 5. Load a BIN file
  # ------------------------------------------------------------
  if (ext == "bin") {
    bin_data <- read_BIN2R(
      file = normalized_path,
      verbose = FALSE
    )

    object_name <- "read_BIN2R_result"
  }

  # ------------------------------------------------------------
  # 6. Load an RDA/RData file
  #    - load into a separate environment so the current one is not polluted
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
      stop("No Risoe.BINfileData object was found in the RDA/RData file.")
    }

    # With several candidates the first is used, but this must not pass silently.
    # The order load() returns = the argument order at save time, so which sample
    # gets analysed would be decided by something the researcher cannot see.
    # The pick and the discarded ones go into the return value so the UI can warn.
    n_candidates <- length(candidates)
    object_name <- candidates[1]
    ignored_objects <- candidates[-1]

    bin_data <- get(object_name, envir = load_env)
  }

  # ------------------------------------------------------------
  # 7. Validate the final object type
  # ------------------------------------------------------------
  if (!inherits(bin_data, "Risoe.BINfileData")) {
    stop("The loaded object is not a Risoe.BINfileData object.")
  }

  # ------------------------------------------------------------
  # 8. Validate METADATA
  # ------------------------------------------------------------
  if (is.null(bin_data@METADATA)) {
    stop("The Risoe.BINfileData object has no METADATA slot.")
  }

  if (nrow(bin_data@METADATA) == 0) {
    stop("The METADATA of the Risoe.BINfileData object is empty.")
  }

  metadata <- bin_data@METADATA
  metadata_columns <- colnames(metadata)

  # ------------------------------------------------------------
  # 9. Validate the POSITION column
  # ------------------------------------------------------------
  if (!"POSITION" %in% metadata_columns) {
    stop("No POSITION column was found in METADATA.")
  }

  positions <- sort(unique(metadata$POSITION))
  positions <- positions[!is.na(positions)]

  if (length(positions) == 0) {
    stop("No POSITION information was found.")
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
  # 11. Measurement mode: a file with GRAIN numbers recorded is a single-grain file.
  #     Single-aliquot files have GRAIN = 0. One (POSITION, GRAIN) pair = one grain.
  # ------------------------------------------------------------
  grain_pairs <- data.frame(POSITION = integer(0), GRAIN = integer(0))

  if ("GRAIN" %in% metadata_columns) {
    grain_pairs <- unique(metadata[!is.na(metadata$GRAIN), c("POSITION", "GRAIN")])
    grain_pairs <- grain_pairs[order(grain_pairs$POSITION, grain_pairs$GRAIN), ]
  }

  single_grain <- any(grain_pairs$GRAIN > 0)

  # ------------------------------------------------------------
  # 12. Return (after storing in the cache)
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

    single_grain = single_grain,
    grain_position = as.integer(grain_pairs$POSITION),
    grain = as.integer(grain_pairs$GRAIN),

    record_types = as.character(record_types)
  )

  .bin_cache_put(cache_key, result)

  result
}

# ============================================================
# POSITION summary
# ============================================================
# Summarizes the file structure, metadata and POSITION list of data loaded by load_bin_data().

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

    single_grain = loaded$single_grain,
    grain_position = loaded$grain_position,
    grain = loaded$grain,

    record_types = loaded$record_types
  )
}
