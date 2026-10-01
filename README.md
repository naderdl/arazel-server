# Game server

Three manual Docker Compose stacks: `infra/` (Traefik and monitoring), `valheim/`, and `ts/` (TeamSpeak 6).

1. Clone the repo on the host. Copy each `.env.example` to `.env` and set real values.
2. Create Docker networks `proxy` and `monitoring`.
3. Start `infra`, then `valheim`; set up `ts` using [its guide](ts/README.md).

Run `docker compose --env-file <stack>/.env.example -f <stack>/compose.yml config --quiet` locally for each stack. [Migration from the old server](docs/MIGRATION.md).

Worlds, admin IDs, passwords, installed mods, backups, and Xray credentials stay outside Git. Deployment is manual.
