# Implementation Plan: cvbs-decode Test Harness

## Overview

This project provides a **local, stripped-down test environment** for `cvbs-decode`
(from the [vhs-decode](https://github.com/oyvindln/vhs-decode) project), wrapped in a
[Nix flake](https://nixos.wiki/wiki/Flakes).  The goal is to exercise `cvbs-decode` as a
black-box validator for the `cvbs-encode` project under development in this repo.

No changes will be upstreamed to the vhs-decode project.

---

## Architecture overview

```
cvbs-decode/                  ← this repo
├── external/
│   └── vhs-decode/           ← git submodule (pinned to vhs_decode branch)
│       ├── cvbsdecode/        # Python CVBS decode module  ← KEEP
│       ├── lddecode/          # LD-decode core library     ← KEEP
│       ├── vhsdecode/         # Shared VHS/CVBS code       ← KEEP (subset)
│       ├── src/               # Rust extension (vhsd_rust) ← KEEP
│       ├── tests/             # pytest suite               ← KEEP
│       └── … (everything else stripped in Phase 4)
├── flake.nix                  ← Nix flake: devShell + package
├── flake.lock
├── tests/                     ← CVBS-specific integration tests live here
│   └── test_cvbs_roundtrip.py
└── implementation-plan.md
```

---

## Dependency map

`cvbs-decode` pulls in:

| Layer | Modules / Files | Notes |
|---|---|---|
| Entry point | `cvbs-decode` (shell script) | Calls `cvbsdecode.main:main` |
| CVBS decode | `cvbsdecode/main.py`, `cvbsdecode/process.py` | Imports from lddecode + vhsdecode |
| LD-decode core | `lddecode/core.py`, `lddecode/utils.py`, `lddecode/utils_logging.py`, others | Base TBC/RF machinery |
| VHS shared | `vhsdecode/formats.py` (get_cvbs_params), `vhsdecode/cmdcommons.py`, `vhsdecode/addons/chromasep.py` | CVBS params, CLI parse, chroma sep |
| Cython extensions | `vhsdecode/sync.pyx`, `vhsdecode/hilbert.pyx`, `vhsdecode/linear_filter.pyx` | Must be compiled at build time |
| Rust extension | `src/` → `vhsd_rust` (pyo3) | Math utilities used by rust_utils.py |
| Python runtime | Python ≥ 3.11 | |
| Python packages | numpy ≥ 1.24, scipy ≥ 1.11, numba ≥ 0.59, Cython, matplotlib, noisereduce ≥ 2.0, setproctitle, sounddevice, soundfile ≥ 0.13.1, soxr, static-ffmpeg | Full list in requirements.txt |

**Components NOT needed** for bare `cvbs-decode`:

- `vhsdecode/hifi/` — HiFi audio decode
- `filter_tune/` — Filter-tuning utility
- `vhs_scripts/` — VHS-specific helper scripts
- `notebooks/` — Jupyter notebooks
- `tools/` — Misc tools
- `assets/`, `docs/` — Documentation assets
- `scripts/` — Release/build helper scripts
- `cmake_modules/`, `CMakeLists.txt`, `src/` **C++ tools** (ld-analyse, ld-chroma-decoder, etc.) — Qt/C++ post-processing tools only needed for viewing `.tbc` output, not for running the decoder itself
- Entry scripts: `vhs-decode`, `hifi-decode`, `ld-decode`, `cx-expander`, `ld-cut`, `decode-launcher`, `filter-tune`

> **Note:** The C++ ld-tools suite (`ld-analyse`, `ld-chroma-decoder`, `tbc-video-export`)
> is useful for post-processing `.tbc` output into a viewable video, but is ***not*** a
> dependency of the `cvbs-decode` Python decoder itself.  Phase 4 strips it; it can be
> re-enabled as a Nix package output later if needed.

---

## Phases

---

### Phase 1 — Repository setup

**Goal:** Get the upstream source locally, pinned to a known commit.

#### Steps

1. **Add vhs-decode as a git submodule** (preferred over a plain clone so the pin is version-controlled):

   ```sh
   mkdir -p external
   git submodule add -b vhs_decode \
       https://github.com/oyvindln/vhs-decode.git \
       external/vhs-decode
   git submodule update --init --recursive
   ```

2. **Pin the submodule** to the latest known-good commit on the `vhs_decode` branch.  Record
   the commit SHA in this document for reference at each phase.

3. **Verify the tree** — confirm the following key paths exist:

   ```
   external/vhs-decode/cvbsdecode/main.py
   external/vhs-decode/cvbsdecode/process.py
   external/vhs-decode/lddecode/core.py
   external/vhs-decode/vhsdecode/formats.py
   external/vhs-decode/vhsdecode/sync.pyx
   external/vhs-decode/src/           # Rust extension
   external/vhs-decode/tests/
   external/vhs-decode/pyproject.toml
   external/vhs-decode/Cargo.toml
   ```

#### Deliverables
- `external/vhs-decode/` present and pinned via `.gitmodules`

---

### Phase 2 — Dependency analysis & Nix flake skeleton

**Goal:** Create a working `flake.nix` that drops into a shell where `cvbs-decode` is
importable and the Cython/Rust extensions are compiled.

#### Steps

1. **Create `flake.nix`** at the repo root with the following outputs:
   - `devShells.default` — development shell
   - `packages.cvbs-decode` — installable package (for CI)
   - `checks.unit-tests` — runs pytest unit suite

2. **Nix inputs** required:

   ```nix
   inputs = {
     nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
     flake-utils.url = "github:numtide/flake-utils";
   };
   ```

3. **Python environment** — build a `python312.withPackages` env including:

   | Nix package name | maps to |
   |---|---|
   | `python312Packages.numpy` | numpy ≥ 1.24 |
   | `python312Packages.scipy` | scipy ≥ 1.11 |
   | `python312Packages.numba` | numba ≥ 0.59 |
   | `python312Packages.cython` | Cython |
   | `python312Packages.matplotlib` | matplotlib |
   | `python312Packages.noisereduce` | noisereduce ≥ 2.0 (may need overlay) |
   | `python312Packages.setproctitle` | setproctitle |
   | `python312Packages.sounddevice` | sounddevice |
   | `python312Packages.soundfile` | soundfile ≥ 0.13.1 |
   | `python312Packages.soxr` | soxr |
   | `python312Packages.pytest` | pytest (testing only) |
   | `python312Packages.setuptools` | build backend |
   | `python312Packages.wheel` | build backend |

   > `static-ffmpeg` (a PyPI wheel that bundles ffmpeg binaries) should be replaced by
   > `pkgs.ffmpeg` from nixpkgs.  The `lddecode/utils_logging.py` code falls back gracefully
   > if static-ffmpeg is not available.

4. **Rust toolchain** — the project uses stable Rust via `pyo3`/`setuptools-rust`.

   ```nix
   nativeBuildInputs = [
     pkgs.cargo
     pkgs.rustc
     pkgs.rustPlatform.bindgenHook   # not needed here but useful pattern
   ];
   ```

   Alternatively use `fenix` or `rust-overlay` for an exact toolchain pin.

5. **System libs** needed by Python packages:

   - `pkgs.portaudio` — required by `sounddevice`
   - `pkgs.libsndfile` — required by `soundfile`
   - `pkgs.ffmpeg` — replaces static-ffmpeg

6. **Build step** inside the devShell / package derivation — compile Cython + Rust
   extensions in the source tree:

   ```sh
   cd external/vhs-decode
   pip install --no-build-isolation -e ".[test]"
   # or: python setup.py build_ext --inplace
   ```

   For the Nix package derivation use `buildPythonPackage` with
   `nativeBuildInputs = [ setuptools-rust cargo rustc ]`.

#### Deliverables
- `flake.nix` — initial skeleton (may not build cleanly yet)
- `flake.lock` — committed after first `nix flake update`

---

### Phase 3 — Build & smoke-test the environment

**Goal:** Enter `nix develop` and successfully run `cvbs-decode --help`.

#### Steps

1. Enter the Nix dev shell:
   ```sh
   nix develop
   ```

2. Compile the Cython and Rust extensions in-place inside `external/vhs-decode`:
   ```sh
   cd external/vhs-decode
   pip install --no-build-isolation -e ".[test]"
   ```

3. Verify import chain:
   ```sh
   python -c "from cvbsdecode.main import main; print('OK')"
   ```

4. Verify CLI:
   ```sh
   python -m cvbsdecode.main --help
   # or once installed:
   cvbs-decode --help
   ```

5. Run the upstream **unit test suite** (currently covers `test_demod`, `test_sync`,
   `test_zero_crossing`, `test_rust_math` — these exercise the shared signal-processing
   code that cvbs-decode relies on):

   ```sh
   cd /tmp
   python -m pytest --rootdir=$REPO_ROOT/external/vhs-decode \
       $REPO_ROOT/external/vhs-decode/tests/unit -v
   ```

   Expected: all 4 test modules pass.

6. Iterate on `flake.nix` until the above succeeds reproducibly with `nix develop`.

#### Deliverables
- `flake.nix` that passes `nix develop` and `cvbs-decode --help`
- CI-ready `nix flake check` target executing unit tests

---

### Phase 4 — Strip the vhs-decode tree

**Goal:** Remove components not needed by `cvbs-decode` to reduce noise, build time, and
attack surface.

> Since the submodule is pinned (not modified for upstream), this stripping is done via a
> **post-checkout hook / setup script** (`scripts/prepare-external.sh`) that removes the
> unneeded paths from the working tree.  The submodule itself is not mutated — the script
> is idempotent and safe to re-run after `git submodule update`.

#### Directories / files to remove

```
external/vhs-decode/vhsdecode/hifi/      # HiFi audio decode
external/vhs-decode/filter_tune/         # Filter tuning tool
external/vhs-decode/vhs_scripts/         # VHS helper scripts
external/vhs-decode/notebooks/           # Jupyter notebooks
external/vhs-decode/tools/               # Misc post-processing tools
external/vhs-decode/assets/              # Images/icons
external/vhs-decode/docs/                # Documentation
external/vhs-decode/scripts/             # Release/CI helper scripts
external/vhs-decode/resources/           # AppImage resources
external/vhs-decode/cmake_modules/       # CMake find modules
external/vhs-decode/CMakeLists.txt       # C++ ld-tools build
external/vhs-decode/CMakePresets.json
external/vhs-decode/vcpkg.json
external/vhs-decode/vcpkg-configuration.json
```

Entry-point scripts that are not `cvbs-decode`:
```
external/vhs-decode/vhs-decode
external/vhs-decode/hifi-decode
external/vhs-decode/ld-decode
external/vhs-decode/decode-launcher
external/vhs-decode/cx-expander
external/vhs-decode/ld-cut
external/vhs-decode/filter-tune
external/vhs-decode/decode.py
external/vhs-decode/gen_chroma_vid*.sh
```

#### Minimum `vhsdecode/` file list

Within `vhsdecode/` only these files are needed (all others can be removed):

```
__init__.py
cmdcommons.py
formats.py
sync.pyx
hilbert.pyx
linear_filter.pyx
rust_utils.py
utils.py
addons/__init__.py
addons/chromasep.py
format_defs/__init__.py
format_defs/cvbs.py    # if it exists, otherwise formats.py covers it
```

> This list should be validated when compiling — if an import error surfaces, the missing
> file is added back.

#### Deliverables
- `scripts/prepare-external.sh` — idempotent strip script
- Documented list of retained files

---

### Phase 5 — CVBS integration test with real captures

**Goal:** Write a pytest integration test that runs `cvbs-decode` end-to-end on a real
CVBS capture, verifying the output `.tbc` file is produced and matches the reference
output.

#### Test data (local — gitignored, see `cvbs-tests/README.md`)

All files are stored in `cvbs-tests/` (not committed).

| File | System | Type | Sample rate | Duration | Notes |
|---|---|---|---|---|---|
| `cvbs-ntsc-hackdac-v2-misrc-v1.5.flac` | NTSC | **Raw CVBS RF** | 40 Msps, 16-bit | ~10.5 s | Primary decode input |
| `cvbs-ntsc-hackdac-v2-misrc-v1.mkv` | NTSC | **Reference output** | — | 10.51 s | FFV1 760×488 yuv422p10le 29.97 fps; used to validate decode results |
| `cvbs-pal-hackdac-v2-misrc-v1.5-full-4fsc-frame.mp4` | PAL | Reference video | — | 74.8 s | H.264 1104×624 50 fps; full 4fsc frame |
| `cvbs-pal-hackdac-v2-misrc-v1.5-test.mp4` | PAL | Reference video | — | 74.8 s | H.264 928×576 50 fps; active-area view |

> **Missing:** No raw PAL FLAC/CVBS capture is present.  PAL roundtrip testing uses
> `cvbs-encode` to synthesise a PAL RF signal from the PAL MP4 (see test tier 2 below).
> If a raw PAL capture becomes available, drop it in `cvbs-tests/` and add a direct PAL
> decode test as done for NTSC below.

**Important FLAC encoding note:** The FLAC header reports `sample_rate=40000` (an artefact
caused by FLAC's ~655 kHz maximum; `40000` is used as a proxy for 40 MHz).  Always decode
with `--frequency 40` to pass the true 40 Msps sample rate.  Duration arithmetic:
421 527 552 samples ÷ 40 000 000 sps ≈ 10.5 s.

#### Test tier 1 — NTSC hardware capture decode

**Input:** `cvbs-tests/cvbs-ntsc-hackdac-v2-misrc-v1.5.flac`  
**Reference:** `cvbs-tests/cvbs-ntsc-hackdac-v2-misrc-v1.mkv` (760×488, 29.97 fps, 10.51 s)

```sh
cvbs-decode \
  --frequency 40 \
  --system NTSC \
  -A \
  --length 300 \
  cvbs-tests/cvbs-ntsc-hackdac-v2-misrc-v1.5.flac \
  cvbs-tests/output/ntsc_test
```

Expected outputs:
- `ntsc_test.tbc` — non-empty 4fsc TBC stream
- `ntsc_test.tbc.json` — `videoParameters.numberOfSequentialFields` > 0; frame
  dimensions match NTSC 4fsc standard (910×525 samples per field)

```python
import subprocess, pathlib, json, pytest

FIXTURES = pathlib.Path(__file__).parent.parent / "cvbs-tests"

@pytest.fixture(scope="session")
def ntsc_flac():
    p = FIXTURES / "cvbs-ntsc-hackdac-v2-misrc-v1.5.flac"
    if not p.exists():
        pytest.skip("NTSC fixture not present — see cvbs-tests/README.md")
    return p

@pytest.mark.integration
def test_ntsc_decode_produces_tbc(ntsc_flac, tmp_path):
    out = tmp_path / "ntsc_out"
    result = subprocess.run(
        [
            "cvbs-decode",
            "--frequency", "40",
            "--system", "NTSC",
            "-A",
            "--length", "300",       # ~10 s of content
            str(ntsc_flac),
            str(out),
        ],
        capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stderr

    tbc = out.with_suffix(".tbc")
    assert tbc.exists() and tbc.stat().st_size > 0, "TBC file missing or empty"

    meta = json.loads(out.with_suffix(".tbc.json").read_text())
    vp = meta["videoParameters"]
    assert vp["numberOfSequentialFields"] >= 20, "Too few fields decoded"
    # NTSC 4fsc: 910 active samples × 525 lines
    assert vp["fieldWidth"] == 910
    assert vp["fieldHeight"] == 525

@pytest.mark.integration
def test_ntsc_decode_frame_count_matches_reference(ntsc_flac, tmp_path):
    """Decoded field count should be close to the reference MKV (10.51 s × 59.94 fields/s ≈ 630 fields)."""
    ref_mkv = FIXTURES / "cvbs-ntsc-hackdac-v2-misrc-v1.mkv"
    if not ref_mkv.exists():
        pytest.skip("NTSC reference MKV not present")

    out = tmp_path / "ntsc_ref_check"
    subprocess.run(
        ["cvbs-decode", "--frequency", "40", "--system", "NTSC",
         "-A", "--length", "300", str(ntsc_flac), str(out)],
        check=True, capture_output=True, timeout=300,
    )
    meta = json.loads(out.with_suffix(".tbc.json").read_text())
    fields = meta["videoParameters"]["numberOfSequentialFields"]
    # Allow ±5 % tolerance around the expected ~630 fields
    assert 598 <= fields <= 663, f"Unexpected field count {fields}"
```

#### Test tier 2 — PAL encode→decode roundtrip (synthetic)

**Input:** `cvbs-tests/cvbs-pal-hackdac-v2-misrc-v1.5-test.mp4` (928×576 50 fps)  
**Flow:** `cvbs-encode` → raw PAL CVBS FL AC → `cvbs-decode` → `.tbc`

```python
@pytest.mark.integration
def test_pal_encode_decode_roundtrip(tmp_path):
    src = FIXTURES / "cvbs-pal-hackdac-v2-misrc-v1.5-test.mp4"
    if not src.exists():
        pytest.skip("PAL fixture not present — see cvbs-tests/README.md")

    raw = tmp_path / "pal_cvbs.u16"  # adjust format to match cvbs-encode output
    subprocess.run(
        ["cvbs-encode", "--system", "PAL", "--input", str(src), "--output", str(raw)],
        check=True, timeout=300,
    )

    out = tmp_path / "pal_decoded"
    subprocess.run(
        ["cvbs-decode", "--frequency", "40", "--system", "PAL",
         "-A", "--length", "50",   # 1 second PAL = 50 fields
         str(raw), str(out)],
        check=True, timeout=300,
    )

    tbc = out.with_suffix(".tbc")
    assert tbc.exists() and tbc.stat().st_size > 0

    meta = json.loads(out.with_suffix(".tbc.json").read_text())
    assert meta["videoParameters"]["numberOfSequentialFields"] > 0
    assert meta["videoParameters"]["fieldWidth"] == 1135  # PAL 4fsc
    assert meta["videoParameters"]["fieldHeight"] == 625
```

> The exact `cvbs-encode` CLI flags and output format (`--output`, byte format, etc.) will
> be finalised once `cvbs-encode` is further along.  Adjust `raw` extension and flags
> accordingly.

#### Running the tests

```sh
pytest tests/unit                          # fast, no fixtures required
pytest -m integration tests/              # full suite — requires cvbs-tests/ populated
pytest -m integration -k ntsc tests/      # NTSC tier only
pytest -m integration -k pal  tests/      # PAL roundtrip only
```

#### Deliverables
- `tests/test_cvbs_roundtrip.py` — integration tests (both tiers)
- `conftest.py` fixture helpers and `pytest.ini_options` marker declarations
- `cvbs-tests/README.md` — fixture catalogue (already created)

---

### Phase 6 — CI/CD wiring

**Goal:** Run all tests reproducibly via `nix flake check`.

#### Steps

1. **Add a `checks` output** in `flake.nix`:

   ```nix
   checks.unit-tests = pkgs.runCommand "unit-tests" {
     buildInputs = [ cvbs-decode-env ];
   } ''
     cd /tmp
     python -m pytest --rootdir=${src}/external/vhs-decode \
         ${src}/external/vhs-decode/tests/unit -v
     touch $out
   '';
   ```

2. **Integration tests** are gated on the `integration` mark and require external data;
   they run via:

   ```sh
   nix develop --command pytest -m integration tests/
   ```

   These should be run manually or in a CI job that has network access / cached fixtures.

3. **Optional: GitHub Actions workflow** in `.github/workflows/test.yml`:

   ```yaml
   - uses: cachix/install-nix-action@v26
   - run: nix flake check
   - run: nix develop --command pytest tests/unit -v
   ```

#### Deliverables
- `flake.nix` with `checks.unit-tests`
- `.github/workflows/test.yml` (optional, for the cvbs-decode repo itself)

---

## Summary table

| Phase | Key output | Blocking? |
|---|---|---|
| 1 | `external/vhs-decode` submodule | Yes — all later phases depend on it |
| 2 | `flake.nix` skeleton | Yes — needed to run anything |
| 3 | Working `cvbs-decode --help` + unit tests pass | Yes |
| 4 | `scripts/prepare-external.sh` (strip script) | No — optional cleanup |
| 5 | CVBS integration test | Yes — core purpose of this repo |
| 6 | `nix flake check` CI target | No — can come last |

---

## Key technical decisions & rationale

### Git submodule vs. vendored copy
Using a git submodule keeps the upstream pin explicit and allows `git submodule update`
to pick up security or bug fixes without losing the strip modifications (which live in the
separate `scripts/prepare-external.sh`).

### Nix flake vs. Docker / pip-only
A Nix flake is reproducible across Linux machines without needing root, works on NixOS and
any Linux with Nix installed, and integrates cleanly with `nix flake check` for CI.
The dev shell replaces all `apt-get` / `pip install` steps with a single `nix develop`.

### Rust extension (vhsd_rust)
The Rust extension is linked into `vhsdecode/rust_utils.py` and used at import time.  It
**must** be compiled as part of the build.  In Nix this is handled by including `cargo` and
`rustc` in `nativeBuildInputs` of the `buildPythonPackage` derivation.

### static-ffmpeg replacement
The upstream project uses `static-ffmpeg` (a PyPI wheel bundling a pre-built ffmpeg binary)
because it targets non-NixOS Linux.  In Nix we replace this with `pkgs.ffmpeg` and use
`makeWrapper` or `wrapProgram` to add ffmpeg to `PATH` inside the cvbs-decode wrapper.

### Unit tests vs. integration tests
The existing upstream unit tests (`tests/unit/`) validate the shared signal-processing
primitives (Cython sync, Rust math, demod).  They run **without real RF data** and are
quick (~5 s).  The integration tests (`tests/integration/`) are marked
`@pytest.mark.integration` and need real or synthetic CVBS captures.  Both tiers are
preserved and separable.

---

## Reference links

- vhs-decode repo: <https://github.com/oyvindln/vhs-decode>
- CVBS decode wiki: <https://github.com/oyvindln/vhs-decode/wiki/CVBS-Composite-Decode>
- CVBS test samples (Internet Archive): <https://archive.org/details/wss-wide-screen-signaling>
- Nix flake documentation: <https://nixos.wiki/wiki/Flakes>
- setuptools-rust: <https://github.com/PyO3/setuptools-rust>
