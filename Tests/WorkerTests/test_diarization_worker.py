"""Community-1 device, access and speaker-output contract regressions."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('diarize', Path(__file__).resolve().parents[2] / 'worker/diarize.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def device(name):
    return SimpleNamespace(type=name)


class DiarizationWorkerTests(unittest.TestCase):
    def test_selects_apple_gpu_when_available(self):
        torch = SimpleNamespace(device=device, backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: True)))
        selected, backend = worker.resolve_device(torch, True)
        self.assertEqual((selected.type, backend), ('mps', 'mps'))

    def test_pipeline_moves_model_and_keeps_source_audio_on_cpu(self):
        waveform = object()
        pipeline = Mock(return_value='turns')
        gpu = device('mps')
        self.assertEqual(worker.run_pipeline(pipeline, waveform, 16000, gpu), 'turns')
        pipeline.to.assert_called_once_with(gpu)
        pipeline.assert_called_once_with({'waveform': waveform, 'sample_rate': 16000})

    def test_cpu_retry_moves_existing_pipeline_without_reloading_models(self):
        pipeline = Mock(side_effect=[RuntimeError('MPS kernel'), 'turns'])
        result, selected = worker.diarize_with_fallback(pipeline, object(), 16000, device('mps'), True, SimpleNamespace(device=device))
        self.assertEqual((result, selected.type), ('turns', 'cpu'))
        self.assertEqual([call.args[0].type for call in pipeline.to.call_args_list], ['mps', 'cpu'])

    def test_gpu_only_setting_does_not_retry_on_cpu(self):
        pipeline = Mock(side_effect=RuntimeError('MPS kernel'))
        with self.assertRaisesRegex(RuntimeError, 'MPS kernel'):
            worker.diarize_with_fallback(pipeline, object(), 16000, device('mps'), False, SimpleNamespace(device=device))
        self.assertEqual(pipeline.call_count, 1)

    def test_preserves_original_gpu_error_if_cpu_also_fails(self):
        pipeline = Mock(side_effect=[RuntimeError('MPS kernel'), RuntimeError('CPU kernel')])
        with self.assertRaisesRegex(RuntimeError, 'MPS kernel.*CPU kernel'):
            worker.diarize_with_fallback(pipeline, object(), 16000, device('mps'), True, SimpleNamespace(device=device))

    def test_gpu_only_run_fails_if_mps_is_unavailable(self):
        torch = SimpleNamespace(device=device, backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: False)))
        with patch.object(worker, 'load_dependencies', return_value=(torch, Mock(), Mock())), patch('sys.argv', ['diarize.py', '--audio', 'unused.wav', '--session-id', 'test', '--source-track', 'system', '--prefer-mps']):
            self.assertEqual(worker.main(), 1)

    def test_unwraps_hidden_hugging_face_permission_error(self):
        denied = RuntimeError('Forbidden')
        denied.response = SimpleNamespace(status_code=403)
        missing = RuntimeError('Not in cache')
        missing.__cause__ = denied
        message = str(worker.model_error(worker.MODEL_REPOSITORIES[0], missing))
        self.assertIn('public gated repos', message)
        self.assertIn('speaker-diarization-community-1', message)

    def test_only_community_model_approval_is_required(self):
        hub = SimpleNamespace(hf_hub_download=Mock())
        pipeline = Mock()
        with patch.dict('sys.modules', {'huggingface_hub': hub}):
            self.assertIs(worker.load_models('test-token', pipeline), pipeline.from_pretrained.return_value)
        hub.hf_hub_download.assert_called_once_with('pyannote/speaker-diarization-community-1', 'config.yaml', token='test-token')
        pipeline.from_pretrained.assert_called_once_with('pyannote/speaker-diarization-community-1', token='test-token')

    def test_model_access_failure_happens_before_any_device_inference(self):
        hub = SimpleNamespace(hf_hub_download=Mock(side_effect=RuntimeError('offline')))
        pipeline = Mock()
        with patch.dict('sys.modules', {'huggingface_hub': hub}):
            with self.assertRaisesRegex(RuntimeError, 'Could not load pyannote/speaker-diarization-community-1'):
                worker.load_models('test-token', pipeline)
        pipeline.from_pretrained.assert_not_called()

    def test_exclusive_turns_keep_correct_embedding_label_order(self):
        regular = SimpleNamespace(labels=lambda: ['SPEAKER_00', 'SPEAKER_01'])
        exclusive = SimpleNamespace(itertracks=lambda **_: [(SimpleNamespace(start=0, end=2), None, 'SPEAKER_01'), (SimpleNamespace(start=2, end=3), None, 'SPEAKER_00')])
        output = SimpleNamespace(speaker_diarization=regular, exclusive_speaker_diarization=exclusive, speaker_embeddings=[[1, 0], [0, 1]])
        payload = worker.serialize_output(output, 'mic', 'mps')
        self.assertEqual(payload['turns'][0]['cluster_id'], 'mic:SPEAKER_01')
        self.assertEqual(payload['embeddings'][0], dict(clusterID='mic:SPEAKER_00', durationSeconds=1, embedding=[1., 0.], sourceTrack='mic'))
        self.assertEqual(payload['embeddings'][1]['durationSeconds'], 2)

    def test_silent_audio_serializes_as_success_with_empty_turns(self):
        output = SimpleNamespace(speaker_diarization=SimpleNamespace(labels=lambda: []), exclusive_speaker_diarization=SimpleNamespace(itertracks=lambda **_: []), speaker_embeddings=None)
        payload = worker.serialize_output(output, 'system', 'mps')
        self.assertEqual(payload['turns'], [])
        self.assertEqual(payload['embeddings'], [])

    def test_invalid_embedding_is_not_stored(self):
        output = SimpleNamespace(speaker_diarization=SimpleNamespace(labels=lambda: ['SPEAKER_00']), exclusive_speaker_diarization=SimpleNamespace(itertracks=lambda **_: []), speaker_embeddings=[[float('nan')]])
        self.assertEqual(worker.serialize_output(output, 'system', 'mps')['embeddings'], [])


if __name__ == '__main__':
    unittest.main()
