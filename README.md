# Game server

Three manual Docker Compose stacks: `infra/` (stock NGINX, docker-gen, Certbot and monitoring), `valheim/`, and `ts/` (TeamSpeak 6). The infrastructure targets rootful Linux x86-64 Docker; transparent game ingress is IPv4-only.

1. Clone the repo and copy each `.env.example` to its private `.env`; set real values without committing secrets.
2. Follow [the infra guide](infra/README.md) to check route/subnet conflicts, install the scoped routing service, prepare external networks and the private BCrypt usersfile. The exercised baseline is Engine 29.8.1 / Compose 5.5.1; dedicated game gateway selection must work at runtime.
3. For an existing server, follow [the forward-only manual migration](docs/MIGRATION.md). Prepare before downtime; do not start a second ingress on occupied public ports.
4. Start the prepared `infra`, then `valheim`; bootstrap TS6/Manager using [the TS guide](ts/README.md). CA terms acceptance and public staging/production issuance are operator actions, not enabled by default.

Render examples without private settings:

```powershell
foreach ($stack in 'infra','ts','valheim') {
    docker compose --env-file "$stack/.env.example" -f "$stack/compose.yml" config --quiet
}
pwsh -NoProfile -File scripts/test-ts6-config.ps1
docker compose --env-file infra/.env.example -f infra/compose.yml build nginx
docker image tag arazel-nginx:local arazel-nginx:local-gate
pwsh -NoProfile -File scripts/test-nginx-local.ps1 -Case all -Image arazel-nginx:local-gate
```

The integration runner uses owned isolated resources and local Pebble, not public CA orders or production game data. Keep the gate tag unchanged until every scenario finishes; concurrent rebuilds must not replace or delete the tested image. Individual selectors: `acme-lifecycle`, `discovery`, `web`, `transparency`, `routing-lifecycle`, `compose-boundary`. A successful subset is not the complete gate. Public DNS/firewall, server reboot/Docker restart, upstream NAT and real gameplay remain separate deployment checks.

Worlds, admin IDs, passwords, installed mods, backups and Xray credentials stay outside Git. Deployment, commits and remote synchronization are manual; no automatic rollback or application-data deletion is configured.
