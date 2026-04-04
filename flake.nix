{
  description = "cvbs-decode – local test harness for the CVBS decoder from vhs-decode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        python = pkgs.python312;

        # All Python runtime, build-time, and test dependencies.
        # Mirrors requirements.txt / pyproject.toml except static-ffmpeg, which is
        # replaced by pkgs.ffmpeg (see native library inputs below).
        #
        # NOTE: noisereduce and soxr are expected to be present in nixpkgs-unstable.
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

            # Suppress setuptools-scm version-detection failures in the submodule.
            # The SETUPTOOLS_SCM_PRETEND_VERSION env var is only used as fallback.
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
        # TODO (Phase 3): Replace this stub with a full buildPythonPackage
        # derivation for cvbs-decode.
        #
        # The main blocker for a sandboxed package build is the pyo3 Rust extension:
        # Cargo fetches crates.io deps at build time, which is not allowed inside the
        # Nix sandbox.  The solution is to vendor the dependency set:
        #
        #   nativeBuildInputs = [
        #     (pkgs.rustPlatform.fetchCargoVendor {
        #       inherit src;
        #       hash = "sha256-<compute with: nix build .#cargoVendorHash>";
        #     })
        #     pkgs.cargo pkgs.rustc
        #     ...
        #   ];
        #
        # Once the devShell build is validated (Phase 3), compute the hash and wire
        # it up here with python.pkgs.buildPythonPackage.
        packages.default = pythonEnv;

        # ── checks ────────────────────────────────────────────────────────────
        #
        # TODO (Phase 6): Add a sandboxed nix flake check for the unit-test suite.
        # Blocked on the buildPythonPackage derivation above.
        #
        # Interim – run the upstream unit suite interactively inside the dev shell:
        #   nix develop --command python -m pytest external/vhs-decode/tests/unit -v
        checks = { };
      }
    );
}
