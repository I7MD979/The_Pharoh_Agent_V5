import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'watchdog', Path(__file__).resolve().parents[1] / 'scripts/llama_watchdog.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class WatchdogTests(unittest.TestCase):
    def test_five_hours_of_generation_keeps_running(self):
        state = {}
        for seconds in range(0, 5 * 3600, 60):
            self.assertFalse(w.assess(state, seconds, [[0, 42, seconds]]))

    def test_stalled_generation_restarts_after_threshold(self):
        state = {}
        self.assertFalse(w.assess(state, 0, [[0, 42, 10]]))
        self.assertFalse(w.assess(state, 1799, [[0, 42, 10]]))
        self.assertTrue(w.assess(state, 1800, [[0, 42, 10]]))

    def test_new_request_resets_stall_clock(self):
        state = {}
        w.assess(state, 0, [[0, 42, 10]])
        self.assertFalse(w.assess(state, 1900, [[0, 43, 10]]))

    def test_three_consecutive_failures_required(self):
        state = {}
        self.assertFalse(w.assess(state, 0, [], False))
        self.assertFalse(w.assess(state, 60, [], False))
        self.assertTrue(w.assess(state, 120, [], False))

    def test_recovery_resets_failure_count(self):
        state = {}
        w.assess(state, 0, [], False)
        w.assess(state, 60, [], True)
        self.assertFalse(w.assess(state, 120, [], False))
        self.assertEqual(state['failures'], 1)

    def test_slot_fingerprint_uses_live_token_progress(self):
        self.assertEqual(w.progress([{'id': 0, 'id_task': 7, 'is_processing': True,
                                     'next_token': {'n_decoded': 13}}]),
                         [[0, 7, None, None, 13]])

    def test_bad_slot_response_is_not_healthy(self):
        for slots in [[], {}, None]:
            with self.assertRaises(ValueError):
                w.progress(slots)

    @patch.object(w, 'request')
    @patch.object(w, 'command', return_value='ActiveState=inactive')
    def test_manually_stopped_service_stays_stopped(self, command, request):
        w.main()
        request.assert_not_called()

    @patch.object(w.time, 'monotonic', return_value=1000)
    @patch.object(w, 'request')
    @patch.object(w, 'command', return_value=(
        'ActiveState=active\nInvocationID=test\nActiveEnterTimestampMonotonic=900000000'))
    def test_startup_grace_allows_model_loading(self, command, request, clock):
        w.main()
        request.assert_not_called()

    def test_health_ok_but_gpu_hung_triggers_real_probe_and_recovery(self):
        props = 'ActiveState=active\nInvocationID=test\nActiveEnterTimestampMonotonic=0'
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(w.os.environ, {'STATE_DIRECTORY': directory}), \
                patch.object(w, 'command', side_effect=lambda *a: props if a[1] == 'show' else 'active'), \
                patch.object(w, 'diagnose') as diagnose, \
                patch.object(w.subprocess, 'run') as run:
            for index in range(3):
                with patch.object(w.time, 'monotonic', return_value=1000 + index * 60), \
                        patch.object(w, 'request', side_effect=[{'status': 'ok'},
                                     [{'id': 0, 'is_processing': False}], TimeoutError('GPU hung')]) as request:
                    w.main()
                    self.assertEqual(request.call_args.args[0], '/completion')
            diagnose.assert_called_once()
            run.assert_called_once_with(['systemctl', 'try-restart', w.SERVICE], check=True, timeout=90)
            self.assertEqual(json.loads((Path(directory) / 'state.json').read_text()), {})


if __name__ == '__main__':
    unittest.main()
