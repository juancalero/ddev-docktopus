#!/usr/bin/env bash
set -euo pipefail

wizard="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wizard/convert-docktopus.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_json() {
  local json="$1" expression="$2" message="$3"
  if ! python3 -c 'import json,sys; data=json.load(sys.stdin); assert eval(sys.argv[1], {"__builtins__": {}}, {"d": data})' "$expression" <<<"$json"; then
    echo "ASSERTION FAILED: $message" >&2
    return 1
  fi
}

compose_project="$tmp/compose-project"
mkdir -p "$compose_project/api"
cat > "$compose_project/docker-compose.yml" <<'YAML'
services:
  drupal:
    ports:
      - "8081:80"
  database:
    image: mariadb:11
YAML
cat > "$compose_project/package.json" <<'JSON'
{"scripts":{"dev":"vite"},"dependencies":{"react":"^19.0.0"}}
JSON
compose_json="$("$wizard" --path "$compose_project" --analyze-only)"
assert_json "$compose_json" 'd["suggested_type"] == "generic"' 'Compose Drupal should use generic DDEV.'
assert_json "$compose_json" 'd["drupal"] is None' 'Compose Drupal should not be misdetected as Composer Drupal.'
assert_json "$compose_json" 'd["has_node_project"] and d["has_frontend_project"]' 'Existing API/Vite code should be detected.'
assert_json "$compose_json" '"drupal" in d["compose"]["services"]' 'Compose Drupal service should be detected.'
assert_json "$compose_json" '"8081" in d["compose"]["host_ports"]' 'Published port should be detected.'
[[ ! -e "$compose_project/.ddev" ]] || { echo 'Analyze-only created project files' >&2; exit 1; }

drupal_project="$tmp/drupal-project"
mkdir -p "$drupal_project/web"
cat > "$drupal_project/composer.json" <<'JSON'
{"require":{"drupal/core-recommended":"^10.3","php":"^8.2"}}
JSON
drupal_json="$("$wizard" --path "$drupal_project" --analyze-only)"
assert_json "$drupal_json" 'd["suggested_type"] == "drupal10"' 'Drupal Composer major should be detected.'
assert_json "$drupal_json" 'd["suggested_docroot"] == "web"' 'Drupal docroot should be detected.'
assert_json "$drupal_json" 'd["suggested_php_version"] == "8.2"' 'PHP version constraint should be detected.'

nested_project="$tmp/nested-project"
mkdir -p "$nested_project/drupal/web"
cat > "$nested_project/drupal/composer.json" <<'JSON'
{"require":{"drupal/core-recommended":"^11.0"}}
JSON
nested_json="$("$wizard" --path "$nested_project" --analyze-only)"
assert_json "$nested_json" 'd["drupal"]["major"] == 11 and not d["drupal"]["composer_at_project_root"]' 'Nested Drupal should be detected.'
assert_json "$nested_json" 'd["suggested_type"] == "generic"' 'Nested Composer project must not default Drupal type at parent.'

legacy_project="$tmp/legacy-project"
mkdir -p "$legacy_project/drupal/web/core/lib"
echo "<?php const VERSION = '9.5.11';" > "$legacy_project/drupal/web/core/lib/Drupal.php"
legacy_json="$("$wizard" --path "$legacy_project" --analyze-only)"
assert_json "$legacy_json" 'd["drupal"]["major"] == 9 and not d["drupal"]["composer_managed"]' 'Legacy Drupal should be detected.'
assert_json "$legacy_json" 'd["suggested_docroot"] == "drupal/web"' 'Legacy Drupal docroot should be detected.'

echo 'All Linux conversion wizard tests passed.'
