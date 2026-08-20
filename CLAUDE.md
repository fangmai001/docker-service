# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of self-hosted Docker Compose service definitions. Each top-level
folder is one independent service — nothing is shared between them, and each
can be deployed on its own.

Currently:

| Service | Description |
| --- | --- |
| `gitlab/` | GitLab EE (Free-tier features, no license) + optional GitLab Runner |

## Repo-wide conventions

- Every service folder is self-contained: its own `docker-compose.yml`,
  `.env.example`, and `README.md`.
- All tunable values (hostnames, ports, passwords, versions) live in `.env` —
  never hardcode them into `docker-compose.yml`. Compose files reference them
  with `${VAR:-default}` fallbacks.
- `.env` itself is never committed, only `.env.example`. Copy it and edit
  before first use: `cp .env.example .env`.
- Runtime state is bind-mounted under each service's own `data/` (and
  `backups/` where relevant); both are gitignored. Treat these as persistent
  volumes, not disposable — don't delete/recreate them without checking with
  the user first, since they hold real service data (repos, DB, secrets).
- Dev/test environment is WSL2 (Ubuntu) + Docker Compose v5. Other Linux
  distros should work as-is; macOS needs extra care with bind-mount
  performance/permissions.

## Working in a service folder

Generic lifecycle (same pattern across all services):

```bash
cd <service>
cp .env.example .env    # edit values, especially passwords, before first run
docker compose up -d
docker compose logs -f <service-container-name>
```

There is no build/lint/test tooling in this repo — it's Compose configuration
only, so "testing a change" means actually bringing the stack up and checking
it behaves.

## gitlab/ specifics

- Image: `gitlab/gitlab-ee:19.2.2-ee.0` (EE image without a license = Free/CE
  feature set).
- `GITLAB_OMNIBUS_CONFIG` in `docker-compose.yml` is the single place that
  configures the container (external_url, SSH port, timezone, and the
  resource-saving tweaks below). Prefer editing values there over reaching
  into the container's `/etc/gitlab/gitlab.rb` directly, since the omnibus
  config gets reconciled from the compose env on every `reconfigure`.
- Host and container HTTP port **must match** (e.g. `8929:8929`, not
  `8929:80`) — `external_url` embeds the port, so GitLab's internal nginx
  listens on that exact port. Changing `GITLAB_HOST`/`GITLAB_HTTP_PORT`
  requires `docker compose up -d` again to trigger a reconfigure (~1–2 min).
- The compose file intentionally disables Prometheus/Grafana/KAS/
  Registry/gitlab-exporter and runs Puma in single-worker mode
  (`puma['worker_processes'] = 0`) to fit small-memory hosts. This is a
  single-machine test-environment tradeoff — don't "fix" it back to defaults
  without checking with the user, and remember to bump `worker_processes`
  back to `2` if this ever moves toward production use.
- Healthcheck turning `healthy` does not mean Rails is done booting — you'll
  still see a 502 "Waiting for GitLab to boot" page for a bit. Verify with the
  actual HTTP response instead of trusting healthcheck status:
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8929/users/sign_in
  # 200 = actually ready
  ```
- If the container restart-loops with `Reading unsupported config value xxx`
  in the logs, it means `GITLAB_OMNIBUS_CONFIG` references a setting removed
  in this GitLab version (e.g. `grafana['enable']`, removed since omnibus
  16.3) — remove the offending line and
  `docker compose up -d --force-recreate`.
- GitLab Runner is opt-in via Compose profile: `docker compose --profile
  runner up -d`. When registering the runner, use the host's real IP in the
  URL, not `localhost` — the runner is a separate container and `localhost`
  would resolve to itself.
- Backups via `gitlab-backup create`/`restore` do **not** include
  `/etc/gitlab` (secrets, `gitlab-secrets.json`) — that's bind-mounted at
  `./data/config` and must be backed up separately, or restored data can't be
  decrypted.
