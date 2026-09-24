# R/04_distribution.R — ④ Distribution diagnostics: De table -> OD, skewness/kurtosis, FMM BIC, radial/abanico plots.
# numOSL sensSAM (conditional adoption) plugs in between this stage's indicators and ⑤ age model, as backing for the model choice.
# ============================================================
# Takes the De values from SAR (De + error), computes the distribution characteristics,
# and saves radial/abanico plots as PNGs. The indicators produced here (OD, skewness, multimodality)
# are the input of the next stage (CAM/MAM/FMM recommendation).
#
# The statistics come straight from Luminescence functions (project principle: do not reimplement):
#   - OD (overdispersion) : calc_CentralDose (CAM). OD (Gy) / rel_OD (%) in the summary
#   - skewness/kurtosis   : calc_Statistics. weighted/unweighted skewness, kurtosis
#
# Multimodality (whether FMM applies) is not judged here. The standard in the OSL literature is to
# fit with varying component counts and compare BIC (calc_FiniteMixture), not to count KDE
# modes. The KDE mode count swings between 3 and 4 with the bandwidth on small samples, which the
# fixture (BT998, n=25) confirmed is unreliable. So multimodality is judged the standard way
# in the next stage (model recommendation), and this function only returns robust indicators such as OD/skewness/kurtosis.

# With output_dir, radial/abanico PNGs are saved. Without it, only the indicators are computed
# (for calls that need no figures, such as the r_runner self-check).
analyse_de_distribution <- function(de, de_error, output_dir = NULL, prefix = "de_dist") {
  # --- input validation ---
  de <- as.numeric(de)
  de_error <- as.numeric(de_error)

  if (length(de) == 0) {
    stop("The De values are empty.")
  }

  if (length(de) != length(de_error)) {
    stop(
      paste0(
        "De values and errors differ in count: ",
        length(de), " vs ", length(de_error)
      )
    )
  }

  # Statistical functions fail when NA/non-finite values are mixed in, so they are dropped.
  # How many were dropped goes into the return value so the UI can tell.
  ok <- is.finite(de) & is.finite(de_error)
  n_dropped <- sum(!ok)
  de <- de[ok]
  de_error <- de_error[ok]

  n <- length(de)

  if (n < 3) {
    stop(
      paste0(
        "De distribution analysis needs at least 3 valid De values (currently ", n, ")."
      )
    )
  }

  # Log-based models (CAM/MAM/FMM) cannot take negative/zero De. calc_CentralDose, under the
  # default log=TRUE, meets a negative value with only a console warning and silently falls back to
  # linear mode, producing an OD not comparable with log-domain thresholds. Stop explicitly before that.
  # By convention negative De are not discarded but handled by unlogged models (Galbraith & Roberts 2012);
  # the unlogged path is not supported yet, so for now the analysis stops.
  # Add unlogged MAM/CAM paths when supporting single-grain data (where negative De are common).
  n_nonpositive <- sum(de <= 0)
  if (n_nonpositive > 0) {
    stop(
      paste0(
        "There are ", n_nonpositive, " negative or zero De values, so log-based models ",
        "(CAM/MAM/FMM) cannot be applied. Negative De should be handled by unlogged ",
        "models, which are not supported yet."
      )
    )
  }

  # Luminescence functions take the first two columns by position (names do not matter).
  data <- data.frame(De = de, De.Error = de_error)

  # --- OD: CAM ---
  cam <- calc_CentralDose(data, verbose = FALSE, plot = FALSE)
  cam_summary <- get_RLum(cam, "summary")

  # --- skewness/kurtosis ---
  stats <- calc_Statistics(data)

  # --- save plots (only with output_dir) ---
  radial_file <- NA_character_
  abanico_file <- NA_character_

  if (!is.null(output_dir) && !is.na(output_dir) && nzchar(output_dir)) {
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }

    output_dir <- normalizePath(output_dir, winslash = "/", mustWork = TRUE)

    radial_file <- .save_png(
      file.path(output_dir, paste0(prefix, "_radial.png")),
      function() plot_RadialPlot(data),
      width = 1400, height = 1000, res = 150, label = "De distribution plot"
    )

    abanico_file <- .save_png(
      file.path(output_dir, paste0(prefix, "_abanico.png")),
      function() plot_AbanicoPlot(data),
      width = 1400, height = 1000, res = 150, label = "De distribution plot"
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

    # shape
    skewness = as.numeric(stats$unweighted$skewness),
    skewness_weighted = as.numeric(stats$weighted$skewness),
    kurtosis = as.numeric(stats$unweighted$kurtosis),

    # spread
    mean_de = as.numeric(stats$unweighted$mean),
    median_de = as.numeric(stats$unweighted$median),
    sd_rel = as.numeric(stats$unweighted$sd.rel),

    radial_plot_file = as.character(radial_file),
    abanico_plot_file = as.character(abanico_file),

    # Data for the browser to draw. de/de_error are the values after dropping NA (same order as radial).
    # Radial plot (Galbraith 1988) coordinates: z = log(De), s = relative error (De.Error/De),
    #   x = 1/s (precision), y = (z - log(CAM central value)) / s (standardized distance).
    # Points on the same line through the origin have the same De. A display transform, not a statistic.
    de = as.numeric(de),
    de_error = as.numeric(de_error),
    radial_x = as.numeric(de / de_error),
    radial_y = as.numeric((log(de) - log(cam_summary$de)) / (de_error / de))
  )
}


# ------------------------------------------------------------
# BIC comparison for judging FMM multimodality
# ------------------------------------------------------------
# Fits component counts k=2..max_k with calc_FiniteMixture and compares their BIC with the
# single component (k=1). The verdict "it is multimodal" is not made here — its threshold
# belongs to the recommendation logic (model_recommend.py); this function only returns the BIC needed for the comparison.
# Choosing a discrete mixture by per-component-count BIC is the standard in the OSL literature
# (Galbraith & Green 1990; Roberts et al. 2000; David et al. 2007).
#
# The result is sensitive to sigmab (the assumed within-component overdispersion). On the CA1 fixture
# sigmab 0.15 gives multiple components and 0.30 a single one. So sigmab is taken as an argument
# and returned, recording which value the verdict used.
.fmm_max_k <- function(n) as.integer(n %/% 2L)

fit_finite_mixture <- function(de, de_error, sigmab = 0.15, max_k = 4L) {
  de <- as.numeric(de)
  de_error <- as.numeric(de_error)

  ok <- is.finite(de) & is.finite(de_error)
  de <- de[ok]
  de_error <- de_error[ok]

  n <- length(de)

  # A k-component FMM has 2k-1 parameters (k doses + k-1 proportions, sigmab fixed), so it needs
  # at least 2k De. The old cap (n-1) fitted up to k=3 (5 parameters) on 4 De, making the BIC comparison meaningless.
  max_k <- min(as.integer(max_k), .fmm_max_k(n))

  if (n < 4 || max_k < 2L) {
    stop(paste0("FMM fitting needs at least 4 valid De values (currently ", n, ")."))
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

    # >0 means multiple components (k>=2) have a lower (better) BIC than a single component.
    delta_bic = as.numeric(single_bic - min(bic$BIC))
  )
}

