# GitOps deployment (ArgoCD)

Для enterprise-клиентов, у которых всё уже живёт под ArgoCD: две `Application`-манифеста с sync-wave ordering.

**Модель**: Git — source of truth, ArgoCD следит за этим репо и применяет. Обновление версии = коммит в этот репо.

## Предпосылки

- ArgoCD установлен в кластере (namespace `argocd`)
- ArgoCD имеет доступ к:
  - `https://airbytehq.github.io/helm-charts` (Airbyte chart repo)
  - `oci://ghcr.io/cyberfabric/charts` (Insight OCI registry) — или git-репо с чартом
- Создан `AppProject` (или используется `default`)

## Файлы

| Файл | Описание |
|------|----------|
| [`airbyte-application.yaml`](./airbyte-application.yaml) | Application для Airbyte. Sync wave 0. |
| [`insight-application.yaml`](./insight-application.yaml) | Application для Insight umbrella. Sync wave 1. |
| [`root-app.yaml`](./root-app.yaml) | App-of-Apps: одна точка входа, управляет двумя выше. |

## Quickstart: apply двух манифестов

```bash
kubectl apply -f deploy/gitops/airbyte-application.yaml
kubectl apply -f deploy/gitops/insight-application.yaml
```

ArgoCD сначала поднимет Airbyte (wave 0), дождётся healthy, потом Insight (wave 1).

## App-of-Apps pattern

Один `root-app.yaml` указывает на директорию `deploy/gitops/` — ArgoCD сам найдёт и создаст все `Application`-ы внутри.

```bash
kubectl apply -f deploy/gitops/root-app.yaml
```

Плюс: клиент применяет ОДИН манифест, всё остальное подтягивается через Git.

## Customization

**Для кастомизации values** клиенту стоит форкнуть репо или завести свой репо с overlays, ссылаться на форк в `source.repoURL`. Не редактируй эти Application-манифесты на месте — потеряешь сдвиг относительно upstream.

Альтернатива: использовать `source.helm.valueFiles` с путём к своим values'ам в **другом** Git-репо (можно несколько `sources[]`).

## Upgrade flow

```bash
# 1. В своём форке — сменить chart version
sed -i '' 's/targetRevision: 0.1.0/targetRevision: 0.2.0/' insight-application.yaml

# 2. PR → merge → ArgoCD автоматически синкнет
# (или manual sync через UI / argocd CLI)
```

## Rollback

```bash
# через ArgoCD CLI
argocd app rollback insight <REVISION>

# или git revert
git revert <commit>; git push
```

## Health checks

```bash
argocd app list
argocd app get insight
argocd app get airbyte
```
