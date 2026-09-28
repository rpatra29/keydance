# Keydance

Keydance is a local-only macOS 14+ typing analytics app. It measures timing,
corrections, sentence speed, and accuracy without persisting typed text, app
identity, window titles, clipboard contents, or ordered key history.

## Run

The recommended path builds and opens a signed macOS app bundle:

```sh
./scripts/run.sh
```

On first launch, allow Keydance under **System Settings → Privacy & Security →
Input Monitoring**. Tracking only runs while Keydance is open.

For a direct development launch:

```sh
swift run Keydance
```

Launch-at-login is intended for the bundled app created by `build-app.sh`.

## Dashboard

The Session tab is the product surface: it shows the current session status,
typing speed, accuracy, session size, and recent bursts. The model runs locally
and reduces its result to three simple states: Typing, Complete, and Unclear.
Settings contains tracking, privacy, and data-purge controls.

## Model and metrics

The runtime combines in-memory text context with timing, pauses, corrections,
punctuation, shortcuts, navigation, pointer movement, clicks, and scrolling.
The bundled Core ML model provides a local signal; a small hybrid layer adds
sentence-shape evidence before producing the simple dashboard state.

Accuracy checks completed sentences against the bundled vocabulary with edit
distance, catches high-confidence context errors, and counts deleted characters
as correction errors. Unknown names and technical terms are left alone.

The training workflow and KLiCKe preparation scripts live in `ml/`; they are
separate from the product runtime.

## Verify

```sh
swift test
./scripts/build-app.sh
codesign --verify --deep --strict dist/Keydance.app
```

The tests cover metric math, adaptive pauses, sentence boundaries, the Core ML
input path, accuracy checks, privacy-safe persistence, and vocabulary audits.

## Vocabulary

The benchmark vocabulary is derived from the Apache-2.0
[`brekker23/English-word-frequencies`](https://github.com/brekker23/English-word-frequencies)
dataset. See `Sources/Keydance/Resources/VOCABULARY_ATTRIBUTION.md`.
