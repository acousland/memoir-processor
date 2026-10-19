#!/usr/bin/env python3

import argparse
import json
import os
import contextlib
import sys
import warnings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--source-track", required=True)
    parser.add_argument("--hf-token", required=False)
    parser.add_argument("--prefer-mps", action="store_true")
    parser.add_argument("--allow-cpu-fallback", action="store_true")
    return parser


def load_dependencies():
    try:
        import torch  # type: ignore
        import torchaudio  # type: ignore
        from pyannote.audio import Pipeline, Model, Inference  # type: ignore
    except Exception as exc:
        print(f"Diarization runtime is not installed: {exc}", file=sys.stderr)
        raise SystemExit(1)
    return torch, torchaudio, Pipeline, Model, Inference


def resolve_device(torch_module, prefer_mps: bool):
    if prefer_mps and getattr(torch_module.backends, "mps", None) and torch_module.backends.mps.is_available():
        return torch_module.device("mps"), "mps"
    return torch_module.device("cpu"), "cpu"


def resample_to_mono_16k(torch_module, torchaudio_module, audio_path: str):
    waveform, sample_rate = torchaudio_module.load(audio_path)
    if waveform.shape[0] > 1:
        waveform = waveform.mean(dim=0, keepdim=True)
    if sample_rate != 16000:
        waveform = torchaudio_module.functional.resample(waveform, sample_rate, 16000)
        sample_rate = 16000
    return waveform, sample_rate


MODEL_REPOSITORIES = (
    "pyannote/speaker-diarization-3.1",
    "pyannote/segmentation-3.0",
    "pyannote/embedding",
)


def model_error(repo, error):
    # huggingface-hub 0.25 wraps some token-permission 403s in a generic
    # LocalEntryNotFoundError. Follow the cause rather than blaming the GPU.
    cause = error
    seen = set()
    while cause is not None and id(cause) not in seen:
        seen.add(id(cause))
        response = getattr(cause, "response", None)
        if response is not None and response.status_code in (401, 403):
            return RuntimeError(
                f"Model access denied for {repo}. In https://huggingface.co/settings/tokens "
                "enable 'Read access to contents of all public gated repos you can access' "
                f"for the saved token, and accept the model conditions at https://huggingface.co/{repo}. "
                "If you create a replacement token, save it in Processor Settings."
            )
        cause = cause.__cause__ or cause.__context__
    return RuntimeError(f"Could not load {repo}: {error}")


def load_models(token, Pipeline, Model, Inference):
    from huggingface_hub import hf_hub_download

    # Check each gated dependency explicitly: pyannote can otherwise return None
    # or hide a permission failure behind a generic missing-cache error.
    for repo in MODEL_REPOSITORIES:
        try:
            hf_hub_download(repo, "config.yaml", token=token)
        except Exception as exc:
            raise model_error(repo, exc) from exc
    try:
        pipeline = Pipeline.from_pretrained(MODEL_REPOSITORIES[0], use_auth_token=token)
        if pipeline is None:
            raise RuntimeError("Pipeline download returned no model; check Hugging Face access.")
        embedding_model = Model.from_pretrained(MODEL_REPOSITORIES[2], use_auth_token=token)
        if embedding_model is None:
            raise RuntimeError("Embedding download returned no model; check Hugging Face access.")
        inference = Inference(embedding_model, window="whole")
    except Exception as exc:
        raise RuntimeError(f"Diarization model setup failed: {exc}") from exc
    return pipeline, inference


def run_pipeline(pipeline, waveform, sample_rate, device):
    pipeline.to(device)
    # pyannote owns chunk transfers to the model device. Keep source audio on
    # CPU: cropping, padding and feature extraction also use NumPy/CPU tensors.
    return pipeline({"waveform": waveform, "sample_rate": sample_rate})


def diarize_with_fallback(pipeline, waveform, sample_rate, device, allow_fallback, torch_module):
    try:
        return run_pipeline(pipeline, waveform, sample_rate, device), device
    except Exception as gpu_error:
        if device.type == "cpu" or not allow_fallback:
            raise RuntimeError(f"Diarization inference failed on {device}: {gpu_error}") from gpu_error
        print(f"GPU diarization failed ({gpu_error}); retrying inference on CPU.", file=sys.stderr)
        cpu = torch_module.device("cpu")
        try:
            return run_pipeline(pipeline, waveform, sample_rate, cpu), cpu
        except Exception as cpu_error:
            raise RuntimeError(
                f"Diarization inference failed on GPU: {gpu_error}; CPU fallback also failed: {cpu_error}"
            ) from cpu_error


def embed_with_fallback(inference, waveform, sample_rate, device, allow_fallback, torch_module):
    try:
        inference.to(device)
        return compute_embedding(inference, waveform, sample_rate), device
    except Exception as gpu_error:
        if device.type == "cpu" or not allow_fallback:
            raise RuntimeError(f"Speaker embedding failed on {device}: {gpu_error}") from gpu_error
        print(f"GPU speaker embedding failed ({gpu_error}); retrying on CPU.", file=sys.stderr)
        # Moving only the waveform does not move the model or Inference.device.
        cpu = torch_module.device("cpu")
        inference.to(cpu)
        return compute_embedding(inference, waveform, sample_rate), cpu


def concatenate_segments(waveform, sample_rate, segments, max_seconds=20.0):
    if not segments:
        return None

    max_samples = int(max_seconds * sample_rate)
    collected = []
    collected_samples = 0
    for segment in segments:
        start = max(0, int(segment["start"] * sample_rate))
        end = min(waveform.shape[1], int(segment["end"] * sample_rate))
        if end <= start:
            continue
        chunk = waveform[:, start:end]
        remaining = max_samples - collected_samples
        if remaining <= 0:
            break
        if chunk.shape[1] > remaining:
            chunk = chunk[:, :remaining]
        collected.append(chunk)
        collected_samples += chunk.shape[1]

    if not collected:
        return None

    import torch  # type: ignore

    return torch.cat(collected, dim=1)


def compute_embedding(inference, waveform, sample_rate):
    vector = inference({"waveform": waveform, "sample_rate": sample_rate})
    if hasattr(vector, "tolist"):
        vector = vector.tolist()
    if isinstance(vector, list) and vector and isinstance(vector[0], list):
        vector = vector[0]
    return [float(value) for value in vector]


def main() -> int:
    args = build_parser().parse_args()
    warnings.filterwarnings("ignore")

    torch, torchaudio, Pipeline, Model, Inference = load_dependencies()
    device, backend = resolve_device(torch, args.prefer_mps)
    if args.prefer_mps and backend == "cpu" and not args.allow_cpu_fallback:
        print("Apple GPU (MPS) is unavailable and CPU fallback is disabled.", file=sys.stderr)
        return 1
    waveform, sample_rate = resample_to_mono_16k(torch, torchaudio, args.audio)

    token = args.hf_token or os.environ.get("HF_TOKEN")
    try:
        # Download/authentication failures cannot be repaired by a CPU retry.
        pipeline, inference = load_models(token, Pipeline, Model, Inference)
        diarization, device = diarize_with_fallback(
            pipeline, waveform, sample_rate, device, args.allow_cpu_fallback, torch
        )
        backend = device.type
    except Exception as exc:
        message = str(exc).replace(token, "[redacted]") if token else str(exc)
        print(message, file=sys.stderr)
        return 1

    turns = []
    grouped_segments = {}

    for turn, _, speaker in diarization.itertracks(yield_label=True):
        cluster_id = f"{args.source_track}:{speaker}"
        start = float(turn.start)
        end = float(turn.end)
        turns.append(
            {
                "cluster_id": cluster_id,
                "start": start,
                "end": end,
                "source_track": args.source_track,
                "matched_profile_id": None,
                "matched_profile_name": None,
                "match_confidence": None,
                "representative_text": None,
            }
        )
        grouped_segments.setdefault(cluster_id, []).append({"start": start, "end": end})

    embeddings = []
    for cluster_id, segments in grouped_segments.items():
        duration_seconds = sum(segment["end"] - segment["start"] for segment in segments)
        if duration_seconds < 0.9:
            continue
        clip = concatenate_segments(waveform, sample_rate, segments)
        if clip is None or clip.shape[1] == 0:
            continue
        try:
            embedding, embedding_device = embed_with_fallback(
                inference, clip, sample_rate, device, args.allow_cpu_fallback, torch
            )
        except Exception as exc:
            print(f"Speaker embedding failed: {exc}", file=sys.stderr)
            return 1
        if embedding_device.type != backend:
            backend = "mps+cpu"
        embeddings.append(
            {
                "clusterID": cluster_id,
                "durationSeconds": float(duration_seconds),
                "representativeText": None,
                "embedding": embedding,
                "sourceTrack": args.source_track,
            }
        )

    payload = {
        "runtime": "pyannote.audio",
        "backend": backend,
        "turns": turns,
        "embeddings": embeddings,
    }
    print(json.dumps(payload), file=sys.__stdout__)
    return 0


if __name__ == "__main__":
    with contextlib.redirect_stdout(sys.stderr):
        raise SystemExit(main())
