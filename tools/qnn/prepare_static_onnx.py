import argparse
import collections
import hashlib
import json
from pathlib import Path

import onnx
import onnxruntime as ort
from onnx import TensorProto, shape_inference


GRAPH_PATHS = {
    "moss_tts_prefill.onnx": "MOSS-TTS-Nano-100M-ONNX/moss_tts_prefill.onnx",
    "moss_tts_decode_step.onnx": "MOSS-TTS-Nano-100M-ONNX/moss_tts_decode_step.onnx",
    "moss_tts_local_fixed_sampled_frame.onnx": "MOSS-TTS-Nano-100M-ONNX/moss_tts_local_fixed_sampled_frame.onnx",
    "moss_audio_tokenizer_decode_full.onnx": "MOSS-Audio-Tokenizer-Nano-ONNX/moss_audio_tokenizer_decode_full.onnx",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def shape_record(value_info) -> dict:
    dimensions: list[int | str | None] = []
    for dimension in value_info.type.tensor_type.shape.dim:
        if dimension.HasField("dim_value"):
            dimensions.append(dimension.dim_value)
        elif dimension.HasField("dim_param"):
            dimensions.append(dimension.dim_param)
        else:
            dimensions.append(None)
    return {
        "name": value_info.name,
        "dtype": TensorProto.DataType.Name(value_info.type.tensor_type.elem_type),
        "shape": dimensions,
    }


def replace_dimensions(model: onnx.ModelProto, dimensions: dict[str, int]) -> None:
    unresolved: set[str] = set()
    values = list(model.graph.input) + list(model.graph.output) + list(model.graph.value_info)
    for value in values:
        for dimension in value.type.tensor_type.shape.dim:
            if not dimension.HasField("dim_param"):
                continue
            name = dimension.dim_param
            replacement = dimensions.get(name)
            if replacement is None:
                unresolved.add(name)
                continue
            dimension.ClearField("dim_param")
            dimension.dim_value = replacement
    graph_io_symbols = {
        dimension.dim_param
        for value in list(model.graph.input) + list(model.graph.output)
        for dimension in value.type.tensor_type.shape.dim
        if dimension.HasField("dim_param")
    }
    if graph_io_symbols:
        raise ValueError(f"unresolved graph I/O dimensions: {sorted(graph_io_symbols)}")


def node_counts(model: onnx.ModelProto) -> dict[str, int]:
    return dict(sorted(collections.Counter(node.op_type for node in model.graph.node).items()))


def save_external(model: onnx.ModelProto, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    onnx.save_model(
        model,
        path,
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location=f"{path.stem}.data",
        size_threshold=1024,
        convert_attribute=False,
    )


def optimize_with_ort(source: Path, output: Path) -> None:
    options = ort.SessionOptions()
    # QAIRT's ONNX frontend does not accept ORT-private fused operators such as
    # com.microsoft::FusedMatMul. BASIC performs constant folding while keeping
    # the serialized graph in the standard ONNX domain.
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    options.optimized_model_filepath = str(output.resolve())
    options.add_session_config_entry(
        "session.optimized_model_external_initializers_file_name",
        f"{output.stem}.data",
    )
    options.add_session_config_entry(
        "session.optimized_model_external_initializers_min_size_in_bytes",
        "1024",
    )
    ort.InferenceSession(str(source), sess_options=options, providers=["CPUExecutionProvider"])


def prepare(name: str, source: Path, output_dir: Path, dimensions: dict[str, int]) -> dict:
    model = onnx.load(source, load_external_data=True)
    before = {
        "nodes": len(model.graph.node),
        "operators": node_counts(model),
        "inputs": [shape_record(item) for item in model.graph.input],
        "outputs": [shape_record(item) for item in model.graph.output],
    }
    replace_dimensions(model, dimensions)
    model = shape_inference.infer_shapes(model, check_type=True, strict_mode=False, data_prop=True)
    intermediate = output_dir / name.replace(".onnx", ".static.onnx")
    optimized = output_dir / name.replace(".onnx", ".static.optimized.onnx")
    save_external(model, intermediate)
    onnx.checker.check_model(intermediate, full_check=False)
    optimize_with_ort(intermediate, optimized)
    optimized_model = onnx.load(optimized, load_external_data=False)
    onnx.checker.check_model(optimized, full_check=False)
    after = {
        "nodes": len(optimized_model.graph.node),
        "operators": node_counts(optimized_model),
        "inputs": [shape_record(item) for item in optimized_model.graph.input],
        "outputs": [shape_record(item) for item in optimized_model.graph.output],
    }
    for value in after["inputs"] + after["outputs"]:
        if any(not isinstance(dimension, int) or dimension <= 0 for dimension in value["shape"]):
            raise ValueError(f"{name} still has non-static I/O: {value}")
    return {
        "source": str(source.resolve()),
        "sourceSha256": sha256(source),
        "staticModel": str(intermediate.resolve()),
        "optimizedModel": str(optimized.resolve()),
        "optimizedSha256": sha256(optimized),
        "dimensions": dimensions,
        "before": before,
        "after": after,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    arguments = parser.parse_args()
    profile = json.loads(arguments.profile.read_text(encoding="utf-8"))
    result = {
        "target": profile["target"],
        "limitations": profile["limitations"],
        "graphs": {},
    }
    for name, relative in GRAPH_PATHS.items():
        result["graphs"][name] = prepare(
            name,
            arguments.source_root / relative,
            arguments.output_root / name.removesuffix(".onnx"),
            profile["graphs"][name],
        )
    report = arguments.output_root / "static-preparation-report.json"
    report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
