# R/selfcheck.R — self-check of the analysis layer. Run: Rscript R/selfcheck.R
#
# Expected values are measured with Luminescence 1.2.1 (after the fix that passes the full integral range, 2026-09-24). A mismatch means the package was upgraded or the computation changed,
# and which one it is directly affects ages, so a person must judge.
# The single-grain checks run only when test_data/ (gitignored, measurement data) exists.

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- dirname(normalizePath(sub("^--file=", "", script_arg)))
source(file.path(here, "Analysis.R"))

tmp <- tempfile("selfcheck_")
dir.create(tmp)

expect_error <- function(expr, pattern) {
  msg <- tryCatch({ expr; NA_character_ }, error = function(e) conditionMessage(e))
  stopifnot("expected an error but it passed" = !is.na(msg), grepl(pattern, msg))
}

# ------------------------------------------------------------
# 1. single-aliquot baseline (fixture built from the package example data)
# ------------------------------------------------------------
data(ExampleData.BINfileData, package = "Luminescence", envir = environment())
fixture <- file.path(tmp, "fixture.rda")
save(CWOSL.SAR.Data, file = fixture)

info <- inspect_positions(fixture)
stopifnot(
  "24 POSITIONs" = identical(info$positions, 1:24),
  "example data is single-aliquot" = !info$single_grain
)

progress <- file.path(tmp, "progress.json")
sar <- run_sar_analysis(fixture, 1:24, "1:2", "900:1000", progress_file = progress)

stopifnot(
  "24/24 analysed" = sar$n_success == 24,
  "21 pass QC" = sum(sar$rc_status == "OK") == 21,
  "POSITIONs 8, 11, 22 fail" = identical(sar$position[sar$rc_status != "OK"], c(8L, 11L, 22L)),
  "De range 673.1–1883.3 s" = min(sar$de) > 673 && max(sar$de) < 1884,
  "POSITION 1 De 1668.3" = abs(sar$de[1] - 1668.3) < 0.1,
  "POSITION 2 De 1534.5" = abs(sar$de[2] - 1534.5) < 0.1,
  # Passing the integral as c(start, end) integrates only two channels and raises this warning (past defect).
  "no integral warning" = !any(grepl("please check your input", sar$warning)),
  "single-aliquot has grain NA" = all(is.na(sar$grain)),
  "progress file shows completion" = identical(readLines(progress), '{"done": 24, "total": 24}')
)

expect_error(
  run_sar_analysis(fixture, 1:2, "1:2", "900:1000", mode = "single_grain"),
  "only possible for files with GRAIN numbers"
)

curve <- get_record_curve(fixture, 1, 2)
stopifnot("curve data" = length(curve$x) == length(curve$y) && length(curve$x) > 1)

cat("[OK] single-aliquot baseline\n")

# ------------------------------------------------------------
# 2. single-grain files: A (per grain) and B (per disc, convert_SG2MG)
#    The integral 6:10 is the range after the laser turns on (the first 5 channels are laser-off).
# ------------------------------------------------------------
sg_cases <- list(
  list(file = "bin.BIN",  n_pos = 11, a_ok = 4, a_de = c(1195, 2428), b_ok = c(1L, 7L, 8L)),
  list(file = "bin2.BIN", n_pos = 21, a_ok = 3, a_de = c(1157, 1339), b_ok = c(5L, 7L, 8L))
)

for (case in sg_cases) {
  f <- file.path(here, "..", "test_data", case$file)

  if (!file.exists(f)) {
    cat("[SKIP]", case$file, "not found\n")
    next
  }

  info <- inspect_positions(f)
  stopifnot(
    "single-grain detected" = info$single_grain,
    "49 grains" = length(info$grain) == 49,
    "disc count" = info$n_positions == case$n_pos
  )

  p1 <- info$grain_position[1]
  g1 <- info$grain[1]

  # A disc with several grains must be refused when requested without a GRAIN (prevents misaligned curves).
  p_multi <- as.integer(names(which(table(info$grain_position) > 1))[1])
  expect_error(get_record_curve(f, p_multi, 1), "A GRAIN must be given")

  recs <- .load_position_records(f, p1, grain = g1)
  stopifnot("records of one grain" = length(recs$obj) %in% c(16L, 18L), recs$grain == g1)

  curve <- get_record_curve(f, p1, 1, grain = g1)
  stopifnot("grain curve data" = curve$grain == g1 && length(curve$y) == 100)

  # Single-aliquot mode curve = the sum of that disc's grain curves (convert_SG2MG).
  disc <- get_record_curve(f, p_multi, 1, mode = "single_aliquot")
  gs <- info$grain[info$grain_position == p_multi]
  summed <- Reduce(`+`, lapply(gs, function(g) get_record_curve(f, p_multi, 1, grain = g)$y))
  stopifnot("disc summed curve" = isTRUE(all.equal(disc$y, summed)))

  a <- run_sar_analysis(f, info$positions, "6:10", "81:100", mode = "single_grain")
  a_de <- a$de[a$rc_status == "OK"]
  stopifnot(
    "A: 49 units" = a$n_requested == 49,
    "A: QC pass count" = length(a_de) == case$a_ok,
    "A: De range" = all(a_de >= case$a_de[1] & a_de <= case$a_de[2]),
    "A: per-disc grain total" = sum(a$disc_n_units) == 49,
    "A: per-disc pass total" = sum(a$disc_n_accepted) == case$a_ok
  )

  # Reproducibility: with a different global RNG state, and with only some discs selected, a grain must get the same verdict.
  set.seed(999)
  a2 <- run_sar_analysis(f, info$positions[1:3], "6:10", "81:100", mode = "single_grain")
  k <- match(paste(a2$position, a2$grain), paste(a$position, a$grain))
  stopifnot(
    "A: seed stamped" = a$seed == 1L,
    "A: reproducible (De)" = identical(a2$de, a$de[k]),
    "A: reproducible (verdict)" = identical(a2$rc_status, a$rc_status[k])
  )

  b <- run_sar_analysis(f, info$positions, "6:10", "81:100", mode = "single_aliquot")
  stopifnot(
    "B: one per disc" = b$n_requested == case$n_pos,
    "B: discs passing QC" = identical(b$position[b$rc_status == "OK"], case$b_ok)
  )

  cat("[OK]", case$file, "A/B\n")
}

# ------------------------------------------------------------
# 3. ⑤ Age model: the rules must match model_recommend.py's regression baseline.
#    CA1 (n=62): OD 34.7%, symmetric, ΔBIC 95.5 -> FMM (k=3) / BT998 (n=25): OD 8.0% -> CAM
# ------------------------------------------------------------
data(ExampleData.DeValues, package = "Luminescence", envir = environment())
ca1 <- ExampleData.DeValues$CA1
bt <- ExampleData.DeValues$BT998

r_ca1 <- run_age_model(ca1[[1]], ca1[[2]], sigmab = 0.15)
stopifnot(
  "CA1 -> FMM" = r_ca1$recommendation$model == "FMM",
  "CA1 ΔBIC" = abs(r_ca1$recommendation$fmm_delta_bic - 95.5) < 0.1,
  "CA1 3 components" = r_ca1$result$n_components == 3,
  "CA1 proportions sum to 1" = abs(sum(r_ca1$result$component_proportion) - 1) < 0.01,
  "FMM does not pick a component" = is.na(r_ca1$result$dose),
  "rule choice recorded" = r_ca1$model_source == "rule"
)

r_bt <- run_age_model(bt[[1]], bt[[2]], sigmab = 0.15)
stopifnot(
  "BT998 -> CAM" = r_bt$recommendation$model == "CAM",
  "BT998 CAM dose" = abs(r_bt$result$dose - 2936) < 1,
  "CAM does not use sigmab" = is.na(r_bt$result$sigmab),
  "package version stamped" = r_bt$result$package_version == as.character(packageVersion("Luminescence"))
)

m_ca1 <- run_age_model(ca1[[1]], ca1[[2]], sigmab = 0.15, model = "MAM")
stopifnot(
  "user choice recorded" = m_ca1$model_source == "user",
  "recommendation kept" = m_ca1$recommendation$model == "FMM",
  "MAM sigmab stamped" = m_ca1$result$sigmab == 0.15,
  "CA1 MAM dose" = abs(m_ca1$result$dose - 40.09) < 0.1
)

expect_error(apply_age_model(bt[[1]], bt[[2]], "MAM"), "sigmab")
expect_error(apply_age_model(c(10, 12, 11, 13), c(1, 1, 1, 1), "FMM", sigmab = 0.2, n_components = 3), "at least 6 De")

# Example data end to end: 21 pass QC -> OD 18.9% -> CAM
acc <- sar$rc_status == "OK"
r_ex <- run_age_model(sar$de[acc], sar$de_error[acc], sigmab = 0.15)
stopifnot(
  "example -> CAM" = r_ex$recommendation$model == "CAM",
  "example CAM dose 1391.9" = abs(r_ex$result$dose - 1391.9) < 0.1
)

cat("[OK] ⑤ age model\n")

# ------------------------------------------------------------
# 4. run.R (web entry point): run with Rscript exactly as PHP calls it.
#    Pins the JSON rules the browser relies on (arrays stay arrays with one element, tables are arrays of row objects).
# ------------------------------------------------------------
library(jsonlite)

call_run <- function(action, args) {
  inp <- tempfile(fileext = ".json", tmpdir = tmp)
  out <- tempfile(fileext = ".json", tmpdir = tmp)
  write_json(list(action = action, args = args), inp, auto_unbox = TRUE, digits = NA)
  status <- system2(file.path(R.home("bin"), "Rscript"), c(file.path(here, "run.R"), inp, out),
                    stdout = FALSE, stderr = FALSE)
  c(fromJSON(out, simplifyVector = FALSE), list(status = status))
}

r <- call_run("inspect", list(path = fixture))
stopifnot(
  "inspect succeeds" = r$ok && r$status == 0,
  "records table" = length(r$result$records) == nrow(CWOSL.SAR.Data@METADATA),
  "positions array" = length(r$result$positions) == 24
)

r <- call_run("curve", list(path = fixture, position = 1, record_index = 2))
stopifnot("curve data" = r$ok && length(r$result$x) == length(r$result$y) && length(r$result$x) > 1)

prog <- file.path(tmp, "run_progress.json")
r <- call_run("sar", list(path = fixture, positions = 1, signal_integral = "1:2",
                          background_integral = "900:1000", progress_file = prog))
stopifnot(
  "sar succeeds" = r$ok,
  "units is an array even for one POSITION" = is.list(r$result$units) && length(r$result$units) == 1,
  "sar De = direct R computation" = abs(r$result$units[[1]]$de - sar$de[1]) < 1e-9,
  "integral array" = length(r$result$signal_integral) == 2,
  "progress" = identical(readLines(prog), '{"done": 1, "total": 1}')
)

r <- call_run("dose_response", list(path = fixture, position = 1, signal_integral = "1:2",
                                    background_integral = "900:1000"))
stopifnot(
  "dose_response De = table" = r$ok && abs(r$result$de - sar$de[1]) < 1e-9,
  "points table" = length(r$result$points) >= 5,
  "curve data" = length(r$result$curve_x) == 100
)

r <- call_run("age_model", list(de = ca1[[1]], de_error = ca1[[2]], sigmab = 0.15))
stopifnot(
  "age_model succeeds" = r$ok,
  "FMM component table" = length(r$result$result$components) == 3,
  "FMM dose is null" = is.null(r$result$result$dose),
  "radial coordinates" = length(r$result$distribution$points) == 62,
  "reasons array" = is.list(r$result$recommendation$reasons)
)

r <- call_run("nope", list())
stopifnot("unknown action fails" = !r$ok && r$status == 1 && grepl("Unknown action", r$error))

r <- call_run("inspect", list(path = file.path(tmp, "missing_file.bin")))
stopifnot("R error delivered as JSON" = !r$ok && r$status == 1 && grepl("File not found", r$error))

cat("[OK] run.R\n")

unlink(tmp, recursive = TRUE)
cat("selfcheck OK\n")
