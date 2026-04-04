"""CVBS integration tests — black-box validation of cvbs-decode.

Test tier 1 — NTSC hardware capture decode
   Input:  cvbs-tests/cvbs-ntsc-hackdac-v2-misrc-v1.5.flac  (40 Msps RF capture)
   Checks: TBC produced, JSON metadata matches NTSC 4fsc geometry and field count.

Test tier 2 — PAL encode→decode roundtrip (synthetic)
   Input:  cvbs-tests/cvbs-pal-hackdac-v2-misrc-v1.5-test.mp4  (928×576 50 fps)
   Flow:   cvbs-encode → raw PAL CVBS → cvbs-decode → .tbc
   NOTE:   Requires 'cvbs-encode' to be on PATH.  The exact CLI is provisional
           and will be updated once cvbs-encode is further along.

All tests are marked @pytest.mark.integration and are skipped automatically when
the required fixture files are absent.  Run:

    pytest -m integration tests/             # full integration suite
    pytest -m integration -k ntsc tests/     # NTSC tier only
    pytest -m integration -k pal  tests/     # PAL roundtrip only
"""

import json
import pathlib
import shutil
import subprocess

import pytest


# ---------------------------------------------------------------------------
# Module-level path constant (mirrored from conftest.py for inline use)
# ---------------------------------------------------------------------------
FIXTURES = pathlib.Path(__file__).parent.parent / "cvbs-tests"


# ---------------------------------------------------------------------------
# Tier 1 — NTSC hardware capture decode
# ---------------------------------------------------------------------------


@pytest.mark.integration
def test_ntsc_decode_produces_tbc(ntsc_flac: pathlib.Path, tmp_path: pathlib.Path) -> None:
    """cvbs-decode on the NTSC capture must produce a non-empty TBC file.

    Checks:
    - Return code is 0.
    - <out>.tbc exists and has non-zero size.
    - <out>.tbc.json is valid JSON and contains the expected NTSC 4fsc geometry:
        fieldWidth  == 910
        fieldHeight == 525
        numberOfSequentialFields >= 20
    """
    out = tmp_path / "ntsc_out"
    result = subprocess.run(
        [
            "cvbs-decode",
            "--frequency", "40",
            "--system", "NTSC",
            "-A",
            "--length", "300",  # ~10 s of content
            str(ntsc_flac),
            str(out),
        ],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, (
        f"cvbs-decode exited with code {result.returncode}\n--- stderr ---\n{result.stderr}"
    )

    tbc = out.with_suffix(".tbc")
    assert tbc.exists() and tbc.stat().st_size > 0, "TBC file missing or empty"

    meta = json.loads(out.with_suffix(".tbc.json").read_text())
    vp = meta["videoParameters"]
    assert vp["numberOfSequentialFields"] >= 20, (
        f"Too few fields decoded: {vp['numberOfSequentialFields']}"
    )
    # NTSC 4fsc: 910 samples/line (outlinelen).  fieldHeight is per-field line
    # count (263 for NTSC: ceil(525/2); full frame = 525 lines split across two fields).
    assert vp["fieldWidth"] == 910, f"Unexpected fieldWidth: {vp['fieldWidth']}"
    assert vp["fieldHeight"] == 263, f"Unexpected fieldHeight: {vp['fieldHeight']}"


@pytest.mark.integration
def test_ntsc_decode_field_count_matches_reference(
    ntsc_flac: pathlib.Path,
    ntsc_ref_mkv: pathlib.Path,
    tmp_path: pathlib.Path,
) -> None:
    """Decoded field count should be close to the reference video duration.

    Reference: ~10.51 s × 59.94 fields/s ≈ 630 fields.
    Tolerance: ±5 % → acceptable range [598, 663].
    """
    out = tmp_path / "ntsc_ref_check"
    subprocess.run(
        [
            "cvbs-decode",
            "--frequency", "40",
            "--system", "NTSC",
            "-A",
            "--length", "300",
            str(ntsc_flac),
            str(out),
        ],
        check=True,
        capture_output=True,
        timeout=300,
    )

    meta = json.loads(out.with_suffix(".tbc.json").read_text())
    fields = meta["videoParameters"]["numberOfSequentialFields"]
    # Allow ±5 % tolerance around the expected ~630 fields for 10.51 s at 59.94 fields/s
    assert 598 <= fields <= 663, (
        f"Unexpected field count {fields}; expected 598–663 for ~10.51 s NTSC capture"
    )


# ---------------------------------------------------------------------------
# Tier 2 — PAL encode→decode roundtrip (synthetic)
# ---------------------------------------------------------------------------


@pytest.mark.integration
def test_pal_encode_decode_roundtrip(
    pal_mp4: pathlib.Path,
    tmp_path: pathlib.Path,
) -> None:
    """Encode a PAL MP4 to raw CVBS RF, then decode it back to TBC.

    Requires 'cvbs-encode' to be available on PATH.  Skipped if it is not.

    NOTE: The cvbs-encode CLI flags and raw output format are provisional and
    will be updated once cvbs-encode stabilises.  Adjust '--output' extension
    and format flags (e.g. --format u16) to match the actual cvbs-encode
    interface when it is available.
    """
    if shutil.which("cvbs-encode") is None:
        pytest.skip("cvbs-encode not found on PATH — skipping PAL roundtrip test")

    raw = tmp_path / "pal_cvbs.u16"
    subprocess.run(
        [
            "cvbs-encode",
            "--system", "PAL",
            "--input", str(pal_mp4),
            "--output", str(raw),
        ],
        check=True,
        capture_output=True,
        timeout=300,
    )

    out = tmp_path / "pal_decoded"
    subprocess.run(
        [
            "cvbs-decode",
            "--frequency", "40",
            "--system", "PAL",
            "-A",
            "--length", "50",  # 1 second PAL = 50 fields
            str(raw),
            str(out),
        ],
        check=True,
        capture_output=True,
        timeout=300,
    )

    tbc = out.with_suffix(".tbc")
    assert tbc.exists() and tbc.stat().st_size > 0, "PAL TBC file missing or empty"

    meta = json.loads(out.with_suffix(".tbc.json").read_text())
    vp = meta["videoParameters"]
    assert vp["numberOfSequentialFields"] > 0, "No PAL fields decoded"
    # PAL 4fsc: 1135 samples/line (outlinelen).  fieldHeight is per-field line
    # count (313 for PAL: ceil(625/2); full frame = 625 lines split across two fields).
    assert vp["fieldWidth"] == 1135, f"Unexpected PAL fieldWidth: {vp['fieldWidth']}"
    assert vp["fieldHeight"] == 313, f"Unexpected PAL fieldHeight: {vp['fieldHeight']}"
