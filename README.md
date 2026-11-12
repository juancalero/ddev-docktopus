[![tests](https://github.com/juancalero/ddev-docktopus/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/juancalero/ddev-docktopus/actions/workflows/tests.yml)
[![release](https://img.shields.io/github/v/release/juancalero/ddev-docktopus)](https://github.com/juancalero/ddev-docktopus/releases/latest)

# DDEV Docktopus

One command installs the complete **docktopus development stack** inside any existing DDEV project: Apache Solr 9, Varnish 7, OpenLDAP + phpLDAPadmin, PostgreSQL 17, a Node 22 + Express API, a React 19 (Vite 7) frontend, Adminer, Portainer, plus the OpenCode AI stack — all the components of the [docktopus](https://github.com/juancalero/docktopus) project template, packaged as independent DDEV add-ons so you can use them on any project (not just the docktopus template).

It works on **existing Drupal projects** (nothing is touched) and, with [`ddev-docktopus-drupal`](https://github.com/juancalero/ddev-docktopus-drupal), it can also **bootstrap a Drupal 11 site from scratch** automatically.

> Inspired by [ddev-ai-workspace](https://github.com/trebormc/ddev-ai-workspace): a meta add-on that orchestrates independent child add-ons, each installable and removable on its own.

## At a glance

| You want to... | Run | Provided by |
| --- | --- | --- |
| Search with Solr 9 (es/en configsets) | automatic | [ddev-drupal-solr](https://github.com/ddev/ddev-drupal-solr) + [ddev-docktopus-config](https://github.com/juancalero/ddev-docktopus-config) |
| Cache pages with Varnish (PURGE, 1m TTL) | automatic | [ddev-varnish](https://github.com/ddev/ddev-varnish) + [ddev-docktopus-config](https://github.com/juancalero/ddev-docktopus-config) |
| Manage the LDAP directory visually | `ddev phpldapadmin` | [ddev-docktopus-phpldapadmin](https://github.com/juancalero/ddev-docktopus-phpldapadmin) |
| Run the Node API | `ddev api` | [ddev-docktopus-node-api](https://github.com/juancalero/ddev-docktopus-node-api) |
| Develop the React frontend | `ddev frontend` | [ddev-docktopus-react](https://github.com/juancalero/ddev-docktopus-react) |
| Store API data | `postgresql://localhost:15432` | [ddev-docktopus-postgres](https://github.com/juancalero/ddev-docktopus-postgres) |
| Manage DBs visually | `ddev phpmyadmin` / `ddev adminer` | DDEV core / [ddev-adminer](https://github.com/ddev/ddev-adminer) |
| Manage containers | `ddev portainer` | [ddev-portainer](https://github.com/julienloizelet/ddev-portainer) |
| Test emails | `ddev mailpit` | DDEV core |
| Work with an AI agent | `ddev opencode` | [ddev-opencode](https://github.com/trebormc/ddev-opencode) (pulls ai-ssh, beads, playwright-mcp, agents-sync) |

## Quick start

### Convert a project that is not configured with DDEV yet

`ddev add-on get` must be run inside a configured DDEV project. The wizard can inspect a project first, suggest the DDEV type/docroot, and ask before making changes.

#### Linux (Bash + Python 3)

```bash
git clone --depth 1 --branch v1.2.0 https://github.com/juancalero/ddev-docktopus.git "${TMPDIR:-/tmp}/ddev-docktopus"
bash "${TMPDIR:-/tmp}/ddev-docktopus/wizard/convert-docktopus.sh" --path "$PWD"
```

#### Windows (PowerShell 5.1+)

```powershell
$wizardDir = Join-Path $env:TEMP 'ddev-docktopus'
git clone --depth 1 https://github.com/juancalero/ddev-docktopus.git $wizardDir
& (Join-Path $wizardDir 'wizard/Convert-Docktopus.ps1') -Path (Get-Location).Path
```

Use `-AnalyzeOnly` to print the detection result as JSON without changing the project:

```powershell
& (Join-Path $wizardDir 'wizard/Convert-Docktopus.ps1') -Path . -AnalyzeOnly
```

Add `--analyze-only` on Linux or `-AnalyzeOnly` on Windows to print detection results as JSON without making changes. Both versions detect Composer-managed Drupal projects, legacy Drupal source trees, Node/Vite projects and common Compose files. They do **not** migrate databases or edit/stop/remove existing Compose services, containers, volumes, or project files. For Compose-managed Drupal (without a root `composer.json`), they recommend a `generic` DDEV project, leave Drupal's empty-project bootstrap opted out, and let you omit Docktopus Node/React add-ons to avoid duplicate services/scaffolds. Review detected host ports and resolve conflicts yourself before starting services.

### Existing Drupal project

```
cd /path/to/your-drupal-project
ddev add-on get juancalero/ddev-docktopus
ddev restart

ddev describe     # every service URL
ddev opencode     # AI assistant in its own container
```

### From scratch

```
mkdir my-site && cd my-site
ddev config --project-type=drupal11 --docroot=web
ddev start
ddev add-on get juancalero/ddev-docktopus
ddev restart      # bootstraps a Drupal 11 site automatically (a few minutes)
```

The result is a working Drupal 11 site (`admin` / `admin`) with `search_api_solr` and `ldap` installed, enabled and connected — see [ddev-docktopus-drupal](https://github.com/juancalero/ddev-docktopus-drupal) for the details. An existing project is never modified.

## Architecture

```
DDEV project (your existing Drupal site)
 ├─ solr 9 ────────── search (configsets es/en from search_api_solr)
 ├─ varnish 7 ─────── HTTP cache in front of the site (via ddev-router)
 ├─ openldap ──────── corporate directory (phpLDAPadmin on :6443)
 ├─ postgres 17 ───── database for the Node API (not DDEV's main db)
 ├─ node ──────────── Node 22 + Express API (api/ scaffold, :13000)
 ├─ react ─────────── Vite dev server (frontend_react/ scaffold, :15173)
 ├─ adminer / portainer ── visual management (via their own add-ons)
 ├─ phpmyadmin / mailpit ── included in DDEV core
 └─ opencode ──────── AI agent container, SSH access to web, beads,
                       playwright-mcp browser, agents-sync

ddev-docktopus-drupal: on an empty project, bootstraps a Drupal 11 site
  (composer + drush + search_api_solr + ldap, connected to the stack)
```

## Repositories

This workspace is a family of independent git repositories. Install them all with this meta add-on, or pick the ones you need.

### Shared dependencies (installed automatically)

| Repository | Description |
| --- | --- |
| [ddev-drupal-solr](https://github.com/ddev/ddev-drupal-solr) | Apache Solr for Drupal (official add-on). Configsets overridden by `ddev-docktopus-config`. |
| [ddev-varnish](https://github.com/ddev/ddev-varnish) | Varnish in front of the site (official add-on). VCL overridden by `ddev-docktopus-config`. |
| [ddev-adminer](https://github.com/ddev/ddev-adminer) | Adminer database UI. |
| [ddev-portainer](https://github.com/julienloizelet/ddev-portainer) | Portainer container UI. |
| [ddev-opencode](https://github.com/trebormc/ddev-opencode) | OpenCode in a dedicated container; auto-installs ddev-ai-ssh, ddev-beads, ddev-playwright-mcp and ddev-agents-sync. |

### docktopus add-ons

| Repository | Description |
| --- | --- |
| [ddev-docktopus-config](https://github.com/juancalero/ddev-docktopus-config) | Configuration layer: Solr 9 pin + modules, docktopus configsets (es/en), docktopus Varnish VCL (PURGE + 1m TTL). |
| [ddev-docktopus-ldap](https://github.com/juancalero/ddev-docktopus-ldap) | OpenLDAP service + PHP `ldap` extension in the web image. |
| [ddev-docktopus-phpldapadmin](https://github.com/juancalero/ddev-docktopus-phpldapadmin) | phpLDAPadmin UI on `:6443` (depends on ddev-docktopus-ldap). |
| [ddev-docktopus-postgres](https://github.com/juancalero/ddev-docktopus-postgres) | PostgreSQL 17 for the Node API, with `postgres-init/` seed. |
| [ddev-docktopus-node-api](https://github.com/juancalero/ddev-docktopus-node-api) | Node 22 + Express API service, `ddev api` command, `api/` scaffold if missing. |
| [ddev-docktopus-react](https://github.com/juancalero/ddev-docktopus-react) | Vite + React 19 dev server, `ddev frontend` command, `frontend_react/` scaffold if missing. |
| [ddev-docktopus-drupal](https://github.com/juancalero/ddev-docktopus-drupal) | Automatic Drupal 11 bootstrap for empty projects (site install + stack modules connected); existing projects untouched. |

### Individual installation

```
ddev add-on get juancalero/ddev-docktopus-config          # Solr 9 + Varnish (docktopus flavor)
ddev add-on get juancalero/ddev-docktopus-ldap            # OpenLDAP (+ PHP ldap extension)
ddev add-on get juancalero/ddev-docktopus-phpldapadmin    # phpLDAPadmin (needs LDAP)
ddev add-on get juancalero/ddev-docktopus-postgres        # PostgreSQL 17
ddev add-on get juancalero/ddev-docktopus-node-api        # Node API
ddev add-on get juancalero/ddev-docktopus-react           # React frontend
ddev add-on get juancalero/ddev-docktopus-drupal          # Drupal 11 auto-bootstrap
ddev add-on get trebormc/ddev-opencode                    # AI stack
```

## Switching the AI agent pack to your own repository

`ddev-agents-sync` clones the agent pack configured in `.ddev/.env.agents-sync` on every `ddev start` and generates the OpenCode configuration from it. This workspace seeds that file (only if it does not exist yet) pointing at the upstream pack:

```dotenv
AGENTS_REPOS=https://github.com/trebormc/drupal-ai-agents.git
```

When your own pack is ready, change **that single line**:

```dotenv
# Replace the upstream pack entirely:
AGENTS_REPOS=https://github.com/juancalero/docktopus-ai-agents.git

# Or keep upstream as a base and override/extend with yours (later wins):
AGENTS_REPOS=https://github.com/trebormc/drupal-ai-agents.git,https://github.com/juancalero/docktopus-ai-agents.git
```

Then run `ddev agents-update && ddev restart`. A `#branch` suffix pins a ref. Your pack only needs to follow the same layout (`.claude/agents/*.md`, `.claude/rules/*.md`, `.claude/skills/*/SKILL.md`, `.env.agents`) and can use the same `${MODEL_*}` tokens, so both packs are interchangeable.

## Child updates

After installing (or whenever you run `ddev add-on get juancalero/ddev-docktopus` again), every child add-on is refreshed to its latest release, so one command keeps the whole family up to date.

- A child that cannot be fetched (unpublished, renamed, offline) is reported as a **warning** and never aborts the installation.
- Set `DDEV_DOCKTOPUS_SKIP_DEPS=1` in the session/CI environment to skip the refresh — for example when the children were installed from local checkouts and you want exact versions with no GitHub traffic.

## Uninstallation

```
ddev add-on remove ddev-docktopus
ddev restart
```

The meta add-on only groups the others: remove them individually with `ddev add-on remove <name>` if you want them gone too.

## Notes

- **Ports** follow DDEV conventions: HTTP services are exposed through the ddev-router (Solr `:8983`/`:8943`, phpLDAPadmin `:6443`/`:6444`, Node API `:13000`/`:13001`, React `:15173`/`:15174`) and can be shared by several projects at once. Only non-HTTP services bind a host port (LDAP `10389`, PostgreSQL `15432`), configurable in each add-on's `.env` file.
- **Scaffolding** (`api/`, `frontend_react/`, `postgres-init/`) is only created when the project does not already have it, and every generated file carries a `#ddev-generated` marker: edit them freely and the add-ons will respect your changes.
- Not intended for production deployments.

## License

GPL-2.0-or-later (all repositories in the family)
