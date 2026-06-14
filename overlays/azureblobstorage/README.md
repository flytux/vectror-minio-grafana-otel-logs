# Azure Blob Storage overlay

이 오버레이는 `base`를 그대로 두고, 아카이브 저장소만 Azure Blob Storage + Azure Workload Identity 기준으로 바꿉니다.

## 포함 사항

- Vector aggregator 아카이브 sink를 `azure_blob` 로 전환
- Grafana audit sidecar sink를 `azure_blob` 로 전환
- ClickHouse `archive_logs_view` 를 `azureBlobStorage(...)` 기반 조회로 전환
- ClickHouse/Grafana/Vector에 Azure Workload Identity용 ServiceAccount 연결

## 적용 전 값 치환

아래 placeholder를 실제 Azure 값으로 바꿔야 합니다.

- `REPLACE_WITH_AZURE_STORAGE_ACCOUNT`
- `REPLACE_WITH_AZURE_CLIENT_ID`
- `REPLACE_WITH_AZURE_TENANT_ID`

## 배포

```bash
kubectl apply -k overlays/azureblobstorage
```
