# Luminous

> Working name. Renamed from LumiGuide on 2026-09-24; the final name is not decided.

A workflow assistant for luminescence (OSL/TL) dating.

It brings the analysis from raw measurement data to age calculation together in one place,
visualizes it, and helps choose a statistical age model (CAM / MAM / FMM, etc.) based on the
characteristics of the equivalent dose (De) distribution (overdispersion, skewness,
multimodality). The statistics are handled by the R
[`Luminescence`](https://cran.r-project.org/package=Luminescence) package; this project does not
reimplement them.

## Current stage

**Being rebuilt as a web application.** The first version built with Streamlit (ver.1.0) is kept
for reference in `version1_streamlit/`; the analysis layer (`R/`) is hardened first and then
moved into a server-based web application. The web structure is browser → PHP →
`Rscript R/run.R` → analysis layer, and R hands over charts as data (JSON), not images, for the
browser to draw.

```
raw data → signal analysis → De distribution analysis → model recommendation → age model → age calculation → results/report
```

| Component | Location | Status |
|---|---|---|
| ① Load | `R/01_load.R` | Reads BIN/RDA, detects single-grain vs single-aliquot automatically |
| ② Signal | `R/02_signal.R` | Records per POSITION (+GRAIN), signal curve data |
| ③ SAR | `R/03_sar.R` | De and QC classification per analysis unit, single-grain / single-aliquot modes, progress file |
| ④ Distribution diagnostics | `R/04_distribution.R` | Overdispersion, skewness, FMM BIC, radial plot coordinates |
| ⑤ Age model | `R/05_models.R` | Rule-based recommendation → CAM/MAM/FMM applied (draft, awaiting researcher review) |
| ⑥ Dose rate & age | — | To be implemented once the source dose rate is provided |
| Web entry point | `R/run.R` | JSON input → action → JSON output (the contract between PHP and R) |
| Analysis layer entry | `R/Analysis.R` | Loads the stage files above in order |
| ver.1.0 UI | `version1_streamlit/` | Works, but is no longer extended |
| Web UI (PHP) | `web/`, `php/bridge.php` | Upload → signal curve → SAR → De distribution dashboard → model (prototype) |

## Design principles

- **Model selection is deterministic.** The same input and the same thresholds always give the
  same model, because a published age must be reproducible. Literature-based rules pick the
  model; a language model's role is limited to explaining the choice with the literature.
- **Classify, don't silently discard.** Aliquots that fail quality checks are kept together with
  the reasons for the verdict. An automatic exclusion would be a judgment that changes the
  result without leaving a record.
- **Record the parameters that change the result alongside the result.** For example, the
  signal/background integrals change De substantially but are not stored in the measurement
  file, so they are stamped on every SAR result row. The measurement mode, random seed,
  sigmab, and the name and version of the packages used are recorded for the same reason.
- **The same input gives the same result.** Luminescence estimates the De error by random
  simulation, so the seed is fixed per analysis unit. Without it, a borderline grain passes QC
  on one run and fails on the next.

## Known limitations

- **The analysis results have not yet been checked against an independent reference.** The
  self-check only pins the current code's output to prevent regressions. The next verification
  is a grain-by-grain comparison with the researchers' own analysis results.
- **The judgment parameters are not finalized.** The QC criteria are Luminescence defaults; the
  minimum number of De for a model recommendation, sigmab for single-aliquot data, and the
  criterion for choosing an FMM component await the researchers' review.
- **De is currently in seconds (s).** The source dose rate (Gy/s) must be applied to get Gy.
  The "Gy" labels on the ver.1.0 screens are wrong.
- **Do not trust the MAM/FMM distinction on multimodal data yet.** The recommendation rules
  evaluate the positive-skew gate before the multimodality gate, so a genuine multi-component
  mixture can be classified as MAM. This affects published ages, so it will be fixed after
  expert review.
- **Negative/zero De are not supported.** Log-based models cannot be applied, so the analysis
  stops explicitly.

## Requirements

- R + the `Luminescence` package (`jsonlite` is installed together with Luminescence)
- Python 3.14 (for the ver.1.0 app and its self-checks, in the project's own virtualenv)

```r
install.packages("Luminescence")
```

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt   # pandas, rpy2, streamlit
```

## Verification

Instead of a test framework there are `assert`-based self-checks. The analysis layer is checked
the same way the web runs it (`Rscript`), and the fixture is built from Luminescence's bundled
example data, so no measurement data is needed in the repository. If local single-grain test
files (`test_data/`, not committed) are present, those checks run too.

```bash
Rscript R/selfcheck.R        # analysis layer + run.R round trips, ~16 s
```

Calling `R/run.R` directly:

```bash
echo '{"action": "inspect", "args": {"path": "/path/to/file.bin"}}' > in.json
Rscript R/run.R in.json out.json     # 0 on success, 1 on failure; out.json holds the result or the error
```

To run the web app locally (uploaded files are stored in `outputs/samples/` and never committed):

```bash
php -S localhost:8000 -t web -d upload_max_filesize=200M -d post_max_size=200M
```

On the server, deploy with `git clone` and update only with `git pull --ff-only`; never edit code on
the server. The web server's DocumentRoot must point at `web/` only (pointing it at the repository
root would expose `.git/` and uploaded measurement files by URL).

ver.1.0 (legacy) is kept for reference only. The image (PNG) saving functions were removed from the
analysis layer on 2026-09-24, so the ver.1.0 screens and the `r_runner.py` self-check no longer run
against the current R code.

Measurement data (`*.bin`, `*.rda`, etc.) is never committed to the repository.
