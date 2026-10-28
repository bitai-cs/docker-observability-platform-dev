# docker-observability-platform-dev

Shared **development** observability platform for a trusted LAN: developers send OpenTelemetry (OTLP) traces, metrics and logs to one Collector, then query, correlate and alert on them in Grafana. Not for production or internet-facing use.

Specification: `OpenTelemetry-Infrastructure-Specification` (latest version kept in the OTEL-Dev-Infrastructure project).

```text
Your services ── OTLP gRPC :4317 / HTTP :4318 ──► OpenTelemetry Collector (contrib)
                                                    ├─ traces  ► Tempo
                                                    ├─ metrics ► Prometheus (OTLP receiver)
                                                    └─ logs    ► Loki (/otlp)
Tempo metrics-generator ► Prometheus (span metrics, service graphs)
Prometheus rules ► Alertmanager ► Mailpit (mail inbox for alerts)
Grafana ► Tempo, Prometheus, Loki, Alertmanager
```

Applications talk only to the Collector, and only via OTLP. Prometheus scrapes only the platform's own components.

## Published ports (bound to `BIND_ADDRESS` from `.env`)

| Port | What |
|---|---|
| 4317 | OTLP gRPC |
| 4318 | OTLP HTTP |
| 13133 | Collector health check |
| 3000 | Grafana |
| 9090 | Prometheus UI/API |
| 9093 | Alertmanager UI |
| 8025 | Mailpit UI (login required) |

Tempo, Loki and the Collector's own metrics (`:8888`) are internal to the Docker network `observability-net`. No host firewall is configured: the trusted LAN is the security boundary.

## Pinned versions

Set in `.env` (see `.env.example`): Collector contrib 0.164.0, Tempo 3.1.1, Loki 3.7.9, Grafana 13.2.4, Prometheus v3.15.1, Alertmanager v0.34.1, Mailpit v1.32.0, telemetrygen v0.164.1. These versions were chosen as the newest of each line; their compatibility as a set is verified by the first run.

## Operator guide (on the Docker server)

**Prerequisites:** the host laptop stays awake while the platform is in use (closing the lid sleeps it and pauses the VM), and the server clock matches real time (`date -u` against a trusted clock; fix with `Docker-server-clock-step-commands.md` from the project if it drifts).

1. Clone the repository and enter it:
   ```bash
   git clone https://github.com/bitai-cs/docker-observability-platform-dev.git
   cd docker-observability-platform-dev
   ```
2. Create `.env` from the example and edit the Grafana administrator password (and `BIND_ADDRESS` if the server address changes). **Do this before the first `docker compose up -d`:** Grafana stores the administrator password in its volume the first time it starts, and editing `.env` afterwards does not change it (change it in Grafana instead). Also, if you load `.env` into your shell (`set -a; . ./.env; set +a`), do it after editing the file and repeat it after every edit: variables exported in the shell override `.env` for Compose.
   ```bash
   cp .env.example .env
   ```
3. Create the Mailpit login file (one `user:password` per line; never committed):
   ```bash
   printf 'alerts:choose-a-password\n' > secrets/mailpit-ui-auth
   ```
   Mailpit reads this file at start. After changing it: `docker compose restart mailpit`.
4. Validate and start:
   ```bash
   docker compose config --quiet && echo "compose file OK"
   docker compose up -d
   docker compose ps
   ```
   Prometheus, Grafana, Tempo and Mailpit show `healthy` after a minute or so (Mailpit's own image defines its check). The Collector, Loki and Alertmanager have no health status (their images have no shell or wget, or no health command; Alertmanager has none configured). Check the Collector with `curl http://<server>:13133/`, and Loki and the others in Grafana's dashboard "Collector and platform health" (`up` per component) or in Prometheus at `http://<server>:9090/targets`.
5. Run the smoke test (sends traces, metrics and logs with `telemetrygen`, no application needed):
   ```bash
   bash scripts/smoke-test.sh
   ```
6. In Grafana (`http://<server>:3000`, user and password from `.env`) create an individual account for each developer (Administration > Users and access > Users). Sign-up and anonymous access are off.
7. Update: `git pull`, then `docker compose up -d`.
8. Containers use the `on-failure` restart policy: they restart after a crash but **not** after a VM reboot or `docker compose stop`. After a VM reboot run `docker compose up -d`.

### Stop vs. delete data

- **Stop, keep data:** `docker compose stop` (or `docker compose down`). Data stays in the named volumes.
- **Delete all data:** `docker compose down -v`. This removes traces, metrics, logs, Grafana preferences and Alertmanager silences for **every** developer. Announce it first. Telemetry is disposable by design.

Volumes: `tempo-data`, `loki-data`, `prometheus-data`, `grafana-data`, `alertmanager-data` (see `storage/README.md`). Retention: traces 72 h, logs 72 h, metrics 3 days.

### Debug mode ("why didn't my span arrive?")

```bash
docker compose -f docker-compose.yml -f docker-compose.debug.yml up -d
docker compose logs -f otel-collector
# back to normal:
docker compose up -d
```

## Developer guide (on your own machine)

Point your application at the server and give it a stable identity:

```text
OTEL_SERVICE_NAME=orders-api
OTEL_EXPORTER_OTLP_ENDPOINT=http://<server-address>:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_RESOURCE_ATTRIBUTES=service.namespace=<your-team-or-name>,service.version=1.0.0,deployment.environment.name=development
```

- Use `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` and port `4318` if gRPC is blocked.
- For a container on the Docker server, join the network `observability-net` and use `http://otel-collector:4317`.
- `service.namespace` identifies the owning team or developer. This is a convention; the platform does not enforce it.
- Do not set `service.instance.id` statically; let the SDK generate it.
- Never put passwords, tokens, connection strings or personal data in attributes. The Collector masks common patterns as a safety net only.
- Every trace is kept (no sampling). Keep log attributes small; values over 4096 characters are truncated.

### Metric names in Prometheus

OTLP names are translated: dots become underscores and unit/type suffixes are added, for example `http.server.request.duration` (seconds) becomes `http_server_request_duration_seconds_bucket|count|sum`. Resource attributes are promoted to labels `service_name`, `service_namespace`, `service_instance_id`, `service_version`, `deployment_environment_name`. Applications have no `up` series (they push), so "service stopped reporting" is detected from `target_info`.

### Dashboards (Grafana folder "Observability")

Service overview (request rate, errors, latency), Service dependencies, Collector and platform health, Runtime health (.NET), Log explorer, Alert overview. The Runtime health dashboard uses `dotnet_*` metric names and has not been verified against a real application yet.

## Alerting

Rules live in `configs/prometheus/rules/` and are evaluated by Prometheus; Alertmanager sends mail to Mailpit (`http://<server>:8025`, login from `secrets/mailpit-ui-auth`).

| Alert | Condition | Severity |
|---|---|---|
| ServiceHighErrorRate | 5xx ratio > 5% for 5 min | warning |
| ServiceHighLatencyP95 | p95 request duration > 1 s for 5 min | warning |
| ServiceStoppedReporting | `target_info` seen in the last hour, absent for 5 min | warning |
| CollectorExportFailures | failed exports in the last 5 min | warning |
| CollectorRefusingData | refused data in the last 5 min | warning |
| PlatformComponentDown | scrape target down for 2 min | critical |

Silence or inspect alerts in Grafana (Alerting > Alertmanager data source) or in the Alertmanager UI (`http://<server>:9093`). To trigger **PlatformComponentDown** on purpose: `docker compose stop loki`, wait about 2.5 minutes plus Alertmanager's 30 s grouping delay, look in Mailpit, then `docker compose start loki`.

## Repository layout

```text
docker-compose.yml            platform definition
docker-compose.debug.yml      optional Collector debug exporter
.env.example                  settings and pinned versions (copy to .env)
configs/                      Collector, Tempo, Loki, Prometheus (+ rules), Alertmanager, Grafana
scripts/smoke-test.sh         telemetrygen end-to-end check
secrets/                      local, uncommitted (Mailpit login file)
storage/README.md             volumes and clean-up
```
