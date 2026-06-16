# MinIO overlay notes

이 오버레이는 Vector aggregator, ClickHouse, MinIO, Grafana를 함께 사용해 OTEL 로그를 보관/조회하는 구성을 담고 있다.

## 현재 구성 요약

- Vector는 `aws_s3` sink를 사용해 MinIO를 S3 호환 스토리지로 접근한다.
- ClickHouse sink는 `otel_logs`, `otel_traces`, `hyperdx_sessions` 테이블로 적재한다.
- Grafana는 ClickHouse datasource를 통해 ClickHouse 테이블과 MinIO 아카이브 로그를 조회한다.

## ClickHouse sink 이슈와 수정 사항

초기 ClickHouse 로그 적재는 `Timestamp` 파싱 오류로 실패했다.

대표 오류:

```text
Code: 27. DB::Exception: Cannot parse input ... (while reading the value of key Timestamp)
```

원인은 Vector ClickHouse sink에서 RFC3339/ISO8601 timestamp를 보내는데 `date_time_best_effort`가 빠져 있었기 때문이다.

현재는 아래 3개 sink에 `date_time_best_effort: true`를 추가해 수정했다.

- `clickhouse_logs`
- `clickhouse_traces`
- `clickhouse_sessions`

## MinIO 아카이브 저장 포맷

현재 MinIO 아카이브는 아래 형식으로 저장된다.

- sink 타입: `aws_s3`
- 인코딩: `encoding.codec: json`
- 압축: `compression: zstd`
- 경로 prefix: `otel-logs/year=%Y/month=%m/date=%d/`

중요: 실제 파일 내용은 newline-delimited JSON이 아니라 **배치 단위 JSON 배열(`[...]`)** 이다.

즉 ClickHouse에서 파일을 바로 행 단위로 읽는 것이 아니라, 문자열로 읽은 뒤 배열을 펼쳐야 한다.

## MinIO 로그를 ClickHouse에서 직접 조회하는 방식

현재 아카이브 조회는 `s3(...)` + `LineAsString` + `JSONExtractArrayRaw` 조합을 사용한다.

예시:

```sql
SELECT
    parseDateTime64BestEffortOrNull(JSONExtractString(event, 'Timestamp'), 9) AS ts,
    JSONExtractString(event, 'ServiceName') AS service,
    JSONExtractString(event, 'SeverityText') AS severity,
    JSONExtractString(event, 'TraceId') AS trace_id,
    JSONExtractString(event, 'SpanId') AS span_id,
    JSONExtractRaw(event, 'Body') AS body,
    JSONExtractRaw(event, 'LogAttributes') AS log_attributes,
    JSONExtractRaw(event, 'ResourceAttributes') AS resource_attributes
FROM
(
    SELECT arrayJoin(JSONExtractArrayRaw(raw)) AS event
    FROM s3(
        'http://minio-service:9000/otel-logs/otel-logs/year=2026/month=06/date=12/*',
        'minioadmin',
        'minioadmin',
        'LineAsString',
        'raw String',
        'zstd'
    )
)
ORDER BY ts DESC
LIMIT 200;
```

## ClickHouse 공통 VIEW

현재는 MinIO 일반 로그(`otel-logs`)와 Grafana 감사 로그(`grafana-audit`)를 공통 스키마로 노출하기 위해 `default.archive_logs_view` 를 사용한다.

이 VIEW는 아래 두 경로를 합쳐서 읽는다.

- `otel-logs/otel-logs/year=*/month=*/date=*/*`
- `audit-logs/grafana-audit/date=*/*`

노출 컬럼:

- `Timestamp`
- `ServiceName`
- `SeverityText`
- `TraceId`
- `SpanId`
- `Body`
- `log_type`
- `log_category`
- `LogAttributes`
- `ResourceAttributes`
- `archive_source`

`archive_source` 값으로 어떤 아카이브에서 온 로그인지 구분할 수 있다.

## Grafana 대시보드

`base/grafana-dashboards.yaml` 에서 MinIO 아카이브 조회용 대시보드를 프로비저닝한다.

현재 대시보드는 더 이상 `s3(...)`를 직접 호출하지 않고 `default.archive_logs_view` 를 조회한다.

생성된 대시보드:

- `MinIO log attribute filter`
  - 시간 범위 선택
  - `log_type`, `log_category` 선택
  - `archive_logs_view` 기반 통합 아카이브 로그 조회
- `MinIO log line search`
  - 시간 범위 선택
  - `search_text` 문자열 입력
  - `archive_logs_view` 기반 로그 본문 검색

초기에는 대시보드 JSON 안 SQL 문자열의 줄바꿈 이스케이프 문제로 ClickHouse에서 아래 오류가 발생했다.

```text
Code: 62. DB::Exception: Unrecognized token: \
```

현재는 대시보드 SQL/변수 쿼리를 한 줄 SQL로 정리해 해결했다.

## Grafana 보안 감사 로그 파이프라인

Grafana에서 생성되는 인증, 권한, 개인정보 관련 보안 로그는 Grafana Pod 내부의 Vector sidecar가 수집한다.

구성 요소:

- Grafana:
  - `GF_LOG_MODE=console file`
  - `GF_PATHS_LOGS=/var/log/grafana`
  - `GF_SERVER_ROUTER_LOGGING=true`
- Vector sidecar:
  - `/var/log/grafana/*.log` 파일 tail
  - 인증(`login`, `logout`, `auth*`)
  - 권한(`accesscontrol`, `permission`, `/api/admin`, `/api/access-control`)
  - 개인정보 관련 사용자 API(`/api/user`, `/api/users`, `/api/org/users`, `/api/teams`, `uname=`, `email=`) 필터
- MinIO sink:
  - 버킷: `audit-logs`
  - prefix: `grafana-audit/date=%Y-%m-%d/`
  - 인코딩: `json`
  - 압축: `zstd`

즉 일반 OTEL 로그는 `otel-logs` 버킷으로, Grafana 보안 감사 로그는 `audit-logs` 버킷으로 분리 저장한다.

## Azure Blob Storage 전환 시 영향

Vector의 transform/encoding/compression이 동일하면 파일 내부의 논리 스키마는 동일하게 유지된다.

즉 아래는 그대로 유지 가능하다.

- `arrayJoin(JSONExtractArrayRaw(raw))`
- `Timestamp`, `Body`, `LogAttributes`, `ResourceAttributes` 파싱
- `log_type`, `log_category` 필터
- `Body` 문자열 검색

달라지는 부분은 storage 함수와 인증/경로뿐이다.

- MinIO/S3: `s3(...)`
- Azure Blob: `azureBlobStorage(...)`

저장 포맷이 동일하다면 ClickHouse/Grafana 쿼리는 storage 접근부만 바꿔 거의 같은 방식으로 재사용할 수 있다.
