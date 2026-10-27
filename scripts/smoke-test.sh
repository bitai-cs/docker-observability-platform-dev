#!/usr/bin/env bash
# End-to-end smoke test: sends traces, metrics and logs with telemetrygen (no
# application involved) and checks that each signal arrived.
#
# Run on the Docker server, in the repository folder, after `docker compose up -d`:
#   ./scripts/smoke-test.sh
#
# Needs: docker, curl, and a populated .env. The telemetrygen flags used here
# must be checked once with `docker run --rm <image> traces --help`
# (Docker-service-readyness-verification-6.md).

set -u
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "FAIL: .env not found (copy .env.example to .env)"; exit 1; fi
set -a; . ./.env; set +a

NETWORK="observability-net"
IMAGE="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:${TELEMETRYGEN_TAG:?TELEMETRYGEN_TAG missing in .env}"
SERVICE="smoke-test"
NAMESPACE="smoke"
WAIT_SECONDS=30
failures=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

echo "== 1. Collector health"
if curl -fsS "http://${BIND_ADDRESS}:${COLLECTOR_HEALTH_PORT}/" >/dev/null; then pass "Collector health endpoint answers"; else fail "Collector health endpoint (http://${BIND_ADDRESS}:${COLLECTOR_HEALTH_PORT}/)"; fi

echo "== 2. Sending telemetry with telemetrygen (${IMAGE})"
ATTRS=(--otlp-endpoint otel-collector:4317 --otlp-insecure --service "${SERVICE}" --otlp-attributes "service.namespace=\"${NAMESPACE}\"" --otlp-attributes "deployment.environment.name=\"development\"")
docker run --rm --network "${NETWORK}" "${IMAGE}" traces  --traces 20  "${ATTRS[@]}" || fail "telemetrygen traces"
docker run --rm --network "${NETWORK}" "${IMAGE}" metrics --metrics 20 "${ATTRS[@]}" || fail "telemetrygen metrics"
docker run --rm --network "${NETWORK}" "${IMAGE}" logs    --logs 20    "${ATTRS[@]}" || fail "telemetrygen logs"

echo "== 3. Waiting ${WAIT_SECONDS}s for batching and ingestion"
sleep "${WAIT_SECONDS}"

echo "== 4. Metrics in Prometheus (OTLP receiver)"
prom=$(curl -fsS -G "http://${BIND_ADDRESS}:${PROMETHEUS_PORT}/api/v1/query" \
  --data-urlencode "query=count(target_info{service_name=\"${SERVICE}\", service_namespace=\"${NAMESPACE}\"})") || prom=""
if echo "${prom}" | grep -q '"result":\[{'; then pass "target_info with promoted service_name/service_namespace labels found"; else fail "no target_info for ${NAMESPACE}/${SERVICE} in Prometheus: ${prom}"; fi

echo "== 5. Traces in Tempo (through Grafana's data source proxy)"
G="http://${BIND_ADDRESS}:${GRAFANA_PORT}/api/datasources/proxy/uid"
tempo=$(curl -fsS -G -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "${G}/tempo/api/search" \
  --data-urlencode "tags=service.name=${SERVICE}" --data-urlencode "limit=5") || tempo=""
if echo "${tempo}" | grep -q '"traceID"'; then pass "traces for ${SERVICE} found in Tempo"; else fail "no traces for ${SERVICE} in Tempo: ${tempo}"; fi

echo "== 6. Logs in Loki (through Grafana's data source proxy)"
loki=$(curl -fsS -G -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "${G}/loki/loki/api/v1/query" \
  --data-urlencode "query={service_name=\"${SERVICE}\"}" --data-urlencode "limit=5") || loki=""
if echo "${loki}" | grep -q '"values"'; then pass "logs for ${SERVICE} found in Loki"; else fail "no logs for ${SERVICE} in Loki: ${loki}"; fi

echo "== 7. Tempo span metrics in Prometheus (metrics-generator)"
sm=$(curl -fsS -G "http://${BIND_ADDRESS}:${PROMETHEUS_PORT}/api/v1/query" \
  --data-urlencode "query=count(traces_spanmetrics_calls_total{service=\"${SERVICE}\"})") || sm=""
if echo "${sm}" | grep -q '"result":\[{'; then pass "span metrics for ${SERVICE} found"; else fail "no span metrics yet (can take a minute more): ${sm}"; fi

echo
if [ "${failures}" -eq 0 ]; then echo "Smoke test passed."; else echo "Smoke test: ${failures} check(s) failed."; fi
exit "${failures}"
