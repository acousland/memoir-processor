#!/usr/bin/env python3
"""Verify saved engine changes on one real agent using an isolated meeting archive."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('agent', type=Path)
parser.add_argument('--engines', nargs='+', choices=['fluidaudio', 'pyannote'], default=['fluidaudio', 'pyannote'])
parser.add_argument('--runtime', type=Path, default=Path.home() / 'Library/Application Support/Memoir Processor/runtime')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='memoir-engine-switch-') as temporary:
    root = Path(temporary)
    data = root / 'data'
    data.mkdir()
    # Reuse downloaded models, keeping every session/database/artifact isolated.
    (data / 'runtime').symlink_to(args.runtime.resolve(), target_is_directory=True)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = uuid.uuid4().hex
    config = dict(bindHost='127.0.0.1', port=port, tlsEnabled=False, authToken=token,
                  transcriptionEngine='whisperkit', modelName='base', maxRetries=1,
                  diarizationEnabled=True, diarizationEngine=('pyannote' if args.engines[0] == 'fluidaudio' else 'fluidaudio'), speakerAutoMatchThreshold=0.86,
                  allowCPUFallbackForDiarization=False, outputFormats=['json','txt','srt'], storageRoot=str(data))
    config_file = root / 'config.json'
    config_file.write_text(json.dumps(config))
    config_file.chmod(0o600)
    audio = root / 'sample.wav'
    subprocess.run(['/usr/bin/say', '-o', str(audio), '--file-format=WAVE', '--data-format=LEI16@16000',
                    'Welcome to the meeting. We are testing local speaker identification. I will prepare the project plan for Friday. Thank you for joining us today.'], check=True)
    with wave.open(str(audio)) as source:
        duration = source.getnframes() / source.getframerate()
    log = open(root / 'agent.log', 'w')
    agent = subprocess.Popen([str(args.agent.resolve()), '--config', str(config_file)], stdout=log, stderr=log)
    def request(path, method='GET', body=None, content='application/json', extra=None):
        headers = {'Authorization': 'Bearer ' + token, 'Content-Type': content, 'X-Memoir-API-Version': '1'}
        headers.update(extra or {})
        payload = json.dumps(body).encode() if isinstance(body, dict) else body
        with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}' + path, data=payload, method=method, headers=headers), timeout=30) as response:
            return json.load(response)
    try:
        for _ in range(100):
            try:
                request('/health')
                break
            except Exception:
                if agent.poll() is not None: raise RuntimeError('Agent exited')
                time.sleep(.1)
        original_pid = agent.pid
        for engine in args.engines:
            config['diarizationEngine'] = engine
            updated = config_file.with_suffix('.new')
            updated.write_text(json.dumps(config))
            updated.chmod(0o600)
            updated.replace(config_file)
            session = str(uuid.uuid4())
            now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
            creation = dict(session_id=session, session_name='Isolated '+engine, recording_started_at=now, recording_ended_at=now,
                            recorder=dict(device_id='smoke',app_version='1.4.0',build='smoke'), expected_files=dict(metadata=True,system=True,mic=False))
            request('/v1/sessions','POST',creation,extra={'Idempotency-Key':str(uuid.uuid4())})
            metadata = dict(session_id=session,session_name=creation['session_name'],recording_started_at=now,recording_ended_at=now,timezone='UTC',
                            system_audio=dict(filename='system.wav',sample_rate_hz=16000,channels=1,duration_seconds=duration))
            uploads = {}
            for kind,body,content in [('metadata',json.dumps(metadata).encode(),'application/json'),('system',audio.read_bytes(),'audio/wav')]:
                digest = hashlib.sha256(body).hexdigest()
                request(f'/v1/sessions/{session}/files/{kind}','PUT',body,content,{'X-Content-SHA256':digest})
                uploads[kind] = dict(size_bytes=len(body),sha256=digest)
            request(f'/v1/sessions/{session}/complete','POST',dict(uploaded_files=uploads),extra={'Idempotency-Key':str(uuid.uuid4())})
            for _ in range(600):
                state = request(f'/v1/sessions/{session}')
                if state.get('processing_state') == 'completed': break
                if state.get('processing_state') == 'failed': raise RuntimeError(str(state.get('error')))
                time.sleep(1)
            else: raise RuntimeError('Job timed out')
            artifacts = data / 'sessions' / session / 'processing'
            diarization = json.loads((artifacts / 'diarization.json').read_text())
            assert diarization['runtime'] == ('FluidAudio offline VBx' if engine == 'fluidaudio' else 'pyannote Community-1'), diarization
            assert diarization['backend'] == ('coreml-cpu+ane' if engine == 'fluidaudio' else 'mps'), diarization
            assert diarization['turns'], 'No speaker turns'
            transcript = json.loads((artifacts / 'transcript.json').read_text())
            assert transcript['segments'] and any(item.get('cluster_id') for item in transcript['segments']), 'Transcript speaker assignment missing'
            assert agent.pid == original_pid and agent.poll() is None, 'Agent restarted during switch'
            print(f'PASS: {engine} through actual upload, WhisperKit, diarization, speaker-labelled artifacts; same agent PID.', flush=True)
    except Exception:
        print((root / 'agent.log').read_text()[-6000:])
        raise
    finally:
        agent.terminate()
        try: agent.wait(timeout=5)
        except subprocess.TimeoutExpired: agent.kill(); agent.wait()
        log.close()
