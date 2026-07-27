import argparse
import collections
import hashlib
import json
from pathlib import Path

import onnx
from onnx import TensorProto


def tensor_shape(value_info):
    tensor_type = value_info.type.tensor_type
    dimensions = []
    for dimension in tensor_type.shape.dim:
        if dimension.HasField("dim_value"):
            dimensions.append(dimension.dim_value)
        elif dimension.HasField("dim_param"):
            dimensions.append(dimension.dim_param)
        else:
            dimensions.append(None)
    return {
        "name": value_info.name,
        "dtype": TensorProto.DataType.Name(tensor_type.elem_type),
        "shape": dimensions,
    }


def external_records(initializer):
    if initializer.data_location != TensorProto.EXTERNAL:
        return []
    return [{entry.key: entry.value for entry in initializer.external_data}]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_model(path):
    model = onnx.load(path, load_external_data=False)
    initializer_names = {initializer.name for initializer in model.graph.initializer}
    operators = collections.Counter(node.op_type for node in model.graph.node)
    domains = collections.Counter(node.domain or "ai.onnx" for node in model.graph.node)
    external_files = {}
    external_initializers = []
    for initializer in model.graph.initializer:
        records = external_records(initializer)
        if not records:
            continue
        record = records[0]
        location = record.get("location")
        external_initializers.append(
            {
                "name": initializer.name,
                "dtype": TensorProto.DataType.Name(initializer.data_type),
                "shape": list(initializer.dims),
                "externalData": record,
            }
        )
        if location and location not in external_files:
            external_path = path.parent / location
            external_files[location] = {
                "path": str(external_path.resolve()),
                "present": external_path.is_file(),
                "bytes": external_path.stat().st_size if external_path.is_file() else None,
                "sha256": sha256(external_path) if external_path.is_file() else None,
            }
    return {
        "path": str(path.resolve()),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
        "irVersion": model.ir_version,
        "opsets": {item.domain or "ai.onnx": item.version for item in model.opset_import},
        "producer": {
            "name": model.producer_name,
            "version": model.producer_version,
        },
        "inputs": [
            tensor_shape(value)
            for value in model.graph.input
            if value.name not in initializer_names
        ],
        "outputs": [tensor_shape(value) for value in model.graph.output],
        "valueInfo": [tensor_shape(value) for value in model.graph.value_info],
        "nodes": len(model.graph.node),
        "operators": dict(sorted(operators.items())),
        "domains": dict(sorted(domains.items())),
        "initializers": len(model.graph.initializer),
        "externalInitializers": external_initializers,
        "externalFiles": external_files,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("models", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--quiet", action="store_true")
    arguments = parser.parse_args()
    result = {path.name: inspect_model(path) for path in arguments.models}
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded + "\n", encoding="utf-8")
    if not arguments.quiet:
        print(encoded)


if __name__ == "__main__":
    main()
