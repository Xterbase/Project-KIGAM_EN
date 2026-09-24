# version1_streamlit/utils/file_utils.py

from datetime import datetime
import hashlib
import json
from pathlib import Path
import re


# ============================================================
# 0. Sample folder convention
# ============================================================
# Folder name: {sample_name}_{YYYYMMDD}_{NN}
#   e.g. ExampleData_20260714_01
#
# Measurements of the same sample are grouped together by name, and within
# that, distinguished by the date/number of when they were uploaded.
#
# Each sample folder also keeps a sample.json (metadata) alongside it.
# This is what lets us tell "has this file already been uploaded" from its
# content hash, preventing a duplicate folder when the same file is uploaded
# again.

SAMPLE_META_FILE = "sample.json"

# If the folder name is too long, it hits macOS's filename length limit
# (255 bytes) and mkdir/open blow up. Trim the stem generously, accounting
# for the date (8) + number (2) + separators that get appended.
MAX_STEM_LENGTH = 80


# ============================================================
# 0-1. Content hash of the uploaded file
# ============================================================
def compute_upload_hash(uploaded_file) -> str:
    """
    Hash the uploaded file's content with sha256.

    Why:
        If "is this the same file" is judged by filename alone, uploading a
        file with the same name but different content (e.g. a re-measured
        data.bin) would leave the previous file's results in place and
        silently produce a wrong analysis. Comparing by content hash
        prevents this misjudgment.
    """
    return hashlib.sha256(uploaded_file.getbuffer()).hexdigest()


# ============================================================
# 1. Building a safe file/folder name
# ============================================================
def sanitize_name(name: str) -> str:
    """
    Turn a filename or sample_id into a name that's safe to use.

    Example:
        "CWOSL SAR example.rda"
        -> "CWOSL_SAR_example"

    Why:
        A filename with lots of spaces, parentheses, or special characters
        can cause headaches later in R/Python/path handling.
    """

    # Strip the extension
    stem = Path(name).stem

    # Keep only alphanumerics, Korean characters, underscores, and hyphens;
    # replace everything else with _
    safe = re.sub(r"[^0-9a-zA-Z가-힣_-]+", "_", stem)

    # Collapse consecutive underscores into one
    safe = re.sub(r"_+", "_", safe)

    # Strip leading/trailing underscores
    safe = safe.strip("_")

    # Length limit (prevents mkdir/open from blowing up on filename length limits)
    safe = safe[:MAX_STEM_LENGTH].strip("_")

    # Fall back to a default if the name ends up empty
    return safe or "sample"


# ============================================================
# 2. Building the sample_id: {sample_name}_{YYYYMMDD}_{NN}
# ============================================================
def make_sample_id(
    base_name: str,
    samples_dir: Path,
    today: str | None = None,
) -> str:
    """
    Build a sample_id that doesn't collide within outputs/samples.

    Example:
        ExampleData_20260714_01
        ExampleData_20260714_02   (a different file uploaded the same day)
        ExampleData_20260715_01   (the next day)

    The number (NN) is appended based on how many existing folders already
    use "the same sample name + the same date".
    """

    stem = sanitize_name(base_name)
    today = today or datetime.now().strftime("%Y%m%d")

    prefix = f"{stem}_{today}_"

    index = 1

    while (samples_dir / f"{prefix}{index:02d}").exists():
        index += 1

    return f"{prefix}{index:02d}"


# ============================================================
# 3. Creating the sample folder structure
# ============================================================
def create_sample_dirs(samples_dir: Path, sample_id: str) -> dict:
    """
    Create the folders needed for one sample.

    Actual storage structure:
        outputs/samples/{sample_id}/
          raw/
          inspect/
          curve_plot/
          analysis_results/

    Only raw and inspect are used at this current stage, but the folders
    needed by later stages are created up front too.
    """

    sample_dir = samples_dir / sample_id

    paths = {
        "sample_dir": sample_dir,
        "raw_dir": sample_dir / "raw",
        "inspect_dir": sample_dir / "inspect",
        "curve_plot_dir": sample_dir / "curve_plot",
        "analysis_results_dir": sample_dir / "analysis_results",
    }

    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)

    return paths


# ============================================================
# 4. Reading/writing the sample metadata (sample.json)
# ============================================================
# sample.json stores only the "file name", not a path. This is so that paths
# can be rebuilt from the sample folder even if the project folder is moved
# or renamed.

def _write_sample_meta(
    sample_dir: Path,
    sample_id: str,
    file_hash: str,
    original_file_name: str,
    raw_file_name: str,
) -> None:
    meta = {
        "sample_id": sample_id,
        "file_hash": file_hash,
        "original_file_name": original_file_name,
        "raw_file_name": raw_file_name,
        "created_at": datetime.now().isoformat(timespec="seconds"),
    }

    (sample_dir / SAMPLE_META_FILE).write_text(
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def _read_sample_meta(sample_dir: Path) -> dict | None:
    meta_path = sample_dir / SAMPLE_META_FILE

    if not meta_path.exists():
        return None

    try:
        return json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        # If the metadata is corrupted, treat it as "absent" (it's recovered
        # the next time it's saved)
        return None


def _build_sample(sample_id: str, paths: dict, raw_path: Path, file_hash: str) -> dict:
    return {
        "sample_id": sample_id,
        "sample_dir": paths["sample_dir"],
        "raw_path": raw_path,
        "paths": paths,
        "file_hash": file_hash,
    }


def find_sample_by_hash(samples_dir: Path, file_hash: str) -> dict | None:
    """
    Find an already-saved sample whose content hash matches.

    This lets a re-upload of the same file reuse the existing folder instead
    of creating a new one. (Previously, every re-upload kept piling up copies
    of the original as ExampleData_2, _3, _4, ...)
    """

    if not samples_dir.exists():
        return None

    for sample_dir in sorted(samples_dir.iterdir()):
        if not sample_dir.is_dir():
            continue

        meta = _read_sample_meta(sample_dir)

        if meta is None or meta.get("file_hash") != file_hash:
            continue

        raw_path = sample_dir / "raw" / str(meta.get("raw_file_name", ""))

        # If the metadata remains but the original file was deleted, don't
        # reuse it — let it be saved fresh instead.
        if not raw_path.exists():
            continue

        paths = create_sample_dirs(samples_dir, sample_dir.name)

        return _build_sample(
            sample_id=sample_dir.name,
            paths=paths,
            raw_path=raw_path,
            file_hash=file_hash,
        )

    return None


# ============================================================
# 5. Saving the uploaded file
# ============================================================
def save_uploaded_file(
    uploaded_file,
    samples_dir: Path,
    file_hash: str | None = None,
) -> dict:
    """
    Save a BIN/RDA file uploaded through Streamlit into the sample folder.

    If a sample with the same content hash already exists, it isn't saved
    again — that existing folder is reused instead. (Previous analysis
    results such as curve_plot/ are left intact too.)

    Returns:
        {
            "sample_id": "ExampleData_20260714_01",
            "sample_dir": Path(...),
            "raw_path": Path(...),
            "paths": {...},
            "file_hash": "...",
            "reused": bool,     # whether an existing folder was reused
        }
    """

    samples_dir.mkdir(parents=True, exist_ok=True)

    if file_hash is None:
        file_hash = compute_upload_hash(uploaded_file)

    # ------------------------------------------------------------
    # Reuse the existing folder if this file has already been uploaded
    # ------------------------------------------------------------
    existing = find_sample_by_hash(samples_dir, file_hash)

    if existing is not None:
        return {**existing, "reused": True}

    # ------------------------------------------------------------
    # New file -> create a {sample_name}_{YYYYMMDD}_{NN} folder
    # ------------------------------------------------------------
    sample_id = make_sample_id(uploaded_file.name, samples_dir)
    paths = create_sample_dirs(samples_dir, sample_id)

    # Keep the original extension
    suffix = Path(uploaded_file.name).suffix
    raw_file_name = f"{sample_id}{suffix}"
    raw_path = paths["raw_dir"] / raw_file_name

    # BIN/RDA are binary files, so save with wb
    with open(raw_path, "wb") as f:
        f.write(uploaded_file.getbuffer())

    _write_sample_meta(
        sample_dir=paths["sample_dir"],
        sample_id=sample_id,
        file_hash=file_hash,
        original_file_name=uploaded_file.name,
        raw_file_name=raw_file_name,
    )

    return {
        **_build_sample(sample_id, paths, raw_path, file_hash),
        "reused": False,
    }


# ============================================================
# 5. Reading the list of existing sample folders
# ============================================================
def list_samples(samples_dir: Path) -> list[dict]:
    """
    Read the list of sample folders under outputs/samples.

    This will be needed later to restore the Research Workspace on the left
    after restarting the app.

    Not required at this current stage, but including it now means it's
    ready to use as soon as the next stage needs it.
    """

    if not samples_dir.exists():
        return []

    samples = []

    for sample_dir in sorted(samples_dir.iterdir()):
        if not sample_dir.is_dir():
            continue

        raw_dir = sample_dir / "raw"
        raw_files = list(raw_dir.glob("*")) if raw_dir.exists() else []

        samples.append(
            {
                "sample_id": sample_dir.name,
                "sample_dir": sample_dir,
                "raw_files": raw_files,
            }
        )

    return samples


# ============================================================
# 6. Deleting a sample
# ============================================================
def save_sar_results(analysis_results_dir: Path, result: dict) -> dict:
    """
    Save the SAR results as CSV.

    If the result only lives in session memory, it has to be re-analyzed
    every time the app restarts, and it can't be passed on to the next stage
    (De distribution) or an external tool. De values are a research
    deliverable, so they're written to disk.

    Files saved:
        sar_de_table.csv         De/error/QC status for every aliquot
        sar_qc_table.csv         every rejection-criteria row per POSITION
        sar_accepted_de.csv      rows where RC.Status is not FAILED
        sar_rejected_de.csv      rows where it is FAILED
        sar_failed_positions.csv POSITIONs where the analysis itself failed, with the reason

        Every CSV gets signal_integral / background_integral columns attached.

    Returns: {name: saved path} — contains only the ones actually saved.
    """

    import pandas as pd

    analysis_results_dir = Path(analysis_results_dir)
    analysis_results_dir.mkdir(parents=True, exist_ok=True)

    tables = {
        "de_table": (result.get("aliquots"), "sar_de_table.csv"),
        "qc_table": (result.get("qc_rows"), "sar_qc_table.csv"),
        "accepted": (result.get("accepted"), "sar_accepted_de.csv"),
        "rejected": (result.get("rejected"), "sar_rejected_de.csv"),
        "failed": (result.get("failed"), "sar_failed_positions.csv"),
    }

    # The loop below won't create a file for a table that's empty this run.
    # Without deleting first, a file from a previous run would linger and
    # mix results from different runs in the same folder.
    for _, file_name in tables.values():
        (analysis_results_dir / file_name).unlink(missing_ok=True)

    # It must be possible to tell which integral a CSV's De values were
    # computed with just by looking at the CSV. This value isn't recorded in
    # the original data file and shifts De by ~15%, so omitting it would make
    # a saved result unreproducible.
    signal_integral = ":".join(str(v) for v in result.get("signal_integral") or [])
    background_integral = ":".join(str(v) for v in result.get("background_integral") or [])

    saved = {}

    for name, (rows, file_name) in tables.items():
        # Don't create empty tables. A leftover empty CSV makes it impossible
        # to tell whether it's from a previous analysis or this run simply
        # produced nothing.
        if not rows:
            continue

        file_path = analysis_results_dir / file_name
        df = pd.DataFrame(rows)
        df["signal_integral"] = signal_integral
        df["background_integral"] = background_integral
        df.to_csv(file_path, index=False, encoding="utf-8-sig")
        saved[name] = file_path

    return saved


# ============================================================
# Self-check
# ============================================================
# This module contains logic that deletes files, so at least one check is
# kept for that.
# Run: venv/bin/python version1_streamlit/utils/file_utils.py

if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)

        run1 = {
            "signal_integral": [1, 2],
            "background_integral": [900, 1000],
            "aliquots": [{"position": 1, "de": 50.0}],
            "rejected": [{"position": 2, "de": 10.0}],
        }
        save_sar_results(out, run1)
        assert (out / "sar_rejected_de.csv").exists(), "the first run's file was not created"

        # Second run: rejected is empty, so the first run's file must not remain
        run2 = {
            "signal_integral": [1, 5],
            "background_integral": [900, 1000],
            "aliquots": [{"position": 1, "de": 60.0}],
            "rejected": [],
        }
        save_sar_results(out, run2)
        assert not (out / "sar_rejected_de.csv").exists(), "a leftover file from the previous run remains"

        text = (out / "sar_de_table.csv").read_text(encoding="utf-8-sig")
        assert "signal_integral" in text, "the integral column is missing from the CSV"
        assert "1:5" in text, "the second run's integral value was not recorded"

    print("file_utils self-check OK")
