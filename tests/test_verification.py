import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'verify', Path(__file__).resolve().parents[1] / 'scripts/verify_stack.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class VerificationTests(unittest.TestCase):
    def result(self, **payload):
        return {'content': [{'type': 'text', 'text': json.dumps(payload)}]}

    def test_real_open_port_output_is_accepted(self):
        self.assertIn('8000/tcp', v.scan_output(self.result(
            success=True, stdout='PORT STATE SERVICE\n8000/tcp open http-alt\n'), 8000))

    def test_configured_port_is_not_hardcoded_to_8000(self):
        self.assertIn('8001/tcp', v.scan_output(self.result(
            success=True, stdout='PORT STATE SERVICE\n8001/tcp open vcom-tunnel\n'), 8001))

    def test_closed_port_with_word_open_elsewhere_is_rejected(self):
        with self.assertRaises(ValueError):
            v.scan_output(self.result(success=True,
                stdout='Scan open ports\n8000/tcp closed http-alt\n'), 8000)

    def test_other_port_reported_open_does_not_confirm_the_requested_port(self):
        with self.assertRaises(ValueError):
            v.scan_output(self.result(success=True,
                stdout='PORT STATE SERVICE\n8001/tcp open vcom-tunnel\n'), 8000)

    def test_failed_command_cannot_pass_with_cached_open_output(self):
        with self.assertRaises(ValueError):
            v.scan_output(self.result(success=False, stdout='8000/tcp open http-alt'), 8000)

    def test_mcp_protocol_error_is_rejected(self):
        with self.assertRaises(ValueError):
            v.scan_output({'isError': True, 'content': []})

    def test_unstructured_prose_is_not_a_scan(self):
        with self.assertRaises(ValueError):
            v.scan_output({'content': [{'type': 'text',
                'text': 'The model should have port 8000/tcp open.'}]})


if __name__ == '__main__':
    unittest.main()
