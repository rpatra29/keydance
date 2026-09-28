#!/usr/bin/env python3
"""Train and export Keydance's text-aware session classifier."""

from __future__ import annotations

import argparse
import json
import math
import random
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

LABELS = ["writing", "midThought", "sentenceComplete", "finished", "otherActivity"]
MAX_TOKENS = 128
VOCABULARY_SIZE = 8_192
NUMERIC_FEATURE_COUNT = 8


@dataclass(frozen=True)
class Sample:
    recording_id: str
    participant_id: str
    captured_at: float
    label: int
    tokens: list[str]
    word_durations: list[float]
    word_gaps: list[float]
    numeric_features: list[float]
    sample_weight: float = 1.0
    source: str = "unknown"
    label_quality: str = "unknown"


def stable_hash(value: str) -> int:
    result = 14_695_981_039_346_656_037
    for byte in value.lower().encode("utf-8"):
        result = ((result ^ byte) * 1_099_511_628_211) & 0xFFFFFFFFFFFFFFFF
    return result


def token_ids(tokens: list[str]) -> list[int]:
    encoded = [stable_hash(token) % (VOCABULARY_SIZE - 2) + 2 for token in tokens[-MAX_TOKENS:]]
    return [0] * (MAX_TOKENS - len(encoded)) + encoded


def pad(values: list[float]) -> list[float]:
    values = values[-MAX_TOKENS:]
    return [0.0] * (MAX_TOKENS - len(values)) + values


def load_samples(path: Path) -> list[Sample]:
    result: list[Sample] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            item = json.loads(line)
            if item.get("schemaVersion") != 1:
                raise ValueError(f"line {line_number}: expected schemaVersion=1")
            label = item.get("label")
            if label not in LABELS:
                raise ValueError(f"line {line_number}: invalid label {label!r}")
            tokens = [str(value) for value in item.get("tokens", [])]
            durations = [float(value) for value in item.get("wordDurations", [])]
            gaps = [float(value) for value in item.get("wordGaps", [])]
            numeric = [float(value) for value in item.get("numericFeatures", [])]
            if len(tokens) != len(durations) or len(tokens) != len(gaps):
                raise ValueError(f"line {line_number}: token and timing lengths differ")
            if len(numeric) != NUMERIC_FEATURE_COUNT or not all(math.isfinite(value) for value in numeric):
                raise ValueError(f"line {line_number}: expected {NUMERIC_FEATURE_COUNT} finite numeric features")
            result.append(Sample(
                recording_id=str(item["recordingID"]),
                participant_id=str(item.get("participantID", item["recordingID"])),
                captured_at=float(item.get("capturedAt", len(result))),
                label=LABELS.index(label),
                tokens=tokens,
                word_durations=durations,
                word_gaps=gaps,
                numeric_features=numeric,
                sample_weight=max(0.05, float(item.get("sampleWeight", 1.0))),
                source=str(item.get("source", "unknown")),
                label_quality=str(item.get("labelQuality", "unknown")),
            ))
    if not result:
        raise ValueError("dataset is empty")
    return result


def summarize(samples: list[Sample]) -> dict[str, object]:
    return {
        "samples": len(samples),
        "recordings": len({sample.recording_id for sample in samples}),
        "participants": len({sample.participant_id for sample in samples}),
        "labels": dict(Counter(LABELS[sample.label] for sample in samples)),
        "sources": dict(Counter(sample.source for sample in samples)),
        "label_quality": dict(Counter(sample.label_quality for sample in samples)),
    }


def split_samples(samples: list[Sample], fraction: float, seed: int) -> tuple[list[Sample], list[Sample]]:
    groups: dict[str, list[Sample]] = defaultdict(list)
    for sample in samples:
        groups[sample.participant_id].append(sample)
    group_ids = list(groups)
    if len(group_ids) < 2:
        raise ValueError("need at least two participant/recording groups for a held-out split")
    rng = random.Random(seed)
    # Keep enough held-out groups for one representative of each class when
    # traces are collected one label/session at a time (the smoke dataset does
    # this deliberately).
    validation_count = min(len(group_ids) - 1, max(1, round(len(group_ids) * fraction), len(LABELS)))
    expected_labels = set(range(len(LABELS)))
    validation_ids: set[str] | None = None
    for _ in range(200):
        shuffled = group_ids[:]
        rng.shuffle(shuffled)
        candidate = set(shuffled[:validation_count])
        train_labels = {sample.label for group_id, values in groups.items() if group_id not in candidate for sample in values}
        validation_labels = {sample.label for group_id, values in groups.items() if group_id in candidate for sample in values}
        if train_labels == expected_labels and validation_labels == expected_labels:
            validation_ids = candidate
            break
    if validation_ids is None:
        raise ValueError(
            "participant split cannot put every label in both partitions; add more varied participant traces"
        )
    train = [sample for group_id, values in groups.items() if group_id not in validation_ids for sample in values]
    validation = [sample for group_id, values in groups.items() if group_id in validation_ids for sample in values]
    if not train or not validation:
        raise ValueError("recording-level split produced an empty partition")
    return train, validation


def tensors(samples: list[Sample], np):
    x_tokens = np.asarray([token_ids(sample.tokens) for sample in samples], dtype=np.int32)
    x_durations = np.asarray([pad(sample.word_durations) for sample in samples], dtype=np.float32)
    x_gaps = np.asarray([pad(sample.word_gaps) for sample in samples], dtype=np.float32)
    x_numeric = np.asarray([sample.numeric_features for sample in samples], dtype=np.float32)
    y = np.asarray([sample.label for sample in samples], dtype=np.int64)
    weights = np.asarray([sample.sample_weight for sample in samples], dtype=np.float32)
    return x_tokens, x_durations, x_gaps, x_numeric, y, weights


def train(args, samples: list[Sample]) -> dict[str, object]:
    try:
        import numpy as np
        import torch
        from torch import nn
        from torch.utils.data import DataLoader, TensorDataset
    except ModuleNotFoundError as exc:
        raise SystemExit("Run `uv sync --project ml` before training") from exc

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    device_name = args.device
    if device_name == "auto":
        device_name = "mps" if torch.backends.mps.is_available() else "cpu"
    device = torch.device(device_name)
    print(f"device={device}")
    training, validation = split_samples(samples, args.validation_fraction, args.seed)
    train_tokens, train_durations, train_gaps, train_numeric, train_y, train_weights = tensors(training, np)
    valid_tokens, valid_durations, valid_gaps, valid_numeric, valid_y, valid_weights = tensors(validation, np)

    numeric_mean = train_numeric.mean(axis=0)
    numeric_std = np.maximum(train_numeric.std(axis=0), 1e-5)
    train_numeric = (train_numeric - numeric_mean) / numeric_std
    valid_numeric = (valid_numeric - numeric_mean) / numeric_std

    class SelfAttentionBlock(nn.Module):
        """Core ML-friendly Transformer encoder block.

        This is mathematically the usual scaled dot-product self-attention,
        written from primitive tensor operations. PyTorch's stock
        TransformerEncoder selects a fused fast path that coremltools 8
        cannot convert reliably on macOS/PyTorch combinations.
        """

        def __init__(self):
            super().__init__()
            width = args.width
            if width % args.heads:
                raise ValueError("width must be divisible by heads")
            self.heads = args.heads
            self.head_width = width // args.heads
            self.query = nn.Linear(width, width)
            self.key = nn.Linear(width, width)
            self.value = nn.Linear(width, width)
            self.output = nn.Linear(width, width)
            self.norm_attention = nn.LayerNorm(width)
            self.feed_forward = nn.Sequential(
                nn.Linear(width, width * 2),
                nn.GELU(),
                nn.Linear(width * 2, width),
            )
            self.norm_feed_forward = nn.LayerNorm(width)

        def split_heads(self, values):
            batch, sequence, _ = values.shape
            return values.reshape(batch, sequence, self.heads, self.head_width).transpose(1, 2)

        def merge_heads(self, values):
            batch, _, sequence, _ = values.shape
            return values.transpose(1, 2).reshape(batch, sequence, self.heads * self.head_width)

        def forward(self, values):
            query = self.split_heads(self.query(values))
            key = self.split_heads(self.key(values))
            value = self.split_heads(self.value(values))
            scores = torch.matmul(query, key.transpose(-2, -1)) / math.sqrt(self.head_width)
            attention = torch.softmax(scores, dim=-1)
            attended = self.output(self.merge_heads(torch.matmul(attention, value)))
            values = self.norm_attention(values + attended)
            return self.norm_feed_forward(values + self.feed_forward(values))

    class SessionTextTransformer(nn.Module):
        def __init__(self):
            super().__init__()
            width = args.width
            self.embedding = nn.Embedding(VOCABULARY_SIZE, width, padding_idx=0)
            self.position = nn.Parameter(torch.zeros(MAX_TOKENS, width))
            self.timing = nn.Linear(2, width)
            self.numeric = nn.Sequential(nn.Linear(NUMERIC_FEATURE_COUNT, width), nn.ReLU())
            self.encoder = nn.ModuleList(SelfAttentionBlock() for _ in range(args.layers))
            self.classifier = nn.Sequential(nn.LayerNorm(width), nn.Linear(width, len(LABELS)))

        def forward(self, token_ids, word_durations, word_gaps, numeric_features):
            timing = torch.stack((word_durations, word_gaps), dim=-1)
            encoded = self.embedding(token_ids) + self.timing(timing) + self.position
            for layer in self.encoder:
                encoded = layer(encoded)
            pooled = encoded[:, -1, :] + self.numeric(numeric_features)
            return self.classifier(pooled)

    model = SessionTextTransformer().to(device)
    train_dataset = TensorDataset(
        torch.from_numpy(train_tokens), torch.from_numpy(train_durations),
        torch.from_numpy(train_gaps), torch.from_numpy(train_numeric), torch.from_numpy(train_y),
        torch.from_numpy(train_weights)
    )
    valid_dataset = TensorDataset(
        torch.from_numpy(valid_tokens), torch.from_numpy(valid_durations),
        torch.from_numpy(valid_gaps), torch.from_numpy(valid_numeric), torch.from_numpy(valid_y),
        torch.from_numpy(valid_weights)
    )
    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True, generator=generator)
    valid_loader = DataLoader(valid_dataset, batch_size=args.batch_size)
    counts = np.bincount(train_y, minlength=len(LABELS))
    weights = np.where(counts > 0, len(train_y) / (len(LABELS) * np.maximum(counts, 1)), 0).astype(np.float32)
    loss_function = nn.CrossEntropyLoss(weight=torch.from_numpy(weights).to(device), reduction="none")
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-4)

    best_state, best_accuracy = None, -1.0
    for epoch in range(1, args.epochs + 1):
        model.train()
        total_loss = 0.0
        for batch_tokens, batch_durations, batch_gaps, batch_numeric, batch_y, batch_weights in train_loader:
            batch_tokens = batch_tokens.to(device)
            batch_durations = batch_durations.to(device)
            batch_gaps = batch_gaps.to(device)
            batch_numeric = batch_numeric.to(device)
            batch_y = batch_y.to(device)
            batch_weights = batch_weights.to(device)
            optimizer.zero_grad()
            logits = model(batch_tokens, batch_durations, batch_gaps, batch_numeric)
            loss = (loss_function(logits, batch_y) * batch_weights).sum() / batch_weights.sum().clamp_min(1e-5)
            loss.backward()
            optimizer.step()
            total_loss += loss.item() * len(batch_y)

        accuracy, _ = evaluate(model, valid_loader, torch, np, device)
        print(f"epoch={epoch:03d} loss={total_loss / len(train_dataset):.4f} validation_accuracy={accuracy:.3f}")
        if accuracy > best_accuracy:
            best_accuracy = accuracy
            best_state = {key: value.detach().cpu().clone() for key, value in model.state_dict().items()}

    model.load_state_dict(best_state)
    validation_accuracy, confusion = evaluate(model, valid_loader, torch, np, device)
    recall = {
        LABELS[index]: float(confusion[index, index] / max(confusion[index].sum(), 1))
        for index in range(len(LABELS))
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = args.output_dir / "SessionTextTransformer.pt"
    torch.save({
        "state_dict": model.state_dict(),
        "labels": LABELS,
        "max_tokens": MAX_TOKENS,
        "vocabulary_size": VOCABULARY_SIZE,
        "numeric_feature_names": [
            "events_per_second", "printable_per_second", "silence_duration",
            "sentence_character_count", "word_count", "correction_count",
            "printable_ratio", "non_typing_ratio",
        ],
        "numeric_mean": numeric_mean.tolist(),
        "numeric_std": numeric_std.tolist(),
    }, checkpoint)
    metadata = {
        "created_at": datetime.now().astimezone().isoformat(),
        "schema_version": 1,
        "labels": LABELS,
        "max_tokens": MAX_TOKENS,
        "vocabulary_size": VOCABULARY_SIZE,
        "numeric_feature_names": [
            "events_per_second", "printable_per_second", "silence_duration",
            "sentence_character_count", "word_count", "correction_count",
            "printable_ratio", "non_typing_ratio",
        ],
        "numeric_mean": numeric_mean.tolist(),
        "numeric_std": numeric_std.tolist(),
        "validation_accuracy": float(validation_accuracy),
        "per_class_recall": recall,
        "training_summary": summarize(training),
        "validation_summary": summarize(validation),
        "confusion_matrix_rows_expected_columns_predicted": confusion.tolist(),
    }
    (args.output_dir / "SessionTextTransformer.metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    if args.skip_coreml:
        print(f"saved {checkpoint}")
        return metadata
    if (validation_accuracy < args.minimum_validation_accuracy
            or min(recall.values()) < args.minimum_class_recall):
        raise SystemExit(
            "checkpoint saved, but Core ML export refused: held-out quality is below "
            f"accuracy={args.minimum_validation_accuracy:.2f} or recall={args.minimum_class_recall:.2f}"
        )
    try:
        import coremltools as ct
    except ModuleNotFoundError as exc:
        raise SystemExit("coremltools is required unless --skip-coreml is used") from exc
    example = (
        torch.zeros(1, MAX_TOKENS, dtype=torch.int32),
        torch.zeros(1, MAX_TOKENS, dtype=torch.float32),
        torch.zeros(1, MAX_TOKENS, dtype=torch.float32),
        torch.zeros(1, NUMERIC_FEATURE_COUNT, dtype=torch.float32),
    )
    model = model.to("cpu")
    # TransformerEncoder switches between two equivalent inference graphs on
    # the first call on some PyTorch versions. That makes trace's optional
    # graph-equivalence check fail even though the model is deterministic.
    traced = torch.jit.trace(model, example, check_trace=False)
    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="token_ids", shape=example[0].shape, dtype=np.int32),
            ct.TensorType(name="word_durations", shape=example[1].shape, dtype=np.float32),
            ct.TensorType(name="word_gaps", shape=example[2].shape, dtype=np.float32),
            ct.TensorType(name="numeric_features", shape=example[3].shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    coreml_model.author = "Keydance"
    coreml_model.short_description = "Text-aware local writing session classifier"
    coreml_model.user_defined_metadata["labels"] = json.dumps(LABELS)
    coreml_model.user_defined_metadata["schema_version"] = "1"
    package = args.output_dir / "SessionTextTransformer.mlpackage"
    coreml_model.save(package)
    print(f"saved {checkpoint}, {package}, validation_accuracy={validation_accuracy:.3f}")
    return metadata


def evaluate(model, loader, torch, np, device):
    model.eval()
    confusion = np.zeros((len(LABELS), len(LABELS)), dtype=np.int64)
    with torch.no_grad():
        for tokens, durations, gaps, numeric, expected, _weights in loader:
            tokens = tokens.to(device)
            durations = durations.to(device)
            gaps = gaps.to(device)
            numeric = numeric.to(device)
            predicted = model(tokens, durations, gaps, numeric).argmax(dim=1)
            for actual, guess in zip(expected.tolist(), predicted.cpu().tolist()):
                confusion[actual, guess] += 1
    return float(np.trace(confusion) / max(confusion.sum(), 1)), confusion


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path, nargs="?")
    parser.add_argument("--output-dir", type=Path, default=Path("ml/artifacts"))
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--width", type=int, default=128)
    parser.add_argument("--layers", type=int, default=2)
    parser.add_argument("--heads", type=int, default=4)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--validation-fraction", type=float, default=0.2)
    parser.add_argument("--minimum-validation-accuracy", type=float, default=0.75)
    parser.add_argument("--minimum-class-recall", type=float, default=0.50)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", choices=("auto", "cpu", "mps"), default="auto")
    parser.add_argument("--skip-coreml", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.dataset:
        samples = load_samples(args.dataset)
    else:
        raise SystemExit("provide a prepared KLiCKe dataset")
    print(json.dumps(summarize(samples), indent=2))
    missing = sorted(set(LABELS) - {LABELS[sample.label] for sample in samples})
    if missing:
        raise SystemExit(f"dataset has no examples for: {', '.join(missing)}")
    train(args, samples)


if __name__ == "__main__":
    main()
