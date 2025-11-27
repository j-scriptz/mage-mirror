# Magento + Hyvä via Warden  
**_mage-mirror.sh v1.0**

From zero to a **local Magento 2 + Hyvä** dev stack in one command — with optional **remote clone**, **one-step core upgrade**, and **multi-store** routing.

This repo ships a single, powerful installer:

> `_mage-mirror.sh` – a guided setup script for macOS/linux + Docker + Warden.

Repo: `j-scriptz/mage-mirror`

---

## Highlights

- 🧱 **Fresh Magento 2 install** via `composer create-project`
- 🔁 **Clone an existing site** (code + DB) from:
  - Local SQL dump + `env.php` / `config.php`, or
  - A remote server via SSH (rsync + tar + remote `mysqldump`)
- ⬆️ **Upgrade mode** (clone + upgrade):
  - Imports your current code & DB
  - Updates Magento core with Composer (e.g. to latest `2.4.x`)
  - Runs `setup:upgrade`, DI compile, static deploy, reindex, etc.
- 🎨 **Hyvä theme integration**:
  - Optional install via OSS composer mirrors
  - Automatically sets Hyvä Default as the storefront theme when available
- 🌐 **Optional multi-store**:
  - `https://app.<project>.test` → base website
  - `https://<project>.test` → optional `subcats` website
  - Host-based routing patch in `pub/index.php` (only when enabled)
- 🧪 **Search & OpenSearch sanity**:
  - Configures Magento to use `opensearch` (Warden’s service)
  - Rebuilds `catalogsearch_fulltext` index
- 🔐 **Remote sync with SSH keys _or_ interactive password fallback**:
  - If `REMOTE_SSH_KEY` is set → uses key-based auth
  - If not, and you’re in a TTY → falls back to password/agent-based SSH (ssh/rsync will prompt)
  - In non-interactive runs, a key is still required
- 🧾 Single, central config file: **`_master.config`**

---

## Prerequisites

- **macOS** (Apple Silicon or Intel)
- **Docker Desktop for Mac**
  - Docker Compose v2 enabled
  - Enough resources (6GB+ RAM recommended)
- **Homebrew** (optional; script can install it)
- **Warden** (installed via Homebrew if missing)

> If `docker info` fails, fix Docker Desktop first.  
> The installer will exit early with a clear error if Docker/Warden aren’t ready.

---

## Quick start

```bash
# 1) Clone the project
git clone https://github.com/j-scriptz/mage-mirror.git
cd mage-mirror

# 2) Configure (optional but recommended)
cp _mage-mirror.config.sample _mage-mirror.config
# edit _mage-mirror.config to match your setup

# 3) Make the installer executable
chmod +x _mage-mirror.sh

# 4) Run it
./_mage-mirror.sh
```

The script will:

1. Load `_master.config` (if present)
2. Ask for anything left as `ask`
3. Spin up a full **Magento + Hyvä + OpenSearch** Warden environment

---

## Central configuration: `_master.config`

Instead of multiple env files, everything is driven from one optional config:

```bash
CONFIG_FILE="${CONFIG_FILE:-_mage-mirror.config}"
if [[ -f "${CONFIG_FILE}" ]]; then
  echo "ℹ️  Loading configuration from ${CONFIG_FILE}..."
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi
```

You control everything via simple key/value pairs.

### Core settings

```bash
# Name of the Warden env / project (warden env-init <PROJECT_NAME> magento2)
PROJECT_NAME=mage

# Magento metapackage & version (fresh install + upgrade target)
MAGENTO_PACKAGE=magento/project-community-edition
# Use a Composer version constraint; 2.4.* resolves to the newest 2.4.x
MAGENTO_VERSION=2.4.*

# Admin frontname for Magento backend
ADMIN_FRONTNAME=mage_admin
```

### Install mode: fresh vs existing DB

```bash
# Use an existing DB + env.php/config.php instead of setup:install
#   yes  = always use existing DB (non-interactive)
#   no   = always run fresh install
#   ask  = prompt at runtime
USE_EXISTING_DB=ask

# When USE_EXISTING_DB=yes and NOT using remote DB dump,
# point to local files (relative to repo root):
EXISTING_DB_SQL=db/mage-multi-hyva.sql
EXISTING_ENV_PHP=config/env.php
EXISTING_CONFIG_PHP=config/config.php
```

### Sample data & Hyvä

```bash
# WITH_SAMPLE_DATA:
#   yes  = always install sample data on fresh installs
#   no   = never install
#   ask  = prompt at runtime
WITH_SAMPLE_DATA=ask

# INSTALL_HYVA:
#   yes  = install Hyvä theme from OSS repos and set as default
#   no   = skip Hyvä install
#   ask  = prompt at runtime
INSTALL_HYVA=ask
```

### Multi-store toggle

```bash
# ENABLE_MULTISTORE:
#   yes  = configure app.${PROJECT_NAME}.test + ${PROJECT_NAME}.test with a secondary 'subcats' website
#   no   = single-store only (no subcats website or host-based routing)
#   ask  = prompt at runtime
ENABLE_MULTISTORE=ask
```

- When enabled:
  - `app.${PROJECT_NAME}.test` → base website
  - `${PROJECT_NAME}.test` → `subcats` website
  - `pub/index.php` gets a small host switch to set `MAGE_RUN_CODE` correctly.
- When disabled:
  - Only the base website is configured
  - No host-based routing or subcats URLs are applied

### Upgrade mode (clone + upgrade)

```bash
# UPGRADE_MAGENTO:
#   yes  = after importing existing code/DB, attempt composer-based Magento core upgrade
#   no   = skip upgrade and keep current version
#   ask  = prompt at runtime in existing-DB path
UPGRADE_MAGENTO=ask

# UPGRADE_MAGENTO_VERSION:
#   Target core version for upgrade. If empty, MAGENTO_VERSION is used.
#   Example: 2.4.* (newest 2.4.x), or a specific release like 2.4.7
UPGRADE_MAGENTO_VERSION=2.4.*
```

How it works (existing DB path):

1. After code/DB import and env/config wiring, the script asks (if `ask`).
2. If enabled:
   - Figures out a target version:
     ```bash
     TARGET_VER="${UPGRADE_MAGENTO_VERSION:-${MAGENTO_VERSION:-2.4.*}}"
     ```
   - Updates the Magento core package constraint in `composer.json`:
     - `magento/product-community-edition:${TARGET_VER}` **or**
     - `magento/magento2-base:${TARGET_VER}`
   - Runs:
     ```bash
     composer update "magento/*" --with-all-dependencies
     ```
   - Then runs:
     ```bash
     bin/magento setup:upgrade
     bin/magento setup:di:compile
     bin/magento setup:static-content:deploy -f
     bin/magento cache:flush
     ```

Result: your cloned site is moved forward to the version you specify while keeping `app/code` and `app/design` modules.

---

## Remote sync (rsync / tar over SSH)

When `USE_EXISTING_DB=yes`, you can optionally pull code/DB from an existing remote instance.

Key flags:

```bash
# Use remote Magento code instead of composer create-project
#   yes  = always rsync from remote
#   no   = never rsync; always use composer locally
#   ask  = prompt at runtime if REMOTE_* is configured
USE_RSYNC_MAGENTO=ask

# How to combine rsync/tar + remote DB when using remote Magento:
#   ask       = prompt with menu (recommended)
#   (others are set internally by the script: everything | code_only | db_code | db_only)
USE_RSYNC_TAR_MAGENTO=ask

# Whether to pull the DB via remote mysqldump over SSH:
#   yes  = run mysqldump on remote host and pipe into warden db import
#   no   = use local SQL file (EXISTING_DB_SQL)
USE_REMOTE_DB_DUMP=no

# If you want to exclude pub/media from the tarball when copying code:
#   yes  = exclude pub/media (smaller tar, no media sync)
#   no   = include pub/media
EXCLUDE_MEDIA_FROM_TAR=no
```

Remote host/SSH:

```bash
# Where the remote Magento instance lives
REMOTE_HOST=your.server.com
REMOTE_USER=sshuser
REMOTE_PATH=/var/www/html/magento

# Path to your PRIVATE SSH key on the host running this script
# If unset or invalid, the script will:
#   - In interactive runs: fall back to password/agent-based SSH
#   - In non-interactive runs: exit with an error
REMOTE_SSH_KEY=/Users/yourname/.ssh/id_ed25519

# Remote DB settings (used when USE_REMOTE_DB_DUMP=yes)
REMOTE_DB_HOST=127.0.0.1
REMOTE_DB_NAME=magento
REMOTE_DB_USER=magento
REMOTE_DB_PASSWORD=secret
REMOTE_DB_PORT=3306
```

When rsync is enabled:

- If `REMOTE_SSH_KEY` exists:
  - The key is copied into the php-fpm container and used for all SSH/rsync calls.
- If `REMOTE_SSH_KEY` is missing/invalid:
  - If a TTY is attached, the script warns and falls back to **password/agent-based SSH**.  
    Expect `ssh` / `rsync` to prompt you.
  - If no TTY (CI/headless), the script exits and tells you to configure `REMOTE_SSH_KEY`.

The script supports four remote copy modes (chosen from an interactive menu when `USE_RSYNC_TAR_MAGENTO=ask`):

1. **Everything** → code + `pub/media` + remote DB
2. **Code only** → code (no media), DB from local SQL
3. **DB + Code only** → code (no media) + remote DB via `mysqldump`
4. **DB only** → DB via `mysqldump`, code via composer

---

## Multi-store URLs & hostnames

By default:

- `PROJECT_NAME=mage` → base domain `mage.test`, subdomain `app`
- The script updates `/etc/hosts` with:
  ```text
  127.0.0.1 mage.test app.mage.test
  ```

When `ENABLE_MULTISTORE=yes`:

- Magento base URLs are configured so that:
  - Default scope & website `base` → `https://app.mage.test/`
  - Website `subcats` → `https://mage.test/`
- `pub/index.php` is patched to route:
  - `app.mage.test` → website code `base`
  - `mage.test` → website code `subcats`
  - Anything else → `base`

When `ENABLE_MULTISTORE=no`:

- Only the base website is configured
- No `subcats` base URLs or host-based routing are applied

You can override Traefik values by setting:

```bash
# TRAEFIK_DOMAIN=mage.test
# TRAEFIK_SUBDOMAIN=app
# SUBCATS_URL=https://mage.test/
```

in `_master.config` if needed.

---

## OpenSearch & search sanity

For both fresh installs and existing DB imports, the script standardizes on **OpenSearch**:

- Fresh installs use `--search-engine=opensearch` with the right flags on `setup:install`.
- Existing DB path:
  - Waits for `opensearch:9200`
  - Forces:

    ```bash
    bin/magento config:set catalog/search/engine opensearch
    bin/magento config:set catalog/search/opensearch_server_hostname opensearch
    bin/magento config:set catalog/search/opensearch_server_port 9200
    bin/magento config:set catalog/search/opensearch_index_prefix magento2
    bin/magento config:set catalog/search/opensearch_enable_auth 0
    ```

  - Rebuilds `catalogsearch_fulltext`

If you see **“No alive nodes found in your cluster”**, this is the part that rewires Magento back to Warden’s OpenSearch instance.

---

## Docker Desktop 4.29 / Warden note

Docker Desktop **4.29** tightened container isolation and Docker socket access.  
If your Warden setup suddenly starts misbehaving after upgrading Docker Desktop (e.g. permission errors, services not starting as expected):

1. Try downgrading Docker Desktop to a pre-4.29 build (e.g. 4.28) known to work with your Warden version.
2. Or adjust Enhanced Container Isolation / socket mount settings if you’re on a plan that exposes them.
3. Keep Warden relatively up-to-date to match Docker changes.

This script just shells out to `docker` / `warden` — if those tools are happy, the installer will be too.

---

## Example one-liners

### Fresh install (Hyvä + sample data)

```bash
PROJECT_NAME=mage USE_EXISTING_DB=no WITH_SAMPLE_DATA=yes INSTALL_HYVA=yes ENABLE_MULTISTORE=no ./_mage-mirror.sh
```

### Clone existing site from local dump (no upgrade, single-store)

```bash
PROJECT_NAME=mage USE_EXISTING_DB=yes EXISTING_DB_SQL=db/mage-multi-hyva.sql EXISTING_ENV_PHP=config/env.php EXISTING_CONFIG_PHP=config/config.php WITH_SAMPLE_DATA=no INSTALL_HYVA=no ENABLE_MULTISTORE=no UPGRADE_MAGENTO=no ./_mage-mirror.sh
```

### Clone from remote + upgrade to newest 2.4.x + multi-store

```bash
PROJECT_NAME=mage USE_EXISTING_DB=yes USE_RSYNC_MAGENTO=yes USE_RSYNC_TAR_MAGENTO=yes USE_REMOTE_DB_DUMP=yes WITH_SAMPLE_DATA=no INSTALL_HYVA=yes ENABLE_MULTISTORE=yes UPGRADE_MAGENTO=yes UPGRADE_MAGENTO_VERSION=2.4.* ./_mage-mirror.sh
```

(Assumes `_master.config` defines working `REMOTE_*` values.)

---

## TL;DR

- One script: **`_mage-mirror.sh`**
- One config: **`_master.config`**
- Three core modes:
  1. Fresh install (Magento + Hyvä)
  2. Clone existing site (code + DB)
  3. Clone **and** upgrade to a newer Magento version

Perfect for quickly spinning up **mirror environments**, rehearsal upgrades, or portfolio-ready Hyvä stores on macOS with Warden.

Happy hacking. 🧙‍♂️
