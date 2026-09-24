# version1_streamlit/tabs/sar_tab.py

from pathlib import Path

import pandas as pd
import streamlit as st

from utils.file_utils import save_sar_results
from utils.r_runner import run_sar_analysis
from utils.state_manager import (
    get_current_sample,
    get_position_result,
    get_signal_params,
    has_signal_params,
    set_sar_target_positions,
    set_sar_result,
    get_sar_result,
    has_sar_result,
)


# The "select all" entry placed at the top of the POSITION list.
# POSITION values are integers, so mixing in a string entry never collides.
SELECT_ALL = "Select All"


def _require_signal_params():
    """
    SAR cannot run without the integral decided in the Signal stage.

    Letting the user re-enter this value here could drift from the value they
    chose after looking at the curve in the Signal tab, so we only use the
    saved value and bounce back if there isn't one.
    """
    if not has_signal_params():
        st.warning(
            "First check the curve in the `Signal Analysis` tab and set the "
            "signal/background integral with `Save current parameters`."
        )
        return None

    return get_signal_params()


def _render_summary(result: dict) -> None:
    col1, col2, col3, col4 = st.columns(4)

    with col1:
        st.metric("Passed QC", result["n_accepted"])

    with col2:
        st.metric("Failed QC", result["n_rejected"])

    with col3:
        st.metric("Analysis failed", result["n_failed"])

    with col4:
        st.write("Integral (signal / background)")
        st.code(
            f"{':'.join(str(v) for v in result['signal_integral'])}"
            f"  /  "
            f"{':'.join(str(v) for v in result['background_integral'])}"
        )


def _render_aliquot_table(aliquots: list[dict]) -> None:
    df = pd.DataFrame(aliquots)

    df = df.drop(columns=["plot_file"], errors="ignore")

    df = df.rename(
        columns={
            "position": "POSITION",
            "de": "De (Gy)",
            "de_error": "De error",
            "rc_status": "QC status",
            "fit": "Fit",
            "n_n": "n/N",
            "recycling_ratio": "Recycling ratio",
            "recuperation": "Recuperation",
        }
    )

    st.dataframe(df, width="stretch", hide_index=True)


def _render_position_detail(result: dict) -> None:
    """
    Pick a single POSITION and view its De, full QC breakdown, and
    dose-response plot together.

    A table alone gives no basis for judging whether a De value is
    reasonable. Being able to see the growth curve is what makes the
    result trustworthy.
    """
    aliquots = result["aliquots"]
    by_position = {a["position"]: a for a in aliquots}

    # The value is a POSITION number, not an aliquot, and the lookup always
    # goes against the current result, so keeping a key here never points at
    # a stale result.
    selected = st.selectbox(
        "POSITION detail",
        options=sorted(by_position.keys()),
        key="sar_detail_position",
    )

    aliquot = by_position[selected]

    col_left, col_right = st.columns([1, 2])

    with col_left:
        st.metric("De (Gy)", f"{aliquot['de']:.1f}" if aliquot["de"] else "N/A")
        st.metric(
            "De error",
            f"{aliquot['de_error']:.1f}" if aliquot["de_error"] else "N/A",
        )

        status = str(aliquot["rc_status"]).upper()

        if status == "FAILED":
            st.error(f"QC status: {aliquot['rc_status']}")
        else:
            st.success(f"QC status: {aliquot['rc_status']}")

        st.caption(f"Fit: {aliquot['fit']}")

    with col_right:
        plot_file = aliquot.get("plot_file")

        if plot_file and Path(plot_file).exists():
            st.image(plot_file, caption=f"POSITION {selected} dose-response")
        else:
            st.info("No dose-response plot for this POSITION.")

    qc_rows = [q for q in result.get("qc_rows", []) if q["position"] == selected]

    if qc_rows:
        st.markdown("**QC criteria detail**")

        qc_df = pd.DataFrame(qc_rows).drop(columns=["position"])
        qc_df = qc_df.rename(
            columns={
                "criteria": "Criteria",
                "value": "Measured value",
                "threshold": "Threshold",
                "status": "Verdict",
            }
        )

        st.dataframe(qc_df, width="stretch", hide_index=True)


def render_sar_tab() -> None:
    """
    Render the SAR Analysis tab.

    Responsibilities:
        Run SAR per POSITION using the integral decided in the Signal stage
        to obtain De values. The resulting collection of De values is the
        input for the next stage (De distribution -> model recommendation).
    """
    st.header("3. SAR Analysis")

    sample = get_current_sample()

    if sample is None:
        st.warning("First upload a BIN/RDA file in the `Data Upload & Inspect` tab.")
        return

    position_result = get_position_result()

    if position_result is None:
        st.warning("First inspect POSITIONs in the `Data Upload & Inspect` tab.")
        return

    params = _require_signal_params()

    if params is None:
        return

    st.caption(
        "Runs SAR analysis on the selected POSITIONs using the integral set "
        "in Signal Analysis."
    )

    st.markdown(
        f"**Your settings:**　"
        f"Signal integral `{params['signal_integral']}`　/　"
        f"Background integral `{params['background_integral']}`"
    )

    st.caption(f"These values were chosen by looking at the curve for POSITION {params['reference_position']}.")

    st.divider()

    # ------------------------------------------------------------
    # Select the target POSITIONs for analysis
    # ------------------------------------------------------------
    available = position_result.get("positions", [])

    st.subheader("Target POSITIONs for analysis")

    # Defaulting to "all" would run every POSITION on an accidental click.
    # Leave it empty instead, and put a "select all" entry at the top of the list.
    picked = st.multiselect(
        "POSITIONs to run SAR on",
        options=[SELECT_ALL] + list(available),
        default=[],
        placeholder="(none selected)",
        help="Building a De distribution requires multiple aliquots.",
    )

    if SELECT_ALL in picked:
        selected = list(available)
    else:
        selected = picked

    if not selected:
        st.info("Select at least one POSITION.")
        return

    if SELECT_ALL in picked:
        st.caption(f"All {len(selected)} POSITIONs are selected.")

    if st.button("Run SAR analysis", type="primary"):
        set_sar_target_positions(selected)

        paths = sample["paths"]

        try:
            with st.spinner(f"Analyzing {len(selected)} POSITION(s)..."):
                result = run_sar_analysis(
                    path=sample["raw_path"],
                    positions=selected,
                    signal_integral=params["signal_integral"],
                    background_integral=params["background_integral"],
                    plot_dir=paths["curve_plot_dir"],
                )

            # Keep analysis and saving separate. Even if saving fails, keep
            # the on-screen result alive.
            try:
                saved = save_sar_results(paths["analysis_results_dir"], result)
                result["saved_files"] = {k: str(v) for k, v in saved.items()}
            except Exception as e:
                result["saved_files"] = {}
                st.warning(f"Failed to save the result CSVs: {e}")

            set_sar_result(result)

        except Exception as e:
            st.error("SAR analysis failed.")
            st.exception(e)
            return

    # ------------------------------------------------------------
    # Results
    # ------------------------------------------------------------
    if not has_sar_result():
        return

    result = get_sar_result()

    st.divider()
    st.success(f"SAR analysis complete — {result['n_success']} De value(s) obtained")

    _render_summary(result)

    st.markdown("### Results per aliquot")
    _render_aliquot_table(result["aliquots"])

    # Don't silently drop failed POSITIONs — show them along with the reason.
    # Without knowing how many were dropped and why, the De distribution's
    # sample size can't be trusted.
    if result["n_failed"] > 0:
        with st.expander(f"{result['n_failed']} analysis failure(s)", expanded=True):
            for item in result["failed"]:
                st.write(f"**POSITION {item['position']}**")
                st.code(item["reason"])

    st.divider()

    st.markdown("### POSITION detail")
    _render_position_detail(result)

    st.divider()

    saved_files = result.get("saved_files") or {}

    if saved_files:
        st.markdown("### Saved results")
        st.caption(
            "Analysis results are saved to the sample folder. They persist "
            "across app restarts and can be passed on to the next stage or "
            "an external tool."
        )

        for name, file_path in saved_files.items():
            st.code(file_path)

    with st.expander("View raw result", expanded=False):
        st.json(result)
