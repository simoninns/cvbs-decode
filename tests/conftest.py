"""Shared pytest fixtures for the cvbs-decode integration test suite."""

import pathlib

import pytest


# Root of the local test fixture directory (gitignored binaries).
# See cvbs-tests/README.md for the expected files and how to obtain them.
FIXTURES_DIR = pathlib.Path(__file__).parent.parent / "cvbs-tests"


@pytest.fixture(scope="session")
def fixtures_dir() -> pathlib.Path:
    """Path to the cvbs-tests/ directory containing local capture fixtures."""
    return FIXTURES_DIR


@pytest.fixture(scope="session")
def ntsc_flac() -> pathlib.Path:
    """Path to the NTSC raw CVBS RF capture (FLAC, 40 Msps, 16-bit).

    Skips if the file is not present — see cvbs-tests/README.md.
    """
    p = FIXTURES_DIR / "cvbs-ntsc-hackdac-v2-misrc-v1.5.flac"
    if not p.exists():
        pytest.skip("NTSC fixture not present — see cvbs-tests/README.md")
    return p


@pytest.fixture(scope="session")
def ntsc_ref_mkv() -> pathlib.Path:
    """Path to the NTSC reference output MKV (FFV1, 760×488, 29.97 fps).

    Skips if the file is not present — see cvbs-tests/README.md.
    """
    p = FIXTURES_DIR / "cvbs-ntsc-hackdac-v2-misrc-v1.mkv"
    if not p.exists():
        pytest.skip("NTSC reference MKV not present — see cvbs-tests/README.md")
    return p


@pytest.fixture(scope="session")
def pal_mp4() -> pathlib.Path:
    """Path to the PAL active-area reference video (928×576, 50 fps).

    Skips if the file is not present — see cvbs-tests/README.md.
    """
    p = FIXTURES_DIR / "cvbs-pal-hackdac-v2-misrc-v1.5-test.mp4"
    if not p.exists():
        pytest.skip("PAL fixture not present — see cvbs-tests/README.md")
    return p
