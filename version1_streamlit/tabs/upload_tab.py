# version1_streamlit/tabs/upload_tab.py

from __future__ import annotations

from pathlib import Path

import streamlit as st

from utils.file_utils import compute_upload_hash, save_uploaded_file
from utils.r_runner import inspect_uploaded_file
from utils.state_manager import (
    get_current_sample,
    get_position_result,
    has_current_sample,
    has_position_result,
    is_new_uploaded_file,
    set_current_sample,
    set_position_result,
)


# ============================================================
# 1. UI helper
# ============================================================

def _render_empty_upload_message() -> None:
    """
    Show a guidance message when no file has been uploaded yet.
    """
    st.info("Upload a BIN/RDA/RData file to inspect its POSITION info.")


def _render_sample_summary(sample: dict) -> None:
    """
    Show info about the currently uploaded sample.
    """
    if sample.get("reused"):
        st.info(
            "This file has already been uploaded before (identical content). "
            "Reusing the existing sample folder instead of creating a new one."
        )
    else:
        st.success("File uploaded successfully")

    col1, col2 = st.columns(2)

    with col1:
        st.write("Sample ID")
        st.code(str(sample["sample_id"]))

    with col2:
        st.write("Storage folder")
        st.code(str(sample["sample_dir"]))

    st.write("Original file path")
    st.code(str(sample["raw_path"]))


def _render_position_result(result: dict) -> None:
    """
    Display the result of inspect_uploaded_file().
    """
    st.success("POSITION inspection complete")

    # If the .rda contains multiple Risoe.BINfileData objects, the first one
    # is auto-selected. The researcher must not be left unaware of which
    # sample is actually being analyzed, so we surface it here.
    n_candidates = result.get("n_candidates") or 1

    if n_candidates > 1:
        ignored = result.get("ignored_objects") or []
        st.warning(
            f"This file contains {n_candidates} Risoe.BINfileData objects. "
            f"Using the first one, `{result.get('object_name')}`.\n\n"
            f"Unused objects: {', '.join(ignored)}\n\n"
            "To analyze a different object, upload a file that saves only that object."
        )

    col1, col2, col3, col4 = st.columns(4)

    with col1:
        st.metric("Number of POSITIONs", result.get("n_positions", "N/A"))

    with col2:
        st.metric("Metadata rows", result.get("n_metadata_rows", "N/A"))

    with col3:
        st.write("File type")
        st.code(str(result.get("file_type", "N/A")))

    with col4:
        st.write("R object")
        st.code(str(result.get("object_name", "N/A")))

    st.divider()

    st.markdown("### POSITION list")
    st.write(result.get("positions", []))

    st.markdown("### Record types")
    st.write(result.get("record_types", []))

    st.markdown("### Metadata columns")
    st.write(result.get("metadata_columns", []))

    with st.expander("View raw result", expanded=False):
        st.json(result)


# ============================================================
# 2. Upload tab
# ============================================================

def render_upload_tab(output_dir: Path) -> None:
    """
    Render the Data Upload & Inspect tab.

    Responsibilities:
        1. Upload a BIN/RDA/RData file
        2. Save the file under outputs/samples/{sample_id}/raw
        3. Inspect the file structure and POSITION info via R (Analysis.R)
        4. Store current_sample and position_result in session_state
    """

    st.header("1. Data Upload & Inspect")
    st.caption("Upload a BIN/RDA/RData file and inspect its POSITION info.")

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    uploaded_file = st.file_uploader(
        "Upload a BIN/RDA/RData file",
        type=["bin", "BIN", "rda", "RDA", "rdata", "RData"],
        help="Upload a Risø BIN file or an RDA/RData file.",
    )

    if uploaded_file is None:
        _render_empty_upload_message()

        if has_current_sample():
            st.warning(
                "A previously uploaded sample is still present in session_state. "
                "Upload a new file or run a full reset."
            )

        return

    # ------------------------------------------------------------
    # Detect a new file upload (based on the content hash, not the filename)
    # ------------------------------------------------------------
    file_hash = compute_upload_hash(uploaded_file)

    if is_new_uploaded_file(uploaded_file.name, file_hash):
        try:
            sample = save_uploaded_file(
                uploaded_file=uploaded_file,
                samples_dir=output_dir,
                file_hash=file_hash,
            )
        except Exception as e:
            st.error("Failed to save the uploaded file.")
            st.exception(e)
            return

        set_current_sample(
            sample=sample,
            uploaded_file_name=uploaded_file.name,
            file_hash=file_hash,
        )

    sample = get_current_sample()

    if sample is None:
        st.error("Failed to load the uploaded sample info.")
        return

    # ------------------------------------------------------------
    # Show the upload result
    # ------------------------------------------------------------
    _render_sample_summary(sample)

    st.divider()

    # ------------------------------------------------------------
    # POSITION inspection
    # ------------------------------------------------------------
    st.markdown("### POSITION inspection")

    st.write(
        "Reads the uploaded file through R (Analysis.R) and inspects its metadata, "
        "record types, and POSITION info."
    )

    if st.button("Inspect POSITIONs", type="primary"):
        try:
            with st.spinner("Inspecting POSITION info..."):
                result = inspect_uploaded_file(sample["raw_path"])

            set_position_result(result)

        except Exception as e:
            st.error("An error occurred while inspecting POSITIONs.")
            st.exception(e)

    # ------------------------------------------------------------
    # Show the POSITION result
    # ------------------------------------------------------------
    if has_position_result():
        result = get_position_result()
        _render_position_result(result)
    else:
        st.info("POSITION inspection has not been run yet.")
