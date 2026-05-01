---
cypilot: true
type: project-rule
topic: code-conventions
version: 1.0
---

# Code Conventions

Hard rules for writing or reviewing imperative code in this project — shell scripts, Python helpers, Argo Workflow / Kubernetes YAML, dbt macros, deploy scripts. **All rules are MUST**, not SHOULD; violations block merge.

The point of these rules is to keep the source of truth in **one place per concept** so that when something changes, exactly one file moves. Defaults, inline copies, and hidden fallbacks fight that goal.

<!-- toc -->

- [No default values](#no-default-values)
- [No inline scripts](#no-inline-scripts)
- [No inline YAML](#no-inline-yaml)
- [Fail-fast over silent fallback](#fail-fast-over-silent-fallback)
- [Audit recipe](#audit-recipe)

<!-- /toc -->

## No default values

**Forbidden** in any imperative code path:

- Bash: `${VAR:-default}`, `${VAR:=default}`, `${VAR:?...}` is OK only when the message documents why the variable is required (the `:?` form aborts).
- Python (helpers, scripts): `dict.get(key, default_value)` for any non-trivial default; instead require the key explicitly and raise on missing.
- Argo Workflow `inputs.parameters[*].default:` for runtime values that originate from a caller (connection IDs, source IDs, image tags). Defaults are allowed only when the value is genuinely a chart-rendered constant (e.g. `clickhouse_host` from Helm `include`).
- Helm chart `default` values for required operator inputs — pair with `required` so missing config fires an explicit error.

**Why**: a default value moves the source of truth from one place (the caller / config) into N places (every default site). When the real value changes, you have to grep for every default — one missed site silently keeps the old value. Treat every default as a hidden second source of truth and remove it.

**Before each new default**, ask:
1. What if this code runs without the value being set anywhere?
2. Is silent fallback (running with a wrong value) better than a loud error?

If the answer to (2) is "no" — and it almost always is — drop the default and require the caller.

**Allowed exceptions** (must be tagged with a `# RULE-DEFAULTS-OK:` comment explaining why):
- Constants that genuinely have no other source (e.g. `argo-workflow` ServiceAccount name baked into chart-rendered manifests).
- Test/dev shorthand values explicitly marked as such.

**How to apply**:
- When writing shell: `VAR=${VAR:?Set VAR — see <docs path> for what it should be}`
- When writing Python: drop `or {}` / `or []` / `, default` style; use explicit `if key not in d: raise ...` or destructure with `KeyError`.
- When writing Argo: omit `default:`; ingestion-pipeline must error out at submission time if a required parameter is missing.

## No inline scripts

**Forbidden**: embedding a non-trivial Python (or other-language) script inside a heredoc inside a shell script.

```bash
# BAD
SOURCE_ID=$(kubectl get secret -o json | python3 -c "
import json, os, sys
...")

# OK (1) — pure shell + jq
SOURCE_ID=$(kubectl get secret -o json | jq -r '.items[0].metadata.name')

# OK (2) — Python in its own file
SOURCE_ID=$(kubectl get secret -o json | python3 src/ingestion/scripts/resolve_source_id.py)
```

**Threshold**: any heredoc Python with imports beyond `sys` is "non-trivial". One-liner string manipulation is OK; anything that reads structured data, applies multi-step logic, or has error handling goes in a `.py` file.

**Why**:
- Embedded scripts can't be linted, type-checked, or unit-tested.
- They share `${VAR}` substitution between the parent shell and the child interpreter — a recurring source of injection bugs (parent shell expands `$x` before Python sees it).
- They duplicate when the same logic appears in two shell scripts (resolve-source-id was on its way to becoming a duplicate before this rule).

**Preferred order**:
1. Pure shell + `jq` for JSON, `yq` for YAML, `awk`/`sed` for text. Almost everything is reachable this way.
2. Standalone `.py` (or `.sh`) file in `src/ingestion/scripts/` (or appropriate location), called as a subprocess.
3. Inline only when the logic is one expression and won't be reused.

## No inline YAML

**Forbidden**: rendering Argo `Workflow` / `WorkflowTemplate` / `CronWorkflow` / `Service` / any K8s object as a heredoc inside a shell script.

```bash
# BAD
kubectl create -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ${CONNECTOR}-
...
EOF

# OK
envsubst < src/ingestion/workflows/onetime/run-sync.yaml.tpl | kubectl create -f -
```

**Why**:
- Inline YAML can't be validated by `kubeval` / `helm lint` / IDE schema tools.
- It diverges from the WorkflowTemplate it shadows (we now have ingestion-pipeline as a chart-rendered template **and** an inline copy in run-sync.sh — when the template grows a parameter, the inline copy silently keeps the old shape).
- It can't be diff-reviewed cleanly: changes show up as shell-string edits, not YAML edits.

**Where to put extracted templates**:
- One-shot `Workflow` submissions → `src/ingestion/workflows/onetime/<name>.yaml.tpl`
- `CronWorkflow` schedules → `src/ingestion/workflows/schedules/<name>.yaml.tpl` (existing pattern — `sync.yaml.tpl`)
- Reusable `WorkflowTemplate`s → `charts/insight/templates/ingestion/<name>.yaml` (chart-rendered; no envsubst, uses Helm templating)

**Renderer**:
- `envsubst` for shell-driven templates with `${VAR}` placeholders. Document expected variables at the top of the template.
- Helm for chart-rendered templates that ship inside the umbrella.

## Fail-fast over silent fallback

When a configuration value, secret annotation, or input is missing, **error explicitly** with a message pointing at how to fix it. Do not silently:

- Match an unannotated Secret to the requested tenant (cross-tenant misresolution).
- Substitute an empty string for a missing `${VAR}`.
- Assume a default region / namespace / image tag.

The first time someone deploys with a missing value, they should see a clear "set X" error — not a successful run that silently does the wrong thing on a different tenant's data.

**Apply this every time** you're tempted to write `or default`, `?:`, `try/except: pass`, or `coalesce(x, y)` — those are the common shapes of silent fallback. Sometimes they're correct; usually they hide a bug.

## Audit recipe

Run this scan on the files your PR touches before requesting review. Each match must either be fixed (replaced with a required env var, extracted to a file, etc.) **or** tagged with a `# RULE-DEFAULTS-OK: <reason>` comment that names the reason.

```bash
# Files touched by the current branch (vs main).
FILES=$(git diff --name-only main...HEAD)

# 1. Bash defaults — `${VAR:-default}`, excluding the abort-form `${VAR:?...}`
echo "$FILES" | xargs -r grep -nE '\$\{[A-Z_][A-Z_0-9]*:-[^?}]' 2>/dev/null

# 2. Python config defaults — non-trivial fallbacks via `.get(k, v)`
echo "$FILES" | xargs -r grep -nE 'os\.environ\.get\([^)]+,\s*[^)]+\)' 2>/dev/null
echo "$FILES" | xargs -r grep -nE '\.get\([^)]+,\s*['"'"'"`]' 2>/dev/null

# 3. Argo / K8s YAML — `default:` lines in chart and workflow templates
echo "$FILES" | grep -E '\.(ya?ml)$' | xargs -r grep -nE '^\s+default:' 2>/dev/null

# 4. Inline Python / YAML inside shell — heredoc and `python3 -c "$"` patterns
echo "$FILES" | grep -E '\.sh$' | xargs -r grep -lE 'python3 -c "$|<<EOF$' 2>/dev/null
```

The first three categories surface defaults; the fourth surfaces inline-script / inline-YAML violations. A clean run produces only `RULE-DEFAULTS-OK`-tagged matches and lines from this rule document itself.
