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


def run_pipeline(audio_path, waveform, sample_rate, token, device, backend, Pipeline, Model, Inference, torch_module):
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", use_auth_token=token)
    embedding_model = Model.from_pretrained("pyannote/embedding", use_auth_token=token)

    if backend != "cpu":
        pipeline.to(device)
        embedding_model.to(device)

    inference = Inference(embedding_model, window="whole")
    diarization = pipeline({"waveform": waveform.to(device), "sample_rate": sample_rate})
    return diarization, inference


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
    waveform, sample_rate = resample_to_mono_16k(torch, torchaudio, args.audio)

    try:
        diarization, inference = run_pipeline(
            args.audio,
            waveform,
            sample_rate,
            (args.hf_token or os.environ.get("HF_TOKEN")),
            device,
            backend,
            Pipeline,
            Model,
            Inference,
            torch,
        )
    except Exception as exc:
        if not args.allow_cpu_fallback or backend == "cpu":
            print(f"Diarization failed: {exc}", file=sys.stderr)
            return 1
        device = torch.device("cpu")
        backend = "cpu"
        try:
            diarization, inference = run_pipeline(
                args.audio,
                waveform,
                sample_rate,
                (args.hf_token or os.environ.get("HF_TOKEN")),
                device,
                backend,
                Pipeline,
                Model,
                Inference,
                torch,
            )
        except Exception as inner_exc:
            print(f"Diarization failed after CPU fallback: {inner_exc}", file=sys.stderr)
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
            embedding = compute_embedding(inference, clip.to(device), sample_rate)
        except Exception:
            if backend != "cpu" and args.allow_cpu_fallback:
                embedding = compute_embedding(inference, clip.to(torch.device("cpu")), sample_rate)
            else:
                continue
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
