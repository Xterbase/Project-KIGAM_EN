# LumiGuide

A workflow assistant for luminescence (OSL/TL) dating interpretation.

It visualizes the analysis pipeline and helps researchers pick a statistical age model
(CAM / MAM / FMM) based on the characteristics of the equivalent-dose (De) distribution
(overdispersion, skewness, multimodality). The statistical heavy lifting is done by the R
`Luminescence` package — this project does not reimplement those statistics, it calls R
via `rpy2`.

## What it does

It provides a step-by-step, tab-based workflow that goes from raw data → signal analysis
→ De distribution analysis → model recommendation → (planned) age calculation → results
and report. The goal is to reduce the uncertainty researchers face when judging "which
model to use given this De distribution" through a standardized, visualized workflow and
evidence-based recommendations.

**The model recommendation is deterministic.** The same input plus the same thresholds
always produce the same model — because a published age value has to be reproducible.
The recommendation does not replace the researcher's judgment; it's a guide that presents
supporting metrics alongside the suggestion.

## Current status

| Stage | Tab | Status |
|---|---|---|
| 1 | Data Upload & Inspect | Implemented |
| 2 | Signal Analysis | Implemented |
| 3 | SAR Analysis | Implemented (De values, QC classification, growth curves, CSV) |
| 4 | De Distribution | Implemented (distribution metrics + CAM/MAM/FMM recommendation) |
| 5 | Model Recommendation | Placeholder — the recommendation logic currently lives inside Tab 4 |

### Known limitations (read before you start)

- **Don't trust the MAM/FMM distinction on multimodal data yet.** The recommendation
  decision tree evaluates the positive-skew gate before the multimodal (FMM) gate.
  Because a lognormal distribution has positive skew in the linear domain regardless of
  partial bleaching, a genuine multi-component mixture can be misclassified as MAM.
  Reordering the gates would affect published age values, so the redesign has been
  deferred until after expert review.
- **Negative/zero De values are not supported.** They are explicitly rejected because a
  log-based model cannot be applied to them. By convention, negative De values are not
  discarded but handled with an unlogged model instead (Galbraith & Roberts 2012); that
  path is not implemented yet.
- **Single-grain (multi-GRAIN) files are blocked.** This is a deliberate block to avoid
  silently plotting an incorrect curve, not a supported feature. Since these are the
  primary target data for MAM/FMM, supporting them is a future priority.

## Requirements

- Python 3.14 (uses the project's own virtualenv)
- R installation + the `Luminescence` package (must be installed system-wide for `rpy2`
  to call it)

On the R side:

```r
install.packages("Luminescence")
```

## Install & run

```bash
source venv/bin/activate          # activate the virtualenv
pip install -r requirements.txt   # install/update dependencies
streamlit run app/main.py         # run the app (main entry point)
```

`requirements.txt` only lists what the code actually imports (`pandas`, `rpy2`,
`streamlit`).

## Structure

Three layers leading down to `rpy2`. Data flows in the **UI → utils → R** direction.

```
app/main.py            Streamlit entry point: page config, sidebar, 5 workflow tabs
  └─ app/tabs/         one module per tab (upload / signal / sar / de implemented)
       └─ app/utils/   bridge + state layer
            └─ R/pipeline.R   R functions running inside the Luminescence package
```

- **`app/utils/r_runner.py`** — the sole gateway into R. `rpy2` is not thread-safe, so
  every R access must go through the lock (`R_LOCK`) pattern here. Tabs must not call R
  directly.
- **`R/pipeline.R`** — the analysis functions. Reads Risø `.bin`/`.rda`/`.rdata` files,
  summarizes positions/records, plots curves, and performs SAR and De distribution
  analysis.
- **`app/utils/state_manager.py`** — models the pipeline as stages with a dependency
  graph. When a stage's input changes, that stage's output and every stage that depends
  on it (directly or indirectly) is invalidated. To add a stage, just add an entry with
  `depends_on` to `SESSION_SCHEMA`.
- **`app/utils/file_utils.py`** — handles uploads and result storage. Analysis results
  must be written to disk (`outputs/samples/{sample_id}/`) as well as session state
  (a project requirement).

More detailed design background and pitfalls live in `CLAUDE.md`.

## Verification

There is no test framework or linter. Instead, each `app/utils/` module carries an
`assert`-based self-check under `__main__`. Run them directly:

```bash
venv/bin/python app/utils/state_manager.py
venv/bin/python app/utils/model_recommend.py
venv/bin/python app/utils/r_runner.py     # requires R + Luminescence installed, ~2s
```

`r_runner.py`'s self-check generates its fixtures on the fly from Luminescence's built-in
example dataset (`CWOSL.SAR.Data`), so no committed data is needed in the repository.
