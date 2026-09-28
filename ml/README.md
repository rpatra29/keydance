# Keydance text-aware session model

The app infers five observable states from recent text context plus timing:
`writing`, `midThought`, `sentenceComplete`, `finished`, and `otherActivity`.
It does not detect a person's actual thoughts. Raw text is only held in memory
by the running app unless a developer explicitly enables trace capture.

## 1. Capture developer traces

Normal Keydance use does not write text. For an explicit training run, launch
the app binary with a trace path:

```sh
mkdir -p .context/text-training
KEYDANCE_TEXT_TRACE_PATH="$PWD/.context/text-training/traces.jsonl" \
KEYDANCE_TEXT_TRACE_PARTICIPANT="developer-1" \
  ./dist/Keydance.app/Contents/MacOS/Keydance
```

Type naturally, including pauses and completed sentences. Finish a session in
the Session tab, then quit the app. Repeat with multiple participants or
recording IDs. The trace file is raw developer training material; do not ship
it or commit it. Secure Input and **Discard** clear the in-memory trace without
writing it.

## 2. Prepare weakly labeled samples

This step creates five-second samples using punctuation, pauses, text activity,
and other input events. These are weak labels, not ground truth:

```sh
uv sync --project ml --python 3.11
uv run --project ml python ml/prepare_text_dataset.py \
  .context/text-training/traces.jsonl \
  .context/text-training/text_samples.jsonl
```

The trainer requires participant/recording groups that allow every label in
both train and held-out partitions. This prevents one person's writing style
from leaking into validation.

## 2a. Use the KLiCKe corpus (real keystroke timing)

KLiCKe is a public research corpus of roughly 5,000 argumentative writing
sessions with keystroke and mouse timestamps. Download `WritingTask.zip` from
the corpus' shared folder into `.context/klicke/`; do not commit or ship the
archive. Then run:

```sh
python3 ml/prepare_klicke_dataset.py \
  .context/klicke/WritingTask.zip \
  .context/text-training/klicke_samples.jsonl
```

The importer preserves real timing, revisions, cursor edits, and nonproduction
activity. Pause labels are behaviorally reviewed against the rest of each
recording: unfinished text becomes `midThought` only when typing resumes within
15 seconds, and terminal punctuation becomes `sentenceComplete` when later
typing is observed. Unobserved pauses are omitted; `finished` remains only an
explicit end-of-recording `boundary_proxy`. KLiCKe still does not provide human
intent labels, so its validation score is agreement with these reviewed
observations, not ground-truth boundary accuracy.

Train it with a participant-held-out split:

```sh
uv run --project ml python ml/train_text_transformer.py \
  .context/text-training/klicke_samples.jsonl \
  --output-dir ml/artifacts
```

The default keeps at most 96 strategically spaced windows per recording so all
participants remain represented without creating a multi-gigabyte training
file. For a quick schema check, add `--limit-recordings 12`; use
`--max-samples-per-recording 0` only when you intentionally need every window.

## 3. Train and export Core ML

```sh
uv run --project ml python ml/train_text_transformer.py \
  .context/text-training/text_samples.jsonl \
  --output-dir ml/artifacts
./scripts/build-app.sh
```

The output is `ml/artifacts/SessionTextTransformer.mlpackage`. The app bundles
it automatically and uses the text-aware fallback if no model is installed.
Core ML export is refused unless held-out accuracy is at least 75% and every
class has at least 50% recall. Review the generated metadata and test the model
on new sessions before bundling it. On the current KLiCKe run, the held-out
accuracy is 90.6% (writing 91.8%, midThought 83.4%, sentenceComplete 91.9%,
finished 56.1%, otherActivity 98.2% recall).

For the shortest manual app test, use `./scripts/run.sh`, confirm the dashboard
says **Core ML text model loaded**, and use the raw five-class probability panel
after each five-second window. Test an unfinished clause, a complete sentence,
and five seconds of arrow/click/scroll activity; the exact test text and expected
labels are documented in the root README.

The KLiCKe pipeline is intentionally the only training-data path. Its
participant-held-out metrics measure agreement with weak observational labels;
KLiCKe does not directly label `midThought` or `finished`, so a small reviewed
evaluation set is still required before making product-quality claims.
