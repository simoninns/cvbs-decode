{
  description = "cvbs-decode – local test harness for the CVBS decoder from vhs-decode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        python = pkgs.python312;

        # Vendored vhs-decode source tree (plain tracked files, pinned to 32ffb0fa).
        vhsDecodeSrc = ./external/vhs-decode;

        # All Python runtime, build-time, and test dependencies.
        # Mirrors requirements.txt / pyproject.toml except static-ffmpeg, which is
        # replaced by pkgs.ffmpeg (see native library inputs below).
        #
        # NOTE: noisereduce and soxr are expected to be present in nixos-25.11.
        # If either is missing from your channel snapshot, add a PyPI overlay here.
        pythonEnv = python.withPackages (ps: [
          # ── Runtime ────────────────────────────────────────────────────────
          ps.numpy            # >= 1.24
          ps.scipy            # >= 1.11
          ps.numba            # >= 0.59
          ps.matplotlib
          ps.noisereduce      # >= 2.0
          ps.setproctitle
          ps.sounddevice
          ps.soundfile        # >= 0.13.1
          ps.soxr

          # ── Build tools ────────────────────────────────────────────────────
          # Cython extensions: vhsdecode/{sync,hilbert,linear_filter}.pyx
          ps.cython
          ps.setuptools
          ps."setuptools-rust"  # pyo3 Rust extension (src/ → vhsd_rust)
          ps."setuptools-scm"   # version detection from git tags
          ps.wheel

          # ── Testing ────────────────────────────────────────────────────────
          ps.pytest
        ]);

        # ── Sandboxed package build ───────────────────────────────────────────
        #
        # Compiles the Cython extensions and the vhsd_rust pyo3 Rust extension
        # inside the Nix sandbox.  Used by checks.unit-tests and packages.default.
        #
        # To recompute the cargoHash after updating Cargo.lock:
        #   nix build --impure --expr '
        #     let pkgs = import <nixpkgs> {};
        #     in pkgs.rustPlatform.fetchCargoVendor {
        #       src = ./external/vhs-decode;
        #       hash = pkgs.lib.fakeHash;
        #     }'
        # and replace the hash with the "got:" value in the error message.
        cvbsDecoderPkg = python.pkgs.buildPythonPackage {
          pname = "vhs-decode";
          version = "0.0.1.dev0";
          format = "pyproject";

          src = vhsDecodeSrc;

          # Rust extension: src/lib.rs → vhsd_rust.(cpython-312-…).so
          cargoRoot = ".";
          cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
            src = vhsDecodeSrc;
            name = "vhs-decode-vendor";
            hash = "sha256-fKAqjvx4Gqa426OyR2qEPXUPEneXGOT1GqOMFDol0Zc=";
          };

          nativeBuildInputs = [
            pkgs.rustPlatform.cargoSetupHook
            pkgs.cargo
            pkgs.rustc
            python.pkgs."setuptools-rust"
            python.pkgs."setuptools-scm"
            python.pkgs.cython
            python.pkgs.setuptools
            python.pkgs.wheel
            # Strip static-ffmpeg from the wheel metadata: it is not in nixpkgs
            # and is replaced by pkgs.ffmpeg added to PATH in the devShell.
            python.pkgs.pythonRelaxDepsHook
          ];

          # Remove static-ffmpeg from the declared runtime requirements so that
          # pythonRuntimeDepsCheckHook does not fail the build.  ffmpeg is
          # provided by pkgs.ffmpeg at runtime (via PATH in the devShell).
          pythonRemoveDeps = [ "static-ffmpeg" ];

          buildInputs = [
            pkgs.portaudio
            pkgs.libsndfile
          ];

          propagatedBuildInputs = with python.pkgs; [
            numpy
            scipy
            numba
            matplotlib
            noisereduce
            setproctitle
            sounddevice
            soundfile
            soxr
            # cvbsdecode/main.py unconditionally imports pyximport at module
            # load time (to support dynamic .pyx compilation in dev mode).
            # The pre-compiled .so extensions don't need it at runtime, but the
            # import still happens, so cython must be present as a runtime dep.
            cython
          ];

          # No git tags in the vendored source; provide a fixed version string.
          SETUPTOOLS_SCM_PRETEND_VERSION = "0.0.1.dev0";

          # Tests are exercised via the checks.unit-tests derivation below.
          doCheck = false;
        };

      in {

        # ── devShell ──────────────────────────────────────────────────────────
        #
        # Provides all Python deps plus the Rust toolchain and native libraries.
        # Extensions are NOT pre-built here; compile them once inside the shell:
        #
        #   nix develop
        #   cd external/vhs-decode
        #   pip install --no-build-isolation -e ".[test]"
        #
        devShells.default = pkgs.mkShell {
          packages = [
            pythonEnv

            # Rust toolchain – required to build the vhsd_rust pyo3 extension
            # (external/vhs-decode/src/lib.rs, pyo3 0.27, numpy 0.27)
            pkgs.cargo
            pkgs.rustc

            # Native libraries
            pkgs.portaudio       # sounddevice (runtime + build)
            pkgs.libsndfile      # soundfile   (runtime + build)
            pkgs.ffmpeg          # replaces the static-ffmpeg PyPI wheel
            pkgs.pkg-config      # needed by portaudio / libsndfile builds
          ];

          shellHook = ''
            # The host PYTHONPATH may contain Python 3.13 system packages (e.g.
            # from mkdocs or other NixOS system tools).  Those leak into pip's
            # dependency resolver and cause setuptools-rust to generate an
            # inconsistent cp313 ABI tag while building for Python 3.12, which
            # trips the wheel tag assertion.  Clearing PYTHONPATH here ensures
            # the Nix-provided Python 3.12 environment is the sole source of
            # packages and the venv inherits only the intended packages.
            unset PYTHONPATH

            # Bootstrap a mutable venv that inherits the Nix-provided packages.
            # This lets `pip install -e` write compiled extensions into a writable
            # prefix while still resolving numpy, scipy, etc. from the Nix store.
            VENV="$PWD/.venv"
            if [ ! -d "$VENV" ]; then
              echo "Bootstrapping Python virtual environment ..."
              python -m venv --system-site-packages "$VENV"
            fi
            source "$VENV/bin/activate"

            # The editable-install finder maps packages (cvbsdecode, vhsdecode, …)
            # but NOT top-level extension modules like vhsd_rust.  Add the source
            # root via a .pth file so `import vhsd_rust` resolves to the compiled
            # .so regardless of how the interpreter was launched.
            PTH="$VENV/lib/python3.12/site-packages/vhs-decode-src.pth"
            if [ ! -f "$PTH" ] || [ "$(cat "$PTH")" != "$PWD/external/vhs-decode" ]; then
              echo "$PWD/external/vhs-decode" > "$PTH"
            fi

            # Suppress setuptools-scm version-detection failures in the vendored source.
            # The tree has no git tags, so scm cannot compute a version; the env var
            # provides a fixed fallback that satisfies the build machinery.
            export SETUPTOOLS_SCM_PRETEND_VERSION="''${SETUPTOOLS_SCM_PRETEND_VERSION:-0.0.1.dev0}"

            # Ensure Nix-provided ffmpeg is used rather than any static-ffmpeg wheel.
            export PATH="${pkgs.ffmpeg}/bin:$PATH"

            echo ""
            echo "=== cvbs-decode dev shell ($(python --version 2>&1)) ==="
            echo ""
            echo "  Build Cython + Rust extensions:"
            echo "    cd external/vhs-decode && pip install --no-build-isolation -e '.[test]'"
            echo ""
            echo "  Smoke-test import:"
            echo "    python -c \"from cvbsdecode.main import main; print('OK')\""
            echo ""
            echo "  Run upstream unit suite:"
            echo "    python -m pytest external/vhs-decode/tests/unit -v"
            echo ""
          '';
        };

        # ── packages ──────────────────────────────────────────────────────────
        #
        # The default package is the full sandboxed build — Cython + Rust compiled.
        # The devShell uses a separate venv-based workflow for faster iteration.
        packages.default = cvbsDecoderPkg;

        # ── checks ────────────────────────────────────────────────────────────
        #
        # Runs the upstream unit test suite inside the Nix sandbox using the
        # sandboxed package build above.  Execute with:
        #   nix flake check
        #
        # The integration tests (marked @pytest.mark.integration) require external
        # capture data and are NOT included here; run them manually:
        #   nix develop --command pytest -m integration tests/
        checks.unit-tests =
          let
            testEnv = python.withPackages (ps: [
              cvbsDecoderPkg
              ps.pytest
            ]);
          in
          pkgs.runCommand "cvbs-decode-unit-tests"
            { buildInputs = [ testEnv ]; }
            ''
              cd /tmp
              # Numba's AOT cache must live in a writable directory.
              export NUMBA_CACHE_DIR=/tmp/numba-cache
              # vhsd_rust is a top-level extension module (not a package), so it is
              # not on sys.path by default.  Add the installed lib path explicitly.
              export PYTHONPATH="${cvbsDecoderPkg}/${python.sitePackages}:$PYTHONPATH"
              # Run only the two test modules whose imports succeed against the
              # stripped vhsdecode tree.  test_demod and test_sync import
              # vhsdecode.process (a VHS-only module removed in Phase 4) and are
              # excluded here; they can still be run interactively in the devShell
              # where the full package is installed via pip -e.
              python -m pytest \
                -p no:cacheprovider \
                --rootdir=${vhsDecodeSrc} \
                ${vhsDecodeSrc}/tests/unit/test_rust_math.py \
                ${vhsDecodeSrc}/tests/unit/test_zero_crossing.py \
                -v
              touch $out
            '';
      }
    );
}
