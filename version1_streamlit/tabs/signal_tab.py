# version1_streamlit/tabs/signal_tab.py

import streamlit as st

from utils.r_runner import inspect_rlum_records, generate_rlum_record_plot
from utils.state_manager import (
    get_current_sample,
    get_position_result,
    set_selected_signal_position,
    set_rlum_records,
    get_rlum_records,
    has_rlum_records,
    set_selected_record_info,
    set_rlum_record_plot_result,
    get_rlum_record_plot_result,
    has_rlum_record_plot_result,
    set_signal_params,
    get_signal_params,
    has_signal_params,
)


def require_sample():
    sample = get_current_sample()

    if sample is None:
        st.warning("First upload a BIN/RDA file in the `Data Upload & Inspect` tab.")
        return None

    return sample


def require_position_result():
    result = get_position_result()

    if result is None:
        st.warning("First run POSITION inspection in the `Data Upload & Inspect` tab.")
        return None

    return result


def build_record_rows(records: dict) -> list[dict]:
    return [
        {
            "record_index": records["record_index"][i],
            "LTYPE": records["record_type"][i],
            "DTYPE": records["dtype"][i],
            "COMMENT": records["comment"][i],
            "RUN": records["run"][i],
            "SET": records["set"][i],
            "IRR_TIME": records["irr_time"][i],
            "NPOINTS": records["npoints"][i],
            "LOW": records["low"][i],
            "HIGH": records["high"][i],
            "AN_TEMP": records["an_temp"][i],
            "AN_TIME": records["an_time"][i],
            "LIGHTSOURCE": records["light_source"][i],
        }
        for i in range(len(records["record_index"]))
    ]


def render_signal_tab():
    st.header("2. Signal Analysis")
    st.caption("Inspect records per POSITION and set the signal/background integral.")

    sample = require_sample()
    position_result = require_position_result()

    if sample is None or position_result is None:
        return

    positions = position_result["positions"]

    selected_position = st.selectbox(
        "POSITION to view the decay curve for",
        positions,
        key="signal_position_selectbox",
    )

    set_selected_signal_position(selected_position)

    if st.button("Load records for the selected POSITION", type="primary"):
        try:
            with st.spinner(f"Loading record info for POSITION {selected_position}..."):
                records = inspect_rlum_records(
                    sample["raw_path"],
                    selected_position,
                )

            set_rlum_records(records)
            st.success("Record info loaded successfully")

        except Exception as e:
            st.error("An error occurred while loading record info.")
            st.exception(e)

    st.divider()

    if not has_rlum_records():
        st.info("First load the record info for the selected POSITION.")
        return

    records = get_rlum_records()
    record_rows = build_record_rows(records)

    curve_types = sorted(set(row["LTYPE"] for row in record_rows))

    selected_curve_type = st.selectbox(
        "Curve type",
        ["ALL"] + curve_types,
        key="signal_curve_type_selectbox",
    )

    if selected_curve_type == "ALL":
        filtered_rows = record_rows
    else:
        filtered_rows = [
            row for row in record_rows
            if row["LTYPE"] == selected_curve_type
        ]

    if not filtered_rows:
        st.warning("No records match the selected curve type.")
        return

    col_left, col_right = st.columns([1, 2])

    with col_left:
        selected_record = st.selectbox(
            "Select a record",
            filtered_rows,
            format_func=lambda row: (
                f"#{row['record_index']} | "
                f"{row['LTYPE']} | "
                f"{row['DTYPE']} | "
                f"{row['COMMENT']}"
            ),
            key="signal_record_selectbox",
        )

        set_selected_record_info(selected_record)

        if st.button("View the selected record's curve", type="primary"):
            try:
                with st.spinner(
                    f"Generating the curve for POSITION {selected_position}, "
                    f"Record {selected_record['record_index']}..."
                ):
                    plot_result = generate_rlum_record_plot(
                        sample["raw_path"],
                        sample["paths"]["curve_plot_dir"],
                        selected_position,
                        selected_record["record_index"],
                    )

                set_rlum_record_plot_result(plot_result)

            except Exception as e:
                st.error("An error occurred while generating the curve image.")
                st.exception(e)

        st.subheader("Selected record info")
        st.json(selected_record)

    with col_right:
        if has_rlum_record_plot_result():
            plot_result = get_rlum_record_plot_result()

            st.image(
                plot_result["plot_file"],
                caption=(
                    f"POSITION {plot_result['position']} / "
                    f"Record {plot_result['record_index']}"
                ),
            )

            st.write("Saved path")
            st.code(plot_result["plot_file"])
        else:
            st.info("The curve image for the selected record will appear here.")

    st.divider()

    st.subheader("Filtered record metadata")
    st.dataframe(
        filtered_rows,
        use_container_width=True,
        hide_index=True,
    )

    st.divider()

    st.subheader("Integral settings")

    # Pull the defaults from saved state. When a new upload clears signal_params,
    # value= changes, which refreshes the widget identity so the previous file's
    # integral doesn't linger in the box.
    saved = get_signal_params() or {}

    col_signal, col_background = st.columns(2)

    with col_signal:
        signal_integral = st.text_input(
            "Signal integral",
            value=saved.get("signal_integral", "1:2"),
            help="e.g. 1:2 or 450:500",
        )

    with col_background:
        background_integral = st.text_input(
            "Background integral",
            value=saved.get("background_integral", "900:1000"),
            help="e.g. 900:1000",
        )

    if st.button("Save current parameters"):
        set_signal_params(
            {
                "reference_position": selected_position,
                "reference_curve_type": selected_record["LTYPE"],
                "reference_record_index": selected_record["record_index"],
                "reference_record_comment": selected_record["COMMENT"],
                "signal_integral": signal_integral,
                "background_integral": background_integral,
            }
        )

        st.success("Signal parameters saved successfully")

    if has_signal_params():
        st.write("Saved parameters")
        st.json(get_signal_params())
