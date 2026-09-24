# version1_streamlit/tabs/de_tab.py

from pathlib import Path

import pandas as pd
import streamlit as st

from utils.model_recommend import recommend_age_model
from utils.r_runner import analyse_de_distribution
from utils.state_manager import (
    get_current_sample,
    get_sar_result,
    has_sar_result,
    set_de_dist_result,
    get_de_dist_result,
    has_de_dist_result,
)


# The aliquot set to feed into the De distribution. Defaults to QC-passed only.
# Whether to include QC-failed aliquots is still an open design decision
# (planning-doc item 4), so it isn't forced here — the researcher chooses,
# and what was used is recorded in the result.
SOURCE_ACCEPTED = "QC-passed only"
SOURCE_ALL = "All (including QC-failed)"

# One-line blurb for each recommended model.
MODEL_BLURB = {
    "CAM": "Central Age Model — central age of a well-bleached single population",
    "MAM": "Minimum Age Model — minimum (youngest) age for a partially bleached sample",
    "FMM": "Finite Mixture Model — per-component age for a discrete mixed population",
}


def _collect_de(sar_result: dict, source_label: str) -> tuple[list, list, int]:
    """Pull the De/error vectors from the selected set. Returns: (de, de_error, set size)."""
    if source_label == SOURCE_ACCEPTED:
        rows = sar_result.get("accepted", [])
    else:
        rows = sar_result.get("aliquots", [])

    de = [r["de"] for r in rows]
    de_error = [r["de_error"] for r in rows]
    return de, de_error, len(rows)


def _render_recommendation(rec: dict) -> None:
    model = rec["model"]

    st.markdown(f"### Recommended model: `{model}`")
    st.caption(MODEL_BLURB.get(model, ""))

    for reason in rec["reasons"]:
        st.markdown(f"- {reason}")

    st.caption(
        "This recommendation is a guide that applies literature-based rules to the "
        "distribution metrics. The same input and thresholds always produce the same "
        "model. The final choice is the researcher's judgment."
    )


def _render_descriptors(result: dict) -> None:
    col1, col2, col3, col4 = st.columns(4)

    col1.metric("Aliquot count", result["n"])
    col2.metric(
        "Central De (Gy)",
        f"{result['central_de']:.1f}" if result["central_de"] is not None else "N/A",
    )
    col3.metric(
        "Overdispersion (OD)",
        f"{result['od_rel']:.1f}%" if result["od_rel"] is not None else "N/A",
    )
    col4.metric(
        "Skewness",
        f"{result['skewness']:.2f}" if result["skewness"] is not None else "N/A",
    )

    if result.get("n_dropped"):
        st.caption(f"{result['n_dropped']} invalid De value(s) were excluded from the analysis.")


def _render_plots(result: dict) -> None:
    col1, col2 = st.columns(2)

    for col, key, caption in (
        (col1, "radial_plot_file", "Radial plot"),
        (col2, "abanico_plot_file", "Abanico plot"),
    ):
        plot_file = result.get(key)

        with col:
            if plot_file and Path(plot_file).exists():
                st.image(plot_file, caption=caption)
            else:
                st.info(f"No {caption} available.")


def _render_fmm(result: dict) -> None:
    fmm = result.get("fmm")

    if fmm is None:
        st.info(f"Could not determine FMM (multimodality): {result.get('fmm_error')}")
        return

    # BIC per component count k. k=1 (single) is placed at the top so it can
    # be compared against the multi-component fits.
    rows = [{"k (components)": 1, "BIC": fmm["single_bic"]}]
    rows += [{"k (components)": k, "BIC": b} for k, b in zip(fmm["k"], fmm["bic"])]

    st.markdown("**BIC by component count** (lower is preferred)")
    st.dataframe(pd.DataFrame(rows), width="stretch", hide_index=True)

    bic_strong = result["recommendation"]["thresholds"]["bic_strong"]
    st.caption(
        f"Best component count k={fmm['best_k']} · ΔBIC vs. single {fmm['delta_bic']:.1f} "
        f"(> {bic_strong:.0f} is strong evidence for multimodality) · sigmab={fmm['sigmab']:.2f}"
    )
    st.caption(
        "The FMM determination is sensitive to sigmab. Re-running with a different "
        "sigmab may change the outcome."
    )


def _render_signals(rec: dict) -> None:
    with st.expander("Determination details (for reproducibility)", expanded=False):
        st.markdown("**Signal metrics**")
        st.json(rec["signals"])
        st.markdown("**Thresholds (literature-based constants)**")
        st.json(rec["thresholds"])


def render_de_tab() -> None:
    """
    Render the De Distribution tab.

    Responsibilities:
        Analyze the characteristics (overdispersion, skewness, multimodality)
        of the De distribution obtained from SAR, and recommend a statistical
        age model (CAM/MAM/FMM) using literature-based rules.
    """
    st.header("4. De Distribution")

    sample = get_current_sample()

    if sample is None:
        st.warning("First upload a BIN/RDA file in the `Data Upload & Inspect` tab.")
        return

    if not has_sar_result():
        st.warning("First run SAR analysis in the `SAR Analysis` tab to obtain De values.")
        return

    sar_result = get_sar_result()

    st.caption(
        "Analyzes the characteristics (overdispersion, skewness, multimodality) of the "
        "De distribution obtained from SAR and recommends a statistical age model "
        "(CAM/MAM/FMM)."
    )

    st.divider()

    # ------------------------------------------------------------
    # Analysis input: De set + sigmab
    # ------------------------------------------------------------
    n_accepted = sar_result.get("n_accepted", 0)
    n_all = len(sar_result.get("aliquots", []))

    source_label = st.radio(
        "De set to use for the analysis",
        options=[SOURCE_ACCEPTED, SOURCE_ALL],
        help="Decide here whether QC-failed aliquots go into the De distribution. What was used is recorded in the result.",
    )
    st.caption(f"QC-passed: {n_accepted} · Total: {n_all}")

    sigmab = st.number_input(
        "sigmab (assumed within-component overdispersion for FMM)",
        min_value=0.01,
        max_value=1.0,
        value=0.15,
        step=0.01,
        help=(
            "The FMM (multimodality) determination is sensitive to this value. It's "
            "the overdispersion estimate for a well-bleached single component; 0.1-0.2 "
            "is typical. The value used is recorded in the result."
        ),
    )

    de, de_error, n_input = _collect_de(sar_result, source_label)
    n_valid = sum(1 for x in de if x is not None)

    if st.button("Run De distribution analysis", type="primary"):
        if n_valid < 3:
            st.warning(
                f"De distribution analysis requires at least 3 De values (currently {n_valid}). "
                "Obtain more aliquots from SAR or change the De set."
            )
            return

        try:
            with st.spinner("Analyzing De distribution..."):
                analysis = analyse_de_distribution(
                    de=de,
                    de_error=de_error,
                    output_dir=sample["paths"]["curve_plot_dir"],
                    sigmab=float(sigmab),
                )

            recommendation = recommend_age_model(
                od_rel=analysis["od_rel"],
                skewness=analysis["skewness"],
                n=analysis["n"],
                fmm=analysis["fmm"],
            )

            result = {
                **analysis,
                "recommendation": recommendation,
                "de_source": source_label,
                "n_input": n_input,
            }

            set_de_dist_result(result)

        except Exception as e:
            st.error("De distribution analysis failed.")
            st.exception(e)
            return

    # ------------------------------------------------------------
    # Results
    # ------------------------------------------------------------
    if not has_de_dist_result():
        return

    result = get_de_dist_result()

    st.divider()
    st.success(f"De distribution analysis complete — using {result['n']} from {result['de_source']}")

    _render_recommendation(result["recommendation"])

    st.divider()
    _render_descriptors(result)

    st.markdown("### Distribution visualization")
    _render_plots(result)

    st.markdown("### Multimodality (FMM)")
    _render_fmm(result)

    _render_signals(result["recommendation"])

    with st.expander("View raw result", expanded=False):
        st.json(result)
