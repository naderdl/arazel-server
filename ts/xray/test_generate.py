import base64
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from generate import build_config, write_config


class GenerateTests(unittest.TestCase):
    def test_builds_private_socks_with_all_nodes(self):
        links = "\n".join(
            f"vless://{uid}@node{i}.example:443?security=tls&type=ws&path=%2Fmusic&host=front.example&sni=front.example&fp=firefox#DJ{i}"
            for i, uid in enumerate(
                ("11111111-2222-4333-8444-555555555555", "e5e65b0e-1000-4000-8000-82370af6195b"), 1
            )
        )
        config = build_config(base64.b64encode(links.encode()).decode())
        self.assertEqual(config["inbounds"][0]["port"], 10808)
        self.assertEqual(config["outbounds"][0]["protocol"], "blackhole")
        self.assertEqual(len(config["outbounds"]), 3)
        self.assertEqual(config["outbounds"][1]["streamSettings"]["wsSettings"]["path"], "/music")
        self.assertEqual(config["outbounds"][1]["streamSettings"]["wsSettings"]["host"], "front.example")
        self.assertEqual(config["outbounds"][1]["streamSettings"]["tlsSettings"]["fingerprint"], "firefox")
        self.assertEqual(config["routing"]["balancers"][0]["fallbackTag"], "block")
        self.assertEqual(config["routing"]["balancers"][0]["strategy"]["type"], "leastPing")

    def test_invalid_input_keeps_previous_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text('{"keep":true}', encoding="utf-8")
            with self.assertRaises(ValueError):
                write_config(path, "vless://not-a-valid-node")
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"keep": True})

    @unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "Linux root ownership check")
    def test_generated_config_is_readable_by_nonroot_xray_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            link = "vless://11111111-2222-4333-8444-555555555555@node.example:443?security=tls&type=ws"
            write_config(path, base64.b64encode(link.encode()).decode())
            self.assertEqual(path.stat().st_uid, 65532)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
