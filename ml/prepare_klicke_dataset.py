#!/usr/bin/env python3
"""Prepare KLiCKe keystroke logs for Keydance's temporal text model.

KLiCKe contains real event timing, revisions, cursor movement, and mouse
activity, but it does not contain per-pause ``midThought``/``finished``
annotations. This importer keeps that distinction explicit:

* writing and other-activity windows come directly from the event stream;
* pauses are reviewed against future typing behavior: a later resume is
  evidence that the earlier pause was real, while an unobserved pause is
  omitted instead of being promoted to ground truth;
* finished is emitted only once, after a recording, as a censored boundary
  proxy. It is not presented as ground truth.

Raw data is read in place and the prepared JSONL contains no raw text, only
the token/timing features consumed by the trainer. Keep both in ``.context/``.
"""

from __future__ import annotations

import argparse
import bisect
import csv
import io
import json
import zipfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

LABELS = ["writing", "midThought", "sentenceComplete", "finished", "otherActivity"]
WINDOW_SECONDS = 5.0
MAX_TOKENS = 128
TEXT_ACTIVITIES = {"Input", "Replace"}
DELETION_ACTIVITIES = {"Remove/Cut"}


@dataclass(frozen=True)
class Event:
    at: float
    end: float
    activity: str
    text_change: str
    down_event: str
    cursor_position: int

    @property
    def is_text(self) -> bool:
        return self.activity in TEXT_ACTIVITIES and bool(self.text_change)

    @property
    def is_deletion(self) -> bool:
        return self.activity in DELETION_ACTIVITIES


@dataclass
class TextState:
    characters: list[str]
    times: list[float]
    cursor: int = 0
    corrections: int = 0

    def insert(self, value: str, at: float, cursor_position: int | None) -> None:
        if not value:
            return
        if cursor_position is not None:
            # Inputlog records the cursor after the insertion using a
            # one-based position. Convert it to Python's insertion index.
            self.cursor = max(0, min(cursor_position - 1, len(self.characters)))
        self.characters[self.cursor:self.cursor] = list(value)
        self.times[self.cursor:self.cursor] = [at] * len(value)
        self.cursor += len(value)

    def remove(self, value: str, cursor_position: int | None, down_event: str) -> None:
        if cursor_position is not None:
            self.cursor = max(0, min(cursor_position, len(self.characters)))
        count = max(1, len(value))
        is_delete = "delete" in down_event.lower() and "back" not in down_event.lower()
        start = self.cursor if is_delete else max(0, self.cursor - count)
        # For remove/cut rows the corpus includes the removed text. Prefer
        # the matching span around the recorded cursor; this handles both
        # backspace and selection removal without inventing character order.
        if value:
            candidates = [self.cursor, self.cursor - len(value), self.cursor - 1]
            matching = next((candidate for candidate in candidates
                             if 0 <= candidate <= len(self.characters) - len(value)
                             and "".join(self.characters[candidate:candidate + len(value)]) == value), None)
            if matching is not None:
                start = matching
        end = min(len(self.characters), start + count)
        if start < end:
            del self.characters[start:end]
            del self.times[start:end]
            self.cursor = start
        self.corrections += 1

    @property
    def text(self) -> str:
        return "".join(self.characters)


def decode_text_change(value: str) -> str:
    value = value or ""
    if value == "" or value.strip() in {"NoChange", "None"}:
        return ""
    return (value.replace("\\r\\n", "\n").replace("\\n", "\n")
            .replace("\\t", "\t").replace("\\r", "\r"))


def number(value: str, fallback: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def parse_events(raw: str) -> list[Event]:
    rows = list(csv.DictReader(io.StringIO(raw)))
    if not rows:
        return []
    origin = min(number(row.get("DownTime")) for row in rows)
    events: list[Event] = []
    for row in rows:
        down = number(row.get("DownTime"))
        up = max(down, number(row.get("UpTime"), down))
        try:
            cursor = int(float(row.get("CursorPosition", "0")))
        except (TypeError, ValueError):
            cursor = 0
        events.append(Event(
            at=max(0.0, (down - origin) / 1000.0),
            end=max(0.0, (up - origin) / 1000.0),
            activity=(row.get("Activity") or "").strip(),
            text_change=decode_text_change(row.get("TextChange", "")),
            down_event=(row.get("DownEvent") or "").strip(),
            cursor_position=cursor,
        ))
    return sorted(events, key=lambda event: (event.at, event.end))


def words_from_state(state: TextState) -> tuple[list[str], list[float], list[float]]:
    words: list[list[tuple[str, float]]] = []
    current: list[tuple[str, float]] = []
    for character, at in zip(state.characters, state.times):
        if character.isspace():
            if current:
                words.append(current)
                current = []
        else:
            current.append((character, at))
    if current:
        words.append(current)
    texts: list[str] = []
    durations: list[float] = []
    gaps: list[float] = []
    previous_end: float | None = None
    for word in words[-MAX_TOKENS:]:
        start, end = word[0][1], word[-1][1]
        texts.append("".join(character for character, _ in word))
        durations.append(max(0.0, end - start))
        gaps.append(max(0.0, start - previous_end) if previous_end is not None else 0.0)
        previous_end = end
    return texts, durations, gaps


def sentence_character_count(text: str) -> int:
    stripped = text.rstrip()
    if not stripped:
        return 0
    boundary = max(stripped.rfind("."), stripped.rfind("?"), stripped.rfind("!"))
    return len(stripped[boundary + 1:].strip())


def classify_window(*, text: str, window_events: list[Event], last_text_at: float | None,
                    next_text_at: float | None, end: float) -> tuple[str, str, float] | None:
    text_events = sum(event.is_text for event in window_events)
    delete_events = sum(event.is_deletion for event in window_events)
    nonproduction = sum(event.activity == "Nonproduction" for event in window_events)
    event_count = len(window_events)
    pause = end - last_text_at if last_text_at is not None else end
    stripped = text.rstrip()
    terminal = bool(stripped) and stripped[-1] in ".?!"
    if event_count and nonproduction / event_count >= 0.55 and text_events == 0:
        return "otherActivity", "observed", 1.0
    # Review pause labels with future behavior. KLiCKe has no human pause
    # annotations, but a later resume gives us a much stronger observational
    # label than "there was no key in this window": it distinguishes a pause
    # that was followed by more unfinished writing from a completed sentence.
    # Long pauses with no observed resume are intentionally omitted here; the
    # sole tail row below is the censored finished-boundary proxy.
    if stripped and pause >= 1.25:
        if terminal and next_text_at is not None:
            return "sentenceComplete", "observed_sentence_pause", 1.0
        if (not terminal and next_text_at is not None
                and next_text_at - end <= 15.0):
            return "midThought", "observed_resume", 1.0
        return None
    if text_events >= 2 or text_events / WINDOW_SECONDS >= 0.8:
        return "writing", "observed", 1.0
    if text_events or delete_events:
        return "writing", "observed_revision", 0.85
    return ("otherActivity", "observed_idle", 0.65) if not stripped else None


def make_row(recording_id: str, captured_at: float, label: str, quality: str, weight: float,
             tokens: list[str], durations: list[float], gaps: list[float], *, event_count: int,
             text_events: int, silence: float, sentence_count: int, correction_count: int,
             non_text: int) -> dict:
    ratio = text_events / event_count if event_count else 0.0
    return {
        "schemaVersion": 1,
        "source": "klicke",
        "recordingID": recording_id,
        "participantID": recording_id,
        "capturedAt": round(captured_at, 3),
        "label": label,
        "labelQuality": quality,
        "sampleWeight": weight,
        "tokens": tokens,
        "wordDurations": [round(value, 4) for value in durations],
        "wordGaps": [round(value, 4) for value in gaps],
        "numericFeatures": [
            event_count / WINDOW_SECONDS, text_events / WINDOW_SECONDS, max(0.0, silence),
            float(sentence_count), float(len(tokens)), float(correction_count), ratio,
            non_text / event_count if event_count else 0.0,
        ],
    }


def sample_for_recording(recording_id: str, events: list[Event], stride: float) -> list[dict]:
    if not events:
        return []
    state = TextState([], [])
    last_text_at: float | None = None
    text_event_times = [event.at for event in events if event.is_text]
    event_index = 0
    last_event = max(event.end for event in events)
    last_text_event = max((event.end for event in events if event.is_text), default=last_event)
    rows: list[dict] = []
    end = WINDOW_SECONDS
    while end <= last_event + 0.01:
        window_start = end - WINDOW_SECONDS
        window_events: list[Event] = []
        while event_index < len(events) and events[event_index].end <= end:
            event = events[event_index]
            if event.end > window_start:
                window_events.append(event)
            if event.is_text:
                state.insert(event.text_change, event.at, event.cursor_position)
                last_text_at = event.end
            elif event.is_deletion:
                state.remove(event.text_change, event.cursor_position, event.down_event)
            event_index += 1
        classified = classify_window(
            text=state.text, window_events=window_events, last_text_at=last_text_at,
            next_text_at=(text_event_times[bisect.bisect_right(text_event_times, end)]
                          if bisect.bisect_right(text_event_times, end) < len(text_event_times)
                          else None),
            end=end,
        )
        tokens, durations, gaps = words_from_state(state)
        if classified is not None and (tokens or classified[0] == "otherActivity"):
            label, quality, weight = classified
            text_events = sum(event.is_text for event in window_events)
            rows.append(make_row(
                recording_id, end, label, quality, weight, tokens, durations, gaps,
                event_count=len(window_events), text_events=text_events,
                silence=end - last_text_at if last_text_at is not None else end,
                sentence_count=sentence_character_count(state.text),
                correction_count=state.corrections,
                non_text=len(window_events) - text_events,
            ))
        end += stride

    # The only available finished signal is a censored tail. Emit it once and
    # mark it so it cannot be mistaken for human completion annotation.
    tail_end = max(last_event + WINDOW_SECONDS, last_text_event + WINDOW_SECONDS)
    tokens, durations, gaps = words_from_state(state)
    if tokens:
        rows.append(make_row(
            recording_id, tail_end, "finished", "boundary_proxy", 0.90,
            tokens, durations, gaps, event_count=0, text_events=0,
            silence=tail_end - (last_text_at or last_event),
            sentence_count=sentence_character_count(state.text),
            correction_count=state.corrections, non_text=0,
        ))
    return rows


def cap_recording_rows(rows: list[dict], limit: int) -> list[dict]:
    """Keep every recording represented without flooding training with idle windows."""
    if not limit or len(rows) <= limit:
        return rows
    finished = [row for row in rows if row["label"] == "finished"]
    remaining = max(0, limit - len(finished))
    groups: dict[str, list[dict]] = {}
    for row in rows:
        if row["label"] != "finished":
            groups.setdefault(row["label"], []).append(row)
    chosen = list(finished)
    labels = sorted(groups)
    quota = remaining // max(1, len(labels))
    for label in labels:
        values = groups[label]
        take = min(len(values), quota)
        if take:
            step = len(values) / take
            chosen.extend(values[min(len(values) - 1, int(index * step))] for index in range(take))
    if len(chosen) < limit:
        candidates = [row for row in rows if row not in chosen]
        step = len(candidates) / max(1, limit - len(chosen))
        chosen.extend(candidates[min(len(candidates) - 1, int(index * step))]
                     for index in range(min(limit - len(chosen), len(candidates))))
    return sorted(chosen[:limit], key=lambda row: row["capturedAt"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path, help="downloaded KLiCKe WritingTask.zip")
    parser.add_argument("output", type=Path, help="prepared developer-only JSONL")
    parser.add_argument("--limit-recordings", type=int, default=0)
    parser.add_argument("--stride", type=float, default=WINDOW_SECONDS)
    parser.add_argument("--max-samples-per-recording", type=int, default=96)
    args = parser.parse_args()
    if args.stride <= 0:
        raise SystemExit("--stride must be positive")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    partial = args.output.with_suffix(args.output.suffix + ".partial")
    counts: Counter[str] = Counter()
    recording_count = 0
    with zipfile.ZipFile(args.archive) as archive:
        prefix = "WritingTask/keystrokelogs/csv/"
        names = sorted(name for name in archive.namelist() if name.startswith(prefix) and name.endswith(".csv"))
        if args.limit_recordings:
            names = names[:args.limit_recordings]
        with partial.open("w", encoding="utf-8") as handle:
            for index, name in enumerate(names, 1):
                recording_id = Path(name).stem
                raw = archive.read(name).decode("cp1252", errors="replace")
                recording_rows = cap_recording_rows(
                    sample_for_recording(recording_id, parse_events(raw), args.stride),
                    args.max_samples_per_recording,
                )
                for row in recording_rows:
                    handle.write(json.dumps(row, separators=(",", ":")) + "\n")
                    counts[row["label"]] += 1
                recording_count += bool(recording_rows)
                if index % 100 == 0 or index == len(names):
                    print(f"processed={index}/{len(names)} samples={sum(counts.values())}", flush=True)
    if not counts:
        partial.unlink(missing_ok=True)
        raise SystemExit("no usable KLiCKe event logs")
    partial.replace(args.output)
    print(json.dumps({"samples": sum(counts.values()), "recordings": recording_count,
                      "labels": {label: counts[label] for label in LABELS}}, indent=2))


if __name__ == "__main__":
    main()
