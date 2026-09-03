# app/utils/state_manager.py

from __future__ import annotations

import streamlit as st


# ============================================================
# 0. session_state key constants
# ============================================================
# Managed as constants to prevent typos in strings and keep call sites readable.

UPLOADED_SAMPLE_KEY = "uploaded_sample"
UPLOADED_FILE_NAME_KEY = "uploaded_file_name"
UPLOADED_FILE_HASH_KEY = "uploaded_file_hash"
POSITION_RESULT_KEY = "position_result"
SELECTED_SIGNAL_POSITION_KEY = "selected_signal_position"
RLUM_RECORDS_KEY = "rlum_records"
SELECTED_RECORD_INFO_KEY = "selected_record_info"
RLUM_RECORD_PLOT_RESULT_KEY = "rlum_record_plot_result"
SIGNAL_PARAMS_KEY = "signal_params"
SAR_TARGET_POSITIONS_KEY = "sar_target_positions"
SAR_RESULT_KEY = "sar_result"
DE_DIST_RESULT_KEY = "de_dist_result"

# The entries within signal_params that actually change the De value.
# The rest (reference_*) are only for recording provenance, so the SAR
# result stays valid even if they change.
DE_AFFECTING_PARAMS = ("signal_integral", "background_integral")



# ============================================================
# 1. Stage schema = single source of truth
# ============================================================
# Within each stage, input and output are kept separate.
#   - input  : values given directly by the user/widget (uploaded file, chosen position, parameters, etc.)
#   - output : the results we compute from that input (position inspection, RLum records, SAR results, etc.)
#
# This distinction is the crux of the design.
# Because every reset is automatically derived from the single rule
#   "when a stage's input changes -> that stage's output + every later stage that depends on it is invalidated",
# adding a new result key never requires touching the reset logic.
#
# depends_on lists only "the stages I directly use". Indirect dependencies
# follow automatically. The invalidation result is decided by the dependency
# relationship, not by definition order, so reordering the definitions
# doesn't change the outcome.
#
# e.g. sar does not depend on signal (which POSITION's curve to view),
#      because changing the POSITION should not discard SAR results
#      that were already computed.

SESSION_SCHEMA: dict[str, dict] = {
    "upload": {
        "depends_on": [],
        "input": {
            UPLOADED_SAMPLE_KEY: None,
            UPLOADED_FILE_NAME_KEY: None,
            UPLOADED_FILE_HASH_KEY: None,
        },
        "output": {
            POSITION_RESULT_KEY: None,
        },
    },
    "signal": {
        "depends_on": ["upload"],
        "input": {
            SELECTED_SIGNAL_POSITION_KEY: None,
        },
        "output": {
            RLUM_RECORDS_KEY: None,
        },
    },
    "record": {
        "depends_on": ["signal"],
        "input": {
            SELECTED_RECORD_INFO_KEY: None,
        },
        "output": {
            RLUM_RECORD_PLOT_RESULT_KEY: None,
        },
    },
    "sar_setup": {
        "depends_on": ["upload"],
        "input": {
            SIGNAL_PARAMS_KEY: None,
        },
        "output": {},
    },
    "sar": {
        "depends_on": ["sar_setup"],
        "input": {
            SAR_TARGET_POSITIONS_KEY: None,
        },
        "output": {
            SAR_RESULT_KEY: None,
        },
    },
    # De distribution analysis + model recommendation. The input is
    # automatically derived from the De vector produced by sar, so there is
    # no user-facing input yet ({}). If something like a model choice or a
    # QC-inclusion flag becomes necessary, add a key to input then (a future
    # "apply model" stage would reference this stage via depends_on).
    "de_dist": {
        "depends_on": ["sar"],
        "input": {},
        "output": {
            DE_DIST_RESULT_KEY: None,
        },
    },
}


# ============================================================
# 2. Schema-derived helpers (internal use)
# ============================================================

def _stage_input(stage: str) -> dict:
    return SESSION_SCHEMA[stage]["input"]


def _stage_output(stage: str) -> dict:
    return SESSION_SCHEMA[stage]["output"]


def _stage_all(stage: str) -> dict:
    """Return a stage's input + output defaults merged together."""
    return {**_stage_input(stage), **_stage_output(stage)}


def _all_defaults() -> dict:
    """The default values for every key this module owns (flat)."""
    merged: dict = {}
    for stage in SESSION_SCHEMA:
        merged.update(_stage_all(stage))
    return merged


def _dependents_of(stage: str) -> list[str]:
    """
    Return every stage that directly or indirectly depends on `stage`, in
    schema definition order.

    Walks depends_on in reverse. A stage already found is never revisited,
    so a cycle in the schema can't cause infinite recursion.
    """
    found: set[str] = set()

    def walk(target: str) -> None:
        for name, spec in SESSION_SCHEMA.items():
            if target in spec["depends_on"] and name not in found:
                found.add(name)
                walk(name)

    walk(stage)

    return [name for name in SESSION_SCHEMA if name in found]


def _reset_keys(defaults: dict) -> None:
    """Reset the given {key: default} set back to its default values."""
    for key, default_value in defaults.items():
        st.session_state[key] = default_value


# ============================================================
# 3. Generic accessors
# ============================================================
# These 3 functions stay the same no matter how many keys are added.
# Call sites look like: set_value(POSITION_RESULT_KEY, result).

def set_value(key: str, value) -> None:
    st.session_state[key] = value


def get_value(key: str):
    return st.session_state.get(key)


def has_value(key: str) -> bool:
    return get_value(key) is not None


# ============================================================
# 4. Initialization
# ============================================================

def init_session_state() -> None:
    """
    Initialize every key defined in the schema to its default value.

    Uses setdefault, so a key that already has a value is not overwritten.
    This means existing state survives a rerun.

    The nested schema is purely 'organization/metadata' — it's flattened
    into session_state. (Flat keys are the safest for widget key= binding
    and mutation tracking.)
    """
    for key, default_value in _all_defaults().items():
        st.session_state.setdefault(key, default_value)


# ============================================================
# 5. Stage-based invalidation (the core piece)
# ============================================================

def invalidate_from(stage: str) -> None:
    """
    Call this when a stage's input has changed.

    Rule:
      - Clear that stage's output (the input that was just set is kept)
      - Clear input + output entirely for every stage that depends on it

    The criterion is "what depends on me", not "what comes after me".
    e.g. invalidate_from("signal") only clears record. sar_setup and sar do
    not depend on signal, so they survive a POSITION change.

    Adding a new stage never requires modifying this function — just add its
    depends_on entry in the schema.
    """
    # Current stage: clear only the output (the input was just updated, so it's kept)
    _reset_keys(_stage_output(stage))

    # Stages that depend on this one: clear input + output entirely
    for dependent in _dependents_of(stage):
        _reset_keys(_stage_all(dependent))


# ============================================================
# 6. Upload-stage wrapper
# ============================================================
# The upload stage, which is used often by widgets/call sites, gets a thin
# wrapper whose name makes its meaning clear (internally it just reuses the
# generic accessors + invalidate_from).

def set_current_sample(
    sample: dict,
    uploaded_file_name: str,
    file_hash: str,
) -> None:
    """
    Save the currently uploaded sample info, and invalidate every downstream
    result that was computed based on the previous file.
    """
    set_value(UPLOADED_SAMPLE_KEY, sample)
    set_value(UPLOADED_FILE_NAME_KEY, uploaded_file_name)
    set_value(UPLOADED_FILE_HASH_KEY, file_hash)
    invalidate_from("upload")


def get_current_sample() -> dict | None:
    return get_value(UPLOADED_SAMPLE_KEY)


def has_current_sample() -> bool:
    return has_value(UPLOADED_SAMPLE_KEY)


def is_new_uploaded_file(uploaded_file_name: str, file_hash: str) -> bool:
    """
    Check whether the currently uploaded file differs from the existing one.

    Judged by content hash. Comparing filenames alone would misjudge a file
    with the same name but different content (e.g. a re-measured data.bin)
    as "the same file", leaving the previous file's results in place and
    silently producing a wrong analysis.

    Why the filename is also compared:
        So the UI state is reset fresh even when a file with identical
        content but a different name is uploaded. (Disk storage is a
        separate matter — file_utils reuses the existing sample folder when
        the hash matches, so no new folder is created in that case.)
    """
    return (
        get_value(UPLOADED_SAMPLE_KEY) is None
        or get_value(UPLOADED_FILE_HASH_KEY) != file_hash
        or get_value(UPLOADED_FILE_NAME_KEY) != uploaded_file_name
    )


# ============================================================
# 7. POSITION result wrapper (optional convenience functions)
# ============================================================

def set_position_result(result: dict) -> None:
    set_value(POSITION_RESULT_KEY, result)


def get_position_result() -> dict | None:
    return get_value(POSITION_RESULT_KEY)


def has_position_result() -> bool:
    return has_value(POSITION_RESULT_KEY)

# ============================================================
# 8. Signal Analysis stage wrapper
# ============================================================

def set_selected_signal_position(position: int) -> None:
    """
    Save the POSITION to inspect, and invalidate results that depend on it.

    When the POSITION changes, that POSITION's record list and curve plot
    become meaningless. signal_params and the SAR result, on the other hand,
    don't depend on signal, so they survive.
    """
    changed = get_value(SELECTED_SIGNAL_POSITION_KEY) != position
    set_value(SELECTED_SIGNAL_POSITION_KEY, position)

    if changed:
        invalidate_from("signal")


def set_rlum_records(records: dict) -> None:
    set_value(RLUM_RECORDS_KEY, records)


def get_rlum_records() -> dict | None:
    return get_value(RLUM_RECORDS_KEY)


def has_rlum_records() -> bool:
    return has_value(RLUM_RECORDS_KEY)


def set_selected_record_info(record_info: dict) -> None:
    """
    Save the record to inspect, and invalidate results that depend on it.

    When the record changes, only the curve plot drawn from that record
    becomes meaningless.
    """
    changed = get_value(SELECTED_RECORD_INFO_KEY) != record_info
    set_value(SELECTED_RECORD_INFO_KEY, record_info)

    if changed:
        invalidate_from("record")


def set_rlum_record_plot_result(result: dict) -> None:
    set_value(RLUM_RECORD_PLOT_RESULT_KEY, result)


def get_rlum_record_plot_result() -> dict | None:
    return get_value(RLUM_RECORD_PLOT_RESULT_KEY)


def has_rlum_record_plot_result() -> bool:
    return has_value(RLUM_RECORD_PLOT_RESULT_KEY)


def set_signal_params(params: dict) -> None:
    """
    Save the SAR parameters.

    Downstream (sar) is only invalidated when the parameters actually
    change. If the integral changes, the existing SAR result's De values
    were computed under different conditions and must not remain on screen.

    Invalidating even a re-save of the same values would discard a
    minutes-long SAR run for no reason, so the values are compared first and
    branched on.

    Only DE_AFFECTING_PARAMS is compared, not the whole dict. The
    reference_* entries in params record "which POSITION's curve this was
    decided by looking at" for display purposes only, and are not passed to
    run_sar_analysis (see the execution code in sar_tab.py). The SAR result
    must not be discarded just because the user browsed a different record
    and re-saved with the same integral.
    """
    old = get_signal_params() or {}
    changed = any(old.get(k) != params.get(k) for k in DE_AFFECTING_PARAMS)

    set_value(SIGNAL_PARAMS_KEY, params)

    if changed:
        invalidate_from("sar_setup")


def get_signal_params() -> dict | None:
    return get_value(SIGNAL_PARAMS_KEY)


def has_signal_params() -> bool:
    return has_value(SIGNAL_PARAMS_KEY)


def set_sar_target_positions(positions: list[int]) -> None:
    """
    Save the target POSITIONs for SAR analysis.

    Calling this means a re-run is about to start, so the old SAR result is
    discarded first. This prevents a previous run's De table from lingering
    on screen if the analysis then fails with an exception. (Unlike
    signal_params, there is no value-comparison guard here — even re-running
    on the same POSITIONs recomputes the result from scratch.)
    """
    set_value(SAR_TARGET_POSITIONS_KEY, positions)
    invalidate_from("sar")


def set_sar_result(result: dict) -> None:
    set_value(SAR_RESULT_KEY, result)


def get_sar_result() -> dict | None:
    return get_value(SAR_RESULT_KEY)


def has_sar_result() -> bool:
    return has_value(SAR_RESULT_KEY)


# ============================================================
# 8b. De Distribution stage wrapper
# ============================================================
# de_dist has no user input. It only has an analysis result (output) derived
# from the sar result, so only 3 result accessors are provided here. This
# result is automatically cleared whenever sar is invalidated.

def set_de_dist_result(result: dict) -> None:
    set_value(DE_DIST_RESULT_KEY, result)


def get_de_dist_result() -> dict | None:
    return get_value(DE_DIST_RESULT_KEY)


def has_de_dist_result() -> bool:
    return has_value(DE_DIST_RESULT_KEY)


# ============================================================
# 9. Full reset
# ============================================================

def reset_all_state() -> None:
    """
    Reset only the keys owned by this module back to their defaults.

    Note: this does not clear all of st.session_state.
    (So that state outside this module — widget keys, chat/agent state, etc.
    — isn't wiped out too.) Pipeline widgets derive their identity from
    schema state, so they get reset along with it.
    """
    _reset_keys(_all_defaults())


# ============================================================
# 10. Self-check
# ============================================================
# There's branching logic here, so at least one check is kept.
# Run: venv/bin/python app/utils/state_manager.py

if __name__ == "__main__":
    init_session_state()

    # A typo in depends_on means that stage is never invalidated by anyone
    # and silently keeps holding a stale value — exactly the situation this
    # module exists to prevent — so first check that every name is an
    # actual stage.
    for _name, _spec in SESSION_SCHEMA.items():
        for _dep in _spec["depends_on"]:
            assert _dep in SESSION_SCHEMA, \
                f"{_name}'s depends_on references '{_dep}', which is not a stage"

    # If a schema key and a widget key collide, the moment _reset_keys
    # touches that key after the widget has rendered, Streamlit raises and
    # the app crashes. Maintaining the list by hand would drift out of sync
    # anyway, so the tab source is scanned directly for key= strings.
    import re
    from pathlib import Path

    _tab_dir = Path(__file__).resolve().parent.parent / "tabs"
    _tab_src = "".join(f.read_text(encoding="utf-8") for f in _tab_dir.glob("*.py"))
    _collisions = set(re.findall(r"""key\s*=\s*["']([^"']+)["']""", _tab_src)) & set(_all_defaults())
    assert not _collisions, f"a schema key is also being used as a widget key: {sorted(_collisions)}"

    # First check that the dependency graph has the intended shape.
    # If this is wrong, everything the invalidation checks below verify is meaningless.
    assert _dependents_of("upload") == ["signal", "record", "sar_setup", "sar", "de_dist"], \
        "uploading a new file must invalidate every stage"
    assert _dependents_of("signal") == ["record"], \
        "changing the POSITION must not touch SAR"
    assert _dependents_of("record") == [], \
        "changing the selected record must not touch anything besides its own plot"
    assert _dependents_of("sar_setup") == ["sar", "de_dist"], \
        "changing the integral must invalidate the SAR result and the De distribution analysis"
    assert _dependents_of("sar") == ["de_dist"], \
        "changing the SAR result must invalidate the De distribution analysis"
    assert _dependents_of("de_dist") == [], \
        "there is no stage after de_dist yet"

    # The integral and SAR result must survive a POSITION change (this is
    # exactly why the hand-written exception function used to exist — it
    # now falls out of the rule automatically)
    set_value(SIGNAL_PARAMS_KEY, {"signal_integral": "1:2"})
    set_value(SAR_RESULT_KEY, {"de": 42})
    set_value(RLUM_RECORDS_KEY, {"record_index": [1]})
    set_selected_signal_position(99)

    assert get_value(SIGNAL_PARAMS_KEY) == {"signal_integral": "1:2"}, \
        "the integral setting was lost on a POSITION change"
    assert get_value(SAR_RESULT_KEY) == {"de": 42}, \
        "the SAR result was lost on a POSITION change"
    assert get_value(RLUM_RECORDS_KEY) is None, \
        "the old record list survived even though the POSITION changed"

    # A new file upload, conversely, must clear everything
    set_current_sample({"raw_path": "x"}, "a.bin", "hash1")
    assert get_value(SIGNAL_PARAMS_KEY) is None, \
        "the old integral setting survived a new file upload"
    assert get_value(SAR_RESULT_KEY) is None, \
        "the old SAR result survived a new file upload"

    # State was disturbed above, so reset it before continuing
    _reset_keys(_all_defaults())

    p1 = {"reference_position": 1, "signal_integral": "1:2", "background_integral": "900:1000"}
    p2 = {"reference_position": 7, "signal_integral": "1:2", "background_integral": "900:1000"}
    p3 = {"reference_position": 7, "signal_integral": "1:5", "background_integral": "900:1000"}

    set_signal_params(p1)
    set_value(SAR_RESULT_KEY, {"de": 100})

    # Re-saving the same values -> the SAR result is kept
    set_signal_params(p1)
    assert get_sar_result() == {"de": 100}, "the result was lost on re-saving the same parameters"

    # Changing only reference_* -> doesn't affect De, so the SAR result is kept
    set_signal_params(p2)
    assert get_sar_result() == {"de": 100}, "the SAR result was lost from a reference_*-only change"

    # Changing the integral -> the SAR result is invalidated
    set_signal_params(p3)
    assert get_sar_result() is None, "the old SAR result survived even though the integral changed"

    # Starting a SAR re-run -> discards the old SAR result AND the De distribution result derived from it
    set_value(SAR_RESULT_KEY, {"de": 200})
    set_de_dist_result({"recommended_model": "CAM"})
    set_sar_target_positions([1, 2, 3])
    assert get_sar_result() is None, "the old result survived even though a SAR re-run started"
    assert get_de_dist_result() is None, \
        "the old De distribution result survived even though SAR was invalidated"

    print("state_manager self-check OK")
