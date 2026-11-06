# ScanDeck — free, open-source Mac scanning software for trading cards

[![CI](https://github.com/eliseorobles/ScanDeck/actions/workflows/ci.yml/badge.svg)](https://github.com/eliseorobles/ScanDeck/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 26](https://img.shields.io/badge/platform-macOS%2026-lightgrey)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange)

**Batch-scan trading cards front and back on macOS, at 600 dpi, with a real
scanner-background border — and get numbered `_F` / `_B` pairs a listing tool
can read.** ScanDeck drives a duplex ADF document scanner, crops each side to
the card (or its toploader) plus 3 mm of genuine captured background, and
publishes a finished folder in one atomic step.

Built for card dealers and TCG sellers who scan in volume on a Mac and feed the
images into a listing pipeline — [CardUploader](https://carduploader.com/),
[TCG Automate](https://www.tcgautomate.com/), Card Dealer Pro, a CSV workflow,
or a grading/centering check.

MIT licensed. No account, no cloud, no upload, no telemetry. Your scans stay on
your machine.

---

## The short version

| | |
|---|---|
| **What it does** | Duplex ADF pass → front/back pairs → review → one atomic published folder |
| **Output** | `scan_000114_F.jpg` + `scan_000114_B.jpg`, JPEG q95, 24-bit RGB, 600 dpi |
| **Border** | 3 mm per edge of **real captured scanner background**, never synthetic padding |
| **Platform** | macOS 26, Apple Silicon |
| **Scanner** | Ricoh / Fujitsu **fi-8170** (the only model supported today — see below) |
| **Cost** | Free, MIT, open source |
| **Tests** | 267 tests in 31 suites, no scanner required |

## Why this exists

**PaperStream Capture is Windows-only.** Ricoh's own system requirements list
Windows 11, Windows 10 and Windows Server — and no macOS. So a dealer who buys
an fi-series scanner and uses a Mac gets the ICA driver and Apple Image Capture,
and the capture *application* Windows dealers rely on simply has no Mac
equivalent from the vendor.

That gap is real and well known. ScanDeck is one answer to it, with a specific
opinion about what matters: **the border is evidence.** A crop that clips the
card edge destroys the thing a buyer inspects and a centering grader measures,
and it does so in a way that still looks fine in a thumbnail. ScanDeck measures
the margin on every side, warns when the two sides of a card disagree, and
**refuses to publish** a batch it cannot vouch for — rather than silently
padding or clamping.

## Honest positioning: what else exists

ScanDeck is **not** the only way to scan cards on a Mac, and you should know the
alternatives before installing anything.

| Tool | Mac? | Free? | Open source? | Built for cards? |
|---|---|---|---|---|
| **ScanDeck** | Yes | Yes | **Yes (MIT)** | Yes |
| [Trading Card Scanner](https://www.tradingcardscanner.com/) (Card Dealer Pro / CollX) | Yes | Yes | No | Yes |
| PaperStream Capture (Ricoh/PFU) | **No — Windows only** | Bundled | No | No (general documents) |
| Apple Image Capture | Yes (built in) | Yes | No | No |
| [VueScan](https://www.hamrick.com/) | Yes | Paid | No | No |
| [ExactScan](https://exactscan.com/) | Yes | Paid | No | No |
| [NAPS2](https://www.naps2.com/) | Yes | Yes | Yes | No (scan-to-PDF) |

**Trading Card Scanner is the closest existing option** and it is good: free,
native Mac and Windows, tested on the same fi-8170, auto-crops, optional black
border, writes `TCS-00000001-front.jpg`. If you want something finished and
supported, try it first.

Pick ScanDeck instead when you want:

- **Open source you can audit, fork, and keep.** MIT, no account, no vendor tie.
- **A margin verdict, not just a crop.** ScanDeck measures the real background
  on all four edges of every side, cross-checks the two sides of each card
  against each other, and blocks Complete Batch on a pair it cannot justify.
- **Nothing leaving your machine.** No login, no upload, no analytics. The one
  optional network feature (a centering check) asks for fresh confirmation every
  single run and names the destination and the exact image count first.
- **Deskew that never invents a pixel.** Every card comes off an ADF slightly
  rotated — measured at 0.19°–1.00°, median 0.54°. ScanDeck squares it, but only
  after proving all four corners of the squared crop lie inside the captured
  frame. If it can't prove that, it doesn't rotate.

## Works with your listing pipeline

ScanDeck deliberately does **no** card recognition, pricing, or listing. It
produces clean, numbered, correctly-oriented image pairs and stops. That is the
listing tool's job.

- **[CardUploader](https://carduploader.com/)** — AI card identification and
  eBay/Shopify/TCGplayer listing export. Accepts JPG and wants both front and
  back for ungraded cards. ScanDeck's naming was designed against this flow.
- **[TCG Automate](https://www.tcgautomate.com/)** — bulk listing across 30+
  TCGs and sports, with an explicit *Front & Back* upload mode.
- **Card Dealer Pro**, **Ximilar**, spreadsheet/CSV workflows, or your own
  script — the output is just numbered JPEGs in a folder.

> **Practical tip on upload order.** CardUploader documents that uploaded files
> are ordered alphabetically, and `scan_000114_B.jpg` sorts *before*
> `scan_000114_F.jpg`. If your tool treats the first image of a pair as the one
> to match on, confirm it is picking the front. This is an inference from their
> documented ordering rule, not a defect we have reproduced — but it costs
> nothing to check, and front and back centering tolerances differ by 5×.

Nobody listed above has endorsed or tested ScanDeck. These are the tools its
output is shaped for, described from their own public documentation.

## Requirements

- **macOS 26**, Apple Silicon
- **Xcode 26** or later to build (Swift 6.2 or later; verified with Xcode 26.3
  and 27.2)
- A **Ricoh / Fujitsu fi-8170** with the PFU ICA driver installed

### About scanner support

ScanDeck currently supports **one scanner model**. It matches on USB identity —
`0x04c5:0x15ff` (Fujitsu-branded) and `0x05ca:0x03d8` (Ricoh-branded), which are
the same fi-8170 — and any other device is detected, named, and explicitly
refused before a session opens.

That is deliberate, not laziness. The pipeline depends on duplex, 600 dpi, a
fixed scan area, and four PFU vendor features (overscan cropping, multifeed
detection off, blank-page skip off, pre-pick off). Overscan is what captures the
real background border the whole design rests on. A scanner missing any of it
would produce output that looks plausible and is wrong — so ScanDeck refuses
rather than guesses.

**Widening this is the single most valuable contribution available.** If you
have a duplex ADF scanner with a macOS ICA driver, `swift run scandeck-m0 --list`
and `--inspect` cost you nothing and produce exactly the data needed. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Getting started

There is no downloadable release yet (it is an open issue), so ScanDeck is built
from source. On a Mac that already has Xcode this takes about five minutes.

### 1. What you need

- A Mac with **Apple Silicon** running **macOS 26** or later.
- **Xcode 26** or later from the Mac App Store. The Swift toolchain ships inside
  it. Open Xcode once so it can finish installing its components, then point the
  command line at it:

  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  swift --version        # Swift 6.2 or later
  ```

- To scan: a **Ricoh / Fujitsu fi-8170** over USB, with Ricoh's macOS ICA
  driver installed (the same driver Apple Image Capture uses). Any other scanner
  is detected, named, and refused. To try ScanDeck without a scanner, skip this
  and use the synthetic page source below.

### 2. Build and launch

```sh
git clone https://github.com/eliseorobles/ScanDeck.git
cd ScanDeck
bash Scripts/bundle-app.sh --run
```

The first build takes a few minutes; later ones are incremental. The script
builds `.build/ScanDeck.app`, ad-hoc signs it, and opens it. To launch it again
later, run the same command or `open .build/ScanDeck.app`.

**Use the bundle rather than `swift run ScanDeck`** — a bare SwiftPM executable
registers as background-only, which means text fields silently ignore every
keystroke.

Because the bundle is ad-hoc signed, macOS may ask for access to your
destination folder again after a rebuild. That is expected.

### 3. Scan a batch

1. Choose the built-in **Cards 600 Full Border** profile.
2. Press **Choose Destination** to pick a folder, then type a batch name such
   as `aug01-sale`. The name must be new — ScanDeck never writes into a folder
   that already exists.
3. Load the feeder and press **Scan**. Each card appears as a front/back pair
   with its number, crop preview already applied.
4. Review. Rotate or delete a side, delete or replace a card, **Retry Card**
   on an incomplete one, or **Continue Scanning** to add another feeder pass.
   If the whole stack scanned dark, the **Brightness** slider in the action bar
   lifts every card in the batch; the preview shows exactly what will be
   published.
5. Press **Complete Batch**. The folder appears in your destination in one
   atomic step, and the summary offers Show in Finder and New Batch.

The **Check Centering** button on the summary depends on a tool that is not part
of this repository. In a fresh clone it reports itself unavailable; everything
else works.

### No scanner? Run the whole pipeline anyway

```sh
bash Scripts/bundle-app.sh --synthetic
```

This swaps *only* the page source. Crop analysis, margin verdicts, deskew and
atomic publication all still run for real, so it exercises the production path.
It is the fastest way to see what ScanDeck does without an fi-8170.

### Command line

```sh
swift run scandeck-m0 --list                        # enumerate scanners
swift run scandeck-m0 --inspect --device fi-8170    # capabilities + vendor features
swift run scandeck-m0 --scan --device fi-8170 --output ./out   # one duplex card
```

Also accepts `--timeout SECONDS` (inactivity, not total elapsed) and
`--scan-window WxH` (an investigation flag; the app never sets it). `--scan`
requires a new or empty output directory and expects exactly two pages.

### Run the tests

```sh
swift test                 # the whole suite, no scanner required
swift test -c release      # what CI runs; image suites are much faster here
```

## What you get

```
<destination you picked>/
└── aug01-sale/                 ← appears only on Complete Batch, by atomic rename
    ├── scan_000114_F.jpg
    ├── scan_000114_B.jpg
    ├── scan_000115_F.jpg
    └── scan_000115_B.jpg
```

- **JPEG**, quality 0.95, 24-bit RGB, **600 dpi** written into both the image
  properties and the JFIF density fields
- Rotation **baked into the pixels**, never left as an EXIF orientation flag, so
  the file is correct in every consumer
- A six-digit **persistent counter** that survives relaunches, crashes and
  cancellations; deleted cards leave intentional gaps rather than reusing numbers
- The batch folder is created by **atomic rename** from a staging directory on
  the same volume. ScanDeck never merges into or overwrites an existing batch.
- An optional **brightness** adjustment: one setting for the whole batch,
  previewed in the review grid before it is baked into the published files. It
  is a gamma curve, so black and white stay fixed and nothing clips; at its
  default of None the output is byte-identical to an unadjusted publish. The
  setting is recorded in the batch history.

## Design rules it will not break

These come from [SPEC.md](SPEC.md) and are enforced by an event-sourced reducer
with 267 tests behind it, not by UI code:

1. **Never lose an acknowledged page.** No jam, multifeed, disconnect, crash or
   save failure may discard a page the app already accepted.
2. **The border is real captured background.** If the requested margin would
   cross the captured frame, ScanDeck flags it and blocks completion. It never
   silently pads or clamps.
3. **The batch folder appears only on Complete Batch**, atomically.
4. **An incomplete card blocks everything** until it is retried or removed.
5. **A cancelled batch burns no counter numbers.**

Crash recovery resumes an unfinished batch with its images, margins and
destination intact.

## Project layout

Pure SwiftPM. **Zero external dependencies** — every import is an Apple system
framework.

| Target | Role |
|---|---|
| `ScanDeckCore` | Hardware-free domain: batch reducer, pairing, margins, counters, durable files |
| `ScanDeckScanner` | `ImageCaptureCore` adapter: device probe, pass client, reconnect policy |
| `ScanDeckImagePipeline` | Media detection, deskew, real-margin crop, JPEG encode, atomic publication |
| `ScanDeckApp` | SwiftUI shell |
| `ScanDeckM0` | CLI probe — the proven hardware path |

Keeping `ImageCaptureCore` inside one target is what makes the domain
deterministic and the test suite possible without hardware.

## Status

The app scans real batches end to end on a physical fi-8170 — including a
186-card production run. Milestones M0–M2 are met.

Still open: a job/profile editor (there is one built-in profile today), an app
icon, accessibility passes, a downloadable release, and a supported-scanner
matrix. Every one of those has an [issue](https://github.com/eliseorobles/ScanDeck/issues).

CI runs `swift build` and `swift test -c release` on every pull request, plus a
hygiene job that fails if a card scan or any private working file ever becomes
tracked.

## Help make this the best scanning app on the Mac

That is the actual goal, and it is reachable — but not by one person with one
scanner.

ScanDeck already does one thing nothing else on the Mac does: it **measures the
border it is about to publish and refuses to publish a batch it cannot vouch
for.** Every published pixel is captured background. When a card's two sides
disagree by more than 140 px the batch stays blocked until a person overrules
that specific card, and the overrule is stored against the two measured
footprints so a re-scan invalidates it. That is not a slogan — it is a reducer,
and you can go read it.

"Best open-source Mac scanning app" would mean that same guarantee holds **on a
scanner you already own, in an app you can download, driven from a keyboard.**
All three of those currently fail, and none of them fail for architectural
reasons:

| The gap | Why it is not hard | Where |
|---|---|---|
| **One supported scanner** | The hardware seam is a single protocol. The allowlist is a two-entry `Set` | `ScannerInventory.swift:23` |
| **No downloadable app** | The bundle script already builds and signs it; it needs notarization and a release | `Scripts/bundle-app.sh` |
| **Mouse required** | Two review actions are hover-only, with no keyboard route | `BatchWorkspaceView.swift:741` |

**Widening scanner support is the highest-value thing anyone can do here**, and
it caps everything else — more scanners means more users, and contributors come
from users. The correctness guarantee is exactly what makes the project worth
widening, so the work is to grow the device list *without* loosening it. The
test harness for that already exists: 267 tests run with no scanner, and
`--synthetic` exercises the real crop, verdict, deskew and publication path.

### You do not need a scanner

This is the most common reason people assume they can't help, and it is wrong.
Every issue is labelled `needs-fi-8170` or `no-hardware-needed`, and almost
everything is the second one. The reducer, the SwiftUI shell, the JPEG and DPI
metadata, the crash-safety primitives, the error copy, accessibility, docs and
CI are all reachable with nothing but a Mac.

### Good places to start

- **[Open issues](https://github.com/eliseorobles/ScanDeck/issues)** — every one
  names the files to touch and the command that proves it worked.
- **Have a different duplex ADF scanner?** Run `swift run scandeck-m0 --list`
  and `--inspect` and open a hardware datapoint. That is the seed of the
  supported-scanner matrix and it costs you five minutes.
- **Found a card ScanDeck measured wrong?** That is the most valuable bug report
  this project can get. Tell us what the two sides measured — but never attach
  the scan.
- **Read [SPEC.md](SPEC.md) and poke holes in it.** It is the contract, and
  disagreeing with it in an issue is a real contribution.

You will get a reply. See [CONTRIBUTING.md](CONTRIBUTING.md) for what to expect
and how changes land.

## Contributing

Contributions go through a branch and a pull request:

```sh
git checkout -b my-change
# ... make your change, run swift test ...
git push -u origin my-change
```

Then open a PR against `main`. `main` is protected and takes changes only by
reviewed pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the build and
hardware-testing workflow, and please **never commit card scans** — they are
someone's property and the repository has never contained one.

## FAQ

**Is there a PaperStream Capture for Mac?**
No. Ricoh does not ship PaperStream Capture for macOS; its system requirements
list Windows only. ScanDeck is an independent open-source app that covers the
card-scanning workflow on macOS.

**How do I scan Pokémon or sports cards front and back automatically?**
Use a duplex ADF scanner, which images both sides in a single pass. ScanDeck
pairs the two sides into one card and names them `_F` and `_B` from a shared
counter.

**Does it work with any Mac scanner?**
Not yet — only the fi-8170. Other scanners are detected and explicitly refused
rather than silently producing wrong output. Widening support is the most useful
contribution available.

**Will it scan graded slabs or semi-rigids?**
No. Supported media are raw cards and cards in toploaders. Semi-rigids stay
unsupported until they pass physical thickness, transport and duplex testing —
an unsafe format stays unsupported rather than being forced through an ADF.

**Does it identify cards or set prices?**
No, by design. ScanDeck publishes a counter and a side, nothing more. A filename
cannot tell you a card is holo or silver-foil, so it does not pretend to.
Identification belongs to your listing tool.

**Does it upload my scans anywhere?**
No. There is one optional post-publication centering check, and it asks for
fresh confirmation on every run, naming the service and the exact image count
before anything is sent. It is never automatic and never remembered.

**Why 600 dpi when other tools use 400?**
More detail for centering and surface inspection, at a larger file. The
published DPI is written into the file metadata, so downstream tools measure in
the right unit.

## Support this project

ScanDeck is free and MIT licensed. If it saves you time:

- ☕ **[Buy me a coffee](https://buymeacoffee.com/eliseorobles)**
- 🌐 **[eliseorobles.com](https://eliseorobles.com/)**
- ⭐ Star the repo — it is how other Mac card sellers find it

## Trademarks and affiliation

ScanDeck is an independent open-source project with **no affiliation to PFU
Limited, Ricoh, or Fujitsu**. "PaperStream" is their trademark and is used here
only to refer to their product. "Pokémon", "eBay", "TCGplayer", "PSA", "BGS",
"CGC" and other marks belong to their respective owners and are used only to
describe what this software is for. No PFU code, assets, screenshots, or
resources are used or vendored anywhere in this repository.

## License

[MIT](LICENSE) © Eliseo Robles
