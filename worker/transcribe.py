#!/usr/bin/env python3

import argparse
import contextlib
import io
import json
import os
import sys


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--language", required=False)
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.engine != "whisper":
        print(f"Unsupported engine: {args.engine}", file=sys.stderr)
        return 1

    try:
        import whisper  # type: ignore
    except Exception:
        print(
            "The Python `whisper` package is not installed. Install it in the runtime environment to enable transcription.",
            file=sys.stderr,
        )
        return 1

    try:
        ffmpeg_binary = os.environ.get("FFMPEG_BINARY")
        if ffmpeg_binary:
            os.environ["PATH"] = os.path.dirname(ffmpeg_binary) + os.pathsep + os.environ.get("PATH", "")

        model = whisper.load_model(args.model)
        captured_stdout = io.StringIO()
        with contextlib.redirect_stdout(captured_stdout):
            result = model.transcribe(
                args.audio,
                language=args.language,
                word_timestamps=False,
                verbose=False,
            )
    except Exception as exc:
        print(f"Whisper transcription failed: {exc}", file=sys.stderr)
        return 1

    payload = {
        "engine": args.engine,
        "model": args.model,
        "language": result.get("language") or args.language or "unknown",
        "segments": [
            {
                "start": float(segment.get("start", 0.0)),
                "end": float(segment.get("end", 0.0)),
                "speaker": None,
                "text": (segment.get("text") or "").strip(),
            }
            for segment in result.get("segments", [])
        ],
    }
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
