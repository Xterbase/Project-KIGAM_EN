# `R/` analysis layer — things that bite

It reads Risø `.bin` / `.rda` / `.rdata` into `Risoe.BINfileData` (`load_bin_data`,
LRU-cached), summarizes positions/records, plots curves, runs SAR, and analyses the De
distribution. Validation and error messages live in R and surface as exceptions.

- **`analyse_SAR.CWOSL()` takes the channels themselves**: `signal_integral = 1:2`,
  `background_integral = 900:1000`. `c(900, 1000)` means channels 900 and 1000 only — the
  code passed that form until 2026-09-24, so the background used 2 channels instead of 101
  (Luminescence warned "please check your input"; example POSITION 1 De 1661.3 → 1668.3 s,
  one more aliquot fails QC). `.parse_integral()` returns `c(start, end)` for stamping;
  `.run_sar_one()` expands it with `seq()`.
- **SAR warnings are captured per unit** into the result's `warning` column instead of
  being lost on the console. A QC-passing grain can still carry one (e.g. a zero Lx/Tx
  point, so the dose-response fit ignored its weights) — show it next to that grain.
- **De comes out in seconds, not Gy.** Regeneration doses (`IRR_TIME`) are in seconds and no
  `dose_rate_source` is passed. Passing the source dose rate (Gy/s) to
  `analyse_SAR.CWOSL(dose_rate_source=)` converts De and the dose-response x-axis together.
  Five `Gy` labels in the code (`sar_tab.py`, `de_tab.py`, `r_runner.py`, `04_distribution.R`) are
  currently wrong.
- **`Risoe.BINfileData2RLum.Analysis()` returns a list per GRAIN, not per record.** With
  several GRAINs under one POSITION, `length(obj)` is the GRAIN count and record indices
  point at grains. `.position_records(bin_data, pos, grain)` is the one place that loads
  records: single-grain files need `grain`; a multi-GRAIN POSITION without it `stop()`s.
  A file is single-grain when any `GRAIN > 0` (single-aliquot files record `GRAIN = 0`).
- **Measurement modes.** `run_sar_analysis(mode = "single_grain")` runs SAR per
  (POSITION, GRAIN); `"single_aliquot"` runs it per POSITION, first applying
  `convert_SG2MG()` when the file is single-grain. Results carry `mode`, `grain`, and a
  per-disc summary (`disc_n_units`, `disc_n_accepted`).
- **SAR results are random unless seeded.** `analyse_SAR.CWOSL()` estimates De error by
  Monte Carlo, and the "Palaeodose error" QC criterion uses it — unseeded, a borderline
  grain flipped between pass and fail across seeds (up to 84% De-error change on dim
  grains). `run_sar_analysis()` seeds each unit (`seed`, stamped on results), so a verdict
  does not depend on which other units were selected.
- **The `.bin_cache` key is `path + mtime + size` only.** If an object picker is added (an
  `.rda` may hold several `Risoe.BINfileData`), `object_name` must join the key.
- **Batch stages collect per-item failures instead of aborting.** `run_sar_analysis`
  returns `failed_position` + `failed_reason`, so one bad aliquot doesn't discard the rest.
- **Integral defaults are file-dependent.** `900:1000` assumes 1000 channels; read
  `NPOINTS` instead. Single-grain laser files can start with laser-off channels (the local
  test files: channels 1–5 are background, signal starts at 6), so a fixed early-channel
  default integrates no signal and every grain fails QC.
