# Manual migration from the old server

All steps below are for **you** to perform on the server. This repo runs no server commands.

1. Clone into a new directory, for example `/srv/arazel-server`. Fill the three private `.env` files and `infra/traefik/usersfile`. For AraZel set `VALHEIM_WORLD=AraZel`, `VALHEIM_NAME=AraZel`, and `GALE_SYNC_CODE=FHQEU1`.
2. Back up the live world on the server. Stop the old Valheim container and wait for its save to finish.
3. Copy the **entire** old `/srv/valheim/saves/worlds_local/AraZel/` directory into the new checkout's `valheim/saves/worlds_local/`. Copy old `/srv/valheim/saves/adminlist.txt` to new `valheim/saves/adminlist.txt`. Compare source and destination files; give UID/GID `1000:1000` write access.
4. Leave old mods, configs, ZIPs, and backups behind. The image and Gale profile create fresh game/mod files.
5. Stop old Caddy, then start new `infra` and `valheim`. Check HTTPS, game join, world buildings/progression, admin rights, and Gale mods. Set up TS6 separately using [its guide](../ts/README.md).

Do not start Valheim before the full world copy is verified. Keep the server backup. No automatic rollback is configured.
