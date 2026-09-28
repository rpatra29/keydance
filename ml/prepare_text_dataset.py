#!/usr/bin/env python3
"""Turn timestamped writing traces into weakly labeled text-model samples.

Input JSONL is a developer-only trace format. It contains event timestamps and
characters. Output JSONL is also developer-only and may contain text. Neither
file is used as a user analytics store.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

LABELS = ["writing", "midThought", "sentenceComplete", "finished", "otherActivity"]
FEATURE_COUNT = 8
MAX_TOKENS = 128


@dataclass(frozen=True)
class Event:
    at: float
    kind: str
    value: str = ""


def parse_events(item: dict) -> list[Event]:
    events = [
        Event(float(raw["at"]), str(raw["kind"]), str(raw.get("value", "")))
        for raw in item.get("events", [])
    ]
    return sorted(events, key=lambda event: event.at)


def words_from_history(history: list[tuple[str, float]]) -> tuple[list[str], list[float], list[float]]:
    words: list[list[tuple[str, float]]] = []
    current: list[tuple[str, float]] = []
    for character, at in history:
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


def classify_window(
    *,
    text: str,
    window_events: list[Event],
    last_text_at: float | None,
    end: float,
    finished_pause: float,
) -> str:
    duration = 5.0
    event_count = len(window_events)
    text_events = sum(event.kind in {"character", "boundary"} for event in window_events)
    non_text_events = event_count - text_events
    event_rate = event_count / duration
    printable_ratio = text_events / event_count if event_count else 0.0
    non_typing_ratio = non_text_events / event_count if event_count else 0.0
    silence = end - last_text_at if last_text_at is not None else duration
    stripped = text.rstrip()
    ends_with_punctuation = bool(stripped) and stripped[-1] in ".?!"

    if non_typing_ratio >= 0.55 and event_count > 0:
        return "otherActivity"
    if silence >= finished_pause and event_count == 0:
        return "finished"
    if text_events / duration >= 0.35 and printable_ratio >= 0.35:
        return "writing"
    if ends_with_punctuation and silence >= 1.2:
        return "sentenceComplete"
    if stripped and not ends_with_punctuation and silence >= 1.2:
        return "midThought"
    if event_rate >= 0.35 and text_events > 0:
        return "writing"
    return "midThought" if stripped else "writing"


def samples_for_trace(item: dict, finished_pause: float) -> list[dict]:
    events = parse_events(item)
    if not events:
        return []
    recording_id = str(item.get("recordingID", item.get("recording_id", "unknown")))
    participant_id = str(item.get("participantID", item.get("participant_id", recording_id)))
    last_event = events[-1].at
    end = 5.0
    text_history: list[tuple[str, float]] = []
    correction_count = 0
    event_index = 0
    last_text_at: float | None = None
    output: list[dict] = []

    # Include one full window after the finished-pause threshold so a trace
    # can actually produce a `finished` example.
    while end <= last_event + max(5.0, finished_pause) + 5.0:
        window_start = end - 5.0
        window_events: list[Event] = []
        while event_index < len(events) and events[event_index].at <= end:
            event = events[event_index]
            if event.at > window_start:
                window_events.append(event)
            if event.kind in {"character", "boundary"}:
                text_history.append((event.value[:1], event.at))
                last_text_at = event.at
            elif event.kind == "deletion" and text_history:
                text_history.pop()
                correction_count += 1
            event_index += 1

        text = "".join(character for character, _ in text_history)
        tokens, durations, gaps = words_from_history(text_history)
        event_count = len(window_events)
        text_events = sum(event.kind in {"character", "boundary"} for event in window_events)
        non_text_events = event_count - text_events
        silence = end - last_text_at if last_text_at is not None else 5.0
        stripped = text.rstrip()
        sentence_start = max(stripped.rfind("."), stripped.rfind("?"), stripped.rfind("!"))
        sentence_characters = len(stripped[sentence_start + 1 :].strip()) if stripped else 0
        label = classify_window(
            text=text,
            window_events=window_events,
            last_text_at=last_text_at,
            end=end,
            finished_pause=finished_pause,
        )
        output.append(
            {
                "schemaVersion": 1,
                "recordingID": recording_id,
                "participantID": participant_id,
                "capturedAt": end,
                "label": label,
                "tokens": tokens,
                "wordDurations": durations,
                "wordGaps": gaps,
                "numericFeatures": [
                    event_count / 5.0,
                    text_events / 5.0,
                    silence,
                    float(sentence_characters),
                    float(len(tokens)),
                    float(correction_count),
                    text_events / event_count if event_count else 0.0,
                    non_text_events / event_count if event_count else 0.0,
                ],
            }
        )
        end += 5.0
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="developer trace JSONL")
    parser.add_argument("output", type=Path, help="weakly labeled text-model JSONL")
    parser.add_argument("--finished-pause", type=float, default=30.0)
    args = parser.parse_args()

    rows: list[dict] = []
    for line_number, line in enumerate(args.input.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        item = json.loads(line)
        if item.get("schemaVersion") != 1:
            raise SystemExit(f"line {line_number}: expected schemaVersion=1")
        rows.extend(samples_for_trace(item, args.finished_pause))
    if not rows:
        raise SystemExit("no usable trace events")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")
    counts = {label: sum(row["label"] == label for row in rows) for label in LABELS}
    print(json.dumps({"samples": len(rows), "labels": counts}, indent=2))


if __name__ == "__main__":
    main()
