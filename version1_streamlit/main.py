# version1_streamlit/main.py

from __future__ import annotations

from pathlib import Path
import sys

import streamlit as st


# ============================================================
# 0. Path setup
# ============================================================

APP_DIR = Path(__file__).resolve().parent
PROJECT_DIR = APP_DIR.parent

if str(APP_DIR) not in sys.path:
    sys.path.append(str(APP_DIR))


# ============================================================
# 1. Internal module imports
# ============================================================

from tabs.upload_tab import render_upload_tab
from tabs.signal_tab import render_signal_tab
from tabs.sar_tab import render_sar_tab
from tabs.de_tab import render_de_tab
from utils.state_manager import init_session_state, reset_all_state


# ============================================================
# 2. Streamlit basic config
# ============================================================

st.set_page_config(
    page_title="LumiGuide",
    page_icon="💡",
    layout="wide",
)


# ============================================================
# 3. session_state initialization
# ============================================================

init_session_state()


# ============================================================
# 4. Base paths
# ============================================================

OUTPUT_DIR = PROJECT_DIR / "outputs" / "samples"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


# ============================================================
# 5. App Header
# ============================================================

st.title("LumiGuide")
st.caption(
    "Luminescence dating workflow assistant: "
    "data upload, signal analysis, SAR analysis, and model recommendation."
)


# ============================================================
# 6. Workflow step definitions
# ============================================================
# The sidebar list and the tab labels are both built from this single list.
# They used to be written separately in two places and drifted out of sync
# (the De Distribution tab was missing, so Model Recommendation ended up at 4).

WORKFLOW_STEPS = [
    "1. Data Upload & Inspect",
    "2. Signal Analysis",
    "3. SAR Analysis",
    "4. De Distribution",
    "5. Model Recommendation",
]

# The key for st.tabs(). Put a tab label in here and rerun, and that tab activates.
#
# Note: giving st.tabs() a key alone does not wire it up to session_state.
# Under the hood, when on_change defaults to "ignore" the tabs aren't
# registered as a widget, so writing a value into session_state[key] won't
# be read by the tabs. on_change="rerun" is required for the sidebar to be
# able to switch tabs.
ACTIVE_TAB_KEY = "active_workflow_tab"


# ============================================================
# 7. Sidebar
# ============================================================
# Button text is centered by default with no built-in option to change that,
# so it's handled with CSS. This relies on Streamlit's internal DOM, so it
# may break on a version upgrade (if it breaks, only the alignment reverts
# to centered — functionality is unaffected).

st.markdown(
    """
    <style>
    section[data-testid="stSidebar"] .stButton > button,
    section[data-testid="stSidebar"] .stButton > button > div {
        justify-content: flex-start;
        text-align: left;
    }
</style>
    """,
    unsafe_allow_html=True,
)

with st.sidebar:
    st.header("LumiGuide")

    st.caption("Workflow")

    for step in WORKFLOW_STEPS:
        # Make the current tab look pressed so it's clear where you are.
        is_active = st.session_state.get(ACTIVE_TAB_KEY) == step

        if st.button(
            step,
            key=f"nav_{step}",
            width="stretch",
            type="primary" if is_active else "tertiary",
        ):
            st.session_state[ACTIVE_TAB_KEY] = step
            st.rerun()

    st.divider()

    if st.button("Reset All", type="secondary"):
        reset_all_state()
        st.rerun()


# ============================================================
# 8. Main Tabs
# ============================================================

tab_upload, tab_signal, tab_sar, tab_de, tab_model = st.tabs(
    WORKFLOW_STEPS,
    key=ACTIVE_TAB_KEY,
    on_change="rerun",
)


# Once tabs are made a stateful widget with on_change="rerun", render only the one selected
# via .open. Without this, every rerun re-executes all five tab bodies, and when one of them
# (e.g. the signal tab's selectbox) registers/unregisters a widget, the tab container is
# remounted on the frontend and operating a widget in another tab bounces the view back.
with tab_upload:
    if tab_upload.open:
        render_upload_tab(OUTPUT_DIR)


with tab_signal:
    if tab_signal.open:
        render_signal_tab()


with tab_sar:
    if tab_sar.open:
        render_sar_tab()


with tab_de:
    if tab_de.open:
        render_de_tab()


with tab_model:
    if tab_model.open:
        st.header("5. Model Recommendation")
        st.info("The De-distribution-based model recommendation feature will be connected in a later stage.")
