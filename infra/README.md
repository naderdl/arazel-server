# Infra

Stock NGINX owns TCP 80/443/30033 and UDP 9987/2456–2458. `docker-gen` discovers opted-in labels; the private controller validates and activates one complete root configuration. Stock Certbot handles HTTP-01 issuance and renewal. Grafana retains its native login; Huginn uses the private BCrypt usersfile. Application containers publish no public host ports. HTTPS application routes require matching TLS SNI and HTTP Host (case-insensitive); crossing two configured hostnames is rejected with HTTP 421.

## Host prerequisites

Deploy manually on rootful **Linux x86-64 Docker**. Game transparency is IPv4-only. Docker Desktop's external forwarding is not evidence of deployed-server source preservation. The exercised local baseline is Docker Engine **29.8.1** and Compose **5.5.1**; use at least that tested baseline. Earlier versions are unverified, not claimed unsupported historically. Dedicated game connections use `gw_priority: 100`; declaration order is not the gateway contract.

The host needs Bash, Docker CLI, `iproute2`, **iptables-nft**, `nftables`, coreutils and util-linux (`flock`). Run all commands below from the checkout root. They are operator instructions, not an automated deployment.

Before allocation, inspect Docker networks, host/VPN routes, policy rules and firewall intent:

```sh
docker network ls
ip -4 route show table all
ip -4 rule show
sudo iptables -t nat -S
sudo iptables -t mangle -S
```

Reserved scope: `ingress-ts6` / `az-ts6` / `172.29.87.0/24`, `ingress-valheim` / `az-valheim` / `172.29.88.0/24`, mark `0x7cf3`, priority `31087`, table `31987`, and `ARAZEL_INGRESS_*` chains. The helper refuses overlaps, unavailable Docker/host-route inventories, incompatible/unowned networks and policy collisions. Do not delete someone else's network or rule to make it pass. Ordinary Docker masquerading must remain enabled; exemptions apply only to the supported game tuples, with unconditional dispatch before masquerading.

The helper requires `net.ipv4.ip_forward=1` and global `net.ipv4.conf.all.rp_filter=0`; it refuses to change those global settings itself. Review the host's anti-spoofing/VPN policy before changing the global reverse-path setting: interfaces that relied solely on the global setting need an explicit policy. Leave other interfaces' settings intact. The helper adjusts only its two game bridges. Persist approved prerequisites in your existing sysctl configuration; do not blindly overwrite another service's file.

```sh
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo install -m 0755 infra/nginx/transparent-routing.sh /usr/local/sbin/arazel-transparent-routing
sudo install -m 0644 infra/nginx/arazel-ingress-routing.service /etc/systemd/system/arazel-ingress-routing.service
sudo systemctl daemon-reload
sudo /usr/local/sbin/arazel-transparent-routing setup
sudo systemd-analyze verify /etc/systemd/system/arazel-ingress-routing.service
sudo systemctl enable --now arazel-ingress-routing.service
sudo /usr/local/sbin/arazel-transparent-routing check
sudo /usr/local/sbin/arazel-transparent-routing request-readiness
```

Enabling the unit adds Docker's wants relationship; the helper itself uses `Requires`, `After` and `PartOf` for Docker stop/start/restart propagation. It runs the foreground root helper with `CAP_NET_ADMIN`; NGINX/controller have no `NET_ADMIN`. Root answers only a fresh bounded nonce/check request through `/run/arazel-ingress`, mounted read-only into ingress/controller. There is no general privileged API or stale-ready-file bypass. Preparing host policy does not bind public sockets, so it can precede the downtime window.

Create `proxy` and `monitoring` if they do not already exist as your intended external networks. Do not recreate existing networks used by live applications.

## Private settings and usersfile

Copy `.env.example` to `infra/.env`; set real Grafana credentials/domains and ACME contact. Keep `INGRESS_ENVIRONMENT=production` and the lab prefix empty. Lab-only bridge/subnet/prefix overrides are rejected in production.

Migrate an existing BCrypt usersfile **byte-for-byte**, without displaying hashes or re-encoding it:

```sh
sudo install -m 0640 -o root -g 101 infra/traefik/usersfile infra/nginx/usersfile
```

If creating a new file instead, use the host's `htpasswd` utility (`apache2-utils` on Debian), which prompts for the password:

```sh
htpasswd -cB infra/nginx/usersfile your-user
sudo chown root:101 infra/nginx/usersfile
sudo chmod 0640 infra/nginx/usersfile
```

The fixed destination must be a regular file readable by the pinned NGINX worker (UID/GID 101), containing at least one BCrypt entry with a supported cost of 04–31. Standard blank lines are allowed; empty, malformed or unreadable files reject the whole candidate before activation. It is ignored by Git and mounted read-only. Do not put passwords in labels, command arguments or commit history.

Docker inspection responses can contain application environment secrets. Read-only Docker access is not secret-free: keep the metadata filter/controller private, and never publish raw `docker inspect`, Compose environment output or discovery diagnostics containing credentials. Existing Alloy host/cAdvisor collectors retain their prior privileged configuration; this ingress migration does not sandbox them.

## Explicit CA consent and staging

`ACME_ACCEPT_TERMS=false` means no account or order requests. Select the directory and review its current terms yourself before setting it to `true`; `ACME_TERMS_DIRECTORY` must exactly match `ACME_DIRECTORY`. Never reuse staging state for production.

For a public staging trial, edit the private env file to:

```dotenv
ACME_ENVIRONMENT=staging
ACME_DIRECTORY=https://acme-staging-v02.api.letsencrypt.org/directory
ACME_TERMS_DIRECTORY=https://acme-staging-v02.api.letsencrypt.org/directory
ACME_ACCEPT_TERMS=false
```

Only after your explicit acceptance, set consent to `true`. Production uses environment `production` and directory/consent target `https://acme-v02.api.letsencrypt.org/directory`. The named volumes are `infra_certbot_staging` and `infra_certbot_production`; changing issuer requires recreating NGINX, controller and Certbot with the matching mounts. Staging certificates are intentionally untrusted by ordinary clients: verify against the appropriate staging trust chain, not by disabling TLS verification.

Public A records, inbound TCP 80/443 and the game ports must reach this host. Remove stale AAAA records unless IPv6 web reachability has been verified independently; the game proxy has no IPv6 baseline. Certbot needs ordinary outbound DNS/HTTPS. No public CA account, terms acceptance or public order was exercised by the isolated Pebble tests.

Build before the cutover window:

```sh
docker compose --env-file infra/.env -f infra/compose.yml config --quiet
docker compose --env-file infra/.env -f infra/compose.yml build nginx
```

Follow [the manual cutover](../docs/MIGRATION.md) before starting the new stack on an existing server. For a fresh prepared host:

```sh
docker compose --env-file infra/.env -f infra/compose.yml up -d
```

## Label contract

Only running, explicitly `ingress.enabled: "true"` containers from Compose projects `infra`, `ts` and `valheim` participate. HTTP fields are `ingress.http.network: proxy`, `ingress.http.host`, numeric `ingress.http.port`, and `ingress.http.auth: none|huginn`. The generated snapshot rejects malformed/duplicate ownership and unsupported fields; it never accepts raw NGINX snippets or selects the first attached NIC.

| Service | HTTP hostname / backend port / auth | Logical game network and port pairs |
| --- | --- | --- |
| Grafana (`infra/lgtm`) | `GRAFANA_DOMAIN` / 3000 / none (native login) | none |
| Huginn (`valheim/valheim`) | `VALHEIM_DOMAIN` / 3000 / huginn | `ingress-valheim`, UDP `2456:2456,2457:2457,2458:2458` |
| Manager frontend | `TS_MANAGER_DOMAIN` / 80 / none (native login), enabled only by `TS_MANAGER_PUBLIC=true` | none |
| TS6 | none | `ingress-ts6`, UDP `9987:9987`, TCP `30033:30033` |

Streams use `ingress.stream.network` and comma-separated `ingress.stream.udp` / `ingress.stream.tcp` listener:backend pairs from that exact inventory. Manager backend, Roadies, Xray and Alloy have no public ingress route. Existing monitoring labels/private connections are unchanged.

## Certificate ownership and repair

Certbot alone writes `/etc/letsencrypt` and the challenge webroot. Its read-only mounted wrapper is invoked through `/bin/sh`, so checkout executable bits are not required. Preserve its **entire** tree, including accounts, renewal metadata, archive files and live symlinks. Ingress/controller mount it read-only. The selected validated root's sorted `# ingress-certificate:` records are the sole issuance inventory; disabling a hostname stops future scheduling after its removal is activated, without deleting its old lineage.

Inventory polling is **30 seconds**, normal per-host renewal checks **12 hours**, failed-host retries **5 minutes**. Each invocation is bounded to **900 seconds**, including termination escalation. Timing/forced-renewal overrides are lab-only. One host's failure does not starve the others. Missing lineages use `certonly`; existing ones use per-name `renew`. Saved CA-directory mismatches are rejected, not silently migrated.

NGINX loads one matching immutable native Certbot archive generation. The controller fingerprints configuration and certificate/key bytes; a hook token is only a hint. It validates with `nginx -t`, selects atomically, sends a local HUP and acknowledges a real new worker generation. Partial publication, failed validation/HUP or missing acknowledgement retain running workers and retry forward. **Do not restore old live links or copy leaves into a separate certificate store.** Lost certificate volumes require fresh rejecting bootstrap and reissuance, not a dummy certificate or plaintext application fallback.

Check expiry from an external client with the correct trust chain:

```sh
HOST=your-web-host.example
# Run this block in Bash so a failed handshake cannot be hidden by the pipe.
set -o pipefail
openssl s_client -connect "$HOST:443" -servername "$HOST" -verify_hostname "$HOST" -verify_return_error </dev/null |
  openssl x509 -noout -serial -dates -checkend 2592000
```

A nonzero result is not a successful expiry check; inspect handshake/expiry errors. Grafana/Alloy remain on private monitoring connections; avoid putting credentials or challenge bodies into diagnostics.

```sh
docker compose --env-file infra/.env -f infra/compose.yml logs --tail 100 nginx controller certbot socket-proxy
sudo journalctl -u arazel-ingress-routing.service --since '15 minutes ago'
sudo /usr/local/sbin/arazel-transparent-routing check
```

Cold startup requires a fresh controller readiness record for this ingress incarnation (host boot ID plus PID 1 start ticks). A recent record persisted by a previous container cannot authorize its selected TLS configuration; the new controller must validate current Docker metadata, certificate lineage and CA settings before NGINX starts.

Controller outage freezes configuration/certificate activation; Certbot outage freezes issuance/renewal. A failed Docker container inspection rejects the entire metadata snapshot even when list/version requests succeed; cached or partial output cannot establish fresh startup readiness. Restore the correct usersfile, Docker metadata access, CA settings, DNS/HTTPS egress or completed publication, then restart the failed role; do not hide validation errors or delete account state. A missed hook is repaired by periodic fingerprint reconciliation. Keep the routing service healthy before restarting ingress; ingress startup and every stream candidate require a fresh root check.

UDP session inactivity is bounded at two minutes; workers have a 30-second shutdown bound. Reload/removal can interrupt old UDP sessions or TCP transfers at that bound: it is not a lossless game failover promise. Gameplay, voice, transfer and music validation belong to the operator.
