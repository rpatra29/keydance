# Keydance

Keydance is a local-only macOS 14+ typing analytics app. It measures timing,
corrections, sentence speed, and editing activity without persisting sentences,
app identity, window titles, clipboard contents, or ordered key history. The
optional Insights surface stores only bounded daily counters for a small set of
frequent/flagged words and typing patterns; raw text remains in memory only.

## Run

The recommended path builds and opens a signed macOS app bundle:

```sh
./scripts/run.sh
```

On first launch, allow Keydance under **System Settings → Privacy & Security →
Input Monitoring**. Keydance can keep tracking from the menu bar while the
dashboard window is closed.

The onboarding can be replayed at any time from the Keydance menu-bar icon.
Dashboard settings are available from the radial navigation control in the
window; the menu-bar popover stays focused on tracking and quick actions.

For a direct development launch:

```sh
swift run Keydance
```

Launch-at-login is intended for the bundled app created by `build-app.sh`.

## Dashboard

The dashboard shows an accuracy-adjusted WPM estimate, raw WPM in the details,
historical daily charts, and comparison insights. Typing insights adds a
collapsible navigation page with a keyboard heatmap, misspelling whitelist,
frequent/slow word patterns, and double-letter signals. Settings contains
tracking, privacy, history-retention, and data-purge controls.

## Model and metrics

The runtime combines in-memory text context with timing, pauses, corrections,
punctuation, shortcuts, navigation, pointer movement, clicks, and scrolling.
When the exported Core ML model is present, it provides a local signal; a small
hybrid layer adds sentence-shape evidence before producing the dashboard state.
The recovered `ContextualAccuracyScorer` transformer also runs locally from a
native weight resource. It compares completed words with nearby SymSpell
alternatives and counts only a strong contextual mismatch as a model signal.

Passive typing still has no reference text, so these are estimates rather than
proofread truth. Raw text remains in memory only and is never persisted.

## Verify

```sh
./scripts/build-app.sh
codesign --verify --deep --strict dist/Keydance.app
```

The build script creates and signs the runnable app bundle in `dist/`.

## Vocabulary

The bundled SymSpell frequency dictionary contains roughly 80,000 common
English terms and provides the rankings used to select correction candidates.
See `Sources/Keydance/Resources/VOCABULARY_ATTRIBUTION.md`.
