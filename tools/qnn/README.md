# QAIRT deployment tooling

`fetch_moss_models.ps1` downloads and verifies the four upstream MOSS ONNX graphs and their
external data. `prepare_static_onnx.py` fixes the SM8850 profile dimensions and performs BASIC
ONNX Runtime constant folding without introducing private ORT fused operators.

`moss_v81_status.json` is the current machine-readable gate. It deliberately keeps Android QNN
disabled: the upstream decode graph grows its KV cache from 768 to 769, and the local sampler
fails V81 finalization on `QNN_CumulativeSum`. Raw dynamic ONNX files are not HTP deployments.

`prepare_qwen3_genie.ps1` accepts only the exact `Qwen3ForCausalLM` 4B/36-layer source model,
runs the QAIRT 2.48 Composer, writes a CPU Genie config, hashes every package file, and optionally
creates the ZIP consumed by Talk2U. Composer output runs through `QnnGenAiTransformer` on the host
CPU. An HTP config may be added only when separately generated and validated artifacts exist. Genie
2.48 does not expose a QNN GPU dialog backend, so the app tries validated HTP and then CPU, marks
HTP as verified only after the first successful query, and reports CPU fallback explicitly.
