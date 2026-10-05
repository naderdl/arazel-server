# Manual migration and ingress cutover

These commands are for **you** to perform on the server. Local infrastructure tests do not deploy, reboot the server, restart Docker, accept public CA terms or validate gameplay. Keep the backups and repair forward; no automatic rollback is configured.

## Preserve the application data first

1. Clone into a new directory, for example `/srv/arazel-server`. Prepare the three private `.env` files and `infra/nginx/usersfile`; migrate existing BCrypt bytes without displaying/re-encoding hashes. For AraZel keep `VALHEIM_WORLD=AraZel`, `VALHEIM_NAME=AraZel`, and `GALE_SYNC_CODE=FHQEU1`.
2. Back up live worlds, TS6/Manager/Roadie data, Xray/private configuration, passwords/admin IDs and monitoring data. Verify the backups before changing ingress or gateway assignments.
3. For migration from the old Valheim server, stop it cleanly and wait for its final save. Copy the **entire** old `/srv/valheim/saves/worlds_local/AraZel/` directory into the new checkout's `valheim/saves/worlds_local/`, and old `/srv/valheim/saves/adminlist.txt` to new `valheim/saves/adminlist.txt`. Compare source/destination files; give UID/GID `1000:1000` write access. Do not start Valheim before the full world copy is verified.
4. Leave obsolete game/mod files behind when migrating that old installation: the pinned game image and Gale server profile create fresh files. Keep all old backups. For an ingress-only cutover, keep existing `valheim/saves`, `server`, `backups`, `ts/data` and private configuration exactly in place; do not initialize replacement state.

## Prepare without occupying public sockets

Follow [infra prerequisites](../infra/README.md): rootful Linux x86-64, tested Compose/Engine baseline, reserved subnet/bridge/mark/table checks, reviewed sysctls, root routing helper and its Docker lifecycle unit. Preserve existing `proxy`/`monitoring` networks. The helper creates/verifies only its dedicated game networks and prepares policy without binding NGINX's public ports.

Build and render the new configuration while the old ingress still serves traffic:

```sh
docker compose --env-file infra/.env -f infra/compose.yml config --quiet
docker compose --env-file ts/.env -f ts/compose.yml config --quiet
docker compose --env-file valheim/.env -f valheim/compose.yml config --quiet
docker compose --env-file infra/.env -f infra/compose.yml build nginx
sudo /usr/local/sbin/arazel-transparent-routing check
```

Confirm public A records, no stale AAAA records, firewall TCP 80/443/30033 and UDP 9987/2456–2458, outbound DNS/HTTPS, the correct usersfile permissions and explicit directory-bound CA consent. Plan a public staging trial first, then production with separate state volumes. Keep `TS_MANAGER_PUBLIC=false` until the private bootstrap/admin setup is complete.

## Downtime window

Announce downtime: game container recreation changes reply gateways and disconnects players; existing TCP transfers/voice/music sessions may be interrupted. Save game state, then stop affected game workloads cleanly:

```sh
docker compose --env-file ts/.env -f ts/compose.yml stop
docker compose --env-file valheim/.env -f valheim/compose.yml stop
```

Stop the **old deployment's** Traefik container, or old Caddy when migrating that installation, using its original deployment file/service. The new Compose file no longer defines Traefik; do not guess a container name or run a global prune. Verify that its public sockets are released:

```sh
sudo ss -lntup
```

Start new infrastructure and recreate applications so dedicated gateway changes actually take effect:

```sh
docker compose --env-file infra/.env -f infra/compose.yml up -d
# Preserve the explicit Manager bootstrap override until its admin is configured.
docker compose --env-file ts/.env -f ts/compose.yml up -d --force-recreate
docker compose --env-file valheim/.env -f valheim/compose.yml up -d --force-recreate
sudo /usr/local/sbin/arazel-transparent-routing check
```

If Manager still needs bootstrap, use the `ts/bootstrap.yml` commands in [its guide](../ts/README.md), not a public uninitialized frontend. Keep native Grafana/Manager login boundaries separate from Huginn Basic auth.

Switching between staging and production changes the certificate volume and trusted directory. Stop/recreate the three ingress roles together, using the privately updated env file:

```sh
docker compose --env-file infra/.env -f infra/compose.yml stop controller certbot nginx
docker compose --env-file infra/.env -f infra/compose.yml up -d --force-recreate nginx controller certbot
```

Expect rejecting HTTPS bootstrap until the correct issuer's certificates become available. Do not reuse staging certificates for production or delete either account/archive volume. Traefik's old ACME volume is not imported, reused or automatically deleted.

## Validate externally, then remove obsolete runtime

Check game NIC default routes, fresh routing readiness, trusted HTTPS/expiry for every configured host, unknown Host/SNI rejection, HTTP-01 reachability outside auth, and missing/wrong/correct Huginn credentials. Verify Grafana and Manager native login, private Query/SSH Query/metrics/API isolation, Alloy private scraping and ingress/controller/Certbot error collection without credentials. Do not count a local Docker Desktop forwarding result as deployed transparency.

Only after new infrastructure is active and validated, remove obsolete Traefik/Caddy containers/service references from the old deployment. Keep backups, old CA state and application data. Do not use `down --volumes`, prune, restore old certificate links or copy a previous leaf to conceal a failed activation. Fix configuration, complete client publication or repair routing and retry forward using the [repair guide](../infra/README.md).

## Checks not exercised by the local gate

The operator must separately verify server reboot and real Docker restart propagation, public DNS/firewall, Let’s Encrypt staging then production after consent, upstream NAT, Steam registration/update, and external TS6 services. No such deployment check is claimed by a local integration PASS.

Your gameplay checklist:

- Valheim: join with the normal password; verify buildings/progression, admin rights, Gale mods and a clean save/restart.
- TS6: voice with two clients, visible original client addresses, normal password enforcement and file transfer.
- Manager/Grafana/Huginn: correct logins; Manager remains private until explicitly enabled.
- Roadies: all three rejoin through their saved identities, play music through Xray, and do not need or expose the player password.
