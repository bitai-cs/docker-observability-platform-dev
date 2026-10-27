# Storage

All telemetry data is **disposable**. Data lives in Docker named volumes (project `observability-platform`), not in this folder.

| Volume | Component | Mount | Retention |
|---|---|---|---|
| `observability-platform_tempo-data` | Tempo | `/var/tempo` | 72 h |
| `observability-platform_loki-data` | Loki | `/loki` | 72 h |
| `observability-platform_prometheus-data` | Prometheus | `/prometheus` | 3 days |
| `observability-platform_grafana-data` | Grafana | `/var/lib/grafana` | n/a (preferences, users) |
| `observability-platform_alertmanager-data` | Alertmanager | `/alertmanager` | default (silences, notification log) |

Mailpit has no volume configured: its messages are not kept when the container is re-created.

## Procedures

- **Stop, keep data:** `docker compose stop`
- **Delete all data:** `docker compose down -v` (affects every developer; announce first)
- **Delete one component's data:** `docker compose stop loki && docker volume rm observability-platform_loki-data`, then `docker compose up -d`
- **List volumes:** `docker volume ls --filter name=observability-platform`
