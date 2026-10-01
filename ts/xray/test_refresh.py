import base64
import tempfile
import unittest
from pathlib import Path

from refresh import refresh_config


LINK = "vless://11111111-2222-4333-8444-555555555555@node.example:443?security=tls&type=ws&path=%2Fmusic&host=front.example&sni=front.example"
PAYLOAD = base64.b64encode(LINK.encode()).decode()


class RefreshTests(unittest.TestCase):
    def test_changed_config_is_validated_then_restarted(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            events = []
            result = refresh_config(config, PAYLOAD, lambda path: events.append(("validate", path.name)), lambda: events.append(("restart", None)))
            self.assertEqual(result, "restarted")
            self.assertEqual(events, [("validate", "config.candidate.json"), ("restart", None)])
            self.assertTrue(config.exists())
            self.assertFalse(config.with_name("config.candidate.json").exists())

    def test_unchanged_config_does_not_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            refresh_config(config, PAYLOAD, lambda path: None, lambda: None)
            events = []
            result = refresh_config(config, PAYLOAD, lambda path: events.append("validate"), lambda: events.append("restart"))
            self.assertEqual(result, "unchanged")
            self.assertEqual(events, [])

    def test_failed_validation_preserves_active_config(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text("working", encoding="utf-8")

            def reject(_path):
                raise ValueError("invalid")

            with self.assertRaises(ValueError):
                refresh_config(config, PAYLOAD, reject, lambda: self.fail("restarted"))
            self.assertEqual(config.read_text(encoding="utf-8"), "working")
            self.assertFalse(config.with_name("config.candidate.json").exists())

    def test_failed_restart_preserves_active_config_for_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text("working", encoding="utf-8")

            def fail_restart():
                raise RuntimeError("Docker unavailable")

            with self.assertRaises(RuntimeError):
                refresh_config(config, PAYLOAD, lambda _path: None, fail_restart)
            self.assertEqual(config.read_text(encoding="utf-8"), "working")

    def test_interrupted_activation_restores_previous_config_before_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            backup = config.with_name("config.previous.json")
            config.write_text("unconfirmed", encoding="utf-8")
            backup.write_text("working", encoding="utf-8")

            def validate(_path):
                self.assertEqual(config.read_text(encoding="utf-8"), "working")

            self.assertEqual(refresh_config(config, PAYLOAD, validate, lambda: None), "restarted")
            self.assertFalse(backup.exists())


if __name__ == "__main__":
    unittest.main()
