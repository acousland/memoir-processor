"""Device and failure-path regressions without downloading gated model weights."""
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
        self.assertEqual(selected.type, 'mps')
        self.assertEqual(backend, 'mps')

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
        self.assertEqual(result, 'turns')
        self.assertEqual(selected.type, 'cpu')
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

    def test_embedding_retry_moves_inference_and_model(self):
        inference = Mock(side_effect=[RuntimeError('MPS embedding'), [0.2, 0.8]])
        waveform = object()
        vector, selected = worker.embed_with_fallback(inference, waveform, 16000, device('mps'), True, SimpleNamespace(device=device))
        self.assertEqual(vector, [0.2, 0.8])
        self.assertEqual(selected.type, 'cpu')
        self.assertEqual([call.args[0].type for call in inference.to.call_args_list], ['mps', 'cpu'])
        self.assertIs(inference.call_args.args[0]['waveform'], waveform)

    def test_unwraps_hidden_hugging_face_permission_error(self):
        denied = RuntimeError('Forbidden')
        denied.response = SimpleNamespace(status_code=403)
        missing = RuntimeError('Not in cache')
        missing.__cause__ = denied
        message = str(worker.model_error('pyannote/segmentation-3.0', missing))
        self.assertIn('public gated repos', message)
        self.assertIn('https://huggingface.co/pyannote/segmentation-3.0', message)

    def test_embedding_gpu_failure_respects_disabled_cpu_fallback(self):
        inference = Mock(side_effect=RuntimeError('unsupported GPU operation'))
        with self.assertRaisesRegex(RuntimeError, 'unsupported GPU operation'):
            worker.embed_with_fallback(inference, object(), 16000, device('mps'), False, SimpleNamespace(device=device))
        self.assertEqual(inference.call_count, 1)
        self.assertEqual([call.args[0].type for call in inference.to.call_args_list], ['mps'])

    def test_gpu_only_run_fails_if_mps_is_unavailable(self):
        torch = SimpleNamespace(device=device, backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: False)))
        with patch.object(worker, 'load_dependencies', return_value=(torch, Mock(), Mock(), Mock(), Mock())), patch('sys.argv', ['diarize.py', '--audio', 'unused.wav', '--session-id', 'test', '--source-track', 'system', '--prefer-mps']):
            self.assertEqual(worker.main(), 1)

    def test_model_setup_preflights_every_gated_dependency(self):
        hub = SimpleNamespace(hf_hub_download=Mock())
        pipeline, model, inference = Mock(), Mock(), Mock()
        with patch.dict('sys.modules', {'huggingface_hub': hub}):
            loaded_pipeline, loaded_inference = worker.load_models('test-token', pipeline, model, inference)
        self.assertEqual([call.args[0] for call in hub.hf_hub_download.call_args_list], list(worker.MODEL_REPOSITORIES))
        self.assertIs(loaded_pipeline, pipeline.from_pretrained.return_value)
        self.assertIs(loaded_inference, inference.return_value)


    def test_model_access_failure_happens_before_any_device_inference(self):
        hub = SimpleNamespace(hf_hub_download=Mock(side_effect=RuntimeError('offline')))
        pipeline = Mock()
        with patch.dict('sys.modules', {'huggingface_hub': hub}):
            with self.assertRaisesRegex(RuntimeError, 'Could not load pyannote/speaker-diarization-3.1'):
                worker.load_models('test-token', pipeline, Mock(), Mock())
        pipeline.from_pretrained.assert_not_called()


if __name__ == '__main__':
    unittest.main()
