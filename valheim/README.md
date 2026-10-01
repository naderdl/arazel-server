# Valheim

1. Copy `.env.example` to `.env`; set password, server/world names, hostname, and Gale **server** profile code.
2. Put the world and `adminlist.txt` under `saves/` as shown in [the migration guide](../docs/MIGRATION.md). Create `server/` and `backups/` on the host.
3. Start with `docker compose --env-file valheim/.env -f valheim/compose.yml up -d` from the repo root.

Odin downloads the game and syncs mods/configs from Gale on startup. Players connect to the configured hostname on UDP 2456. Keep `saves/`, `server/`, and `backups/` outside Git.
