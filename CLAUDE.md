# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Luminous (working name; renamed from LumiGuide on 2026-09-24, may change again) is a
luminescence (OSL/TL) dating workflow assistant. It visualizes the analysis
pipeline and helps researchers pick a statistical age model (CAM / MAM / FMM, and related
models) from the equivalent-dose (De) distribution.
The statistics are done by the R `Luminescence` package — the project deliberately does
**not** reimplement them.

This repository is the English mirror of the Korean one: same code and content, with source
comments and messages in English. Communication with the user is in Korean.

## Direction reset (2026-09-22)

After a meeting with the domain researchers and the package review that followed, the
project restarts on these decisions (made by the user):

1. **The Streamlit frontend is retired.** The whole ver.1.0 app was moved, unchanged, from
   `app/` to `version1_streamlit/`. Read it for reference only. Since 2026-09-24 it no longer
   runs against the current `R/` (the PNG and record-list functions it called were removed);
   do not restore them for it.
2. **`Luminescence` is the reference implementation.** Other packages are added only for a
   concrete gap, per the conditional-adoption table below — never speculatively.
3. **Analysis first, but not strictly sequential.** `R/Analysis.R` (renamed from
   `pipeline.R` on 2026-09-22) carries the priority, since nearly all unresolved risk is
   there. The order is:
   0. Fix the contract (the three decisions under Open engineering decisions) and prove it
      with the thinnest end-to-end slice on the real server.
   1. Harden `Analysis.R` against that contract **in parallel with** a frontend prototype
      built on mock data shaped by the same contract. Without step 0 the two sides would be
      guessing the interface, which is exactly the integration cost that made parallel work
      a loss before (`멀티에이전트_계획.txt` §5).
   2. Integrate and confirm the requested features end to end.
4. **The end product is a web application** hosted on a server the user provides. Server
   details are still to come — do not assume a stack, OS, or deployment model.

Decision 4 is consistent with the old plan, not a reversal: `멀티에이전트_계획.txt` §3 said
to revisit a backend layer when (a) several researchers need concurrent access, (b) the
analysis server and the screen are physically separate, or (c) the frontend moves off
Streamlit. All three now hold.

## Private context and sources

The repository is public. Requested features, the requirement source, pending inputs from
the researchers, and the list of local-only documents live in **`CLAUDE.local.md`**
(gitignored, loaded automatically). If it is missing, ask the user. **Never copy its
contents** — links, institution names, meeting-derived requirements or figures — into this
file, `README.md`, code comments, or commit messages.

- **Never open a Notion page titled "회의록", nor the local folder `회의록&자료/회의록/`.**
  Both contain personal information. This holds even when they look relevant; ask the user
  instead.
- Local-only documents (`회의록&자료/`, `멀티에이전트_계획.txt`) are gitignored — never
  commit them. Keep one issue list (the planning doc); do not start dated note files.

The target data is **single-grain** (one grain per hole on a multi-hole disc, hundreds to
thousands of grains per sample); both modes are handled by `run_sar_analysis(mode=)`. "Single aliquot" in
the requirements means a *multi-grain* aliquot: one De per disc. SAR is the protocol for
both.

## Package review conclusions

From `루미네선스_분석패키지_검토.html` (Luminescence 1.2.1 installed; CRAN latest 1.3.1).

- **Luminescence covers nearly every requested feature.** It ships 10 De-distribution
  models (`calc_CentralDose`, `calc_MinDose`, `calc_FiniteMixture`, `calc_CommonDose`,
  `calc_MaxDose`, `calc_AverageDose`, `calc_IEU`, `calc_FuchsLang2001`,
  `calc_WodaFuchs2008`, `calc_EED_Model`), 2 fading corrections, 3 distribution
  diagnostics, single-grain helpers (`subset_SingleGrainData`, `verify_SingleGrainData`,
  `convert_SG2MG`, `plot_SingleGrainDisc`), and all dashboard plots. `convert_SG2MG`
  **sums the signals** of all grains on a disc into one synthetic aliquot (then SAR gives
  one De per disc); it does not average grain De values.
- **Package choice does not decide accuracy.** The same estimator (e.g. Galbraith 1999
  CAM) gives the same answer in any package. Accuracy is decided by three researcher
  judgments — integral choice (~15% De shift), which grains are kept, and which model
  is applied. Each added package adds a fourth: "which package was used".
- **Conditional adoption** (add only when the condition actually occurs):

  | Condition | Add | Plugs in at (stage, see Code as it stands) |
  |---|---|---|
  | Model choice needs quantitative backing | numOSL `sensSAM` | between ④ and ⑤ — backs the rule pick, does not replace it |
  | ML estimates insufficient for MAM/FMM uncertainty | numOSL `mcMAM`, `mcFMM` | ⑤, beside `calc_MinDose` / `calc_FiniteMixture` (comparison, not replacement) |
  | Medium/slow component contamination found in real data | `OSLdecomposition` | between ② and ③: `RLum.OSL_global_fitting` → `RLum.OSL_decomposition` returns `RLum.Analysis` meant for `analyse_SAR.CWOSL`; replaces the channel-integral signal, so stamp it on results |
  | DRAC's external transfer is not allowed | numOSL `calDA` (offline) | ⑥, instead of `use_DRAC()` |

  The numOSL functions above take a two-column (De, error) matrix — `cbind(de, de_error)`;
  `calDA` takes numeric inputs (U/Th/K, grain size, water content, depth, location). A
  conversion layer is needed only if numOSL's own BIN pipeline were used, which is not
  planned. Neither numOSL nor OSLdecomposition is installed yet.
  **DRAC is a web service, not a package**: `use_DRAC()` sends sample data to Durham's
  server — check the institution's data policy first. RLumShiny is a GUI layer (a design
  reference for which parameters to expose), not an analysis supplement.
- **CSV import is not supported by Luminescence** (`import_Data` reads BIN/BINX, XSYG,
  Daybreak, PSL, RF, SPE, TIFF, HeliosOSL). A CSV of computed De values is trivial
  (`read.csv` → any `calc_*`); a raw Risø CSV export needs a rebuild into `RLum.Analysis`.
  Don't start either until the file type is known.

Several pieces of work wait on inputs from the researchers (listed in `CLAUDE.local.md`) —
notably the source dose rate, without which De stays in seconds. Do not guess them.

## Open engineering decisions

Decide these before hardening `Analysis.R`'s public functions, since each one changes their
signatures:

- **Output contract — decided (2026-09-24): R returns plot *data*; the browser draws.** The
  researchers find the plots of their current tools and of R hard to read, so the frontend
  draws richer, colour-coded charts. `R/run.R` is the only interface:
  `Rscript R/run.R input.json output.json`, input `{"action", "args"}`, output
  `{"ok", "action", "result" | "error", "meta"}`, exit 0/1 (the file is written either way).
  Actions: `inspect`, `curve`, `sar`, `dose_response`, `age_model`. JSON rules the browser
  relies on: array fields stay arrays even with one element (`I()`), tables are arrays of row
  objects, NA/NaN/Inf become `null`, numbers are not rounded. The analysis layer draws no
  images: the PNG path (`save_rlum_record_plot`, `.save_png`, `plot_dir`, radial/abanico
  `output_dir`) and `inspect_rlum_records_by_position` were removed on 2026-09-24.
  - Chart data sources: `get_record_curve()` (②), `get_dose_response()` (③, same data and
    seed as `run_sar_analysis()`, so De matches the table), `analyse_de_distribution()`'s
    `radial_x/radial_y` (④, Galbraith radial coordinates around the CAM centre).
  - The dose-response `curve_x/curve_y` evaluate Luminescence's `Formula`, whose
    coefficients are rounded to 3 significant digits — display only (~0.03% off at De);
    De itself comes from the unrounded fit.
  - `inspect` returns every record row (~240 KB for 882 records). A full single-grain file
    (~86,000 records) would be ~24 MB — paginate or filter before that reaches a browser.
- **R bridge — decided (2026-09-24): PHP calls `Rscript` per request (approach A).** The
  server runs nginx + Apache + PHP; SSH is the admin channel only, not the request path.
  Request flow: browser → nginx → Apache → PHP → `Rscript R/run.R` → `R/Analysis.R`.
  No Python backend is planned, so `r_runner.py` does not survive into the web build.
  `model_recommend.py`'s rules move to R, so selection is reproducible in one place.
  Consequences:
  - Each request is a fresh R process, so the in-memory `.bin_cache` only helps within one
    request. Cache the parsed `Risoe.BINfileData` to disk (`saveRDS`/`readRDS`, keyed like
    `.bin_cache`) and reuse stage outputs from the sample folder, invalidated by
    dependency as in `state_manager.py`. Move to a resident R process (`plumber`) only if
    measured load times demand it.
  - Pass user input to R with `escapeshellarg()` or a JSON file, never interpolated into
    a shell string.
  - Measure on the server: BIN parse vs `readRDS` time, and full single-grain SAR runtime.
    If SAR exceeds PHP's execution limit, run it as a background job with progress.
- **Execution model.** SAR runs serially per unit (POSITION, or POSITION + GRAIN);
  `run_sar_analysis(progress_file=)` rewrites `{"done", "total"}` JSON atomically after each
  unit, for the web layer's progress bar. At single-grain scale (thousands of
  grains) the runtime is unmeasured on the server; if it is minutes, the web layer needs
  background jobs with progress. Local trial: ~0.04–0.06 s per grain SAR, so ~4,800 grains
  ≈ 3–5 min serial — above PHP's default 30 s limit.
- **Frontend stack.** PHP renders pages (HTML/CSS/JS in the browser); the JS/UI approach
  beyond that is open. Decided: no separate SAR screen —
  SAR exists to feed the De distribution, so its results (De, QC verdicts) are shown within
  the distribution view.
- **LLM layer.** RAG over an OCR'd luminescence-literature corpus that *explains* the
  rule-picked model with citations. Its interaction shape (free prompt vs structured
  narration) is not decided — do not assume a chat UI.

## Commands

The analysis layer needs only R. The project virtualenv (Python 3.14) is kept for the legacy
code, whose pure-Python checks still pass:

```bash
Rscript R/selfcheck.R                                       # analysis-layer self-check (~15 s)
source venv/bin/activate
venv/bin/python version1_streamlit/utils/model_recommend.py
venv/bin/python version1_streamlit/utils/file_utils.py
venv/bin/python version1_streamlit/utils/state_manager.py   # Streamlit-specific
```

There is no test suite or linter. `R/selfcheck.R` is the analysis layer's test and runs the
way the web layer will (`Rscript`); it builds its fixture from the installed package, so it
needs no committed data. Add new checks there. The legacy `r_runner.py` self-check and the
Streamlit UI no longer run (they call removed R functions).

## Code as it stands

```
R/Analysis.R                     entry point: library() + sources the stage files  ← the focus now
R/01_load.R                      ① path → Risoe.BINfileData; file cache
R/02_signal.R                    ② POSITION → RLum.Analysis records, curve plots
R/03_sar.R                       ③ RLum.Analysis + integrals → De table + QC
R/04_distribution.R              ④ De table → OD, skewness, FMM BIC, radial/abanico
R/05_models.R                    ⑤ De table → rule recommendation → CAM/MAM/FMM dose (run_age_model)
                                 ⑥ dose rate & age: not written (dose rate pending)
R/run.R                          web entry point: JSON in → action → JSON out (the PHP ↔ R contract)
R/selfcheck.R                    analysis-layer self-check (Rscript), including run.R round trips
version1_streamlit/              the ver.1.0 app, moved intact (imports are relative to it)
  utils/r_runner.py              the only crossing point into R (rpy2)   ← not carried into the web build
  utils/file_utils.py            sample_id + per-sample folder layout, CSV output
  utils/model_recommend.py       the same rules in Python — legacy; the R copy in 05_models.R leads
  main.py, tabs/, utils/state_manager.py   Streamlit UI
```

`r_runner.py` resolves `R/Analysis.R` as `parents[2]` of itself, so keep
`version1_streamlit/` directly under the repo root or that path breaks. `Analysis.R` finds
the stage files next to itself (innermost `source()` frame's `ofile`), so it must be loaded
with `source()`.

### `R/` analysis layer — things that bite

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

### `r_runner.py` (while rpy2 is the bridge)

`Analysis.R` is `source()`d once (`_ANALYSIS_LOADED` + `R_LOCK`); every R call runs under
`R_LOCK` inside `default_converter.context()`. rpy2 is not thread-safe — never call
`rpy2.robjects.r[...]` from elsewhere.

**Unpack R vectors through the `r_*_list` / `r_scalar_*` helpers**, never a bare
`int(x) if x is not None`: rpy2 returns per-type NA sentinels, not `None` — `NA_integer_`
arrives as `-2147483648`, `NA_character_` as the string `"NA_character_"` (a `str`
subclass, so `isinstance` won't catch it; `is_r_na()` compares by identity), `NA_real_` as
`nan`.

### Legacy Streamlit layer

The one idea worth carrying into the web build is `state_manager.py`'s invalidation rule:
stages declare `depends_on`, and a changed input invalidates that stage and everything that
depends on it **transitively — by dependency, not by order**. Everything else there
(widget-key rules, `st.session_state` flattening) is Streamlit-specific.

## Design principles (carry into the new build)

- **Reproducibility decides model selection.** Same input → same model, or the age is not
  publishable. Rules select CAM/MAM/FMM; the LLM (RAG) only explains the pick with
  literature citations and may offer a second opinion near a rule's boundary. A design where
  the LLM itself chooses reopens this and needs its own justification.
- **Classify, don't silently filter.** SAR marks aliquots accepted/rejected (all six
  `rejection.criteria` rows per POSITION) and keeps both. Narrowing the grains to a final
  subset fits this: keep every grain with its verdict, present the accepted list
  separately. An automatic drop is a judgment that changes the result and leaves no record.
- **Stamp the judgment parameters onto results.** Integrals are written onto every SAR row
  because they shift De ~15% and are not in the data file. Anything else that changes the
  result (dose rate, sigmab, model thresholds) follows the same rule. So do the **name and
  version of every analysis package** that produced a result — Luminescence included, not
  only supplements (installed 1.2.1 vs CRAN 1.3.1 can differ). Store them in the result
  file itself, and show them in the frontend below the result they belong to.
- **Results are written to disk**, not only held in memory (project requirement).
  `file_utils.py` defines `outputs/samples/{sample_id}/{raw,inspect,curve_plot,analysis_results}/`;
  a new SAR run deletes the previous CSVs first, so a file never mixes two runs.
- **Measurement data is never committed** (`*.bin`, `*.rda`, … in `.gitignore`).

## Current state

Implemented in ver.1.0 (Streamlit): upload, signal analysis, SAR (De, QC classification,
dose-response plots, CSV), De distribution (OD, skewness, FMM BIC, radial/abanico) with
rule-based recommendation in `model_recommend.py`.

Known defects to resolve in the analysis-first phase:

- **Single-grain QC uses Luminescence's default rejection criteria** — the researchers'
  selection criteria are pending.
- **De unit** is seconds (above) — needs the dose rate.
- **Stage ⑤ is a first draft for researcher review.** `run_age_model()` picks the model by
  rule (or takes the user's, recorded as `model_source`) and applies it. FMM returns every
  component and does not pick one — which component dates the event is a depositional
  judgment. sigmab is an explicit input: 0.20 for single grains is literature-backed
  (well-bleached single-grain quartz OD ~20%, Arnold & Roberts 2009); 0.15 for aliquots is
  the legacy default and unconfirmed.
- **No minimum sample size gates the recommendation.** With the local files, 3–4 accepted
  De reach ⑤ and get a CAM dose; that is computable but statistically weak. Only the
  mathematical floors are enforced (De > model parameters; FMM with k components needs 2k
  De). A threshold must come from the researchers, not be guessed.
- **Recommendation gate order is wrong for multimodal data.** The positive-skew (MAM) gate
  runs before the multimodality (FMM) gate, and skewness is computed on raw De, where a
  lognormal is always right-skewed — so genuine 2–3 component mixtures are classified MAM.
  Do not reorder without expert review (it changes published ages); until then, do not
  trust MAM/FMM separation on multimodal data. Negative/zero De stops explicitly (the
  unlogged path is not implemented).
- **Scale is untested**: 24 POSITIONs today vs thousands of grains.

**Verification baseline** (for spotting drift): `ExampleData.BINfileData`
(`CWOSL.SAR.Data`) has 24 POSITIONs; a clean SAR run (`1:2` / `900:1000`, seed 1) gives
24/24 analysed, 21 passing QC (POSITIONs 8, 11, 22 fail; 22 on recycling ratio 1.114 > 1.1),
De 673.1–1883.3 **s** (seconds — see the unit note), CV ~17%; the 21 accepted give OD 18.9%
→ CAM 1391.9 ± 58.4 s. `ExampleData.DeValues`: CA1 → FMM (k = 3, ΔBIC 95.5), BT998 → CAM
2936 s. `R/selfcheck.R` asserts all of this. Local test inputs (`test_data/`) are gitignored
and never committed: hand-made multi-GRAIN and subset `.bin` files, plus two real
single-grain files (`bin.BIN`, `bin2.BIN`: 49 grains each, laser off in channels 1–5). With
integrals `6:10` / `81:100` and seed 1, single-grain mode passes 4 and 3 grains;
single-aliquot mode passes discs 1, 7, 8 and 5, 7, 8. `R/selfcheck.R` asserts these when
the files exist.
