# R/05_models.R — ⑤ Age model: De table -> model recommendation (rules) -> burial dose with the chosen model.
#
#   recommend_age_model()  deterministic rules mapping ④'s indicators to CAM/MAM/FMM
#   apply_age_model()      applies one chosen model and returns the dose
#   run_age_model()        ④ indicators + FMM BIC + recommendation + application in one call (the web layer's entry point)
#
# The rules are moved over unchanged from version1_streamlit/utils/model_recommend.py (so the choice
# is reproducible in one place, R). 
# The gate order (skewness MAM before multimodal FMM) is a known defect that can be wrong on multimodal data, but it changes published ages, so it is not changed before expert review.
#
# numOSL mcMAM/mcFMM (conditional adoption) plug in beside apply_age_model(), for comparison.
#
# Threshold sources (same as model_recommend.py):
#   OD 20%     : even well-bleached single-grain quartz typically shows ~20% overdispersion (Arnold & Roberts 2009;
#                Galbraith & Roberts 2012)
#   ΔBIC 6     : lower bound of "strong evidence" in Kass & Raftery (1995)
#   Skew significance : 2 × SES, SES = sqrt(6n(n-1)/((n-2)(n+1)(n+3))); partial-bleaching diagnosis (Bailey & Arnold 2006)

.MODEL_THRESHOLDS <- list(od_low_pct = 20, bic_strong = 6)

.skewness_se <- function(n) {
  sqrt(6 * n * (n - 1) / ((n - 2) * (n + 1) * (n + 3)))
}

# fmm: the result of fit_finite_mixture(), or NULL (not fitted, e.g. insufficient sample or no convergence).
recommend_age_model <- function(od_rel, skewness, n, fmm = NULL) {
  n <- as.integer(n)

  # The OD gate is the root of the tree. Without OD no verdict is possible at all.
  if (is.null(od_rel) || !is.finite(od_rel)) {
    stop("Cannot recommend a model because OD (overdispersion) could not be computed (e.g. no variance).")
  }

  th <- .MODEL_THRESHOLDS
  skew_crit <- 2 * .skewness_se(n)
  skew_known <- !is.null(skewness) && is.finite(skewness)
  positively_skewed <- skew_known && skewness > skew_crit
  dbic <- if (is.null(fmm)) NA_real_ else fmm$delta_bic
  multimodal <- is.finite(dbic) && dbic > th$bic_strong

  reasons <- character(0)

  if (od_rel < th$od_low_pct) {
    model <- "CAM"
    reasons <- c(reasons, sprintf("Overdispersion %.1f%% < %.0f%% → well-bleached single population", od_rel, th$od_low_pct))
  } else if (positively_skewed) {
    model <- "MAM"
    reasons <- c(reasons, sprintf(
      "Overdispersion %.1f%% high + positive skew %.2f > threshold %.2f → partial bleaching (asymmetric upper tail)",
      od_rel, skewness, skew_crit
    ))
  } else if (multimodal) {
    model <- "FMM"
    reasons <- c(reasons, sprintf(
      "Overdispersion high, no significant skew, BIC prefers %d component(s) over single with ΔBIC %.1f (>%.0f) → discrete mixture",
      fmm$best_k, dbic, th$bic_strong
    ))
  } else {
    model <- "CAM"
    reasons <- c(reasons, sprintf(
      "Overdispersion %.1f%% is high but there is no significant skew or multimodality evidence → CAM (note the high overdispersion)", od_rel
    ))
    if (is.null(fmm)) {
      reasons <- c(reasons, "FMM could not be fitted (e.g. insufficient sample), so multimodality could not be checked")
    }
  }

  if (!skew_known && od_rel >= th$od_low_pct) {
    reasons <- c(reasons, "Skewness could not be computed (e.g. insufficient variance), so the partial-bleaching (MAM) check was skipped")
  }

  list(
    model = model,
    reasons = reasons,
    od_rel = as.numeric(od_rel),
    skewness = if (skew_known) as.numeric(skewness) else NA_real_,
    skew_crit = as.numeric(skew_crit),
    positively_skewed = positively_skewed,
    multimodal = multimodal,
    n = n,
    fmm_delta_bic = as.numeric(dbic),
    fmm_best_k = if (is.null(fmm)) NA_integer_ else as.integer(fmm$best_k),
    od_low_pct = th$od_low_pct,
    bic_strong = th$bic_strong
  )
}


# Applies one chosen model. These are log models, so De must be > 0 (same reason as ④).
#
#   CAM  calc_CentralDose : central dose + overdispersion
#   MAM  calc_MinDose     : minimum dose. sigmab = "overdispersion expected if well bleached" (ratio, 0.2 = 20%)
#   FMM  calc_FiniteMixture(n.components = k) : per-component dose, error, proportion.
#        Which component dates the event is a researcher judgment based on the depositional context,
#        so none is picked (dose is NA; only the component table is returned).
#
# The result records the model, sigmab, and package name and version (principle of stamping judgment parameters).
apply_age_model <- function(de, de_error, model, sigmab = NULL, n_components = NULL,
                            mam_par = 3L) {
  model <- match.arg(model, c("CAM", "MAM", "FMM"))

  de <- as.numeric(de)
  de_error <- as.numeric(de_error)

  if (length(de) != length(de_error)) {
    stop("De values and errors differ in count: ", length(de), " vs ", length(de_error))
  }

  ok <- is.finite(de) & is.finite(de_error)
  de <- de[ok]
  de_error <- de_error[ok]
  n <- length(de)

  if (any(de <= 0)) {
    stop("There are ", sum(de <= 0), " negative or zero De values, so a log-based model cannot be applied.")
  }

  # With no more samples than parameters, estimation is not possible at all.
  n_par <- switch(model, CAM = 2L, MAM = as.integer(mam_par), FMM = 2L * as.integer(n_components))
  if (model != "FMM" && n <= n_par) {
    stop(model, " needs at least ", n_par + 1L, " De values (currently ", n, ").")
  }

  if (model %in% c("MAM", "FMM")) {
    if (is.null(sigmab) || !is.finite(sigmab) || sigmab <= 0 || sigmab >= 1) {
      stop(model, " needs sigmab (a ratio between 0 and 1, e.g. 0.2).")
    }
  }

  data <- data.frame(De = de, De.Error = de_error)

  dose <- NA_real_
  dose_error <- NA_real_
  extra <- list()

  if (model == "CAM") {
    s <- get_RLum(calc_CentralDose(data, verbose = FALSE, plot = FALSE), "summary")
    dose <- s$de
    dose_error <- s$de_err
    extra <- list(od_rel = as.numeric(s$rel_OD), od_rel_error = as.numeric(s$rel_OD_err))
  } else if (model == "MAM") {
    s <- get_RLum(
      calc_MinDose(data, sigmab = sigmab, log = TRUE, par = mam_par,
                   bootstrap = FALSE, plot = FALSE, verbose = FALSE),
      "summary"
    )
    dose <- s$de
    dose_error <- s$de_err
    extra <- list(mam_par = as.integer(mam_par), p0 = as.numeric(s$p0))
  } else {
    k <- as.integer(n_components)
    if (length(k) != 1 || is.na(k) || k < 2 || k > .fmm_max_k(n)) {
      stop("FMM (k=", k, ") needs at least ", 2L * k, " De values (currently ", n, ").")
    }

    res <- calc_FiniteMixture(data, sigmab = sigmab, n.components = k,
                              verbose = FALSE, plot = FALSE)
    comp <- res@data$summary  # data.frame: de, de_err, proportion(0~1)

    # Without convergence / with a singular matrix, NA comes back instead of an error. Do not let it pass silently.
    if (is.null(comp) || any(!is.finite(comp$de))) {
      stop("The FMM (k=", k, ") fit is invalid (no convergence, singular matrix, etc.).")
    }

    extra <- list(
      n_components = k,
      component_dose = as.numeric(comp$de),
      component_dose_error = as.numeric(comp$de_err),
      component_proportion = as.numeric(comp$proportion)
    )
  }

  c(
    list(
      model = model,
      n = as.integer(n),
      dose = as.numeric(dose),
      dose_error = as.numeric(dose_error),
      # CAM does not use sigmab. Recording an unused value would make the result misleading.
      sigmab = if (model == "CAM" || is.null(sigmab)) NA_real_ else as.numeric(sigmab),
      package = "Luminescence",
      package_version = as.character(packageVersion("Luminescence"))
    ),
    extra
  )
}


# ④ indicators -> FMM BIC -> rule recommendation -> model application.
# With model given, a model other than the recommended one is applied, recording what was recommended and who chose.
# It does not stop when FMM fails (insufficient sample, no convergence): the rules handle "no FMM".
run_age_model <- function(de, de_error, sigmab, model = NULL, max_k = 4L) {
  dist <- analyse_de_distribution(de, de_error)

  fmm <- tryCatch(fit_finite_mixture(de, de_error, sigmab = sigmab, max_k = max_k),
                  error = function(e) e)
  fmm_error <- NA_character_

  if (inherits(fmm, "error")) {
    fmm_error <- conditionMessage(fmm)
    fmm <- NULL
  } else if (!is.finite(fmm$delta_bic) || is.na(fmm$best_k)) {
    fmm_error <- "The FMM fit is invalid (singular matrix, no convergence, etc.)."
    fmm <- NULL
  }

  rec <- recommend_age_model(dist$od_rel, dist$skewness, dist$n, fmm)

  chosen <- if (is.null(model)) rec$model else model

  n_components <- NULL
  if (chosen == "FMM") {
    if (is.null(fmm)) {
      stop("Applying FMM needs a BIC comparison to set the component count, but the FMM fit failed: ", fmm_error)
    }
    n_components <- fmm$best_k
  }

  applied <- apply_age_model(de, de_error, chosen, sigmab = sigmab, n_components = n_components)

  list(
    distribution = dist,
    fmm = fmm,
    fmm_error = fmm_error,
    recommendation = rec,
    model_source = if (is.null(model)) "rule" else "user",
    result = applied
  )
}
