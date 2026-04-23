# Argo Workflows installation for Insight

Argo Workflows — движок для ingestion-pipelines (Airbyte sync → dbt run → enrichment). Ставится **отдельным Helm-релизом** в namespace `argo`.

Insight-сервисы создают `CronWorkflow` объекты; Argo controller их исполняет.

## Pinned version

| Component | Version |
|-----------|---------|
| Chart     | 0.45.x (pinned in install script) |

## Install (quickstart)

```bash
./deploy/scripts/install-argo.sh
```

Или вручную:
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo --create-namespace \
  -f deploy/argo/values.yaml \
  --wait --timeout 5m
kubectl apply -f deploy/argo/rbac.yaml
```

## Production overrides

Поверх [`values.yaml`](./values.yaml) — свой `values-prod.yaml`:
- HA: `controller.replicas: 2`, workflow archive в Postgres
- `server.sso` с OIDC клиентом
- Resource limits под размер потока workflow'ов
- Ограничить `controller.parallelism` если кластер shared

```bash
EXTRA_VALUES_FILE=deploy/argo/values-prod.yaml \
  ./deploy/scripts/install-argo.sh
```

## WorkflowTemplates

WorkflowTemplates (`airbyte-sync`, `dbt-run`, `ingestion-pipeline`) — это **контент**, а не инфра. Они поставляются umbrella-чартом Insight под флагом `ingestion.templates.enabled: true`. После установки umbrella они появятся в namespace `insight` и их можно ссылать из `CronWorkflow`-ов.

## Verify

```bash
kubectl -n argo get pods
kubectl -n argo port-forward svc/argo-workflows-server 2746:2746
# UI: http://localhost:2746

# Submit a test workflow
argo -n argo submit --from workflowtemplate/ingestion-pipeline -p connector=m365
```

## Uninstall

```bash
helm -n argo uninstall argo-workflows
kubectl delete -f deploy/argo/rbac.yaml
kubectl delete namespace argo
```
