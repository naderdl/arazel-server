"""Generate a private Xray config from a VLESS WebSocket/TLS subscription."""

import base64
import json
import os
import tempfile
import uuid
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen


def build_config(payload):
    try:
        encoded = "".join(payload.split())
        decoded = base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True).decode("utf-8")
    except (ValueError, UnicodeError) as exc:
        raise ValueError("Subscription must be a base64 VLESS link list") from exc

    outbounds = [{"tag": "block", "protocol": "blackhole", "settings": {}}]
    for index, link in enumerate(filter(None, (line.strip() for line in decoded.splitlines())), 1):
        try:
            uri = urlsplit(link)
            query = parse_qs(uri.query)
            if uri.scheme != "vless" or query.get("security") != ["tls"] or query.get("type") != ["ws"]:
                raise ValueError
            node_id = str(uuid.UUID(uri.username or ""))
            address, port = uri.hostname, uri.port
            if not address or not port:
                raise ValueError
            host = query.get("host", [address])[0]
            sni = query.get("sni", [address])[0]
            path = query.get("path", ["/"])[0]
            fingerprint = query.get("fp", [""])[0]
            if not host or not sni or not path:
                raise ValueError
        except (ValueError, TypeError) as exc:
            raise ValueError(f"Unsupported or invalid node at line {index}") from exc

        tls = {"serverName": sni, "allowInsecure": False}
        if fingerprint:
            tls["fingerprint"] = fingerprint
        outbounds.append(
            {
                "tag": f"node-{index}",
                "protocol": "vless",
                "settings": {"vnext": [{"address": address, "port": port, "users": [{"id": node_id, "encryption": "none"}]}]},
                "streamSettings": {
                    "network": "ws",
                    "security": "tls",
                    "wsSettings": {"path": path, "host": host},
                    "tlsSettings": tls,
                },
            }
        )

    if len(outbounds) == 1:
        raise ValueError("Subscription contains no nodes")
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"tag": "roadie-socks", "listen": "0.0.0.0", "port": 10808, "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}],
        "outbounds": outbounds,
        "routing": {
            "rules": [{"type": "field", "inboundTag": ["roadie-socks"], "balancerTag": "nodes"}],
            "balancers": [{"tag": "nodes", "selector": ["node-"], "strategy": {"type": "leastPing"}, "fallbackTag": "block"}],
        },
        "observatory": {"subjectSelector": ["node-"], "probeURL": "https://www.youtube.com/generate_204", "probeInterval": "30s", "enableConcurrency": True},
    }


def write_config(path, payload):
    config = build_config(payload)
    path = Path(path)
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=".xray-", suffix=".json", delete=False) as file:
            temp_path = Path(file.name)
            json.dump(config, file, indent=2)
            file.write("\n")
        os.chmod(temp_path, 0o600)
        if os.name == "posix":
            os.chown(temp_path, 65532, 65532)  # Pinned Xray image runs as nonroot.
        os.replace(temp_path, path)
    finally:
        if temp_path and temp_path.exists():
            temp_path.unlink()
    return len(config["outbounds"]) - 1


def fetch_subscription():
    subscription_url = os.environ.get("XRAY_SUBSCRIPTION_URL")
    if not subscription_url or not subscription_url.startswith("https://"):
        raise SystemExit("Set XRAY_SUBSCRIPTION_URL to the HTTPS subscription URL")
    try:
        with urlopen(subscription_url, timeout=30) as response:
            payload = response.read(2_000_001)
        if len(payload) > 2_000_000:
            raise ValueError("Subscription too large")
    except Exception:
        raise ValueError("Subscription fetch failed") from None
    return payload.decode("utf-8")


if __name__ == "__main__":
    try:
        count = write_config(Path(__file__).with_name("config.json"), fetch_subscription())
    except (ValueError, UnicodeError):
        raise SystemExit("Subscription conversion failed; existing config retained") from None
    print(f"Generated private Xray config with {count} nodes")
