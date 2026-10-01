# Infra

1. Copy `.env.example` to `.env`; set Grafana password, ACME email, and Grafana hostname.
2. Create `traefik/usersfile` with a BCrypt `user:hash` for the Valheim web dashboard.
3. Create external Docker networks `proxy` and `monitoring`.
4. Point your web hostnames at the host. Start with `docker compose --env-file infra/.env -f infra/compose.yml up -d` from the repo root.

Traefik owns TCP 80/443/30033 and UDP 2456–2458/9987. Application containers publish no host ports.
