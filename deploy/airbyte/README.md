# Airbyte installation for Insight

Airbyte устанавливается **отдельным Helm-релизом** в свой namespace `airbyte`. Umbrella-chart Insight про Airbyte знает только URL и creds — см. [`charts/insight/values.yaml`](../../charts/insight/values.yaml) → блок `airbyte:`.

## Почему отдельно

См. обсуждение в архитектурных заметках. Кратко:
- Airbyte — тяжёлый (10+ подов), его релизный цикл не совпадает с Insight
- `helm upgrade` umbrella'ы не должен каждый раз переинсталлировать Airbyte
- Compatibility matrix: Insight X.Y поддерживает Airbyte 1.4.x–1.6.x — связка мягкая

## Pinned version

| Component | Version | Status |
|-----------|---------|--------|
| Chart     | 1.5.1   | supported |
| Приложение| 1.5.1   | совпадает с chart appVersion |

Обновление — отдельным PR с регрешн-тестами ingestion workflow'ов.

## Install (quickstart / eval)

```bash
./deploy/scripts/install-airbyte.sh
```

Или вручную:
```bash
helm repo add airbyte https://airbytehq.github.io/helm-charts
helm repo update
helm upgrade --install airbyte airbyte/airbyte \
  --namespace airbyte --create-namespace \
  --version 1.5.1 \
  -f deploy/airbyte/values.yaml \
  --wait --timeout 15m
```

## Install (production)

1. Подготовь внешние ресурсы:
   - managed Postgres (RDS / CloudSQL / on-prem) для Airbyte state
   - S3-compatible bucket для logs + state
2. Создай Secret'ы в namespace `airbyte`:
   ```bash
   kubectl create namespace airbyte
   kubectl -n airbyte create secret generic airbyte-db-secret \
     --from-literal=password='...'
   kubectl -n airbyte create secret generic airbyte-s3-creds \
     --from-literal=AWS_ACCESS_KEY_ID='...' \
     --from-literal=AWS_SECRET_ACCESS_KEY='...'
   ```
3. Сделай overrides-файл (см. закомментированные блоки в [`values.yaml`](./values.yaml)), сохрани как `values-prod.yaml`.
4. Установи:
   ```bash
   helm upgrade --install airbyte airbyte/airbyte \
     --namespace airbyte --create-namespace \
     --version 1.5.1 \
     -f deploy/airbyte/values.yaml \
     -f deploy/airbyte/values-prod.yaml \
     --wait --timeout 15m
   ```

## Verify

```bash
# Все поды Ready
kubectl -n airbyte get pods -w

# UI через port-forward
kubectl -n airbyte port-forward svc/airbyte-airbyte-webapp-svc 8080:80
# → http://localhost:8080

# API reachable
kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8001:8001
curl http://localhost:8001/api/v1/health
```

## Интеграция с Insight

Insight обращается к Airbyte по DNS:
```
http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001
```

Эти значения уже прописаны:
- [`src/ingestion/airbyte-toolkit/lib/env.sh`](../../src/ingestion/airbyte-toolkit/lib/env.sh) → `AIRBYTE_API`
- [`charts/insight/files/ingestion/airbyte-sync.yaml`](../../charts/insight/files/ingestion/airbyte-sync.yaml) → default arg
- [`charts/insight/values.yaml`](../../charts/insight/values.yaml) → `airbyte.apiUrl`

**Auth**: токен — server-signed JWT, подписывается секретом `AB_JWT_SIGNATURE_SECRET` из пода `airbyte-server`. См. `env.sh` — там готовая генерация на node.js. Этот секрет создаётся чартом Airbyte автоматически, Insight-у нужно:
1. Получить его из Airbyte namespace (RBAC + `kubectl get secret`)
2. Сохранить в Insight namespace как `insight-airbyte-jwt-secret`

Делается один раз при установке — см. [`install-airbyte.sh`](../scripts/install-airbyte.sh).

## Uninstall

```bash
helm -n airbyte uninstall airbyte
kubectl delete namespace airbyte
# PVC удалятся вместе с namespace
```
