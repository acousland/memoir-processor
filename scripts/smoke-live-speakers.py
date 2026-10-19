#!/usr/bin/env python3
"""Exercise live detection, human naming, voice memory and final names using isolated synthetic speech."""
import argparse
import base64
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
import urllib.error
import uuid
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('agent', type=Path)
parser.add_argument('--engine', choices=['fluidaudio','pyannote'], default='pyannote')
parser.add_argument('--runtime', type=Path, default=Path.home()/'Library/Application Support/Memoir Processor/runtime')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='memoir-live-smoke-') as temporary:
    root = Path(temporary)
    data = root/'data'; data.mkdir()
    (data/'runtime').symlink_to(args.runtime.resolve(), target_is_directory=True)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
    token = uuid.uuid4().hex
    config = dict(bindHost='127.0.0.1',port=port,tlsEnabled=False,authToken=token,transcriptionEngine='whisperkit',modelName='base',maxRetries=1,
                  diarizationEnabled=True,diarizationEngine=args.engine,speakerAutoMatchThreshold=.86,allowCPUFallbackForDiarization=False,
                  outputFormats=['json','txt','srt'],storageRoot=str(data))
    config_file=root/'config.json';config_file.write_text(json.dumps(config));config_file.chmod(0o600)
    clips=[]
    for index,voice in enumerate(['Samantha','Daniel','Samantha']):
        source=root/f'{index}.wav'
        subprocess.run(['say','-v',voice,'-o',str(source),'--file-format=WAVE','--data-format=LEI16@16000',
                        'Today we are discussing the meeting schedule and the next project milestone. We should review the plan on Friday.'],check=True)
        with wave.open(str(source)) as wav: clips.append(wav.readframes(48000))
    audio=root/'system.wav'
    with wave.open(str(audio),'wb') as wav:
        wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(b''.join(clips))
    log=open(root/'agent.log','w')
    agent=subprocess.Popen([str(args.agent.resolve()),'--config',str(config_file)],stdout=log,stderr=log)
    def request(path,method='GET',body=None,content='application/json',extra=None,auth=True):
        headers={'Content-Type':content,'X-Memoir-API-Version':'1'}
        if auth:headers['Authorization']='Bearer '+token
        headers.update(extra or {})
        payload=json.dumps(body).encode() if isinstance(body,dict) else body
        with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=payload,method=method,headers=headers),timeout=100) as response:
            return json.load(response)
    try:
        for _ in range(100):
            try:request('/health');break
            except Exception:
                if agent.poll() is not None:raise RuntimeError('Agent exited')
                time.sleep(.1)
        session=str(uuid.uuid4())
        try:
            request('/v1/live/'+session,'POST',{},auth=False)
            raise AssertionError('Live endpoint accepted missing authentication')
        except urllib.error.HTTPError as error:assert error.code==401
        snapshot=request('/v1/live/'+session,'POST',{})
        ids={}
        for index,pcm in enumerate(clips):
            chunk=dict(sequence=index,sourceTrack='system',firstSampleHostTimeNs=str((1000+index*3)*1_000_000_000),sampleRateHz=16000,pcmBase64=base64.b64encode(pcm).decode())
            started=time.perf_counter()
            snapshot=request(f'/v1/live/{session}/chunks','POST',chunk)
            print('Live chunk',index,'processed in',round(time.perf_counter()-started,2),'seconds',flush=True)
            assert snapshot['speakers'],'No live voices detected'
            if index<2:
                anonymous=[item for item in snapshot['speakers'] if item.get('profileID') is None]
                assert anonymous,'Distinct voice was merged into an existing speaker'
                speaker=anonymous[-1]
                name=['Alex','Jamie'][index]
                snapshot=request(f'/v1/live/{session}/speaker','POST',dict(speakerID=speaker['id'],name=name))
                named=next(item for item in snapshot['speakers'] if item['id']==speaker['id'])
                assert named['name']==name and named['confirmed']
                ids[name]=named['profileID']
            else:
                assert len(snapshot['speakers'])==2,'Returning voice was split into another speaker'
                assert next(item for item in snapshot['speakers'] if item['name']=='Alex')['speaking']
            repeated=request(f'/v1/live/{session}/chunks','POST',chunk)
            assert len(repeated['speakers'])==len(snapshot['speakers'])
        quiet=dict(sequence=3,sourceTrack='system',firstSampleHostTimeNs=str(1009*1_000_000_000),sampleRateHz=16000,pcmBase64=base64.b64encode(b'\0'*96000).decode())
        quiet_state=request(f'/v1/live/{session}/chunks','POST',quiet)
        assert not any(item['speaking'] for item in quiet_state['speakers']),'Speaking indicator remained on during silence'
        request(f'/v1/live/{session}/close','POST',{})
        next_session=str(uuid.uuid4())
        request('/v1/live/'+next_session,'POST',{})
        fresh_voice=root/'fresh-voice.wav'
        subprocess.run(['say','-v','Samantha','-o',str(fresh_voice),'--file-format=WAVE','--data-format=LEI16@16000',
                        'Please send the completed report by Friday so that we can review the final decision.'],check=True)
        with wave.open(str(fresh_voice)) as fresh: fresh_pcm=fresh.readframes(48000)
        recognised=request(f'/v1/live/{next_session}/chunks','POST',dict(sequence=0,sourceTrack='system',firstSampleHostTimeNs=str(2000*1_000_000_000),sampleRateHz=16000,pcmBase64=base64.b64encode(fresh_pcm).decode()))
        assert recognised['speakers'][0]['name']=='Alex' and recognised['speakers'][0]['profileID']==ids['Alex'],'Voice memory did not recognise a named person in another meeting'
        assert not recognised['speakers'][0]['confirmed'],'An automatic match was incorrectly marked human-confirmed'
        request(f'/v1/live/{next_session}/close','POST',{})
        print('PASS: authenticated live audio, two distinct speakers, naming, repeat detection, silence and voice recognition in another meeting.',flush=True)
        now=datetime.datetime.now(datetime.timezone.utc)
        stamp=lambda date:date.isoformat().replace('+00:00','Z')
        creation=dict(session_id=session,session_name='Synthetic live speaker test',recording_started_at=stamp(now),recording_ended_at=stamp(now+datetime.timedelta(seconds=9)),
                      recorder=dict(device_id='live-smoke',app_version='1.4.0',build='smoke'),expected_files=dict(metadata=True,system=True,mic=False))
        request('/v1/sessions','POST',creation,extra={'Idempotency-Key':str(uuid.uuid4())})
        stream=dict(first_sample_host_time_ns=str(1000*1_000_000_000),start_offset_seconds=0,sample_rate_hz=16000,duration_frames=144000,latency_frames=0)
        sync=dict(schema_version=1,timeline='host_time_ns',session_zero_host_time_ns=str(1000*1_000_000_000),reference_stream='system',aligned_wav_export=True,drift_corrected=False,estimated_drift_ppm=0,relative_offset_to_system_seconds=0,sync_confidence='high',echo_cancellation=dict(applied=False,mode='none'),streams=dict(system=stream))
        metadata=dict(session_id=session,session_name=creation['session_name'],recording_started_at=creation['recording_started_at'],recording_ended_at=creation['recording_ended_at'],timezone='UTC',
                      system_audio=dict(filename='system.wav',sample_rate_hz=16000,channels=1,duration_seconds=9),stream_sync=sync)
        uploads={}
        for kind,body,content in [('metadata',json.dumps(metadata).encode(),'application/json'),('system',audio.read_bytes(),'audio/wav')]:
            digest=hashlib.sha256(body).hexdigest();request(f'/v1/sessions/{session}/files/{kind}','PUT',body,content,{'X-Content-SHA256':digest})
            uploads[kind]=dict(size_bytes=len(body),sha256=digest)
        request(f'/v1/sessions/{session}/complete','POST',dict(uploaded_files=uploads),extra={'Idempotency-Key':str(uuid.uuid4())})
        for _ in range(600):
            state=request(f'/v1/sessions/{session}')
            if state.get('processing_state')=='completed':break
            if state.get('processing_state')=='failed':raise RuntimeError(str(state.get('error')))
            time.sleep(1)
        else:raise RuntimeError('Final processing timed out')
        artifacts=data/'sessions'/session/'processing'
        diarization=json.loads((artifacts/'diarization.json').read_text())
        names={turn.get('matched_profile_name') for turn in diarization['turns']}
        assert {'Alex','Jamie'}<=names, f'Live names did not carry to final {args.engine} speakers: {names}'
        transcript=json.loads((artifacts/'transcript.json').read_text())
        assert transcript['segments'] and any(segment.get('speaker') in {'Alex','Jamie'} for segment in transcript['segments']), [(item.get('speaker'),item.get('start'),item.get('end')) for item in transcript['segments']]
        print(f'PASS: live names carried into the finished {args.engine} diarization and WhisperKit transcript; mixed voice clusters excluded from training.',flush=True)
        if os.environ.get('MEMOIR_RECORDER_REPO'):
            pcm_file=root/'recorder-client.pcm';pcm_file.write_bytes(clips[0])
            environment=dict(os.environ,MEMOIR_LIVE_SMOKE_URL=f'http://127.0.0.1:{port}',MEMOIR_LIVE_SMOKE_TOKEN=token,MEMOIR_LIVE_SMOKE_PCM=str(pcm_file))
            subprocess.run(['swift','test','--filter','LiveSpeakerProtocolTests'],cwd=environment['MEMOIR_RECORDER_REPO'],env=environment,check=True)
            print('PASS: native recorder networking client detected, named and closed a live speaker session through the actual agent.',flush=True)
    except Exception:
        print((root/'agent.log').read_text()[-5000:])
        raise
    finally:
        agent.terminate()
        try:agent.wait(timeout=5)
        except subprocess.TimeoutExpired:agent.kill();agent.wait()
        log.close()
