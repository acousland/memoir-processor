#!/usr/bin/env python3

import argparse
import json
import os
import contextlib
import sys
import warnings
import math

os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--session-id")
    parser.add_argument("--source-track")
    parser.add_argument("--hf-token", required=False)
    parser.add_argument("--prefer-mps", action="store_true")
    parser.add_argument("--allow-cpu-fallback", action="store_true")
    return parser


def load_dependencies():
    try:
        import torch  # type: ignore
        import torchaudio  # type: ignore
        from pyannote.audio import Pipeline  # type: ignore
    except Exception as exc:
        print(f"Diarization runtime is not installed: {exc}", file=sys.stderr)
        raise SystemExit(1)
    return torch, torchaudio, Pipeline


def resolve_device(torch_module, prefer_mps: bool):
    if prefer_mps and getattr(torch_module.backends, "mps", None) and torch_module.backends.mps.is_available():
        return torch_module.device("mps"), "mps"
    return torch_module.device("cpu"), "cpu"


def resample_to_mono_16k(torch_module, torchaudio_module, audio_path: str):
    # pyannote 4's TorchCodec file loader is unnecessary for normalized WAVs.
    # SoundFile avoids dependence on a particular system FFmpeg ABI.
    import soundfile
    samples, sample_rate = soundfile.read(audio_path, dtype="float32", always_2d=True)
    waveform = torch_module.from_numpy(samples.T.copy())
    if waveform.shape[0] > 1:
        waveform = waveform.mean(dim=0, keepdim=True)
    if sample_rate != 16000:
        waveform = torchaudio_module.functional.resample(waveform, sample_rate, 16000)
        sample_rate = 16000
    return waveform, sample_rate


MODEL_REPOSITORIES = ("pyannote/speaker-diarization-community-1",)

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


def load_models(token, Pipeline):
    from huggingface_hub import hf_hub_download
    repo = MODEL_REPOSITORIES[0]
    try:
        hf_hub_download(repo, "config.yaml", token=token)
        pipeline = Pipeline.from_pretrained(repo, token=token)
        if pipeline is None:
            raise RuntimeError("Pipeline download returned no model; check Hugging Face access.")
        return pipeline
    except Exception as exc:
        raise model_error(repo, exc) from exc


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


def serialize_output(output, track, backend):
    # Exclusive turns are intended for matching transcription timestamps. The
    # embeddings are ordered by regular diarization labels, not by turn order.
    annotation = output.exclusive_speaker_diarization
    turns = []
    durations = {}
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        start, end = float(turn.start), float(turn.end)
        turns.append({"cluster_id": f"{track}:{speaker}", "start": start, "end": end, "source_track": track})
        durations[speaker] = durations.get(speaker, 0.0) + max(0.0, end - start)
    embeddings = []
    if output.speaker_embeddings is not None:
        for speaker, vector in zip(output.speaker_diarization.labels(), output.speaker_embeddings):
            values = [float(value) for value in vector]
            if not values or not all(math.isfinite(value) for value in values):
                continue
            embeddings.append({"clusterID": f"{track}:{speaker}", "durationSeconds": durations.get(speaker, 0.0),
                               "embedding": values, "sourceTrack": track})
    return {"runtime": "pyannote Community-1", "backend": backend, "turns": turns, "embeddings": embeddings}


def main() -> int:
    args = build_parser().parse_args()
    warnings.filterwarnings("ignore")

    torch, torchaudio, Pipeline = load_dependencies()
    device, backend = resolve_device(torch, args.prefer_mps)
    if args.prefer_mps and backend == "cpu" and not args.allow_cpu_fallback:
        print("Apple GPU (MPS) is unavailable and CPU fallback is disabled.", file=sys.stderr)
        return 1
    token = args.hf_token or os.environ.get("HF_TOKEN")
    try:
        pipeline = load_models(token, Pipeline)
        if args.prepare:
            pipeline.to(device)
            print(json.dumps({"status": "ready", "backend": backend}), file=sys.__stdout__)
            return 0
        if not args.audio or not args.source_track:
            raise RuntimeError("--audio and --source-track are required for diarization.")
        waveform, sample_rate = resample_to_mono_16k(torch, torchaudio, args.audio)
        output, device = diarize_with_fallback(pipeline, waveform, sample_rate, device, args.allow_cpu_fallback, torch)
        print(json.dumps(serialize_output(output, args.source_track, device.type)), file=sys.__stdout__)
        return 0
    except Exception as exc:
        message = str(exc).replace(token, "[redacted]") if token else str(exc)
        print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    with contextlib.redirect_stdout(sys.stderr):
        raise SystemExit(main())
