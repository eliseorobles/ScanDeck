# Contributing

ScanDeck scans real batches end to end (SPEC milestones M0–M2 are met on a
physical fi-8170).

## How changes land

`main` is protected. Everything arrives as a pull request:

```sh
git checkout -b short-descriptive-branch
# ... change, then run the suite ...
swift test
git push -u origin short-descriptive-branch
```

Open the PR against `main` and it gets reviewed before merge. Small, focused
branches are easier to review than one large one — if a change touches the
reducer *and* the image pipeline, it is usually two pull requests.

Say in the PR whether you ran against real hardware or not. "Tests pass, no
scanner" is a completely fine and useful thing to write; claiming a hardware
behaviour nobody observed is not.

## What you can expect back

**A human reply within three days**, even when the reply is "not yet" or "not
this". If you have waited longer than that, the notification was missed rather
than ignored — say so on the thread and it will be picked up.

This is a small project maintained by one person, so the honest version is:
review may be slower than you would like, but silence is never the answer and a
stale PR is a failure on this end, not yours.

## Open an issue first for anything load-bearing

Not bureaucracy — this codebase has unusually strong invariants, and the
expensive place to discover a scope mismatch is after you have written the code.

**Ask first** if the change touches:

- a `BatchSession` gate, or any safety rule
- `CardImageCropper` detection constants — these were measured against real
  scanner artefacts and a plausible-sounding rewrite is how a defect gets back in
- an invariant in [SPEC.md](SPEC.md), or the v1 scope
- the `ImageCaptureCore` boundary

**Just send it** for docs, operator copy, tests, accessibility, hardware
datapoints, or anything already described in an open issue.

One concrete example of why: `AcceptedPairSizeMismatch` stores the two measured
footprints rather than a `Bool`, and that looks like something to simplify. It
is not — a `Bool` would carry a person's consent onto a re-measured pair they
never saw. Several things here are shaped that way, and the reasoning usually
lives in a doc comment right above the code.

## Do you need an fi-8170?

Almost certainly not. Every issue is labelled `needs-fi-8170` or
`no-hardware-needed`, and the second group is much larger: the whole reducer,
the SwiftUI shell, image encoding and DPI metadata, the crash-safety primitives,
error copy, accessibility, docs and CI.

`swift test` runs 251 tests with no scanner attached, and
`bash Scripts/bundle-app.sh --synthetic` runs the real crop, margin verdicts,
deskew and atomic publication against a simulated page source — so you can
reproduce and fix most UI and pipeline behaviour without hardware.

## Using AI assistance

Allowed, and it does not need to be hidden — but note it in the PR so a reviewer
knows what kind of scrutiny to apply, and hold it to the same bar as anything
you wrote by hand. You are the author of what you submit.

Two rules that bind harder here than in most projects, because this codebase's
safety story rests on things a model cannot check:

- **An LLM cannot observe hardware.** Never let generated text become a claim
  about what a scanner did. If a pass was not physically run, say so.
- **Detector constants need evidence, not rationale.** A change to
  `CardImageCropper`'s thresholds must cite a corpus run. A confident-sounding
  explanation for a new number is exactly the failure mode those constants were
  measured to prevent.

## The most useful contributions right now

- **Exercise the suite.** Run `swift test` on Apple Silicon with Xcode 26 —
  251 tests in 29 suites, no scanner required. Image-pipeline work belongs in
  release mode: `swift test -c release --filter CardImageCropperTests`.
  Five suites are opt-in and skip unless a `SCANDECK_*` variable points them at
  a corpus of real scans, so a clean checkout is green with no setup.
- **Run the app.** `bash Scripts/bundle-app.sh --run` builds and launches the
  signed bundle against a real scanner; `--synthetic` swaps in a simulated
  page source while the production crop, verdict, and publication pipeline
  still runs for real.
- **Hardware datapoints.** If you have a duplex ADF scanner with a macOS ICA
  driver (Ricoh/Fujitsu fi series, or anything visible to Apple Image
  Capture), run `swift run scandeck-m0 --list` and `--inspect`. Reports on
  `vendorFeatures` and driver quirks are especially valuable — they seed the
  supported-scanner matrix. See `docs/research/macos-scanning-apis.md` for the
  fi-8170 baseline.
- **Detection datapoints.** The cropper's constants are calibrated against
  real scanner artefacts (rear-side streaks, faint toploader lip glints). If
  detection mis-measures one of your scans, a front/back pair of masters is
  the most useful artifact you can attach — the opt-in test suite
  (`SCANDECK_REAL_ASSET_DIR`, files paired by `_F`/`_B`) turns such pairs
  into permanent regressions. Never commit card scans to the repository.
- **Read [SPEC.md](SPEC.md) and poke holes in it.** Open an issue for
  anything that seems wrong, missing, or over-engineered.

Ground rules:

- The v1 scope in SPEC §2 is deliberately tiny. Feature ideas beyond it go to
  issues tagged for the post-v1 backlog (see SPEC §8), not into v1.
- The real media are **raw cards and cards in toploaders** — test with those.
  A card in a penny sleeve alone is not a supported case; semi-rigids stay
  unsupported until they pass physical safety testing.
- Swift + SwiftUI + ImageCaptureCore is the settled stack (SPEC §6).
  Alternative-stack proposals need evidence, not vibes.
- Keep `ImageCaptureCore` objects inside the scanner adapter; domain and
  storage logic stay deterministic and hardware-independent — that is what
  makes the test suite possible.
- Safety rules live in the `BatchSession` reducer, never in the presentation
  model; a new gate surfaces to the operator as a notice carrying its
  corrective action.
- Use expendable media and stay with the scanner during a feed. Never run
  `--scan` against someone else's scanner or media without explicit
  permission.
- Tests must never touch real user state: inject temporary directories and
  the in-memory bookmark storage, or you will corrupt an operator's counters
  and remembered destination.
- Be kind, be concrete.

License: MIT. By contributing you agree your contributions are MIT-licensed.
