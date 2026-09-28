# Text-aware session ML plan

## Goal

Estimate writing state from the text being produced and its timing, without
claiming to read a person's mind.

The product states are:

- `writing`: text is actively changing.
- `midThought`: typing paused while the current sentence appears unfinished.
- `sentenceComplete`: punctuation or a clear boundary suggests a sentence ended.
- `finished`: a longer pause follows completed text.
- `otherActivity`: keyboard or pointer activity is not text composition.

`thinking` is a user-facing description for `midThought`; it is not a measured
mental state.

## Runtime design

```text
keyboard event
    |
    v
ephemeral writing buffer
    |  characters, words, punctuation, timestamps
    |  never persisted or uploaded
    v
five-second immutable snapshot
    |  recent text context + word timing + pause features
    v
local text classifier
    |  Core ML Transformer; deterministic fallback before model exists
    v
session state machine
    |  state durations, speed, pause summaries
    v
persist numeric session summary only
```

The event buffer clears after each analysis window. A bounded context buffer
keeps the current sentence and recent tokens so a sentence crossing a window
boundary is not split. Session totals keep counts and durations only.

## Model input

Each five-second snapshot contains:

- bounded recent text context, tokenized for the model
- word durations
- gaps between words
- time since last character
- sentence punctuation and boundary flags
- correction count
- current sentence length
- aggregate keyboard, pointer, and scroll features

The model predicts state probabilities. It does not receive application name,
window title, key code, or ordered mouse data.

## Model choice

Use a small local Transformer encoder first. It fits text classification and can
combine token context with timing features. Keep the input bounded so inference
is cheap. Consider a small LSTM only if Core ML conversion or latency makes the
Transformer impractical; architecture is secondary to useful labels.

Do not train from scratch on a few app recordings. Bootstrap obvious labels
from punctuation and observed pauses, then evaluate on new writing traces.
`finished` and `midThought` are behavioral interpretations, not exact keyboard
events; the KLiCKe importer now performs an automated review against future
typing resumption and marks end-of-recording labels as boundary proxies.

## Dataset strategy

Use the KLiCKe corpus as the only training-data source. Its 4,992 writing
recordings provide real keystroke timestamps, revisions, cursor positions, and
nonproduction activity. The importer keeps all participants represented while
bounding adjacent windows per recording, then splits by participant so a
writer's behavior cannot leak into validation.

KLiCKe does not directly label whether a pause means thinking or completion.
The importer therefore marks event-observed labels separately from reviewed
resume/punctuation labels and uses only an explicit end-of-recording boundary
proxy for `finished`. Report those limitations with every evaluation.

## Privacy contract

- Text may exist in memory during an active session.
- Text never goes to disk, logs, clipboard, analytics records, or network APIs.
- Secure Input clears the in-memory buffer immediately.
- Persisted session records contain numeric summaries and model probabilities.
- Training capture is external to the product runtime and separate from user
  analytics.

## Delivery phases

### Phase 1: data path

- Add bounded in-memory text/timing buffer.
- Snapshot it every five seconds with existing session windows.
- Clear it on secure input, discard, rollover, and finalize.
- Add tests proving context exists only in memory and does not persist.

### Phase 2: classifier seam

- Define versioned text-aware model input and output labels.
- Add a deterministic sentence/pause fallback.
- Keep Core ML loading behind the same runtime interface.

### Phase 3: model training

- [x] Keep training data preparation external to the product runtime.
- [x] Train a small Core ML-friendly Transformer with participant-level
  train/validation splits.
- [x] Export `SessionTextTransformer.mlpackage`.
- [x] Require held-out accuracy and per-class recall thresholds.

The export pipeline is complete. A KLiCKe-trained model is bundled locally from
4,992 participant recordings with real keystroke timing, revisions, cursor
positions, and nonproduction activity. The current participant-held-out result
is 90.6% accuracy with recalls of 91.8% writing, 83.4% midThought, 91.9%
sentenceComplete, 56.1% finished, and 98.2% otherActivity. KLiCKe still does
not provide human intent labels, so this is agreement with reviewed
observations, not ground truth. KLiCKe is the only training-data source for the
bundled model.

### Phase 4: product integration

- [x] Bundle the KLiCKe-trained model when
  `ml/artifacts/SessionTextTransformer.mlpackage` exists; the app falls back to
  the deterministic text-aware classifier only when the artifact is absent.
- [x] Show only session state and useful metrics in the app.
- [x] Keep training, trace inspection, and confusion matrices out of normal UI.

## Non-goals

- Detecting actual thoughts or attention.
- Uploading text to a server.
- Persisting raw typed text.
- Building a general-purpose language model.
- Keeping the old TCN training console in the product.

## Current implementation stop condition

Phase 1 is complete when a five-second inference snapshot can contain recent
text and word timing, while persisted `SessionRecord` data remains text-free.
Only then should model architecture and training data be implemented.
