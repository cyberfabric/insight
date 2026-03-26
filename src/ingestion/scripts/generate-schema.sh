#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS_DIR="./tools/declarative-connector"

connector="${1:?Usage: $0 <class/connector> <connection>}"
connection="${2:?Usage: $0 <class/connector> <connection>}"
manifest="./connectors/${connector}/connector.yaml"

if [[ ! -f "$manifest" ]]; then
  echo "ERROR: manifest not found: $manifest" >&2
  exit 1
fi

echo "Reading data from ${connector}/${connection}..." >&2

SCHEMAS=$("${TOOLS_DIR}/source.sh" read "${connector}" "${connection}" 2>/dev/null | python3 -c "
import sys, json

schemas = {}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
        if msg.get('type') != 'RECORD': continue
        stream = msg['record']['stream']
        data = msg['record']['data']
        if stream not in schemas: schemas[stream] = {}
        for k, v in data.items():
            if k in schemas[stream]: continue
            if v is None: schemas[stream][k] = ['string', 'null']
            elif isinstance(v, bool): schemas[stream][k] = ['boolean', 'null']
            elif isinstance(v, (int, float)): schemas[stream][k] = ['number', 'null']
            elif isinstance(v, list): schemas[stream][k] = ['array', 'null']
            else: schemas[stream][k] = ['string', 'null']
    except: pass

print(json.dumps(schemas))
")

if [[ -z "$SCHEMAS" || "$SCHEMAS" == "{}" ]]; then
  echo "ERROR: no records received" >&2
  exit 1
fi

echo "$SCHEMAS" | python3 -c "
import sys, json

schemas = json.load(sys.stdin)
for stream in sorted(schemas):
    fields = schemas[stream]
    print(f'  {stream}: {len(fields)} fields', file=sys.stderr)

    props = {}
    for field in sorted(fields):
        types = fields[field]
        if field in ('unique_key', 'reportRefreshDate'):
            p = {'type': 'string'}
        elif len(types) == 1:
            p = {'type': types[0]}
        else:
            p = {'type': types}
        if field == 'assignedProducts':
            p['items'] = {'type': ['string', 'null']}
        props[field] = p

    schema = {
        'type': 'object',
        '\$schema': 'http://json-schema.org/schema#',
        'properties': props,
        'required': ['unique_key', 'reportRefreshDate'],
        'additionalProperties': True,
    }
    print(f'---STREAM:{stream}---')
    print(json.dumps(schema, indent=2))
" > /tmp/schemas_out.txt 2>&1

cat /tmp/schemas_out.txt | grep "^  " >&2

# Update each stream's schema in the manifest using yq
while IFS= read -r line; do
  if [[ "$line" == ---STREAM:*--- ]]; then
    stream_name="${line#---STREAM:}"
    stream_name="${stream_name%---}"
    schema_json=""
  elif [[ -n "${stream_name:-}" ]]; then
    schema_json+="$line"$'\n'
    if echo "$schema_json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
      idx=$(yq -c '.streams | to_entries[] | select(.value.name == "'"${stream_name}"'") | .key' "${manifest}" 2>/dev/null)
      if [[ -n "$idx" ]]; then
        schema_yaml=$(echo "$schema_json" | yq -y '.')
        tmp=$(mktemp)
        yq -y ".streams[${idx}].schema_loader.schema = $(echo "$schema_json" | yq -c '.')" "${manifest}" > "$tmp"
        mv "$tmp" "${manifest}"
        echo "  Updated ${stream_name} in manifest" >&2
      fi
      stream_name=""
      schema_json=""
    fi
  fi
done < /tmp/schemas_out.txt

rm -f /tmp/schemas_out.txt
echo "Done. Verify with: ./tools/declarative-connector/source.sh validate ${connector}" >&2
