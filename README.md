# Vector Observability Stack

이 프로젝트는 Vector, ClickHouse, Grafana를 기반으로 하는 가시성(Observability) 파이프라인 구축을 위한 쿠버네티스 매니페스트 및 설정들을 포함하고 있습니다.

## 시스템 아키텍처

1.  **Dice Service**: OpenTelemetry(OTLP)로 계측된 샘플 Java 애플리케이션입니다. 로그, 트레이스, 메트릭을 Vector로 전송합니다.
2.  **Vector Aggregator**: OTLP 데이터를 수집하여 처리하고 ClickHouse 및 Azure Blob Storage와 같은 목적지로 라우팅합니다.
3.  **ClickHouse**: 로그 및 트레이스 데이터를 저장하는 고성능 OLAP 데이터베이스입니다. `clickhouse-operator`를 통해 관리됩니다.
4.  **Azure Blob Storage**: 오브젝트 스토리지로, 로그 백업 또는 저장을 위해 사용됩니다. Vector는 Azure Workload Identity로 인증합니다.
5.  **Grafana**: ClickHouse에 저장된 데이터를 시각화합니다. ClickHouse 데이터소스가 사전 설정되어 있습니다.

## 주요 파일 및 디렉토리 구조

- `kustomization.yaml`: 전체 스택을 관리하는 Kustomize 설정 파일입니다.
- `vector/`, `charts/vector/`: Vector Aggregator를 위한 Helm 차트 및 설정입니다.
- `clickhouse.yaml`: ClickHouse 클러스터 및 Keeper 설정입니다.
- `clickhouse-operator.yaml`: ClickHouse Operator 설치 매니페스트입니다.
- `cert-manager.yaml`: 인증서 관리를 위한 Cert Manager 매니페스트입니다.
- `grafana.yaml`: Grafana 배포 및 ClickHouse 데이터소스 설정입니다.
- `dice-service.yaml`: 샘플 애플리케이션 배포 매니페스트입니다.
- `values.yaml`: Vector Helm 차트용 사용자 정의 값 파일입니다.

## 배포 방법

### 사전 준비
- 쿠버네티스 클러스터
- `kubectl` 및 `kustomize` 설치

### 단계별 설치

1.  **네임스페이스 생성**
    ```bash
    kubectl create namespace vector
    ```

2.  **인프라스트럭처 설치 (선택 사항)**
    ```bash
    kubectl apply -f cert-manager.yaml
    kubectl apply -f clickhouse-operator.yaml
    ```

3.  **전체 스택 배포**
    Kustomize를 사용하여 모든 컴포넌트를 한 번에 배포합니다.
    ```bash
    kubectl apply -k .
    ```

    배포 전 `values.yaml`의 아래 placeholder 값을 실제 Azure 환경 값으로 변경해야 합니다.
    - `serviceAccount.annotations.azure.workload.identity/client-id`
    - `serviceAccount.annotations.azure.workload.identity/tenant-id`
    - `customConfig.sinks.azure_blob_storage.account_name`
    - `customConfig.sinks.azure_blob_storage.blob_endpoint`

4.  **ClickHouse 내부 Secret 재생성**
    `clickhouse-clickhouse` Secret는 더 이상 operator에 의해 임의 생성되도록 두지 않고, `clickhouse-secret.yaml`에서 명시적으로 관리합니다. 값을 바꾼 뒤 재생성하려면 다음 순서로 적용합니다.
    ```bash
    kubectl delete secret clickhouse-clickhouse -n vector --ignore-not-found
    kubectl apply -k .
    ```

## 접속 정보

- **Grafana**: `http://grafana.node-01` (admin/admin)
- **ClickHouse HTTP**: `http://clickhouse-clickhouse-headless:8123`

## 테스트

`dice-service`는 배포 직후 자동으로 `dice-caller` 컨테이너를 통해 트래픽을 생성하며, 생성된 OTLP 데이터는 Vector를 거쳐 ClickHouse에 저장됩니다. Grafana에서 `otel_logs` 및 `otel_traces` 테이블을 조회하여 데이터를 확인할 수 있습니다.

Grafana 비활성화 Job 테스트용으로는 아래 스크립트를 사용할 수 있습니다. 이 스크립트는 기본적으로 ingress 주소 `http://grafana.node-01`로 접속해 테스트 사용자를 Grafana에 등록하고, 기본값으로 `otel_logs_local`에 `deleted_user` 조건을 만족하는 로그를 넣습니다.

```bash
./scripts/prepare-grafana-user-disable-test.sh
```
