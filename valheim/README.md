# Valheim

1. Copy `.env.example` to `.env`; set password, server/world names, hostname, and Gale **server** profile code. Complete [infra routing/network preparation](../infra/README.md) first; `ingress-valheim` must exist with the scoped policy and higher game gateway priority.
2. Put the world and `adminlist.txt` under `saves/` as shown in [the migration guide](../docs/MIGRATION.md). Create `server/` and `backups/` on the host.
3. Start with `docker compose --env-file valheim/.env -f valheim/compose.yml up -d` from the repo root.

Odin downloads the game and syncs mods/configs from Gale on startup. Players connect to the configured hostname over IPv4 on UDP 2456–2458; transparent NGINX binds and scoped host policy are configured to retain the client IP/port. Verify the deployed path externally. The web dashboard uses HTTPS/Huginn Basic auth via the private BCrypt usersfile, not a public 3000 binding. Existing gateway changes require clean container recreation and game downtime; follow [the forward-only cutover](../docs/MIGRATION.md). Keep `saves/`, `server/`, and `backups/` outside Git. Local echo/transport tests do not prove Steam registration, mods or real gameplay.
