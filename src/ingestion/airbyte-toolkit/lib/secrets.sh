#!/usr/bin/env bash
# Helpers for resolving connector Secret metadata from Kubernetes.
# Sourced by run-sync.sh and run-tt-enrich-jira.sh.

# resolve_source_id <connector> <tenant>
#
# Resolves insight_source_id from a connector Secret in $INSIGHT_NAMESPACE.
# Matching:
#   - annotation insight.cyberfabric.com/connector == <connector>
#   - annotation insight.cyberfabric.com/tenant    == <tenant>
#   (Secrets without the tenant annotation are NOT matched — by rule, missing
#    annotations are explicit errors, not silent matches.)
#
# Stdout: source-id when exactly one Secret matches; empty when none match.
# Exit:   2 when multiple Secrets match (ambiguous).
resolve_source_id() {
  local connector="$1"
  local tenant="$2"
  : "${INSIGHT_NAMESPACE:?INSIGHT_NAMESPACE must be set}"

  kubectl get secret -n "$INSIGHT_NAMESPACE" -l app.kubernetes.io/part-of=insight -o json |
    jq -r --arg c "$connector" --arg t "$tenant" '
      [
        .items[]
        | .metadata.annotations
        | select(. != null)
        | select(."insight.cyberfabric.com/connector" == $c)
        | select(has("insight.cyberfabric.com/tenant"))
        | select(."insight.cyberfabric.com/tenant" == $t)
        | ."insight.cyberfabric.com/source-id"
        | select(. != null and . != "")
      ]
      | if length == 0 then ""
        elif length == 1 then .[0]
        else ("multiple Secrets match connector=" + $c + " tenant=" + $t + ": " + tojson) | halt_error(2) end
    '
}
