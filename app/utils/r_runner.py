import math
from pathlib import Path
from threading import Lock

import rpy2.robjects as ro
from rpy2 import rinterface
from rpy2.robjects import default_converter


# ========================================================================================================================

# 1. Path setup and base functions
## Project path setup
BASE_DIR = Path(__file__).resolve().parents[2]
R_PIPELINE_PATH = BASE_DIR / "R" / "pipeline.R"


## Safety setup for rpy2
R_LOCK = Lock()
_PIPELINE_LOADED = False


## VECTOR -> LIST
def r_vector_to_list(r_vector) -> list:
    if r_vector is None:
        return []

    if type(r_vector).__name__ == "NULLType":
        return []

    return list(r_vector)


# ========================================================================================================================

# 2. Converting R NA -> Python None
#
# rpy2 gives back R's NA not as None but as a per-type sentinel object.
# Applying int()/str() to it directly silently corrupts the value.
#
#   int(NA_integer_)   -> -2147483648
#   str(NA_character_) -> "NA_character_"   (NACharacterType subclasses str, so it isn't filtered out)
#   NA_real_           -> float("nan")
#
# So the sentinel must always be checked with `is` identity.

_R_NA_SENTINELS = (
    rinterface.NA_Character,
    rinterface.NA_Integer,
    rinterface.NA_Logical,
    rinterface.NA_Real,
)


def is_r_na(value) -> bool:
    if value is None:
        return True

    if any(value is na for na in _R_NA_SENTINELS):
        return True

    if isinstance(value, float) and math.isnan(value):
        return True

    return False


def r_int_list(r_vector) -> list[int | None]:
    return [
        None if is_r_na(x) else int(x)
        for x in r_vector_to_list(r_vector)
    ]


def r_float_list(r_vector) -> list[float | None]:
    return [
        None if is_r_na(x) else float(x)
        for x in r_vector_to_list(r_vector)
    ]


def r_str_list(r_vector) -> list[str | None]:
    return [
        None if is_r_na(x) else str(x)
        for x in r_vector_to_list(r_vector)
    ]


def r_scalar_int(r_vector) -> int | None:
    values = r_int_list(r_vector)
    return values[0] if values else None


def r_scalar_str(r_vector) -> str | None:
    values = r_str_list(r_vector)
    return values[0] if values else None


def r_scalar_float(r_vector) -> float | None:
    values = r_float_list(r_vector)
    return values[0] if values else None


# ========================================================================================================================

# version1: upload data
## Load the R/pipeline.R file
def load_r_pipeline() -> None:
    """
    Source the R/pipeline.R file into the R environment.
    Guaranteed to load only once even if called multiple times.
    """
    global _PIPELINE_LOADED

    if _PIPELINE_LOADED:
        return
    

    if not R_PIPELINE_PATH.exists():
        raise FileNotFoundError(f"Could not find pipeline.R: {R_PIPELINE_PATH}")

    r_path = R_PIPELINE_PATH.as_posix()

    with R_LOCK:
        if _PIPELINE_LOADED:
            return

        with default_converter.context():
            ro.r["source"](r_path)

        _PIPELINE_LOADED = True


## Call R's inspect_positions() and convert the result to a Python dict
def inspect_uploaded_file(path: str | Path) -> dict:
    """
    Inspect the uploaded BIN/RDA/RData file with the R function inspect_positions().

    R pipeline:
    - inspect_positions(path)
      - calls load_bin_data(path) internally
      - returns file info, POSITION info, and record type info

    Python return:
    - a dict that's convenient to use directly in Streamlit
    """
    load_r_pipeline()

    file_path = Path(path).resolve()

    if not file_path.exists():
        raise FileNotFoundError(f"Could not find the uploaded file: {file_path}")

    r_file_path = file_path.as_posix()

    with R_LOCK:
        with default_converter.context():
            result = ro.r["inspect_positions"](r_file_path)

            file_name = r_scalar_str(result.rx2("file"))
            file_path_result = r_scalar_str(result.rx2("file_path"))
            file_type = r_scalar_str(result.rx2("file_type"))
            object_name = r_scalar_str(result.rx2("object_name"))
            n_candidates = r_scalar_int(result.rx2("n_candidates"))
            ignored_objects = r_str_list(result.rx2("ignored_objects"))

            n_metadata_rows = r_scalar_int(result.rx2("n_metadata_rows"))
            metadata_columns = r_str_list(result.rx2("metadata_columns"))

            n_positions = r_scalar_int(result.rx2("n_positions"))
            positions = r_int_list(result.rx2("positions"))

            record_types = r_str_list(result.rx2("record_types"))

    return {
        "file": file_name,
        "file_path": file_path_result,
        "file_type": file_type,
        "object_name": object_name,
        "n_candidates": n_candidates,
        "ignored_objects": ignored_objects,
        "n_metadata_rows": n_metadata_rows,
        "metadata_columns": metadata_columns,
        "n_positions": n_positions,
        "positions": positions,
        "record_types": record_types,
    }

def inspect_rlum_records(path: str | Path, position: int) -> dict:
    """
    Look up the RLum record list for the selected POSITION with the R
    function inspect_rlum_records_by_position().

    R pipeline:
    - inspect_rlum_records_by_position(path, pos)
      - calls load_bin_data(path) internally
      - returns the metadata row and RLum record info for that POSITION

    Python return:
    - a dict that's convenient to feed directly into a Streamlit record table/selectbox
    """
    load_r_pipeline()

    file_path = Path(path).resolve()

    if not file_path.exists():
        raise FileNotFoundError(f"Could not find the uploaded file: {file_path}")

    r_file_path = file_path.as_posix()
    position = int(position)

    with R_LOCK:
        with default_converter.context():
            result = ro.r["inspect_rlum_records_by_position"](
                r_file_path,
                position,
            )

            r_position = r_scalar_int(result.rx2("position"))
            n_records = r_scalar_int(result.rx2("n_records"))

            record_index = r_int_list(result.rx2("record_index"))
            metadata_index = r_int_list(result.rx2("metadata_index"))

            record_type = r_str_list(result.rx2("record_type"))
            dtype = r_str_list(result.rx2("dtype"))
            comment = r_str_list(result.rx2("comment"))

            run = r_int_list(result.rx2("run"))
            set_no = r_int_list(result.rx2("set"))
            irr_time = r_float_list(result.rx2("irr_time"))
            npoints = r_int_list(result.rx2("npoints"))

            low = r_float_list(result.rx2("low"))
            high = r_float_list(result.rx2("high"))
            an_temp = r_float_list(result.rx2("an_temp"))
            an_time = r_float_list(result.rx2("an_time"))

            light_source = r_str_list(result.rx2("light_source"))
            record_label = r_str_list(result.rx2("record_label"))

    return {
        "position": r_position,
        "n_records": n_records,
        "record_index": record_index,
        "metadata_index": metadata_index,
        "record_type": record_type,
        "dtype": dtype,
        "comment": comment,
        "run": run,
        "set": set_no,
        "irr_time": irr_time,
        "npoints": npoints,
        "low": low,
        "high": high,
        "an_temp": an_temp,
        "an_time": an_time,
        "light_source": light_source,
        "record_label": record_label,
    }

def generate_rlum_record_plot(
    path: str | Path,
    output_dir: str | Path,
    position: int,
    record_index: int,
) -> dict:
    """
    Save one specific record from the selected POSITION as a PNG via plot_RLum.

    R pipeline:
    - save_rlum_record_plot(path, pos, record_index, output_dir)
    """
    load_r_pipeline()

    file_path = Path(path).resolve()
    output_dir = Path(output_dir).resolve()

    if not file_path.exists():
        raise FileNotFoundError(f"Could not find the uploaded file: {file_path}")

    output_dir.mkdir(parents=True, exist_ok=True)

    with R_LOCK:
        with default_converter.context():
            result = ro.r["save_rlum_record_plot"](
                file_path.as_posix(),
                int(position),
                int(record_index),
                output_dir.as_posix(),
            )

            position_value = r_scalar_int(result.rx2("position"))
            record_index_value = r_scalar_int(result.rx2("record_index"))
            plot_file = r_scalar_str(result.rx2("plot_file"))

    return {
        "position": position_value,
        "record_index": record_index_value,
        "plot_file": plot_file,
    }


def run_sar_analysis(
    path: str | Path,
    positions: list[int],
    signal_integral: str,
    background_integral: str,
    plot_dir: str | Path | None = None,
) -> dict:
    """
    Run SAR analysis in batch over the selected POSITIONs and obtain De values.

    R pipeline:
    - run_sar_analysis(path, positions, signal_integral, background_integral)
      - integral string parsing/validation is done in R
      - if one POSITION fails, the rest continue, and the failure reason is returned separately

    Python return:
    - aliquots: list of per-POSITION result rows (the input to the De distribution stage)
    - failed:   the POSITIONs that failed and why
    """
    load_r_pipeline()

    file_path = Path(path).resolve()

    if not file_path.exists():
        raise FileNotFoundError(f"Could not find the uploaded file: {file_path}")

    if not positions:
        raise ValueError("No POSITIONs were selected for analysis.")

    if plot_dir is not None:
        plot_dir = Path(plot_dir).resolve()
        plot_dir.mkdir(parents=True, exist_ok=True)
        r_plot_dir = plot_dir.as_posix()
    else:
        r_plot_dir = ro.NULL

    with R_LOCK:
        with default_converter.context():
            result = ro.r["run_sar_analysis"](
                file_path.as_posix(),
                ro.IntVector([int(p) for p in positions]),
                str(signal_integral),
                str(background_integral),
                r_plot_dir,
            )

            signal_range = r_int_list(result.rx2("signal_integral"))
            background_range = r_int_list(result.rx2("background_integral"))

            n_requested = r_scalar_int(result.rx2("n_requested"))
            n_success = r_scalar_int(result.rx2("n_success"))
            n_failed = r_scalar_int(result.rx2("n_failed"))

            position_list = r_int_list(result.rx2("position"))
            de_list = r_float_list(result.rx2("de"))
            de_error_list = r_float_list(result.rx2("de_error"))
            rc_status_list = r_str_list(result.rx2("rc_status"))
            fit_list = r_str_list(result.rx2("fit"))
            n_n_list = r_float_list(result.rx2("n_n"))
            recycling_list = r_float_list(result.rx2("recycling_ratio"))
            recuperation_list = r_float_list(result.rx2("recuperation"))
            plot_file_list = r_str_list(result.rx2("plot_file"))

            qc_position_list = r_int_list(result.rx2("qc_position"))
            qc_criteria_list = r_str_list(result.rx2("qc_criteria"))
            qc_value_list = r_float_list(result.rx2("qc_value"))
            qc_threshold_list = r_float_list(result.rx2("qc_threshold"))
            qc_status_list = r_str_list(result.rx2("qc_status"))

            failed_position_list = r_int_list(result.rx2("failed_position"))
            failed_reason_list = r_str_list(result.rx2("failed_reason"))

    aliquots = [
        {
            "position": position_list[i],
            "de": de_list[i],
            "de_error": de_error_list[i],
            "rc_status": rc_status_list[i],
            "fit": fit_list[i],
            "n_n": n_n_list[i],
            "recycling_ratio": recycling_list[i],
            "recuperation": recuperation_list[i],
            "plot_file": plot_file_list[i] if i < len(plot_file_list) else None,
        }
        for i in range(len(position_list))
    ]

    qc_rows = [
        {
            "position": qc_position_list[i],
            "criteria": qc_criteria_list[i],
            "value": qc_value_list[i],
            "threshold": qc_threshold_list[i],
            "status": qc_status_list[i],
        }
        for i in range(len(qc_position_list))
    ]

    failed = [
        {
            "position": failed_position_list[i],
            "reason": failed_reason_list[i],
        }
        for i in range(len(failed_position_list))
    ]

    # QC determination: RC.Status == "FAILED" means it fell short of the
    # quality criteria. It's only classified here, not filtered out — what
    # actually goes into the De distribution is better left for the
    # researcher to choose in the next stage, in keeping with this
    # project's intent.
    accepted = [a for a in aliquots if str(a["rc_status"]).upper() != "FAILED"]
    rejected = [a for a in aliquots if str(a["rc_status"]).upper() == "FAILED"]

    return {
        "signal_integral": signal_range,
        "background_integral": background_range,
        "n_requested": n_requested,
        "n_success": n_success,
        "n_failed": n_failed,
        "n_accepted": len(accepted),
        "n_rejected": len(rejected),
        "aliquots": aliquots,
        "accepted": accepted,
        "rejected": rejected,
        "qc_rows": qc_rows,
        "failed": failed,
    }


# version4: De distribution analysis
def analyse_de_distribution(
    de: list[float],
    de_error: list[float],
    output_dir: str | Path | None = None,
    sigmab: float = 0.15,
    prefix: str = "de_dist",
) -> dict:
    """
    Compute characteristics of the De value distribution (overdispersion,
    skewness, kurtosis), and produce evidence for multimodality by comparing
    BIC across FMM component counts. If output_dir is given, radial/abanico
    plots are also saved.

    R pipeline:
    - analyse_de_distribution(de, de_error, output_dir, prefix): distribution metrics + plots
    - fit_finite_mixture(de, de_error, sigmab): BIC per component count (for the multimodality determination)

    This is as far as R's job goes for the statistics. The decision logic
    that maps these metrics to CAM/MAM/FMM belongs to
    model_recommend.recommend_age_model (pure Python), and the caller (a
    tab) passes this function's result into that one. r_runner stays
    confined to the R bridge.

    Fitting FMM can fail (fewer than 4 valid De values, non-convergence,
    etc.). In that case the distribution metrics are returned as-is with
    fmm=None and the reason in fmm_error — only the multimodality
    determination is unavailable; CAM/MAM can still be judged from the
    metrics alone.

    Python return:
    - distribution metrics (dict) + sigmab + "fmm" (BIC comparison dict, or None) + "fmm_error"
    """
    load_r_pipeline()

    if len(de) != len(de_error):
        raise ValueError(
            f"The number of De values and errors differ: {len(de)} vs {len(de_error)}"
        )

    if output_dir is not None:
        output_dir = Path(output_dir).resolve()
        output_dir.mkdir(parents=True, exist_ok=True)
        r_output_dir = output_dir.as_posix()
    else:
        r_output_dir = ro.NULL

    with R_LOCK:
        with default_converter.context():
            r_de = ro.FloatVector(
                [float("nan") if x is None else float(x) for x in de]
            )
            r_de_error = ro.FloatVector(
                [float("nan") if x is None else float(x) for x in de_error]
            )

            result = ro.r["analyse_de_distribution"](
                r_de,
                r_de_error,
                r_output_dir,
                str(prefix),
            )

            descriptors = {
                "n": r_scalar_int(result.rx2("n")),
                "n_dropped": r_scalar_int(result.rx2("n_dropped")),
                "central_de": r_scalar_float(result.rx2("central_de")),
                "central_de_error": r_scalar_float(result.rx2("central_de_error")),
                "od_abs": r_scalar_float(result.rx2("od_abs")),
                "od_abs_error": r_scalar_float(result.rx2("od_abs_error")),
                "od_rel": r_scalar_float(result.rx2("od_rel")),
                "od_rel_error": r_scalar_float(result.rx2("od_rel_error")),
                "skewness": r_scalar_float(result.rx2("skewness")),
                "skewness_weighted": r_scalar_float(result.rx2("skewness_weighted")),
                "kurtosis": r_scalar_float(result.rx2("kurtosis")),
                "mean_de": r_scalar_float(result.rx2("mean_de")),
                "median_de": r_scalar_float(result.rx2("median_de")),
                "sd_rel": r_scalar_float(result.rx2("sd_rel")),
                "radial_plot_file": r_scalar_str(result.rx2("radial_plot_file")),
                "abanico_plot_file": r_scalar_str(result.rx2("abanico_plot_file")),
            }

            # FMM can fail, so it's wrapped separately from the distribution
            # metrics. The metrics above have already been extracted into
            # Python values, so they're unaffected even if FMM fails.
            try:
                fmm_result = ro.r["fit_finite_mixture"](
                    r_de,
                    r_de_error,
                    float(sigmab),
                )

                fmm = {
                    "sigmab": r_scalar_float(fmm_result.rx2("sigmab")),
                    "single_bic": r_scalar_float(fmm_result.rx2("single_bic")),
                    "k": r_int_list(fmm_result.rx2("k")),
                    "bic": r_float_list(fmm_result.rx2("bic")),
                    "best_k": r_scalar_int(fmm_result.rx2("best_k")),
                    "best_bic": r_scalar_float(fmm_result.rx2("best_bic")),
                    "delta_bic": r_scalar_float(fmm_result.rx2("delta_bic")),
                }
                # On a singular matrix / non-convergence, calc_FiniteMixture
                # returns an NA BIC instead of raising, which would produce a
                # dict where every field above is None. To preserve the
                # invariant "fmm is dict-or-None" (which the recommendation
                # logic assumes), fold that case down to None here.
                if fmm["delta_bic"] is None or fmm["best_k"] is None:
                    fmm = None
                    fmm_error = "The FMM fit result is not valid (e.g. singular matrix / non-convergence)."
                else:
                    fmm_error = None
            except Exception as exc:
                fmm = None
                lines = str(exc).strip().splitlines()
                fmm_error = lines[-1].strip() if lines else "Failed to fit FMM."

    return {
        **descriptors,
        "sigmab": float(sigmab),
        "fmm": fmm,
        "fmm_error": fmm_error,
    }


# ============================================================
# Self-check
# ============================================================
# The R layer is bridged by manually unpacking R vectors into dicts on the
# Python side, so if an R function changes or the Luminescence version is
# upgraded, the shape can drift silently. Running an actual analysis once
# here confirms the return shape and values are unchanged.
#
# There is no verification data in the repository (outputs/ is gitignored).
# Instead, Luminescence's own CWOSL.SAR.Data example is written to a
# temporary folder on the fly.
#
# Run: venv/bin/python app/utils/r_runner.py   (~2 seconds)

def _write_fixture(target_dir: Path) -> Path:
    """Save Luminescence's example data as an .rda to build the verification input."""
    import subprocess

    fixture = target_dir / "fixture.rda"

    script = (
        'suppressMessages(library(Luminescence)); '
        'data(ExampleData.BINfileData, envir=environment()); '
        f'save(CWOSL.SAR.Data, file="{fixture.as_posix()}")'
    )

    done = subprocess.run(
        ["Rscript", "-e", script],
        capture_output=True,
        text=True,
    )

    if done.returncode != 0 or not fixture.exists():
        raise RuntimeError(f"Failed to generate the verification fixture: {done.stderr.strip()}")

    return fixture


if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        fixture = _write_fixture(tmp_dir)

        # --------------------------------------------------------
        # 1. File inspection
        # --------------------------------------------------------
        info = inspect_uploaded_file(fixture)

        assert info["positions"] == list(range(1, 25)), \
            f"the POSITION list has changed: {info['positions']}"
        assert info["n_positions"] == 24, f"POSITION count: {info['n_positions']}"
        assert info["object_name"] == "CWOSL.SAR.Data", \
            f"the object name picked from the rda: {info['object_name']}"
        assert info["n_candidates"] == 1, "there should be exactly one candidate object"

        # --------------------------------------------------------
        # 2. Record inspection — every column must have the same length.
        #    If even one is off, build_record_rows silently produces a truncated table.
        # --------------------------------------------------------
        recs = inspect_rlum_records(fixture, 1)

        n = len(recs["record_index"])
        assert n == 30, f"record count for POSITION 1: {n}"

        for key in ("record_type", "dtype", "comment", "run", "set",
                    "irr_time", "npoints", "low", "high",
                    "an_temp", "an_time", "light_source"):
            assert len(recs[key]) == n, f"'{key}' has a different length than record_index"

        assert {"OSL", "IRSL", "TL"} <= set(recs["record_type"]), \
            f"an expected curve type is missing: {set(recs['record_type'])}"

        # --------------------------------------------------------
        # 3. Curve PNG — on macOS, quartz only writes the file at dev.off().
        #    If this ordering breaks, an empty file is left behind with no
        #    exception, so we check "does it actually exist on disk and is
        #    it non-empty" rather than just the path.
        # --------------------------------------------------------
        osl_index = next(
            idx for idx, kind in zip(recs["record_index"], recs["record_type"])
            if kind == "OSL"
        )

        plot = generate_rlum_record_plot(fixture, tmp_dir, 1, osl_index)
        plot_file = Path(plot["plot_file"])

        assert plot_file.exists(), f"the curve PNG was not created: {plot_file}"
        assert plot_file.stat().st_size > 0, "the curve PNG is empty"

        # --------------------------------------------------------
        # 4. SAR analysis
        # --------------------------------------------------------
        sar_dir = tmp_dir / "sar"
        sar_dir.mkdir()

        sar = run_sar_analysis(fixture, [1, 2], "1:2", "900:1000", sar_dir)

        # analyse_SAR.CWOSL() takes a vector, not a min/max pair.
        # If this shape breaks, De changes entirely, so it's checked round-trip.
        assert sar["signal_integral"] == [1, 2], \
            f"signal_integral: {sar['signal_integral']}"
        assert sar["background_integral"] == [900, 1000], \
            f"background_integral: {sar['background_integral']}"

        # Batches collect failures rather than aborting. The requested count
        # must equal success + failure, so one aliquot doesn't silently disappear.
        assert sar["n_requested"] == 2, f"n_requested: {sar['n_requested']}"
        assert sar["n_success"] + sar["n_failed"] == sar["n_requested"], \
            "the requested count doesn't match success + failure"
        assert len(sar["aliquots"]) == sar["n_success"], \
            "the aliquot count doesn't match n_success"
        assert len(sar["accepted"]) + len(sar["rejected"]) == len(sar["aliquots"]), \
            "accepted + rejected doesn't match the total aliquots"

        assert sar["qc_rows"], "the QC table is empty"
        assert {"criteria", "position", "status", "threshold", "value"} \
            <= set(sar["qc_rows"][0]), f"the QC columns have changed: {sar['qc_rows'][0].keys()}"

        # --------------------------------------------------------
        # 5. De values
        #    The ranges below are based on values measured with Luminescence 1.2.1
        #    (POSITION 1: 1661.3 Gy / POSITION 2: 1534.9 Gy).
        #    Falling outside this means either Luminescence was upgraded or
        #    the calculation changed. Which one it is directly affects the
        #    age value, so it needs a human judgment call.
        # --------------------------------------------------------
        expected_de = {1: (1600, 1720), 2: (1480, 1590)}

        for aliquot in sar["aliquots"]:
            pos = aliquot["position"]
            de = aliquot["de"]

            assert isinstance(de, float) and de == de, \
                f"POSITION {pos}'s De is not numeric: {de}"

            low, high = expected_de[pos]
            assert low < de < high, \
                f"POSITION {pos}'s De is outside the measured range: {de:.1f} (expected {low}-{high})"

            assert aliquot["rc_status"], f"POSITION {pos} has no QC status"

            # Also check that the growth-curve PNG was actually written (same reason as #3)
            dose_plot = Path(aliquot["plot_file"])
            assert dose_plot.exists() and dose_plot.stat().st_size > 0, \
                f"POSITION {pos}'s growth-curve PNG is missing or empty"

        # --------------------------------------------------------
        # 6. Input validation should be blocked in R and the exception should
        #    propagate up to Python. Silently returning an empty result would
        #    make the UI display "analysis succeeded".
        # --------------------------------------------------------
        for bad_input, label in (
            (tmp_dir / "no_such_file.rda", "nonexistent path"),
            (tmp_dir / "fixture.txt", "unsupported extension"),
        ):
            if label == "unsupported extension":
                bad_input.write_text("not a bin file")

            try:
                inspect_uploaded_file(bad_input)
                raise AssertionError(f"no exception was raised for {label}")
            except AssertionError:
                raise
            except Exception:
                pass

        try:
            run_sar_analysis(fixture, [1, 99], "1:2", "900:1000", sar_dir)
            raise AssertionError("no exception was raised for a POSITION that isn't in the file")
        except AssertionError:
            raise
        except Exception:
            pass

        # --------------------------------------------------------
        # 7. De distribution analysis + FMM + recommendation (Phase A)
        #    Checks that the metrics/recommendation are unchanged against the
        #    verified distribution in ExampleData.DeValues.
        #    CA1 (n=62):   overdispersion 34.7%, symmetric, multimodal (ΔBIC 95.5) -> FMM
        #    BT998 (n=25): overdispersion 8.0% -> CAM via the OD gate
        #    If these values drift, Luminescence was upgraded or the calculation changed.
        # --------------------------------------------------------
        de_dir = tmp_dir / "de"
        de_dir.mkdir()

        # Pull the De vectors from R. analyse_de_distribution is called
        # after exiting this with block (the Lock isn't reentrant, so nesting is forbidden).
        with R_LOCK:
            with default_converter.context():
                ro.r('data("ExampleData.DeValues")')
                ca1_de = r_float_list(ro.r("ExampleData.DeValues$CA1[[1]]"))
                ca1_err = r_float_list(ro.r("ExampleData.DeValues$CA1[[2]]"))
                bt_de = r_float_list(ro.r("ExampleData.DeValues$BT998[[1]]"))
                bt_err = r_float_list(ro.r("ExampleData.DeValues$BT998[[2]]"))

        ca1 = analyse_de_distribution(ca1_de, ca1_err, output_dir=de_dir,
                                      sigmab=0.15, prefix="ca1")

        assert ca1["n"] == 62, f"CA1 n: {ca1['n']}"
        assert 33 < ca1["od_rel"] < 36, \
            f"CA1 overdispersion is outside the measured range: {ca1['od_rel']}"
        assert -0.2 < ca1["skewness"] < 0.2, f"CA1 skewness: {ca1['skewness']}"
        assert ca1["fmm"] is not None and ca1["fmm_error"] is None, \
            f"the CA1 FMM fit failed: {ca1['fmm_error']}"
        assert ca1["fmm"]["delta_bic"] > 6, \
            f"CA1's multimodality evidence (ΔBIC) is weak: {ca1['fmm']['delta_bic']}"

        # Check that the radial/abanico PNGs were actually written to disk (same reason as the macOS quartz case)
        for key in ("radial_plot_file", "abanico_plot_file"):
            f = Path(ca1[key])
            assert f.exists() and f.stat().st_size > 0, \
                f"CA1's {key} PNG is missing or empty"

        # The full chain through to the decision logic. Since the self-check
        # runs in the app/utils context, model_recommend is imported directly
        # here (production code doesn't have r_runner import it).
        from model_recommend import recommend_age_model

        rec_ca1 = recommend_age_model(ca1["od_rel"], ca1["skewness"], ca1["n"], ca1["fmm"])
        assert rec_ca1["model"] == "FMM", f"CA1's recommendation is not FMM: {rec_ca1['model']}"

        # BT998: CAM via the OD gate. Also checks the metrics-only path with no plot.
        bt = analyse_de_distribution(bt_de, bt_err, sigmab=0.15)
        assert bt["n"] == 25, f"BT998 n: {bt['n']}"
        assert 7 < bt["od_rel"] < 9, f"BT998 overdispersion: {bt['od_rel']}"
        assert bt["radial_plot_file"] is None, \
            "a plot path was created even though output_dir was not given"

        rec_bt = recommend_age_model(bt["od_rel"], bt["skewness"], bt["n"], bt["fmm"])
        assert rec_bt["model"] == "CAM", f"BT998's recommendation is not CAM: {rec_bt['model']}"

        # With fewer than 3 valid De values, R should block it and the
        # exception should propagate up to Python.
        try:
            analyse_de_distribution([100.0, 200.0], [10.0, 20.0])
            raise AssertionError("no exception was raised for only 2 De values")
        except AssertionError:
            raise
        except Exception:
            pass

    print("r_runner self-check OK")
