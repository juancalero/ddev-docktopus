#!/usr/bin/env bash
# Safe, interactive conversion helper for existing projects on Linux.
# Requires Bash, Python 3 and DDEV. It never imports data or changes/stops
# existing Docker Compose services, containers, or volumes.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: convert-docktopus.sh [--path DIR] [--analyze-only] [--help]

Analyze an existing project and interactively configure DDEV Docktopus.
--analyze-only prints JSON and makes no changes.
USAGE
}

project_path="$(pwd -P)"
analyze_only=0
while (($#)); do
  case "$1" in
    --path)
      (($# >= 2)) || { echo "--path requires a directory" >&2; exit 2; }
      project_path="$2"
      shift 2
      ;;
    --analyze-only)
      analyze_only=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$project_path" ]] || { echo "Not a directory: $project_path" >&2; exit 2; }
project_path="$(cd "$project_path" && pwd -P)"
command -v python3 >/dev/null || { echo "Python 3 is required for project detection." >&2; exit 2; }

analysis="$(python3 - "$project_path" <<'PY'
import json
import os
import re
import sys

root = os.path.realpath(sys.argv[1])
name = re.sub(r"[^a-z0-9-]+", "-", os.path.basename(root).lower()).strip("-") or "docktopus-project"
if not name[0].isalpha():
    name = "project-" + name
name = name[:63].rstrip("-") or "docktopus-project"

def read_json(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def major_from_constraint(value):
    if not isinstance(value, str):
        return None
    match = re.search(r"(?:\^|~|>=?|\*)?\s*(\d+)", value)
    return int(match.group(1)) if match else None

drupal = None
candidates = [
    (".", root), ("drupal", os.path.join(root, "drupal")),
    ("web", os.path.join(root, "web")), ("docroot", os.path.join(root, "docroot")),
]
for relative, candidate_root in candidates:
    manifest = read_json(os.path.join(candidate_root, "composer.json"))
    if not manifest:
        continue
    requirements = {}
    for section in ("require", "require-dev"):
        values = manifest.get(section, {})
        if isinstance(values, dict):
            requirements.update(values)
    major = major_from_constraint(requirements.get("drupal/core-recommended") or requirements.get("drupal/core"))
    if major is None:
        for webroot in ("web", "docroot", "public_html"):
            version_file = os.path.join(candidate_root, webroot, "core/lib/Drupal.php")
            try:
                text = open(version_file, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            match = re.search(r"const VERSION = '(\d+)", text)
            if match:
                major = int(match.group(1))
                break
    if major is None:
        continue
    docroot = next((p for p in ("web", "docroot", "public_html") if os.path.isdir(os.path.join(candidate_root, p))), "web")
    if relative != ".":
        docroot = os.path.join(relative, docroot)
    php_constraint = str(requirements.get("php", ""))
    php_match = re.search(r"(?:\^|~|>=?)?\s*(\d+\.\d+)", php_constraint)
    drupal = {
        "composer_path": os.path.join(candidate_root, "composer.json"),
        "composer_relative_path": relative,
        "composer_at_project_root": relative == ".",
        "docroot": docroot.replace(os.sep, "/"),
        "major": major,
        "project_type": f"drupal{major}",
        "php_version": php_match.group(1) if php_match else "8.3",
        "composer_managed": True,
    }
    break

if drupal is None:
    for relative, candidate_root in candidates:
        for webroot in ("web", "docroot", "public_html", "."):
            version_file = os.path.join(candidate_root, webroot, "core/lib/Drupal.php")
            try:
                text = open(version_file, encoding="utf-8", errors="replace").read()
            except OSError:
                text = ""
            match = re.search(r"const VERSION = '(\d+)", text)
            if match:
                major = int(match.group(1))
                docroot = relative if webroot == "." else os.path.join(relative, webroot)
                drupal = {
                    "composer_path": None, "composer_relative_path": None,
                    "composer_at_project_root": False,
                    "docroot": docroot.replace(os.sep, "/"), "major": major,
                    "project_type": f"drupal{major}", "php_version": "8.3",
                    "composer_managed": False,
                }
                break
            drupal7 = os.path.join(candidate_root, webroot, "includes/bootstrap.inc")
            if webroot != "." and os.path.isfile(drupal7):
                docroot = os.path.join(relative, webroot)
                drupal = {
                    "composer_path": None, "composer_relative_path": None,
                    "composer_at_project_root": False, "docroot": docroot.replace(os.sep, "/"),
                    "major": 7, "project_type": "drupal7", "php_version": "7.4",
                    "composer_managed": False,
                }
                break
        if drupal:
            break

compose_files = [n for n in ("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml")
                 if os.path.isfile(os.path.join(root, n))]
services, ports = [], []
for filename in compose_files:
    text = open(os.path.join(root, filename), encoding="utf-8", errors="replace").read()
    inside_services = False
    for line in text.splitlines():
        if re.match(r"^services:\s*$", line):
            inside_services = True
            continue
        if inside_services:
            if line and not line[0].isspace():
                inside_services = False
            elif re.match(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$", line):
                services.append(re.match(r"^  ([A-Za-z0-9_-]+):", line).group(1))
    ports.extend(re.findall(r"(?m)^\s*-\s*[\"']?(\d{2,5}):\d{1,5}(?:/\w+)?[\"']?", text))

config_path = os.path.join(root, ".ddev/config.yaml")
config = ""
try:
    config = open(config_path, encoding="utf-8", errors="replace").read()
except OSError:
    pass
def config_value(key, default):
    match = re.search(rf"(?m)^{re.escape(key)}:\s*[\"']?([^\s\"']*)", config)
    return match.group(1) if match else default

package = read_json(os.path.join(root, "package.json")) or {}
scripts = package.get("scripts", {}) if isinstance(package.get("scripts", {}), dict) else {}
dependencies = {}
for section in ("dependencies", "devDependencies"):
    values = package.get(section, {})
    if isinstance(values, dict):
        dependencies.update(values)
has_node = any(os.path.isdir(os.path.join(root, d)) for d in ("api", "server"))
has_frontend = os.path.isfile(os.path.join(root, "frontend_react/package.json"))
has_node = has_node or bool(re.search(r"node|tsx|ts-node", str(scripts.get("start", "")))) or "express" in dependencies
has_frontend = has_frontend or bool(re.search(r"vite|next", str(scripts.get("dev", "")))) or any(d in dependencies for d in ("react", "next"))

already_ddev = os.path.isfile(config_path)
suggested_type = config_value("type", "generic") if already_ddev else (
    drupal["project_type"] if drupal and (drupal["composer_at_project_root"] or not drupal["composer_managed"]) else "generic")
suggested_docroot = config_value("docroot", ".") if already_ddev else (
    drupal["docroot"] if drupal and (drupal["composer_at_project_root"] or not drupal["composer_managed"]) else ".")
suggested_php = config_value("php_version", drupal["php_version"] if drupal else "8.3") if already_ddev else (drupal["php_version"] if drupal else "8.3")

print(json.dumps({
    "path": root, "project_name": name, "already_ddev": already_ddev,
    "drupal": drupal,
    "compose": {"files": compose_files, "services": sorted(set(services)), "host_ports": sorted(set(ports))},
    "has_root_package_json": os.path.isfile(os.path.join(root, "package.json")),
    "has_node_project": has_node, "has_frontend_project": has_frontend,
    "suggested_type": suggested_type, "suggested_docroot": suggested_docroot,
    "suggested_php_version": suggested_php,
}, indent=2))
PY
)"

if ((analyze_only)); then
  printf '%s\n' "$analysis"
  exit 0
fi

field() {
  python3 -c 'import json,sys; x=json.loads(sys.stdin.read());
for key in sys.argv[1].split("."):
 x=x.get(key) if isinstance(x,dict) else None
if isinstance(x,list): print(" ".join(str(v) for v in x))
else: print("" if x is None else ("true" if x is True else "false" if x is False else x))' "$1" <<<"$analysis"
}

project_name="$(field project_name)"
already_ddev="$(field already_ddev)"
project_type="$(field suggested_type)"
docroot="$(field suggested_docroot)"
php_version="$(field suggested_php_version)"
has_node="$(field has_node_project)"
has_frontend="$(field has_frontend_project)"
drupal_major="$(field drupal.major)"
drupal_composer="$(field drupal.composer_managed)"
drupal_root="$(field drupal.composer_at_project_root)"
compose_files="$(field compose.files)"
compose_services="$(field compose.services)"
compose_ports="$(field compose.host_ports)"

yes_no() {
  local prompt="$1" default="${2:-no}" reply suffix
  [[ "$default" == yes ]] && suffix='Y/n' || suffix='y/N'
  while true; do
    read -r -p "$prompt [$suffix] " reply
    reply="${reply,,}"
    if [[ -z "$reply" ]]; then [[ "$default" == yes ]]; return; fi
    case "$reply" in y|yes) return 0 ;; n|no) return 1 ;; *) echo 'Answer y or n.' >&2 ;; esac
  done
}

run_ddev() (
  cd "$project_path"
  ddev "$@"
)

install_addons() {
  local repository
  for repository in "$@"; do
    printf '\n>>> ddev add-on get %s\n' "$repository"
    run_ddev add-on get "$repository"
  done
}

printf '\nDDEV Docktopus project conversion wizard\n\nProject: %s\nName:    %s\n' "$project_path" "$project_name"
if [[ "$already_ddev" == true ]]; then echo 'DDEV:    already configured (.ddev/config.yaml found)'; else echo 'DDEV:    not configured yet'; fi
if [[ -n "$drupal_major" ]]; then
  if [[ "$drupal_composer" == true ]]; then management=Composer; else management='legacy/non-Composer source'; fi
  printf 'Drupal:  %s project, Drupal %s, docroot %s\n' "$management" "$drupal_major" "$docroot"
  if [[ "$drupal_composer" == true && "$drupal_root" != true ]]; then
    echo "Composer is nested below the selected project root; rerun with --path pointing to the Drupal directory." >&2
  fi
else
  echo 'Drupal:  no Drupal source detected at the root or common subdirectories'
fi
if [[ -n "$compose_files" ]]; then
  printf 'Compose: %s\nServices: %s\nPublished host ports: %s\n' "$compose_files" "$compose_services" "$compose_ports"
  for port in $compose_ports; do
    if [[ "$port" == 10389 || "$port" == 15432 ]]; then
      printf 'WARNING: possible Docktopus host-port conflict on %s; resolve it before starting that add-on.\n' "$port" >&2
    fi
  done
  echo 'Existing Compose files/services/containers/volumes will not be edited, stopped, imported, or deleted.'
fi
if [[ "$has_node" == true || "$has_frontend" == true ]]; then
  echo 'Existing Node/Vite application detected; Node/React add-ons are optional to avoid duplicate scaffolds.'
fi

if [[ "$already_ddev" != true ]]; then
  read -r -p "DDEV project type [$project_type] (Enter accepts; use generic for Compose-managed Drupal): " answer
  [[ -n "$answer" ]] && project_type="$answer"
  read -r -p "DDEV docroot [$docroot]: " answer
  [[ -n "$answer" ]] && docroot="$answer"
  if [[ "$project_type" == generic ]]; then php_version=8.3; fi
  read -r -p 'DDEV database [mariadb:10.11]: ' database
  database="${database:-mariadb:10.11}"
  printf '\nWill run: ddev config --project-name=%s --project-type=%s --docroot=%s --php-version=%s --database=%s\n' "$project_name" "$project_type" "$docroot" "$php_version" "$database"
  if ! yes_no 'Create DDEV configuration?' yes; then echo 'Cancelled; no files changed.'; exit 0; fi
  run_ddev config "--project-name=$project_name" "--project-type=$project_type" "--docroot=$docroot" "--php-version=$php_version" "--database=$database"
fi

cat <<'MODES'

Installation modes:
  1. Full meta add-on (all Docktopus services, including Node and React)
  2. Curated add-ons (core services; Node/React asked separately)
  3. DDEV configuration only
MODES
read -r -p 'Choose 1, 2, or 3 [2]: ' mode
mode="${mode:-2}"
[[ "$mode" =~ ^[123]$ ]] || { echo "Invalid mode: $mode" >&2; exit 2; }
if [[ "$mode" == 3 ]]; then
  echo 'DDEV configuration is in place. This mode will not start DDEV or install add-ons.'
  exit 0
fi
if ! yes_no 'Start this DDEV project now?' yes; then
  echo 'DDEV is configured. Run ddev start, then rerun this wizard to install add-ons.'
  exit 0
fi
run_ddev start -y

if [[ "$mode" == 1 ]]; then
  if [[ "$has_node" == true || "$has_frontend" == true ]]; then
    echo 'WARNING: full meta may install duplicate services or create api/ and frontend_react/ scaffolds.' >&2
  fi
  if yes_no 'Install the full ddev-docktopus meta add-on?' no; then
    install_addons juancalero/ddev-docktopus
    if [[ "$project_type" == generic || -z "$drupal_major" || "$drupal_root" != true || "$drupal_composer" != true ]]; then
      mkdir -p "$project_path/.ddev/docktopus-drupal"
      : > "$project_path/.ddev/docktopus-drupal/.skip"
      echo 'Disabled automatic Drupal bootstrap (.ddev/docktopus-drupal/.skip).'
    fi
  fi
elif [[ "$mode" == 2 ]]; then
  repositories=(ddev/ddev-adminer julienloizelet/ddev-portainer juancalero/ddev-docktopus-config juancalero/ddev-docktopus-ldap juancalero/ddev-docktopus-phpldapadmin juancalero/ddev-docktopus-postgres trebormc/ddev-opencode)
  [[ "$has_node" == true ]] && node_default=no || node_default=yes
  [[ "$has_frontend" == true ]] && react_default=no || react_default=yes
  if yes_no 'Add the Docktopus Node API service?' "$node_default"; then repositories+=(juancalero/ddev-docktopus-node-api); fi
  if yes_no 'Add the separate Docktopus React/Vite service?' "$react_default"; then repositories+=(juancalero/ddev-docktopus-react); fi
  if [[ "$drupal_composer" == true && "$drupal_root" == true ]]; then drupal_default=yes; else drupal_default=no; fi
  if yes_no 'Add the Drupal bootstrap add-on?' "$drupal_default"; then repositories+=(juancalero/ddev-docktopus-drupal); fi
  install_addons "${repositories[@]}"
  if [[ "$drupal_composer" != true || "$drupal_root" != true ]]; then
    mkdir -p "$project_path/.ddev/docktopus-drupal"
    : > "$project_path/.ddev/docktopus-drupal/.skip"
    echo 'Disabled automatic Drupal bootstrap because no root Composer Drupal project was detected.'
  fi
fi

if yes_no 'Restart DDEV now to apply add-ons?' yes; then run_ddev restart -y; else echo 'Run ddev restart when ready.'; fi

printf '\nConversion wizard finished. Run `ddev describe` to review service status and URLs.\n'
[[ -z "$compose_files" ]] || echo 'Existing Docker Compose configuration and volumes were left untouched.'
