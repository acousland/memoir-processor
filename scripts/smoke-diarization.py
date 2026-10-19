#!/usr/bin/env python3
"""Run either actual diarization engine using isolated synthetic speech. No cloud audio or session writes."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--engine', choices=['pyannote', 'fluidaudio'], default='pyannote')
parser.add_argument('--helper', type=Path, default=Path('/Applications/Memoir Processor.app/Contents/MacOS/MemoirDiarizationWorker'))
parser.add_argument('--models', type=Path, default=Path.home() / 'Library/Application Support/Memoir Processor/runtime/fluidaudio')
parser.add_argument('--python', type=Path, default=Path.home() / 'Library/Application Support/Memoir Processor/runtime/diarization-community-1/venv/bin/python3')
parser.add_argument('--worker', type=Path, default=Path(__file__).resolve().parents[1] / 'worker/diarize.py')
args = parser.parse_args()
environment = dict(os.environ)
if args.engine == 'pyannote' and not environment.get('HF_TOKEN'):
    token = subprocess.run(['security', 'find-generic-password', '-s', 'com.memoir.processor', '-a', 'huggingface-token', '-w'], capture_output=True, text=True, check=True).stdout.strip()
    environment['HF_TOKEN'] = token
with tempfile.TemporaryDirectory(prefix='memoir-diarization-smoke-') as temporary:
    root = Path(temporary)
    clips = []
    for index, (voice, text) in enumerate([
        ('Samantha', 'Welcome to our meeting. Today we are testing speaker identification on this Mac. Let us discuss the next project milestone.'),
        ('Daniel', 'Thank you. I will prepare the project plan and send it on Friday. We should meet again next week to review the progress.'),
        ('Samantha', 'That sounds good. I will review the plan and confirm the next meeting date. Thank you for joining today.'),
    ]):
        path = root / f'{index}.wav'
        subprocess.run(['/usr/bin/say', '-v', voice, '-o', str(path), '--file-format=WAVE', '--data-format=LEI16@16000', text], check=True)
        with wave.open(str(path)) as source:
            assert source.getnchannels() == 1 and source.getframerate() == 16000
            clips.append(source.readframes(source.getnframes()))
    audio = root / 'meeting.wav'
    with wave.open(str(audio), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes((b'\0\0' * 8000).join(clips))
    # CPU fallback is deliberately omitted: a CPU run must fail this check.
    if args.engine == 'pyannote':
        command = [str(args.python), str(args.worker), '--audio', str(audio), '--session-id', 'isolated-gpu-smoke', '--source-track', 'system', '--prefer-mps']
    else:
        command = [str(args.helper), '--audio', str(audio), '--source-track', 'system', '--models', str(args.models)]
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=1800)
    secret = environment.get('HF_TOKEN', '')
    if result.returncode:
        message = result.stderr.replace(secret, '[redacted]') if secret else result.stderr
        raise SystemExit(message[-6000:])
    payload = json.loads(result.stdout)
    assert payload['backend'] == ('mps' if args.engine == 'pyannote' else 'coreml-cpu+ane'), payload['backend']
    assert payload['turns'], 'No speaker turns detected'
    assert payload['embeddings'], 'No voice embeddings extracted'
    for item in payload['embeddings']:
        assert item['embedding'] and all(math.isfinite(value) for value in item['embedding'])
    print(f"PASS: actual local {args.engine} diarization ({payload['backend']}), {len(payload['turns'])} turns, {len(payload['embeddings'])} voice embeddings.")
