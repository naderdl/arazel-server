"""Refresh the private Xray config from a host systemd service."""

import os
import subprocess
from pathlib import Path

from generate import fetch_subscription, write_config


ROOT = Path(__file__).resolve().parents[2]
CONFIG = Path(__file__).with_name("config.json")
COMPOSE = ["docker", "compose", "--env-file", str(ROOT / "ts/.env"), "-f", str(ROOT / "ts/compose.yml")]


def refresh_config(config, payload, validate, restart):
    config = Path(config)
    candidate = config.with_name("config.candidate.json")
    backup = config.with_name("config.previous.json")
    if backup.exists():
        os.replace(backup, config)  # Recover an interrupted activation.
    try:
        write_config(candidate, payload)
        if config.exists() and candidate.read_bytes() == config.read_bytes():
            return "unchanged"
        validate(candidate)
        if config.exists():
            os.link(config, backup)
        try:
            os.replace(candidate, config)
            restart()
        except Exception:
            if backup.exists():
                os.replace(backup, config)
            else:
                config.unlink(missing_ok=True)
            raise
        backup.unlink(missing_ok=True)
        return "restarted"
    finally:
        candidate.unlink(missing_ok=True)


def run_compose(stage, *args):
    try:
        subprocess.run([*COMPOSE, *args], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        raise RuntimeError(f"Xray {stage} failed") from None


def main():
    try:
        payload = fetch_subscription()
        result = refresh_config(
            CONFIG,
            payload,
            lambda _: run_compose("validation", "exec", "-T", "xray", "/usr/local/bin/xray", "run", "-test", "-config", "/usr/local/etc/xray/config.candidate.json"),
            lambda: run_compose("restart", "restart", "xray"),
        )
    except (ValueError, UnicodeError, RuntimeError) as exc:
        raise SystemExit(f"Xray refresh failed: {exc}") from None
    print("Xray config unchanged" if result == "unchanged" else "Xray config updated; container restarted")


if __name__ == "__main__":
    main()
