# R/Analysis.R — entry point of the analysis layer. source() it to load the stage files in order.
#
# Pipeline (file = stage):
#   01_load.R          ① Load          file path -> Risoe.BINfileData (+cache, shared PNG saving)
#   02_signal.R        ② Signal        BINfileData -> per-POSITION RLum.Analysis, curves
#   03_sar.R           ③ SAR           RLum.Analysis + integrals -> De table + QC
#   04_distribution.R  ④ Distribution  De table -> OD, skewness, FMM BIC
#   05_models.R        ⑤ Age model     De table -> rule recommendation -> CAM/MAM/FMM dose
#   (⑥ dose rate & age not implemented: waiting for the dose rate input)
#
# For where the conditional-adoption packages plug in, see CLAUDE.md "Package review conclusions".

library(Luminescence)

local({
  # Location of this file = ofile of the innermost source() frame. It must work regardless of the
  # working directory or whether it was source()d from inside another script (nested).
  ofiles <- Filter(Negate(is.null), lapply(sys.frames(), function(f) f$ofile))
  here <- dirname(normalizePath(ofiles[[length(ofiles)]], winslash = "/"))

  for (f in c("01_load.R", "02_signal.R", "03_sar.R", "04_distribution.R", "05_models.R")) {
    source(file.path(here, f), local = globalenv())
  }
})
