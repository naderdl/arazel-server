# TeamSpeak 6

1. Copy `.env.example` to `.env`. Set Manager secrets and hostname. Accept the [TS6 license](https://github.com/teamspeak/teamspeak6-server#readme) yourself before setting `TSSERVER_LICENSE_ACCEPTED=accept`.
2. Create `data/ts6`, `data/manager`, and `data/roadie-dj1` through `data/roadie-dj3`. Copy each `roadie/roadie-djN.example.json` to its matching `data/roadie-djN/config.json`; replace channel **name**, admin UID, and music group placeholders.
3. Set `XRAY_SUBSCRIPTION_URL` in ignored `.env`. Follow [Xray for the music bots](XRAY-SUBSCRIPTION.md) to create the private config and enable six-hour refresh on Linux.
4. Build Roadie with `docker compose --env-file ts/.env -f ts/compose.yml build roadie-dj1`. Start TS6 first; collect its first admin key privately and create your channels/groups.
5. Keep `TS_MANAGER_PUBLIC=false`. Start Manager with `ts/bootstrap.yml`, reach its loopback port 13000 through an SSH tunnel, create the admin, and add the private TS6 WebQuery connection. Then set `TS_MANAGER_PUBLIC=true` and recreate the frontend with only `compose.yml`.
6. Validate the generated file with `docker compose --env-file ts/.env -f ts/compose.yml run --rm --no-deps xray run -test -config /usr/local/etc/xray/config.json`. Start Xray and Roadies after their private configs are ready. Verify voice on UDP 9987, files on TCP 30033, Manager login, and music playback.

## Player password and Roadie access

TS6 keeps the player password and server groups in `data/ts6`, not in Compose. On first setup, do this in the TS6 client while the server has no password:

1. Let all three Roadies connect once. Create a **Roadies** server group, grant it `b_virtualserver_join_ignore_password`, and add only DJ 1, DJ 2, and DJ 3 to it. Do not give them Server Admin.
2. Set the virtual server password in **Edit Virtual Server**. Share it with players privately; keep it out of Git and Roadie configs.
3. Restart one Roadie and check it rejoins without a password. Test a new ordinary identity: it must need the password. The group, password, and Roadie identities persist in `data/ts6` and `data/roadie-djN`.

NGINX is the only public listener. Complete [infra host policy/network preparation](../infra/README.md) before starting TS6: its dedicated `ingress-ts6` connection has the higher gateway priority, while `ts-private` keeps `ts6.docker` for Manager/Roadies and monitoring stays private. Existing container gateway changes require recreation, not a label-only restart. `data/`, `.env`, and `xray/config.json` stay outside Git. Check locally with `pwsh -NoProfile -File scripts/test-ts6-config.ps1`.

Monitoring: Alloy collects logs and container metrics for every TS service, and scrapes TS6's private `:9187/metrics` endpoint. The Xray refresh service writes to the host journal, which Alloy sends to LGTM. Per-packet voice metrics remain off to avoid extra work on the voice path.

## Private Manager bootstrap

With `TS_MANAGER_PUBLIC=false`, no public Manager route/certificate is requested after the controller reconciles its labels. Keep the backend API on `ts-private`; never publish 3001 or TS6 Query/SSH Query/metrics ports. Use the explicit loopback override until the admin and private WebQuery connection are configured:

```sh
docker compose --env-file ts/.env -f ts/compose.yml -f ts/bootstrap.yml up -d ts6 manager-backend manager-frontend
ssh -L 127.0.0.1:13000:127.0.0.1:13000 your-server
```

Open `http://127.0.0.1:13000` locally. After setup, set `TS_MANAGER_PUBLIC=true` in the private env file and recreate the frontend **without** the bootstrap override:

```sh
docker compose --env-file ts/.env -f ts/compose.yml up -d --force-recreate manager-frontend
```

Its validated `ingress.http.*` labels then add the hostname to Certbot's inventory, subject to the infra CA consent gate. Disabling it stops future scheduling after removal is activated; old certificates are retained. Native Manager authentication is not replaced by Huginn Basic auth. See [cutover and operator gameplay checks](../docs/MIGRATION.md) for expected downtime and external validation.
