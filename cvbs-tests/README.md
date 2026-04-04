# cvbs-tests — local test fixtures

This directory holds CVBS capture and reference files used by the integration
test suite.  **All binary files are gitignored** — they live only on your local
machine.  This README is the only tracked file here.

---

## What should be in this directory

### NTSC — hardware capture + reference output (HackDAC v2 / MISRC v1.5)

| Filename | Size | Notes |
|---|---|---|
| `cvbs-ntsc-hackdac-v2-misrc-v1.5.flac` | ~284 MB | **Primary NTSC test input.** FLAC-compressed raw CVBS RF capture. 40 Msps, 16-bit, mono. ~10.5 seconds. Captured with a HackDAC v2 signal generator → MISRC v1.5 ADC board. Decode with `--frequency 40 --system NTSC -A`. |
| `cvbs-ntsc-hackdac-v2-misrc-v1.mkv` | ~73 MB | **NTSC reference output.** FFV1 lossless, 760×488, yuv422p10le, 29.97 fps (30000/1001), 10.51 s. This is the known-good decoded output for the NTSC capture above — used to validate decode results. |

### PAL — decoded reference videos (HackDAC v2 / MISRC v1.5)

| Filename | Size | Notes |
|---|---|---|
| `cvbs-pal-hackdac-v2-misrc-v1.5-full-4fsc-frame.mp4` | ~19 MB | H.264, 1104×624, yuv420p, 50 fps, 74.8 s. Full 4fsc PAL frame view (includes VBI area). Reference output or `cvbs-encode` source material. |
| `cvbs-pal-hackdac-v2-misrc-v1.5-test.mp4` | ~17 MB | H.264, 928×576, yuv420p, 50 fps, 74.8 s. Active video area (PAL 576). Reference output or `cvbs-encode` source material. |

> **Note:** No raw PAL RF capture (`.flac` / `.cvbs`) is present in this set.
> The PAL MP4s are either reference decoded outputs or input source material
> intended for a `cvbs-encode → cvbs-decode` roundtrip test.
> If a raw PAL capture becomes available, drop it here and update the test suite.

---

## Source

All files were captured / generated using:

- **Signal generator:** HackDAC v2 (composite CVBS test signal)
- **ADC capture hardware:** MISRC v1.5
- **Original Google Drive folder:**
  `https://drive.google.com/drive/folders/1PVKRyKeu74RXmwJSAc4Zm2CXZomfhMc9`
  (folder: `CX_Blue_Card_CVBS_SMPTE_Bars_WSS-Modes_Sixdb-0_Level-0`)
- **Internet Archive mirror:**
  `https://archive.org/details/wss-wide-screen-signaling`

---

## How the NTSC FLAC is decoded

The FLAC container stores raw RF samples using FLAC's audio encoding machinery.
The FLAC stream metadata shows `sample_rate: 40000` (a header artefact — FLAC
does not natively support 40 MHz), but the actual capture rate is **40 Msps**.
Always pass `--frequency 40` (or `-f 40`) explicitly to `cvbs-decode`.

```sh
cvbs-decode \
  --frequency 40 \
  --system NTSC \
  -A \
  --length 300 \
  cvbs-ntsc-hackdac-v2-misrc-v1.5.flac \
  output/ntsc_test
```

The outputs are:
- `output/ntsc_test.tbc` — 4fsc TBC luma+chroma (headerless 16-bit GREY16)
- `output/ntsc_test.tbc.json` — frame/field metadata
- `output/ntsc_test.log` — decode log

---

## Adding more fixtures

Place additional `.flac` / `.cvbs` / `.u8` captures in this directory.
They will be automatically gitignored. Update this README with:
- TV system (NTSC / PAL / PAL-M)
- Sample rate and bit depth
- Signal source (generator model or real tape deck)
- Duration
- Decode flags needed
