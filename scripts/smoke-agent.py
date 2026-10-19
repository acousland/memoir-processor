#!/usr/bin/env python3
"""Exercise a real agent with synthetic speech and isolated storage. No microphone capture."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
import uuid
import wave

agent = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='memoir-smoke-') as temporary:
    root = Path(temporary)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = uuid.uuid4().hex
    config = dict(bindHost='127.0.0.1', port=port, tlsEnabled=False, authToken=token,
                  transcriptionEngine='whisperkit', modelName='base', maxRetries=2,
                  diarizationEnabled=False, speakerAutoMatchThreshold=0.86,
                  allowCPUFallbackForDiarization=True, outputFormats=['json','txt','srt'],
                  storageRoot=str(root/'data'))
    config_file = root/'config.json'
    config_file.write_text(json.dumps(config))
    config_file.chmod(0o600)
    audio = root/'sample.wav'
    subprocess.run(['/usr/bin/say', '-o', str(audio), '--file-format=WAVE', '--data-format=LEI16@16000',
                    'Welcome to the Memoir test meeting. We are checking that local transcription works. The next meeting is on Friday.'], check=True)
    with wave.open(str(audio)) as wav:
        duration = wav.getnframes()/wav.getframerate()
    log = open(root/'agent.log', 'w')
    process = subprocess.Popen([str(agent), '--config', str(config_file)], stdout=log, stderr=log)
    base = f'http://127.0.0.1:{port}'
    def request(path, method='GET', body=None, content_type='application/json', extra=None, authenticated=True):
        headers = {'Content-Type':content_type, 'X-Memoir-API-Version':'1'}
        if authenticated: headers['Authorization'] = 'Bearer '+token
        if extra: headers.update(extra)
        data = json.dumps(body).encode() if isinstance(body, dict) else body
        with urllib.request.urlopen(urllib.request.Request(base+path, data=data, method=method, headers=headers), timeout=30) as response:
            return json.load(response)
    try:
        for _ in range(100):
            try:
                request('/health', authenticated=False)
                break
            except Exception:
                if process.poll() is not None: raise RuntimeError('Agent exited: '+(root/'agent.log').read_text()[-2000:])
                time.sleep(.1)
        assert request('/v1/connection')['status']=='authenticated'
        try:
            request('/v1/connection', authenticated=False)
            raise AssertionError('Unauthenticated request accepted')
        except urllib.error.HTTPError as error:
            assert error.code==401
        # Reproduce the old parser crash against the actual listener; then verify health survives.
        with socket.create_connection(('127.0.0.1',port)) as connection:
            connection.sendall(b'PUT /upload HTTP/1.1\r\nContent-Length: -1\r\n\r\n')
            assert b'400' in connection.recv(4096)
        assert request('/health', authenticated=False)['status']=='ok'
        session = str(uuid.uuid4())
        now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
        creation=dict(session_id=session,session_name='Synthetic speech smoke test',recording_started_at=now,recording_ended_at=now,
                      recorder=dict(device_id='smoke',app_version='1.1.0',build='2026101901'),expected_files=dict(metadata=True,system=True,mic=False))
        try:
            request('/v1/sessions','POST',{**creation,'session_id':'../escape'},extra={'Idempotency-Key':str(uuid.uuid4())})
            raise AssertionError('Traversal accepted')
        except urllib.error.HTTPError as error: assert error.code==400
        request('/v1/sessions','POST',creation,extra={'Idempotency-Key':str(uuid.uuid4())})
        metadata=dict(session_id=session,session_name=creation['session_name'],recording_started_at=now,recording_ended_at=now,timezone='UTC',
                      system_audio=dict(filename='system.wav',sample_rate_hz=16000,channels=1,duration_seconds=duration))
        uploads={}
        for kind,data,content in [('metadata',json.dumps(metadata).encode(),'application/json'),('system',audio.read_bytes(),'audio/wav')]:
            checksum=hashlib.sha256(data).hexdigest()
            accepted=request(f'/v1/sessions/{session}/files/{kind}','PUT',data,content,{'X-Content-SHA256':checksum})
            assert accepted['sha256']==checksum
            uploads[kind]=dict(size_bytes=len(data),sha256=checksum)
        request(f'/v1/sessions/{session}/complete','POST',dict(uploaded_files=uploads),extra={'Idempotency-Key':str(uuid.uuid4())})
        for _ in range(360):
            status=request(f'/v1/sessions/{session}')
            if status.get('processing_state')=='completed': break
            if status.get('processing_state')=='failed': raise RuntimeError(json.dumps(status.get('error')))
            time.sleep(2)
        else: raise RuntimeError('Transcription timed out')
        artifacts=root/'data'/'sessions'/session/'processing'
        transcript=json.loads((artifacts/'transcript.json').read_text())
        assert transcript['segments'], 'Empty transcript'
        assert (artifacts/'transcript.txt').stat().st_size and (artifacts/'transcript.srt').stat().st_size
        text=' '.join(segment['text'] for segment in transcript['segments'])
        assert 'meeting' in text.lower(), 'Synthetic speech not recognized'
        assert '<|' not in text, 'Whisper control tokens leaked into transcript'
        meeting=request(f'/v1/meetings/{session}')
        assert meeting['meeting']['status']=='completed' and meeting['segments']
        assert all(s['speaker']=='Others' for s in meeting['segments'])
        assert request('/v1/meetings/search','POST',dict(query='meeting',offset=0,limit=100))[0]['id']==session
        try:
            request(f'/v1/meetings/{session}', authenticated=False)
            raise AssertionError('Unauthenticated transcript access accepted')
        except urllib.error.HTTPError as error: assert error.code==401
        try:
            request('/v1/meetings/search','POST',dict(query='meeting',offset='invalid',limit=100))
            raise AssertionError('Malformed search accepted')
        except urllib.error.HTTPError as error: assert error.code==400
        if os.environ.get('MEMOIR_RECORDER_REPO'):
            environment=dict(os.environ, MEMOIR_SMOKE_URL=base, MEMOIR_SMOKE_TOKEN=token, MEMOIR_SMOKE_SESSION=session)
            subprocess.run(['swift','test','--filter','MeetingLibraryLiveTests'],cwd=os.environ['MEMOIR_RECORDER_REPO'],env=environment,check=True)
        print('PASS: actual HTTP authentication, parser survival, path validation, upload checksums, WhisperKit transcription and JSON/TXT/SRT artifacts.')
        print('PASS: authenticated meeting library, full-text search, transcript download and malformed search rejection.')
        print('Synthetic transcript:', text)
    except Exception:
        print((root/'agent.log').read_text()[-6000:], file=sys.stderr)
        raise
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
        log.close()
