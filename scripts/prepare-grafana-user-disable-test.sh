#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-vector}"
GRAFANA_URL="${GRAFANA_URL:-http://grafana.node-01}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
CLICKHOUSE_POD="${CLICKHOUSE_POD:-clickhouse-clickhouse-0-0-0}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-clickhouse}"
CLICKHOUSE_INSERT_TABLE="${CLICKHOUSE_INSERT_TABLE:-otel_logs_local}"
CLICKHOUSE_VERIFY_TABLE="${CLICKHOUSE_VERIFY_TABLE:-otel_logs_local}"
DELETE_DESCRIPTION="${DELETE_DESCRIPTION:-테스트 사용자 삭제 완료}"
TEST_LOGIN="${TEST_LOGIN:-deleted-user-test-$(date +%s)}"
TEST_PASSWORD="${TEST_PASSWORD:-ChangeMe123!}"
TEST_EMAIL="${TEST_EMAIL:-${TEST_LOGIN}@example.com}"

case "$TEST_LOGIN" in
  *[!A-Za-z0-9._-]*)
    echo "TEST_LOGIN must match [A-Za-z0-9._-]+" >&2
    exit 1
    ;;
esac

workdir="$(mktemp -d)"
response_file="$workdir/response.json"

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

request() {
  local method=$1
  local url=$2
  local payload=${3-}

  if [ -n "$payload" ]; then
    status="$(
      curl -sS -o "$response_file" -w '%{http_code}' \
        -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        -X "$method" \
        "$url" \
        --data "$payload"
    )"
  else
    status="$(
      curl -sS -o "$response_file" -w '%{http_code}' \
        -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        -H 'Accept: application/json' \
        -X "$method" \
        "$url"
    )"
  fi

  body="$(cat "$response_file")"
}

wait_for_grafana() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if curl -fsS -o /dev/null "$GRAFANA_URL/api/health"; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done

  echo "grafana api did not become ready in time" >&2
  exit 1
}

wait_for_grafana

request "POST" "$GRAFANA_URL/api/admin/users" "$(printf '{"name":"%s","email":"%s","login":"%s","password":"%s"}' "$TEST_LOGIN" "$TEST_EMAIL" "$TEST_LOGIN" "$TEST_PASSWORD")"
if [ "$status" = "200" ]; then
  user_id="$(sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$response_file" | head -n 1)"
elif [ "$status" = "412" ]; then
  request "GET" "$GRAFANA_URL/api/users/lookup?loginOrEmail=$TEST_LOGIN"
  [ "$status" = "200" ] || { echo "grafana user lookup failed: $body" >&2; exit 1; }
  user_id="$(sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$response_file" | head -n 1)"
else
  echo "grafana user creation failed: $body" >&2
  exit 1
fi

[ -n "$user_id" ] || { echo "could not parse grafana user id: $body" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec "$CLICKHOUSE_POD" -- \
  clickhouse-client \
    --user "$CLICKHOUSE_USER" \
    --password "$CLICKHOUSE_PASSWORD" \
    --query "
      INSERT INTO $CLICKHOUSE_INSERT_TABLE
      (Timestamp, Body, TraceId, SpanId, SeverityText, ServiceName, LogAttributes, ResourceAttributes)
      VALUES
      (
        now64(9),
        'grafana disable job test',
        '',
        '',
        'INFO',
        'HGI-OIDC',
        map('user', '$TEST_LOGIN', 'description', '$DELETE_DESCRIPTION'),
        map('service.name', 'HGI-OIDC')
      )
    "

log_count="$(
  kubectl -n "$NAMESPACE" exec "$CLICKHOUSE_POD" -- \
    clickhouse-client \
      --user "$CLICKHOUSE_USER" \
      --password "$CLICKHOUSE_PASSWORD" \
      --query "
        SELECT count()
        FROM $CLICKHOUSE_VERIFY_TABLE
        WHERE ServiceName = 'HGI-OIDC'
          AND LogAttributes['user'] = '$TEST_LOGIN'
          AND LogAttributes['description'] = '$DELETE_DESCRIPTION'
          AND Timestamp >= now() - INTERVAL 10 MINUTE
      " | tr -d '[:space:]'
)"

echo "grafana_user_id=$user_id"
echo "grafana_login=$TEST_LOGIN"
echo "grafana_email=$TEST_EMAIL"
echo "inserted_deleted_user_logs=$log_count"
