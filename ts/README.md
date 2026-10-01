# TeamSpeak 6

1. Copy `.env.example` to `.env`. Set Manager secrets and hostname. Accept the [TS6 license](https://github.com/teamspeak/teamspeak6-server#readme) yourself before setting `TSSERVER_LICENSE_ACCEPTED=accept`.
2. Create `data/ts6`, `data/manager`, and `data/roadie-dj1` through `data/roadie-dj3`. Copy each `roadie/roadie-djN.example.json` to its matching `data/roadie-djN/config.json`; replace channel, admin UID, and music group placeholders.
3. Copy `xray/config.example.json` to ignored `xray/config.json` and configure a real outbound. The example blocks traffic.
4. Build Roadie with `docker compose --env-file ts/.env -f ts/compose.yml build roadie-dj1`. Start TS6 first; collect its first admin key privately and create your channels/groups.
5. Keep `TS_MANAGER_PUBLIC=false`. Start Manager with `ts/bootstrap.yml`, reach its loopback port 13000 through an SSH tunnel, create the admin, and add the private TS6 WebQuery connection. Then set `TS_MANAGER_PUBLIC=true` and recreate the frontend with only `compose.yml`.
6. Start Roadies and Xray after their private configs are ready. Verify voice on UDP 9987, files on TCP 30033, Manager login, and music playback.

Only Traefik publishes host ports. `data/`, `.env`, and `xray/config.json` stay outside Git. Check locally with `pwsh -File scripts/test-ts6-config.ps1`.
