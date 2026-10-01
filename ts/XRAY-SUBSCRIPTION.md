# Xray for the music bots

Xray is a private SOCKS proxy at `xray:10808` inside the TS Docker network. Roadie sends music downloads through it. It has no public port; TS6 voice traffic does not use it.

`xray/generate.py` fetches `XRAY_SUBSCRIPTION_URL` from `ts/.env` and turns the VLESS WebSocket/TLS links into **one** ignored `xray/config.json` containing all nodes. Xray probes them and selects a working node with `leastPing`. If none work, music downloads are blocked instead of going direct.

`xray/refresh.py` is run by the host's `xray-refresh.service`. It generates a candidate, checks it with the running Xray container, and restarts Xray only when a valid config has changed. A failed fetch or validation keeps the active config. `xray-refresh.timer` runs the service every six hours.

## Linux setup

1. Set `XRAY_SUBSCRIPTION_URL` in ignored `ts/.env`. Keep the URL private. Install host Python 3 and Docker Compose.
2. The units assume the clone is at `/root/arazel-server`. If yours is elsewhere, edit the three paths in `systemd/xray-refresh.service` before copying it.
3. Start Xray with the blocking example if no config exists yet, then install and run the units:

```sh
cd /root/arazel-server
test -f ts/xray/config.json || cp ts/xray/config.example.json ts/xray/config.json
docker compose --env-file ts/.env -f ts/compose.yml up -d xray
sudo cp ts/systemd/xray-refresh.service ts/systemd/xray-refresh.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xray-refresh.timer
sudo systemctl start xray-refresh.service
```

4. Enable persistent host journal collection, then restart Alloy: `sudo mkdir -p /var/log/journal && sudo journalctl --flush`, followed by `docker compose --env-file infra/.env -f infra/compose.yml restart alloy`.

Check runs with `journalctl -u xray-refresh.service -n 30`. Alloy sends TS container logs and this service's journal entries to LGTM as `service_name="xray-refresh"`.
