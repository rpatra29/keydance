#!/usr/bin/env python3
"""Convert the recovered PyTorch state dict to Keydance's tiny native format.

This is a packaging conversion only. It does not train or inspect user text.
The app intentionally does not ship a PyTorch runtime.
"""

from __future__ import annotations

import io
import pickle
import struct
import sys
import zipfile
from pathlib import Path


class TensorPlaceholder:
    def __init__(self, *args):
        self.args = args


class CheckpointReader(pickle.Unpickler):
    def persistent_load(self, persistent_id):
        return ("storage", persistent_id)

    def find_class(self, module, name):
        if module == "collections" and name == "OrderedDict":
            from collections import OrderedDict

            return OrderedDict
        return TensorPlaceholder


def convert(source: Path, target: Path) -> None:
    with zipfile.ZipFile(source) as archive:
        root_name = source.stem
        metadata = CheckpointReader(io.BytesIO(archive.read(f"{root_name}/data.pkl"))).load()
        storages = {
            name.removeprefix(f"{root_name}/data/"): archive.read(name)
            for name in archive.namelist()
            if name.startswith(f"{root_name}/data/") and name.removeprefix(f"{root_name}/data/").isdigit()
        }

    tensors = metadata["state_dict"]
    output = bytearray(b"KDAC")
    output += struct.pack("<II", 1, len(tensors))
    for name, tensor in tensors.items():
        persistent, offset, shape, _strides, _requires_grad, _metadata = tensor.args
        storage_id = persistent[1][2]
        values = storages[storage_id]
        count = 1
        for dimension in shape:
            count *= dimension
        if offset != 0 or len(values) < count * 4:
            raise ValueError(f"unsupported tensor layout for {name}")
        encoded_name = name.encode("utf-8")
        output += struct.pack("<I", len(encoded_name)) + encoded_name
        output += struct.pack("<I", len(shape))
        output += struct.pack("<" + "I" * len(shape), *shape)
        output += struct.pack("<I", count) + values[: count * 4]

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(output)
    print(f"converted {source} -> {target} ({len(tensors)} tensors)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: convert-contextual-scorer.py CHECKPOINT OUTPUT")
    convert(Path(sys.argv[1]), Path(sys.argv[2]))
