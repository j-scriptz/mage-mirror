#!/usr/bin/env bash

set -euo pipefail

# ---- Optional centralized config file (.env.config) ----
# If .env.config exists, source it to pre-populate PROJECT_NAME, USE_EXISTING_DB,
# remote rsync settings (REMOTE_*), and other toggles used below. Any real
# environment variables you export before running the script will always win.
CONFIG_FILE="${CONFIG_FILE:-_mage-mirror.config}"
if [[ -f "${CONFIG_FILE}" ]]; then
  echo "ℹ️  Loading configuration from ${CONFIG_FILE}..."
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

### ---- Configurable bits up top ----

PROJECT_NAME="${PROJECT_NAME:-mage}"       # WARDEN_ENV_NAME
MAGENTO_PACKAGE="${MAGENTO_PACKAGE:-magento/project-community-edition}"
MAGENTO_VERSION="${MAGENTO_VERSION:-2.4.x}"   # "2.4.x" = latest 2.4

MAGENTO_DB_HOST="${MAGENTO_DB_HOST:-db}"
MAGENTO_DB_NAME="${MAGENTO_DB_NAME:-magento}"
MAGENTO_DB_USER="${MAGENTO_DB_USER:-magento}"
MAGENTO_DB_PASSWORD="${MAGENTO_DB_PASSWORD:-magento}"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-Admin123!}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME:-Admin}"
ADMIN_LASTNAME="${ADMIN_LASTNAME:-User}"

# Let warden env-init decide these (usually TRAEFIK_DOMAIN=${PROJECT_NAME}.test, TRAEFIK_SUBDOMAIN=app)
TRAEFIK_DOMAIN=""
TRAEFIK_SUBDOMAIN=""

# Fresh install vs import existing DB
USE_EXISTING_DB="${USE_EXISTING_DB:-ask}"     # "yes", "no", or "ask"
EXISTING_DB_SQL="${EXISTING_DB_SQL:-}"        # path to .sql inside project tree
EXISTING_ENV_PHP="${EXISTING_ENV_PHP:-config/env.php}"      # path to env.php
EXISTING_CONFIG_PHP="${EXISTING_CONFIG_PHP:-config/config.php}"

# Optional rsync of existing remote Magento code (only when using existing DB)
USE_RSYNC_MAGENTO="${USE_RSYNC_MAGENTO:-ask}"   # "yes", "no", or "ask"
RSYNC_ENV_FILE="${RSYNC_ENV_FILE:-.env.config}"  # centralized config for REMOTE_* and other options
USE_RSYNC_TAR_MAGENTO="${USE_RSYNC_TAR_MAGENTO:-ask}"  # "yes", "no", or "ask" (only used if USE_RSYNC_MAGENTO=yes)
USE_REMOTE_DB_DUMP="${USE_REMOTE_DB_DUMP:-no}"         # "yes" to pull DB via remote mysqldump over SSH
REMOTE_COPY_MODE=""                                     # internal: everything | code_only | db_code | db_only
EXCLUDE_MEDIA_FROM_TAR="${EXCLUDE_MEDIA_FROM_TAR:-no}" # "yes" to exclude pub/media from tar-over-ssh

# Toggle these by env var if you want non-interactive runs:
WITH_SAMPLE_DATA="${WITH_SAMPLE_DATA:-ask}"   # "yes", "no", or "ask" (ignored in existing-DB mode)
INSTALL_HYVA="${INSTALL_HYVA:-ask}"           # "yes", "no", or "ask"
ENABLE_MULTISTORE="${ENABLE_MULTISTORE:-ask}" # "yes", "no", or "ask"
UPGRADE_MAGENTO="${UPGRADE_MAGENTO:-ask}"     # "yes", "no", or "ask" (existing-DB path only)
UPGRADE_MAGENTO_VERSION="${UPGRADE_MAGENTO_VERSION:-${MAGENTO_VERSION:-2.4.*}}"  # target core version for upgrade

INSTALL_JSCRIPTZ="${INSTALL_JSCRIPTZ:-ask}"           # "yes", "no", or "ask"

DISABLE_TWOFACTOR_AUTH="${DISABLE_TWOFACTOR_AUTH:-true}"
MAGENTO_DEVELOPER_MODE="${MAGENTO_DEVELOPER_MODE:-true}"
DISABLE_CONFIG_CACHE="${DISABLE_CONFIG_CACHE:-true}"
DISABLE_FULLPAGE_CACHE="${DISABLE_FULLPAGE_CACHE:-true}"

# Custom admin route
ADMIN_FRONTNAME="${ADMIN_FRONTNAME:-mage_admin}"


echo "=========================================="
echo " Magento 2 + Hyvä via Warden (macOS / Linux / Windows WSL2/Ubuntu)"
echo " Project        : ${PROJECT_NAME}"
echo " Primary domain : https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
echo " Admin URL      : /${ADMIN_FRONTNAME}"
echo "=========================================="
echo ""

### ---- Basic sanity checks (Docker + OS) ----

OS_NAME="$(uname -s)"
PLATFORM_OS="other"

case "${OS_NAME}" in
  Darwin)
    PLATFORM_OS="macos"
    ;;
  Linux)
    PLATFORM_OS="linux"
    ;;
  *)
    PLATFORM_OS="other"
    ;;
esac

if [[ "${PLATFORM_OS}" == "other" ]]; then
  echo "⚠️  This script is tuned for macOS and Linux. You're on ${OS_NAME}."
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ Docker not found. Install Docker (Docker Desktop on macOS, Docker Engine on Linux) and rerun."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker is installed but not running. Start it and rerun."
  exit 1
fi

### ---- Ensure Warden (macOS: auto-install via Homebrew, Linux: require pre-installed) ----

if ! command -v warden >/dev/null 2>&1; then
  if [[ "${PLATFORM_OS}" == "macos" ]]; then
    echo "➡️  Warden not found, installing via Homebrew..."

    if ! command -v brew >/dev/null 2>&1; then
      echo "➡️  Homebrew not found, installing..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

      # Add Homebrew to PATH for Apple Silicon
      if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      fi
    fi

    brew install wardenenv/warden/warden
  else
    echo "❌ Warden is not in PATH."
    echo "   On Linux, install Warden following the official docs https://docs.warden.dev/installing.html#alternative-installation, then rerun this script."
    exit 1
  fi
fi

echo "✅ Warden is installed at $(command -v warden)"

### ---- Start Warden global services ----

echo ""
echo "➡️  Starting Warden global services (svc up)..."
warden svc up

### ---- Initialize Warden env (.env) ----

if [[ ! -f .env ]]; then
  echo ""
  echo "➡️  Creating Warden .env for ${PROJECT_NAME} (magento2)..."
  warden env-init "${PROJECT_NAME}" magento2
else
  echo ""
  echo "ℹ️  .env already exists, skipping warden env-init"
fi

# Read TRAEFIK_DOMAIN and TRAEFIK_SUBDOMAIN from .env (whatever Warden chose)
if [[ -f .env ]]; then
  # shellcheck disable=SC2046
  eval "$(grep -E '^(TRAEFIK_DOMAIN|TRAEFIK_SUBDOMAIN)=' .env || true)"
fi

if [[ -z "${TRAEFIK_DOMAIN:-}" || -z "${TRAEFIK_SUBDOMAIN:-}" ]]; then
  echo "❌ Could not determine TRAEFIK_DOMAIN / TRAEFIK_SUBDOMAIN from .env"
  echo "   Make sure 'warden env-init ${PROJECT_NAME} magento2' ran successfully."
  exit 1
fi

echo ""
echo "Primary domain : https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"

# Re-read explicitly to overwrite defaults if needed
if [[ -f .env ]]; then
  ENV_TRAEFIK_DOMAIN=$(grep -E '^TRAEFIK_DOMAIN=' .env | head -n1 | cut -d= -f2- || true)
  ENV_TRAEFIK_SUBDOMAIN=$(grep -E '^TRAEFIK_SUBDOMAIN=' .env | head -n1 | cut -d= -f2- || true)

  if [[ -n "${ENV_TRAEFIK_DOMAIN}" ]]; then
    TRAEFIK_DOMAIN="${ENV_TRAEFIK_DOMAIN}"
  fi
  if [[ -n "${ENV_TRAEFIK_SUBDOMAIN}" ]]; then
    TRAEFIK_SUBDOMAIN="${ENV_TRAEFIK_SUBDOMAIN}"
  fi
fi

### ---- Composer auth.json ----

if [[ -f auth.json ]]; then
  echo ""
  echo "➡️  Found composer auth / magento repo at ./auth.json;"

else
  echo ""
  echo "ℹ️  No auth.json found; Composer may prompt for repo.magento.com auth."
fi

### ---- Decide whether to use existing DB ----

if [[ "${USE_EXISTING_DB}" == "ask" ]]; then
  echo ""
  read -r -p "Use existing Magento (instead of fresh setup:install)? (y/N): " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    USE_EXISTING_DB="yes"
  else
    USE_EXISTING_DB="no"
  fi
fi

### ---- Decide whether to enable local multi-store ----

if [[ "${ENABLE_MULTISTORE}" == "ask" ]]; then
  echo ""
  read -r -p "Enable local multi-store (app.${PROJECT_NAME}.test + ${PROJECT_NAME}.test with 'subcats' website)? (y/N): " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    ENABLE_MULTISTORE="yes"
  else
    ENABLE_MULTISTORE="no"
  fi
fi

RSYNC_REMOTE_HOST=""
RSYNC_REMOTE_USER=""
RSYNC_REMOTE_PATH=""
RSYNC_REMOTE_SSH_KEY=""

# Optional: remote DB credentials for mysqldump (used for tar/DB modes)
RSYNC_REMOTE_DB_HOST=""
RSYNC_REMOTE_DB_NAME=""
RSYNC_REMOTE_DB_USER=""
RSYNC_REMOTE_DB_PASSWORD=""
RSYNC_REMOTE_DB_PORT=""

if [[ "${USE_EXISTING_DB}" == "yes" ]]; then

    echo ""
    echo "ℹ️  Loading rsync settings..."

    RSYNC_REMOTE_HOST="${REMOTE_HOST:-}"
    RSYNC_REMOTE_USER="${REMOTE_USER:-}"
    RSYNC_REMOTE_PATH="${REMOTE_PATH:-}"
    RSYNC_REMOTE_SSH_KEY="${REMOTE_SSH_KEY:-}"

    # Optional remote DB settings (for mysqldump over SSH)
    RSYNC_REMOTE_DB_HOST="${REMOTE_DB_HOST:-}"
    RSYNC_REMOTE_DB_NAME="${REMOTE_DB_NAME:-}"
    RSYNC_REMOTE_DB_USER="${REMOTE_DB_USER:-}"
    RSYNC_REMOTE_DB_PASSWORD="${REMOTE_DB_PASSWORD:-}"
    RSYNC_REMOTE_DB_PORT="${REMOTE_DB_PORT:-3306}"

  if [[ "${USE_RSYNC_MAGENTO}" == "ask" ]]; then
    if [[ -n "${RSYNC_REMOTE_HOST}" && -n "${RSYNC_REMOTE_USER}" && -n "${RSYNC_REMOTE_PATH}" ]]; then
      echo ""
      read -r -p "Rsync remote Magento code from ${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}:${RSYNC_REMOTE_PATH} into the Warden php-fpm container (instead of composer create-project)? (y/N): " REPLY
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        USE_RSYNC_MAGENTO="yes"
      else
        USE_RSYNC_MAGENTO="no"
      fi
    else
      USE_RSYNC_MAGENTO="no"
    fi
  fi
fi

# Decide tar/rsync + remote DB behaviour when using remote Magento code
if [[ "${USE_EXISTING_DB}" == "yes" && "${USE_RSYNC_MAGENTO}" == "yes" ]]; then
  if [[ "${USE_RSYNC_TAR_MAGENTO}" == "ask" ]]; then
    echo ""
    echo "How would you like to sync from the remote Magento instance?"
    echo "  1) Everything (DB, code, *including* pub/media)"
    echo "  2) Code only (tar, exclude pub/media)"
    echo "  3) DB + Code only (tar, exclude pub/media)"
    echo "  4) DB only (no remote code; install code via composer)"
    read -r -p "Enter choice [1-4, default: 2]: " REPLY

    case "$REPLY" in
      1) REMOTE_COPY_MODE="everything" ;;
      3) REMOTE_COPY_MODE="db_code" ;;
      4) REMOTE_COPY_MODE="db_only" ;;
      2|"") REMOTE_COPY_MODE="code_only" ;;
      *) REMOTE_COPY_MODE="code_only" ;;
    esac

    case "$REMOTE_COPY_MODE" in
      everything)
        USE_RSYNC_TAR_MAGENTO="yes"
        USE_REMOTE_DB_DUMP="yes"
        EXCLUDE_MEDIA_FROM_TAR="no"
        ;;
      code_only)
        USE_RSYNC_TAR_MAGENTO="yes"
        USE_REMOTE_DB_DUMP="no"
        EXCLUDE_MEDIA_FROM_TAR="yes"
        ;;
      db_code)
        USE_RSYNC_TAR_MAGENTO="yes"
        USE_REMOTE_DB_DUMP="yes"
        EXCLUDE_MEDIA_FROM_TAR="yes"
        ;;
      db_only)
        # DB from remote, code installed via composer locally
        USE_RSYNC_TAR_MAGENTO="no"
        USE_RSYNC_MAGENTO="no"
        USE_REMOTE_DB_DUMP="yes"
        EXCLUDE_MEDIA_FROM_TAR="no"
        ;;
    esac
  fi
fi

EXISTING_DB_SQL_REL=""
EXISTING_ENV_PHP_REL=""
EXISTING_CONFIG_PHP_REL=""

if [[ "${USE_EXISTING_DB}" == "yes" ]]; then
  echo ""
  echo "➡️  Existing DB import selected."

  # If we're *not* pulling the DB from remote via mysqldump, we still
  # need a local SQL dump plus env.php/config.php.
  if [[ "${USE_REMOTE_DB_DUMP}" != "yes" ]]; then
    if [[ -z "${EXISTING_DB_SQL}" ]]; then
      read -r -p "Path to existing DB dump (.sql, relative to project root, e.g. db/mage.sql): " EXISTING_DB_SQL
    fi
    if [[ -z "${EXISTING_ENV_PHP}" ]]; then
      read -r -p "Path to existing env.php (relative to project root, e.g. config/env.php): " EXISTING_ENV_PHP
    fi
    # If user hit enter and our known defaults exist, use them
    if [[ -z "${EXISTING_DB_SQL}" && -f db/mage-multi-hyva.sql ]]; then
      EXISTING_DB_SQL="db/mage-multi-hyva.sql"
      echo "ℹ️  Using default DB dump: ${EXISTING_DB_SQL}"
    fi
    if [[ -z "${EXISTING_ENV_PHP}" && -f config/env.php ]]; then
      EXISTING_ENV_PHP="config/env.php"
      echo "ℹ️  Using default env.php: ${EXISTING_ENV_PHP}"
    fi
    if [[ -z "${EXISTING_CONFIG_PHP}" && -f config/config.php ]]; then
      EXISTING_CONFIG_PHP="config/config.php"
      echo "ℹ️  Using default config.php: ${EXISTING_CONFIG_PHP}"
    fi
    if [[ ! -f "${EXISTING_DB_SQL}" ]]; then
      echo "❌ DB dump not found at ${EXISTING_DB_SQL}"
      exit 1
    fi
    if [[ ! -f "${EXISTING_ENV_PHP}" ]]; then
      echo "❌ env.php not found at ${EXISTING_ENV_PHP}"
      exit 1
    fi
    if [[ ! -f "${EXISTING_CONFIG_PHP}" ]]; then
      echo "❌ config.php not found at ${EXISTING_CONFIG_PHP}"
      exit 1
    fi
    # Normalise paths for container (relative to /var/www/html)
    EXISTING_DB_SQL_REL="${EXISTING_DB_SQL#./}"
    EXISTING_ENV_PHP_REL="${EXISTING_ENV_PHP#./}"
    EXISTING_CONFIG_PHP_REL="${EXISTING_CONFIG_PHP#./}"
  else
    # Remote DB mode: we still need env.php/config.php when NOT using rsync for code.
    if [[ "${USE_RSYNC_MAGENTO}" != "yes" ]]; then
      if [[ -z "${EXISTING_ENV_PHP}" ]]; then
        read -r -p "Path to existing env.php (relative to project root, e.g. config/env.php): " EXISTING_ENV_PHP
      fi
      if [[ -z "${EXISTING_CONFIG_PHP}" && -f config/config.php ]]; then
        EXISTING_CONFIG_PHP="config/config.php"
        echo "ℹ️  Using default config.php: ${EXISTING_CONFIG_PHP}"
      fi
      if [[ ! -f "${EXISTING_ENV_PHP}" ]]; then
        echo "❌ env.php not found at ${EXISTING_ENV_PHP}"
        exit 1
      fi
      if [[ ! -f "${EXISTING_CONFIG_PHP}" ]]; then
        echo "❌ config.php not found at ${EXISTING_CONFIG_PHP}"
        exit 1
      fi
      EXISTING_ENV_PHP_REL="${EXISTING_ENV_PHP#./}"
      EXISTING_CONFIG_PHP_REL="${EXISTING_CONFIG_PHP#./}"
    fi
  fi
fi

### ---- /etc/hosts entry for mage.test + app.mage.test ----

if ! grep -q "${TRAEFIK_DOMAIN}" /etc/hosts 2>/dev/null; then
  echo ""
  echo "➡️  Adding hosts entry (requires sudo):"
  echo "    127.0.0.1 ${TRAEFIK_DOMAIN} ${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}"
  sudo sh -c "echo '127.0.0.1 ${TRAEFIK_DOMAIN} ${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}' >> /etc/hosts"
else
  echo "ℹ️  /etc/hosts already contains ${TRAEFIK_DOMAIN}"
fi

### ---- Sign TLS cert for TRAEFIK_DOMAIN ----

echo ""
echo "➡️  Signing TLS certificate for ${TRAEFIK_DOMAIN}..."
warden sign-certificate "${TRAEFIK_DOMAIN}"

### ---- Bring environment up ----

echo ""
echo "➡️  Starting Warden environment (env up)..."
warden env up

echo ""
echo "✅ Warden environment is up."
echo "   Containers will expose: https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
echo ""

### ---- Magento code + DB (fresh install vs import) ----

echo "➡️  Setting up Magento codebase and database..."

if [[ "${USE_EXISTING_DB}" == "yes" ]]; then

  echo ""
  echo "➡️  Importing existing DB into Warden database..."

  if [[ "${USE_REMOTE_DB_DUMP}" == "yes" ]]; then
    echo "  - Using remote mysqldump streamed over SSH"

    if [[ -z "${RSYNC_REMOTE_DB_HOST}" || -z "${RSYNC_REMOTE_DB_NAME}" || -z "${RSYNC_REMOTE_DB_USER}" || -z "${RSYNC_REMOTE_DB_PASSWORD}" ]]; then
      echo "❌ USE_REMOTE_DB_DUMP=yes but REMOTE_DB_HOST/NAME/USER/PASSWORD not set in ${CONFIG_FILE}."
      echo "   Make sure your _mage-mirror.config defines REMOTE_DB_HOST, REMOTE_DB_NAME, REMOTE_DB_USER, REMOTE_DB_PASSWORD."
      exit 1
    fi

    SSH_CMD=(ssh -o StrictHostKeyChecking=no)
    if [[ -n "${RSYNC_REMOTE_SSH_KEY}" ]]; then
      SSH_CMD=(ssh -i "${RSYNC_REMOTE_SSH_KEY}" -o StrictHostKeyChecking=no)
    fi

    # Stream mysqldump over SSH, fix utf8mb4_0900_* collations on the fly, and import into the Warden DB.
    "${SSH_CMD[@]}" "${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}" \
      "mysqldump --single-transaction -h \"${RSYNC_REMOTE_DB_HOST}\" -P \"${RSYNC_REMOTE_DB_PORT}\" -u \"${RSYNC_REMOTE_DB_USER}\" -p\"${RSYNC_REMOTE_DB_PASSWORD}\" \"${RSYNC_REMOTE_DB_NAME}\"" \
      | sed 's/utf8mb4_0900_ai_ci/utf8mb4_general_ci/g' \
      | warden db import

  else
    echo "  - Using local SQL dump: ${EXISTING_DB_SQL}"

    # Some dumps from MySQL 8 use utf8mb4_0900_* collations which MariaDB doesn't support.
    # If we see those, rewrite them to a MariaDB-compatible collation on the fly.
    if grep -q "utf8mb4_0900" "${EXISTING_DB_SQL}"; then
      echo "ℹ️  Detected MySQL 8 utf8mb4_0900_* collations; rewriting to utf8mb4_general_ci for MariaDB..."
      sed 's/utf8mb4_0900_ai_ci/utf8mb4_general_ci/g' "${EXISTING_DB_SQL}" | warden db import
    else
      warden db import < "${EXISTING_DB_SQL}"
    fi
  fi

  # If rsync is enabled for code, copy SSH key into php-fpm container so rsync/ssh can use it.
  # If no key is configured and we are running interactively (TTY attached), fall back to
  # password/agent-based SSH and let ssh/rsync prompt the user as needed.
  if [[ "${USE_RSYNC_MAGENTO}" == "yes" ]]; then
    if [[ -z "${RSYNC_REMOTE_SSH_KEY}" || ! -f "${RSYNC_REMOTE_SSH_KEY}" ]]; then
      if [[ -t 0 || -t 1 ]]; then
        echo "⚠️  USE_RSYNC_MAGENTO=yes but REMOTE_SSH_KEY is not set or file not found."
        echo "    Falling back to password/agent-based SSH. ssh/rsync may prompt you for a password."
        # No id_rsa will be created inside the container; rsync/ssh will use default SSH behavior.
      else
        echo "❌ USE_RSYNC_MAGENTO=yes but REMOTE_SSH_KEY is not set or file not found, and no TTY is attached."
        echo "   For non-interactive runs, set REMOTE_SSH_KEY in ${CONFIG_FILE} (or as an env var) to a valid private key."
        exit 1
      fi
    else
      echo ""
      echo "➡️  Copying SSH key into php-fpm container for rsync..."
      warden env exec -T php-fpm bash -lc 'mkdir -p /home/www-data/.ssh && chmod 700 /home/www-data/.ssh'
      warden env exec -T php-fpm bash -lc 'cat > /home/www-data/.ssh/id_rsa && chmod 600 /home/www-data/.ssh/id_rsa' < "${RSYNC_REMOTE_SSH_KEY}"
    fi
  fi

##########################################
  # Path A: existing DB + env.php import  #
  ##########################################
warden env exec -T php-fpm env \
  MAGENTO_PACKAGE="${MAGENTO_PACKAGE}" \
  MAGENTO_VERSION="${MAGENTO_VERSION}" \
  UPGRADE_MAGENTO="${UPGRADE_MAGENTO}" \
  UPGRADE_MAGENTO_VERSION="${UPGRADE_MAGENTO_VERSION}" \
  ADMIN_FRONTNAME="${ADMIN_FRONTNAME}" \
  TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN}" \
  TRAEFIK_SUBDOMAIN="${TRAEFIK_SUBDOMAIN}" \
  ENABLE_MULTISTORE="${ENABLE_MULTISTORE}" \
  EXISTING_DB_SQL_REL="${EXISTING_DB_SQL_REL}" \
  EXISTING_ENV_PHP_REL="${EXISTING_ENV_PHP_REL}" \
  EXISTING_CONFIG_PHP_REL="${EXISTING_CONFIG_PHP_REL}" \
  USE_RSYNC_MAGENTO="${USE_RSYNC_MAGENTO}" \
  RSYNC_REMOTE_HOST="${RSYNC_REMOTE_HOST:-}" \
  RSYNC_REMOTE_USER="${RSYNC_REMOTE_USER:-}" \
  RSYNC_REMOTE_PATH="${RSYNC_REMOTE_PATH:-}" \
  USE_RSYNC_TAR_MAGENTO="${USE_RSYNC_TAR_MAGENTO}" \
  EXCLUDE_MEDIA_FROM_TAR="${EXCLUDE_MEDIA_FROM_TAR:-no}" \
  bash <<'MAGENTO_EXISTING'

set -e

cd /var/www/html

echo "➡️  Installing Magento code (rsync or composer)..."

if [ "${USE_RSYNC_MAGENTO:-no}" = "yes" ]; then
  echo "  - Using remote codebase from ${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}:${RSYNC_REMOTE_PATH}..."

  if [ -z "${RSYNC_REMOTE_HOST:-}" ] || [ -z "${RSYNC_REMOTE_USER:-}" ] || [ -z "${RSYNC_REMOTE_PATH:-}" ]; then
    echo "❌ USE_RSYNC_MAGENTO is yes but RSYNC_REMOTE_HOST/USER/PATH are not set."
    exit 1
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    echo "❌ rsync is not available inside php-fpm container."
    exit 1
  fi

  RSYNC_SSH_CMD="ssh -o StrictHostKeyChecking=no"
  if [ -f /home/www-data/.ssh/id_rsa ]; then
    RSYNC_SSH_CMD="ssh -i /home/www-data/.ssh/id_rsa -o StrictHostKeyChecking=no"
  fi

  if [ "${USE_RSYNC_TAR_MAGENTO:-no}" = "yes" ]; then
    echo "    Mode: tar-over-ssh (create tar on remote, rsync tarball, extract locally)"
    REMOTE_TAR="/tmp/magento-warden-$(date +%s).tar.gz"

    # Derive directory and basename from RSYNC_REMOTE_PATH
    REMOTE_DIR="$(dirname "${RSYNC_REMOTE_PATH}")"
    REMOTE_BASE="$(basename "${RSYNC_REMOTE_PATH}")"

    echo "    Creating tarball on remote at ${REMOTE_TAR}..."

    EXCLUDES="--exclude=${REMOTE_BASE}/generated \
          --exclude=${REMOTE_BASE}/var/cache \
          --exclude=${REMOTE_BASE}/var/report \
          --exclude=${REMOTE_BASE}/var/log \
          --exclude=${REMOTE_BASE}/var/generated \
          --exclude=${REMOTE_BASE}/var/view_preprocessed \
          --exclude=${REMOTE_BASE}/pub/static \
          --exclude=${REMOTE_BASE}/pub/media/downloadable"

    if [ "${EXCLUDE_MEDIA_FROM_TAR:-no}" = "yes" ]; then
      EXCLUDES="${EXCLUDES} --exclude=${REMOTE_BASE}/pub/media"
    fi

    $RSYNC_SSH_CMD "${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}" \
      "tar czfh ${REMOTE_TAR} --ignore-failed-read -C \"${REMOTE_DIR}\" ${EXCLUDES} \"${REMOTE_BASE}\"" || {
        echo "❌ Failed to create tarball on remote host."
        exit 1
      }

    echo "    Rsyncing tarball down to container..."
    rsync -avz -e "$RSYNC_SSH_CMD" \
      "${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}:${REMOTE_TAR}" \
      /tmp/magento-remote.tar.gz

    echo "    Removing tarball from remote host..."
    $RSYNC_SSH_CMD "${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}" "rm -f ${REMOTE_TAR}" || true

    echo "    Extracting tarball into /var/www/html..."
    mkdir -p /var/www/html

    # Clean up any bad pub / pub/media from previous runs
    if [ -e /var/www/html/pub ] && [ ! -d /var/www/html/pub ]; then
      echo "    ⚠️ /var/www/html/pub exists but is not a directory (likely a symlink); removing."
      rm -f /var/www/html/pub
    fi

    if [ -e /var/www/html/pub/media ] && [ ! -d /var/www/html/pub/media ]; then
      echo "    ⚠️ /var/www/html/pub/media exists but is not a directory (likely a symlink); removing."
      rm -f /var/www/html/pub/media
    fi

    tar xzf /tmp/magento-remote.tar.gz -C /var/www/html --strip-components=1

  else
    echo "    Mode: direct rsync of directory"
    echo "    Source: ${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}:${RSYNC_REMOTE_PATH}"
    echo "    Target: /var/www/html"

    rsync -avz -e "$RSYNC_SSH_CMD" \
      "${RSYNC_REMOTE_USER}@${RSYNC_REMOTE_HOST}:${RSYNC_REMOTE_PATH}/" \
      /var/www/html/
  fi

else
  echo "➡️  Installing Magento code via composer (if not present)..."
  if [ ! -d vendor ]; then
    META_PACKAGE="${MAGENTO_PACKAGE:-magento/project-community-edition}"
    META_VERSION="${MAGENTO_VERSION:-2.4.*}"
    if [ -f auth.json ]; then
      echo "  - auth.json found; using COMPOSER_AUTH for repo.magento.com..."
      export COMPOSER_AUTH="$(cat auth.json)"
    fi

    composer create-project --repository-url=https://repo.magento.com/ \
      "${META_PACKAGE}" /tmp/magento "${META_VERSION}"

    rsync -a /tmp/magento/ /var/www/html/
    rm -rf /tmp/magento/
  fi
fi

# Wire up env.php and config.php inside the container
if [ "${USE_RSYNC_MAGENTO:-no}" = "yes" ]; then
  # In rsync mode we expect env.php to already live in app/etc/env.php from the remote codebase
  if [ ! -f app/etc/env.php ]; then
    echo "❌ Expected app/etc/env.php from remote code, but it is missing."
    echo "   Make sure your remote Magento root (${RSYNC_REMOTE_PATH}) contains app/etc/env.php."
    exit 1
  fi
  echo "➡️  Using env.php from rsynced app/etc/env.php..."
else
  # Non-rsync mode: copy env.php and config.php from the paths provided on the host (EXISTING_ENV_PHP_REL / EXISTING_CONFIG_PHP_REL)
  if [ ! -f "/var/www/html/${EXISTING_ENV_PHP_REL}" ]; then
    echo "❌ Cannot find env.php inside container at /var/www/html/${EXISTING_ENV_PHP_REL}"
    exit 1
  fi

  echo "➡️  Copying existing env.php and config.php into app/etc/..."
  mkdir -p app/etc
  cp "/var/www/html/${EXISTING_ENV_PHP_REL}" app/etc/env.php
  cp "/var/www/html/${EXISTING_CONFIG_PHP_REL}" app/etc/config.php
fi

# Ensure DB host matches Warden's db service (imported env.php often has remote host like 'mysql' or 'localhost')
php <<'PHP'
<?php
$envFile = __DIR__ . '/app/etc/env.php';
if (!file_exists($envFile)) {
    fwrite(STDERR, "env.php not found at {$envFile}\n");
    exit(0);
}
$env = include $envFile;
if (!is_array($env)) {
    fwrite(STDERR, "env.php did not return an array, skipping DB host adjustment.\n");
    exit(0);
}

if (isset($env['db']['connection']['default']['host'])) {
    $oldHost = $env['db']['connection']['default']['host'];
    if ($oldHost !== 'db') {
        $env['db']['connection']['default']['host'] = 'db';
        $code = "<?php\nreturn " . var_export($env, true) . ";\n";
        file_put_contents($envFile, $code);
        fwrite(STDOUT, "➡️  Updated DB host in env.php from '{$oldHost}' to 'db'.\n");
    }
}
PHP

# Optional: generate config.php if missing
if [ ! -f app/etc/config.php ]; then
  echo "➡️  app/etc/config.php missing; generating deployment configuration from code..."
  php <<'PHP'
<?php
$root = getcwd();

// Load Magento autoloader
$autoload1 = $root . '/app/autoload.php';
$autoload2 = $root . '/vendor/autoload.php';
if (file_exists($autoload1)) {
    require $autoload1;
} elseif (file_exists($autoload2)) {
    require $autoload2;
} else {
    fwrite(STDERR, "Autoloader not found.\n");
    exit(1);
}

if (!class_exists(\Magento\Framework\Component\ComponentRegistrar::class)) {
    fwrite(STDERR, "ComponentRegistrar missing.\n");
    exit(1);
}

// Let Composer handle vendor modules; we only manually register app/code modules.
$appCodeDir = $root . '/app/code';
if (is_dir($appCodeDir)) {
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($appCodeDir, RecursiveDirectoryIterator::SKIP_DOTS)
    );
    foreach ($iterator as $file) {
        if ($file->getFilename() === 'registration.php') {
            require_once $file->getPathname();
        }
    }
}

// Use ComponentRegistrar instance (works with non-static getPaths())
$registrar = new \Magento\Framework\Component\ComponentRegistrar();
$modules = $registrar->getPaths(\Magento\Framework\Component\ComponentRegistrar::MODULE);

$config = ['modules' => []];
foreach (array_keys($modules) as $name) {
    $config['modules'][$name] = 1;
}

$etcDir = $root . '/app/etc';
if (!is_dir($etcDir)) {
    mkdir($etcDir, 0775, true);
}

file_put_contents($etcDir . '/config.php', "<?php\nreturn " . var_export($config, true) . ";\n");
echo "config.php generated with " . count($config['modules']) . " modules.\n";
PHP
fi


# Ensure setup/config/application.config.php exists (some production installs remove the setup directory)
echo "➡️  Ensuring setup/config/application.config.php exists..."
if [ ! -f setup/config/application.config.php ]; then
  echo "⚠️  setup/config/application.config.php missing; bootstrapping setup directory from a temporary composer project..."
  META_PACKAGE="${MAGENTO_PACKAGE:-magento/project-community-edition}"
  META_VERSION="${MAGENTO_VERSION:-2.4.*}"

  if [ -f auth.json ]; then
    echo "  - auth.json found; using COMPOSER_AUTH for repo.magento.com..."
    export COMPOSER_AUTH="$(cat auth.json)"
  else
    echo "  - WARNING: auth.json not found; Composer may prompt for repo.magento.com credentials."
  fi

  composer create-project --repository-url=https://repo.magento.com/ "$META_PACKAGE" /tmp/magento-setup "$META_VERSION"

  if [ -d /tmp/magento-setup/setup ]; then
    echo "  - setup directory created, copying into project root..."
    rm -rf setup
    mv /tmp/magento-setup/setup ./setup
  else
    echo "❌ Expected /tmp/magento-setup/setup but it was not created."
    ls -la /tmp || true
    ls -la /tmp/magento-setup || true
    exit 1
  fi

  rm -rf /tmp/magento-setup
else
  echo "ℹ️  setup/config/application.config.php already present; skipping setup bootstrap."
fi


# Optional Magento core upgrade via composer (existing DB path)
if [ "${UPGRADE_MAGENTO:-no}" = "ask" ]; then
  echo ""
  read -r -p "Attempt Magento core upgrade via composer after importing existing code/DB? (y/N): " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    UPGRADE_MAGENTO="yes"
  else
    UPGRADE_MAGENTO="no"
  fi
fi

if [ "${UPGRADE_MAGENTO:-no}" = "yes" ]; then
  echo "➡️  Preparing Magento core upgrade via composer..."

  TARGET_VER="${UPGRADE_MAGENTO_VERSION:-${MAGENTO_VERSION:-2.4.*}}"
  echo "  - Target Magento version: ${TARGET_VER}"

  if grep -q '"magento/product-community-edition"' composer.json; then
    echo "  - Updating magento/product-community-edition constraint in composer.json..."
    composer require "magento/product-community-edition:${TARGET_VER}" --no-update
  elif grep -q '"magento/magento2-base"' composer.json; then
    echo "  - Updating magento/magento2-base constraint in composer.json..."
    composer require "magento/magento2-base:${TARGET_VER}" --no-update
  else
    echo "⚠️  Could not find magento/product-community-edition or magento/magento2-base in composer.json; skipping automatic constraint update."
  fi

  echo "  - Running composer update for Magento packages (this may take a while)..."
  composer update "magento/*" --with-all-dependencies

  echo "  - Composer update completed; continuing with setup:upgrade..."
fi

echo "➡️  Waiting for OpenSearch (opensearch:9200) to be ready..."
if command -v curl >/dev/null 2>&1; then
  for i in {1..30}; do
    if curl -sS "http://opensearch:9200" >/dev/null 2>&1; then
      echo "   OpenSearch is responding."
      break
    fi
    echo "   ...OpenSearch not ready yet, sleeping 5s (attempt $i/30)"
    sleep 5
  done
else
  echo "ℹ️  curl not available in php-fpm; skipping OpenSearch readiness check."
fi

echo "➡️  Forcing search configuration to Warden OpenSearch..."
echo "    bin/magento config:set catalog/search/engine opensearch"
echo "    bin/magento config:set catalog/search/opensearch_server_hostname opensearch"
echo "    bin/magento config:set catalog/search/opensearch_server_port 9200"
echo "    bin/magento config:set catalog/search/opensearch_index_prefix magento2"
echo "    bin/magento config:set catalog/search/opensearch_enable_auth 0"
bin/magento config:set catalog/search/engine opensearch || true
bin/magento config:set catalog/search/opensearch_server_hostname opensearch || true
bin/magento config:set catalog/search/opensearch_server_port 9200 || true
bin/magento config:set catalog/search/opensearch_index_prefix magento2 || true
bin/magento config:set catalog/search/opensearch_enable_auth 0 || true

echo "➡️  Updating base URLs for local store configuration..."

BASE_URL="https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
SUBCATS_URL="https://${TRAEFIK_DOMAIN}/"

# Default scope (fallback) → app.mage.test
bin/magento config:set web/unsecure/base_url      "$BASE_URL"
bin/magento config:set web/secure/base_url        "$BASE_URL"
bin/magento config:set web/unsecure/base_link_url "$BASE_URL"
bin/magento config:set web/secure/base_link_url   "$BASE_URL"

# Website 'base' → app.mage.test
bin/magento config:set web/unsecure/base_url      "$BASE_URL"    --scope=websites --scope-code=base
bin/magento config:set web/secure/base_url        "$BASE_URL"    --scope=websites --scope-code=base
bin/magento config:set web/unsecure/base_link_url "$BASE_URL"    --scope=websites --scope-code=base
bin/magento config:set web/secure/base_link_url   "$BASE_URL"    --scope=websites --scope-code=base

if [ "${ENABLE_MULTISTORE:-no}" = "yes" ]; then
  # Website 'subcats' → mage.test
  bin/magento config:set web/unsecure/base_url      "$SUBCATS_URL" --scope=websites --scope-code=subcats
  bin/magento config:set web/secure/base_url        "$SUBCATS_URL" --scope=websites --scope-code=subcats
  bin/magento config:set web/unsecure/base_link_url "$SUBCATS_URL" --scope=websites --scope-code=subcats
  bin/magento config:set web/secure/base_link_url   "$SUBCATS_URL" --scope=websites --scope-code=subcats
fi

echo "➡️  Verifying base URLs after update..."
bin/magento config:show web/unsecure/base_url || true
bin/magento config:show web/unsecure/base_link_url || true
bin/magento config:show web/secure/base_url || true
bin/magento config:show web/secure/base_link_url || true
bin/magento config:show web/unsecure/base_url --scope=websites --scope-code=base || true
if [ "${ENABLE_MULTISTORE:-no}" = "yes" ]; then
  bin/magento config:show web/unsecure/base_url --scope=websites --scope-code=subcats || true
fi

bin/magento cache:flush


MAGENTO_EXISTING

  echo "✅ Existing DB imported and configured."
  echo ""

else

  ##########################################
  # Path B: fresh install (setup:install) #
  ##########################################
  warden env exec -T php-fpm env \
    MAGENTO_PACKAGE="${MAGENTO_PACKAGE}" \
    MAGENTO_VERSION="${MAGENTO_VERSION}" \
    ADMIN_FRONTNAME="${ADMIN_FRONTNAME}" \
    TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN}" \
    TRAEFIK_SUBDOMAIN="${TRAEFIK_SUBDOMAIN}" \
    ADMIN_USER="${ADMIN_USER}" \
    ADMIN_PASS="${ADMIN_PASS}" \
    ADMIN_EMAIL="${ADMIN_EMAIL}" \
    ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME}" \
    ADMIN_LASTNAME="${ADMIN_LASTNAME}" \
    MAGENTO_DB_HOST="${MAGENTO_DB_HOST}" \
    MAGENTO_DB_NAME="${MAGENTO_DB_NAME}" \
    MAGENTO_DB_USER="${MAGENTO_DB_USER}" \
    MAGENTO_DB_PASSWORD="${MAGENTO_DB_PASSWORD}" \
    bash <<'MAGENTO_NEW'

set -e

cd /var/www/html

if [ -f app/etc/env.php ]; then
  echo "ℹ️  Magento already installed (app/etc/env.php exists). Skipping setup:install."
  exit 0
fi

echo "➡️  Running composer create-project for Magento..."
META_PACKAGE="${MAGENTO_PACKAGE:-magento/project-community-edition}"
META_VERSION="${MAGENTO_VERSION:-2.4.*}"
if [ -f auth.json ]; then
  echo "  - auth.json found; using COMPOSER_AUTH for repo.magento.com..."
  export COMPOSER_AUTH="$(cat auth.json)"
fi

composer create-project --repository-url=https://repo.magento.com/ \
  "${META_PACKAGE}" /tmp/magento "${META_VERSION}"

rsync -a /tmp/magento/ /var/www/html/
rm -rf /tmp/magento/

echo "➡️  Running bin/magento setup:install..."
bin/magento setup:install \
  --backend-frontname="${ADMIN_FRONTNAME}" \
  --admin-firstname="${ADMIN_FIRSTNAME}" \
  --admin-lastname="${ADMIN_LASTNAME}" \
  --admin-email="${ADMIN_EMAIL}" \
  --admin-user="${ADMIN_USER}" \
  --admin-password="${ADMIN_PASS}" \
  --amqp-host=rabbitmq \
  --amqp-port=5672 \
  --amqp-user=guest \
  --amqp-password=guest \
  --db-host=db \
  --db-name=magento \
  --db-user=magento \
  --db-password=magento \
  --search-engine=opensearch \
  --opensearch-host=opensearch \
  --opensearch-port=9200 \
  --opensearch-index-prefix=magento2 \
  --opensearch-enable-auth=0 \
  --opensearch-timeout=15 \
  --http-cache-hosts=varnish:80 \
  --session-save=redis \
  --session-save-redis-host=redis \
  --session-save-redis-port=6379 \
  --session-save-redis-db=2 \
  --session-save-redis-max-concurrency=20 \
  --cache-backend=redis \
  --cache-backend-redis-server=redis \
  --cache-backend-redis-db=0 \
  --cache-backend-redis-port=6379 \
  --page-cache=redis \
  --page-cache-redis-server=redis \
  --page-cache-redis-db=1 \
  --page-cache-redis-port=6379 \
  --use-rewrites=1

echo "➡️  Applying base URL + dev-friendly config..."
echo "  - bin/magento config:set web/unsecure/base_url \"https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/\""
echo "  - bin/magento config:set web/unsecure/base_link_url \"https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/\""
echo "  - bin/magento config:set web/secure/base_url \"https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/\""
echo "  - bin/magento config:set web/secure/base_link_url \"https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/\""
bin/magento config:set web/unsecure/base_url \
  "https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
bin/magento config:set web/unsecure/base_link_url \
  "https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"

bin/magento config:set web/secure/base_url \
  "https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
bin/magento config:set web/secure/base_link_url \
  "https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"

bin/magento config:set --lock-env web/secure/offloader_header X-Forwarded-Proto
bin/magento config:set --lock-env web/secure/use_in_frontend 1
bin/magento config:set --lock-env web/secure/use_in_adminhtml 1
bin/magento config:set --lock-env web/seo/use_rewrites 1

bin/magento config:set --lock-env system/full_page_cache/caching_application 2
bin/magento config:set --lock-env system/full_page_cache/ttl 604800

bin/magento config:set --lock-env catalog/search/enable_eav_indexer 1
bin/magento config:set --lock-env dev/static/sign 0

bin/magento deploy:mode:set -s developer
bin/magento cache:disable block_html full_page
bin/magento indexer:reindex
bin/magento cache:flush

MAGENTO_NEW

  echo "✅ Magento fresh install done."
  echo ""
fi

if [[ "${INSTALL_JSCRIPTZ}" == "ask" ]]; then
  read -r -p "Install Jscriptz Subcats extension? (Hyva/Luma compatible) (y/N): " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    INSTALL_JSCRIPTZ="yes"
  else
    INSTALL_JSCRIPTZ="no"
  fi
fi

if [[ "${INSTALL_JSCRIPTZ}" == "yes" ]]; then
  echo "➡️  Installing Jscriptz Subcats extension"
  warden env exec -T php-fpm bash <<'JSCRIPTZ'
set -e
cd /var/www/html
composer require jscriptz/module-subcats:^2.1
bin/magento module:enable Jscriptz_Subcats || true
JSCRIPTZ

  echo "✅ jscriptz/module-subcats installed."
  echo ""
fi



echo ""
echo "➡️  Final sanity: ensure Magento CLI 'setup' exists and local base URLs are correct..."
warden env exec -T php-fpm env \
  TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN}" \
  TRAEFIK_SUBDOMAIN="${TRAEFIK_SUBDOMAIN}" \
  MAGENTO_PACKAGE="${MAGENTO_PACKAGE}" \
  MAGENTO_VERSION="${MAGENTO_VERSION}" \
  ENABLE_MULTISTORE="${ENABLE_MULTISTORE}" \
  DISABLE_TWOFACTOR_AUTH="${DISABLE_TWOFACTOR_AUTH}" \
  MAGENTO_DEVELOPER_MODE="${MAGENTO_DEVELOPER_MODE}" \
  DISABLE_CONFIG_CACHE="${DISABLE_CONFIG_CACHE}" \
  DISABLE_FULLPAGE_CACHE="${DISABLE_FULLPAGE_CACHE}" \
  ADMIN_FRONTNAME="${ADMIN_FRONTNAME}" \
  bash <<'FINAL_FIX'

set -e

cd /var/www/html

echo "  - Checking for setup/config/application.config.php..."
if [ ! -f setup/config/application.config.php ]; then
  echo "⚠️  setup/config/application.config.php missing; bootstrapping setup directory from a temporary composer project..."

  META_PACKAGE="${MAGENTO_PACKAGE:-magento/project-community-edition}"
  META_VERSION="${MAGENTO_VERSION:-2.4.*}"

  if [ -f auth.json ]; then
    echo "    • auth.json found; using COMPOSER_AUTH for repo.magento.com..."
    export COMPOSER_AUTH="$(cat auth.json)"
  else
    echo "    • WARNING: auth.json not found; composer may prompt or fail against repo.magento.com."
  fi

  composer create-project --repository-url=https://repo.magento.com/ "$META_PACKAGE" /tmp/magento-setup "$META_VERSION"

  if [ -d /tmp/magento-setup/setup ]; then
    echo "    • setup directory created, copying into project root..."
    rm -rf setup
    mv /tmp/magento-setup/setup ./setup
  else
    echo "❌ Expected /tmp/magento-setup/setup but it was not created."
    ls -la /tmp || true
    ls -la /tmp/magento-setup || true
    exit 1
  fi

  rm -rf /tmp/magento-setup
else
  echo "    • setup/config/application.config.php already present; nothing to do."
fi

if [[ -f app/etc/env.php ]]; then
  php <<'PHP'
<?php
$envFile = __DIR__ . '/app/etc/env.php';
if (!file_exists($envFile)) {
    echo "env.php not found; skipping DB normalization.\n";
    exit(0);
}

$env = include $envFile;

// Local defaults (overrideable via env if you want later)
$localDbName = getenv('MAGENTO_DB_NAME') ?: 'magento';
$localDbUser = getenv('MAGENTO_DB_USER') ?: 'magento';
$localDbPass = getenv('MAGENTO_DB_PASSWORD') ?: 'magento';
$localHost   = getenv('MAGENTO_DB_HOST') ?: 'db';

if (isset($env['db']['connection']) && is_array($env['db']['connection'])) {
    foreach ($env['db']['connection'] as $name => &$conn) {
        if (isset($conn['host']) && $conn['host'] !== $localHost) {
            $old = $conn['host'];
            $conn['host'] = $localHost;
            echo "Fixed DB host for connection '{$name}' from '{$old}' to '{$localHost}'.\n";
        }
        if (isset($conn['dbname']) && $conn['dbname'] !== $localDbName) {
            $old = $conn['dbname'];
            $conn['dbname'] = $localDbName;
            echo "Fixed DB name for connection '{$name}' from '{$old}' to '{$localDbName}'.\n";
        }
        if (isset($conn['username']) && $conn['username'] !== $localDbUser) {
            $old = $conn['username'];
            $conn['username'] = $localDbUser;
            echo "Fixed DB user for connection '{$name}' from '{$old}' to '{$localDbUser}'.\n";
        }
        if (isset($conn['password']) && $conn['password'] !== $localDbPass) {
            $conn['password'] = $localDbPass;
            echo "Fixed DB password for connection '{$name}'.\n";
        }
    }

    file_put_contents(
        $envFile,
        "<?php\nreturn " . var_export($env, true) . ";\n"
    );
} else {
    echo "No db/connection section found in env.php; skipping DB normalization.\n";
}
PHP
else
  echo "env.php not found; skipping DB normalization."
fi


php <<'PHP'
<?php
$envFile = __DIR__ . '/app/etc/env.php';
if (!file_exists($envFile)) {
    echo "env.php not found; skipping backend frontName normalization.\n";
    exit(0);
}

$env = include $envFile;
if (!is_array($env)) {
    echo "env.php did not return an array; skipping backend frontName normalization.\n";
    exit(0);
}

$targetFrontName = getenv('ADMIN_FRONTNAME') ?: 'mage_admin';

if (!isset($env['backend'])) {
    $env['backend'] = [];
}

if (!isset($env['backend']['frontName']) || $env['backend']['frontName'] !== $targetFrontName) {
    $old = isset($env['backend']['frontName']) ? $env['backend']['frontName'] : '(none)';
    $env['backend']['frontName'] = $targetFrontName;

    file_put_contents(
        $envFile,
        "<?php\nreturn " . var_export($env, true) . ";\n"
    );

    echo "Fixed backend frontName from '{$old}' to '{$targetFrontName}'.\n";
} else {
    echo "Backend frontName already set to '{$targetFrontName}'; nothing to change.\n";
}
PHP

BASE_URL="https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
SUBCATS_URL="https://${TRAEFIK_DOMAIN}/"

echo "  - Updating base URLs for default scope..."
bin/magento config:set web/unsecure/base_url      "$BASE_URL"
bin/magento config:set web/secure/base_url        "$BASE_URL"
bin/magento config:set web/unsecure/base_link_url "$BASE_URL"
bin/magento config:set web/secure/base_link_url   "$BASE_URL"

echo "  - Updating base URLs for website 'base' (app.mage.test)..."
bin/magento config:set web/unsecure/base_url      "$BASE_URL"    --scope=websites --scope-code=base
bin/magento config:set web/secure/base_url        "$BASE_URL"    --scope=websites --scope-code=base
bin/magento config:set web/unsecure/base_link_url "$BASE_URL"    --scope=websites --scope-code=base
bin/magento config:set web/secure/base_link_url   "$BASE_URL"    --scope=websites --scope-code=base

if [ "${ENABLE_MULTISTORE:-no}" = "yes" ]; then
  echo "  - Updating base URLs for website 'subcats' (mage.test)..."
  bin/magento config:set web/unsecure/base_url      "$SUBCATS_URL" --scope=websites --scope-code=subcats
  bin/magento config:set web/secure/base_url        "$SUBCATS_URL" --scope=websites --scope-code=subcats
  bin/magento config:set web/unsecure/base_link_url "$SUBCATS_URL" --scope=websites --scope-code=subcats
  bin/magento config:set web/secure/base_link_url   "$SUBCATS_URL" --scope=websites --scope-code=subcats
fi

echo "  - Base URLs are now:"
echo "    (web/unsecure/base_url, web/unsecure/base_link_url, web/secure/base_url, web/secure/base_link_url)"
bin/magento config:show web/unsecure/base_url      || true
bin/magento config:show web/unsecure/base_link_url || true
bin/magento config:show web/secure/base_url        || true
bin/magento config:show web/secure/base_link_url   || true

# Dev-friendly sanity toggles
if [ "${DISABLE_TWOFACTOR_AUTH:-true}" = "true" ]; then
  echo "  - Disabling admin two-factor auth modules for local dev..."
  bin/magento module:disable Magento_TwoFactorAuth Magento_AdminAdobeImsTwoFactorAuth || true
fi

if [ "${MAGENTO_DEVELOPER_MODE:-true}" = "true" ]; then
  echo "  - Setting Magento to developer mode..."
  bin/magento deploy:mode:set developer || true
fi

if [ "${DISABLE_CONFIG_CACHE:-true}" = "true" ]; then
  echo "  - Disabling config cache..."
  bin/magento cache:disable config || true
fi

if [ "${DISABLE_FULLPAGE_CACHE:-true}" = "true" ]; then
  echo "  - Disabling full_page cache..."
  bin/magento cache:disable full_page || true
fi
echo "  - Disabling admin login CAPTCHA..."
echo "    bin/magento config:set admin/captcha/enable 0"
bin/magento config:set admin/captcha/enable 0 || true

echo "➡️  Forcing search configuration to Warden OpenSearch..."
echo "    bin/magento config:set catalog/search/engine opensearch"
echo "    bin/magento config:set catalog/search/opensearch_server_hostname opensearch"
echo "    bin/magento config:set catalog/search/opensearch_server_port 9200"
echo "    bin/magento config:set catalog/search/opensearch_index_prefix magento2"
echo "    bin/magento config:set catalog/search/opensearch_enable_auth 0"
bin/magento config:set catalog/search/engine opensearch || true
bin/magento config:set catalog/search/opensearch_server_hostname opensearch || true
bin/magento config:set catalog/search/opensearch_server_port 9200 || true
bin/magento config:set catalog/search/opensearch_index_prefix magento2 || true
bin/magento config:set catalog/search/opensearch_enable_auth 0 || true


FINAL_FIX

### ---- Optional: Magento sample data (fresh installs only) ----

if [[ "${USE_EXISTING_DB}" != "yes" ]]; then
  if [[ "${WITH_SAMPLE_DATA}" == "ask" ]]; then
    read -r -p "Install Magento sample data? (y/N): " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      WITH_SAMPLE_DATA="yes"
    else
      WITH_SAMPLE_DATA="no"
    fi
  fi

  if [[ "${WITH_SAMPLE_DATA}" == "yes" ]]; then
    echo "➡️  Installing Magento sample data (this can take a while)..."
    warden env exec -T php-fpm bash <<'SAMPLEDATA'
set -e
cd /var/www/html
bin/magento sampledata:deploy
SAMPLEDATA
    echo "✅ Sample data installed."
    echo ""
  fi
fi

### ---- Optional: Hyvä theme install (private Packagist + license key) ----

if [[ "${INSTALL_HYVA}" == "ask" ]]; then
  # If Hyvä is already present in the vendor tree (e.g. rsynced/tar from live),
  # skip the prompt and do not try to re-install it via Composer.
  if warden env exec -T php-fpm test -d /var/www/html/vendor/hyva-themes/magento2-theme-module; then
    echo "Hyvä vendor modules already present in container; skipping Hyvä install."
    INSTALL_HYVA="no"
  else
    read -r -p "Install Hyvä theme now? (y/N): " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      INSTALL_HYVA="yes"
    else
      INSTALL_HYVA="no"
    fi
  fi
fi

if [[ "${INSTALL_HYVA}" == "yes" ]]; then
  echo ""
  echo "➡️  Installing Hyvä theme (OSS GitHub mirrors, no license key)..."

  warden env exec -T php-fpm bash <<'HYVA'
set -e
cd /var/www/html

echo "  - Configuring Hyvä OSS Git repositories..."
composer config repositories.hyva-themes/magento2-default-theme git https://github.com/hyva-themes/magento2-default-theme.git
composer config repositories.hyva-themes/magento2-theme-module git https://github.com/hyva-themes/magento2-theme-module.git
composer config repositories.hyva-themes/magento2-base-layout-reset git https://github.com/hyva-themes/magento2-base-layout-reset.git
composer config repositories.hyva-themes/magento2-compat-module-fallback git https://github.com/hyva-themes/magento2-compat-module-fallback.git
composer config repositories.hyva-themes/magento2-theme-fallback git https://github.com/hyva-themes/magento2-theme-fallback.git
composer config repositories.hyva-themes/magento2-default-theme-csp git https://github.com/hyva-themes/magento2-default-theme-csp.git
composer config repositories.hyva-themes/magento2-email-module git https://github.com/hyva-themes/magento2-email-module.git
composer config repositories.hyva-themes/magento2-luma-checkout git https://github.com/hyva-themes/magento2-luma-checkout.git
composer config repositories.hyva-themes/magento2-order-cancellation-webapi git https://github.com/hyva-themes/magento2-order-cancellation-webapi.git
composer config repositories.hyva-themes/magento2-mollie-theme-bundle git https://github.com/hyva-themes/magento2-mollie-theme-bundle.git

echo "  - Checking for existing Hyvä vendor modules..."
if [ -d vendor/hyva-themes/magento2-theme-module ]; then
  echo "    Hyvä vendor modules already present; skipping composer require."
else
  echo "  - Clearing composer cache..."
  composer clear-cache

  echo "  - Requiring hyva-themes/magento2-default-theme..."
  composer require hyva-themes/magento2-default-theme:"^1.4" --with-all-dependencies --prefer-source
fi

echo "  - Detecting Hyvä *default* theme_id via Magento ORM..."
HYVA_THEME_ID=$(php -r '
require "app/bootstrap.php";
use Magento\Framework\App\Bootstrap;

$bootstrap = Bootstrap::create(BP, $_SERVER);
$objectManager = $bootstrap->getObjectManager();

/** @var \Magento\Theme\Model\ResourceModel\Theme\Collection $collection */
$collection = $objectManager->get(\Magento\Theme\Model\ResourceModel\Theme\Collection::class);

// Prefer the Hyvä Default theme (theme_path = "Hyva/default")
$collection->addFieldToFilter("area", "frontend");
$collection->addFieldToFilter("theme_path", "Hyva/default");
$theme = $collection->getFirstItem();

// Fallback: any Hyvä frontend theme if explicit default is missing
if (!$theme->getId()) {
    $collection = $objectManager->get(\Magento\Theme\Model\ResourceModel\Theme\Collection::class);
    $collection->addFieldToFilter("area", "frontend");
    $collection->addFieldToFilter(
        ["theme_path", "theme_title", "code"],
        [
            ["like" => "%Hyva%"],
            ["like" => "%Hyva%"],
            ["like" => "%Hyva%"]
        ]
    );
    $collection->setOrder("theme_id", "ASC");
    $theme = $collection->getFirstItem();
}

// Normalise to a physical theme if possible
if ($theme->getId()) {
    $theme->setType(0)->save();
}

echo $theme->getId() ?: "";
')

if [ -z "$HYVA_THEME_ID" ]; then
  echo "⚠️  Could not detect Hyvä theme in DB; leaving default theme unchanged."
else
  echo "  - Found Hyvä Default theme_id=${HYVA_THEME_ID}; setting as default..."
  bin/magento config:set design/theme/theme_id "$HYVA_THEME_ID"
fi

HYVA

  echo "✅ Hyvä theme installed and (if detected) set as default."
  echo ""
fi

if warden env exec -T php-fpm test -d /var/www/html/vendor/hyva-themes/magento2-theme-module; then
  echo "Hyvä vendor modules already present in container; skipping Hyvä install."
  INSTALL_HYVA="no"
else
  read -r -p "Install Hyvä theme from their private packagist now? (y/N): " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    INSTALL_HYVA="yes"
  else
    INSTALL_HYVA="no"
  fi
fi

if [[ "${INSTALL_HYVA}" == "yes" ]]; then
  echo ""
  echo "➡️  Installing Hyvä theme (private Packagist + license key)..."

  # Sanity check for required vars
  if [[ -z "${HYVA_REPO:-}" || -z "${HYVA_TOKEN:-}" ]]; then
    echo "❌ HYVA_REPO or HYVA_TOKEN is not set."
    echo "   Set them in _mage-mirror.config before running this installer."
    exit 1
  fi

  warden env exec -T php-fpm env \
    HYVA_REPO="${HYVA_REPO}" \
    HYVA_TOKEN="${HYVA_TOKEN}" \
    bash <<'HYVA'
set -e
cd /var/www/html

echo "  - Configuring Hyvä private Packagist repository..."
composer config --auth http-basic.hyva-themes.repo.packagist.com token "${HYVA_TOKEN}"
composer config repositories.private-packagist composer "${HYVA_REPO}"

echo "  - Checking for existing Hyvä vendor modules..."
if [ -d vendor/hyva-themes/magento2-theme-module ]; then
  echo "    Hyvä vendor modules already present; skipping composer require."
else
  echo "  - Clearing composer cache..."
  composer clear-cache
  echo "  - Requiring hyva-themes/magento2-default-theme..."
  composer require hyva-themes/magento2-default-theme:"^1.4" --with-all-dependencies --prefer-source
fi

echo "  - Detecting Hyvä *default* theme_id via Magento ORM..."
HYVA_THEME_ID=$(php -r '
require "app/bootstrap.php";
use Magento\Framework\App\Bootstrap;

$bootstrap = Bootstrap::create(BP, $_SERVER);
$objectManager = $bootstrap->getObjectManager();

/** @var \Magento\Theme\Model\ResourceModel\Theme\Collection $collection */
$collection = $objectManager->get(\Magento\Theme\Model\ResourceModel\Theme\Collection::class);

// Prefer the Hyvä Default theme (theme_path = "Hyva/default")
$collection->addFieldToFilter("area", "frontend");
$collection->addFieldToFilter("theme_path", "Hyva/default");
$theme = $collection->getFirstItem();

// Fallback: any Hyvä frontend theme if explicit default is missing
if (!$theme->getId()) {
    $collection = $objectManager->get(\Magento\Theme\Model\ResourceModel\Theme\Collection::class);
    $collection->addFieldToFilter("area", "frontend");
    $collection->addFieldToFilter(
        ["theme_path", "theme_title", "code"],
        [
            ["like" => "%Hyva%"],
            ["like" => "%Hyva%"],
            ["like" => "%Hyva%"]
        ]
    );
    $collection->setOrder("theme_id", "ASC");
    $theme = $collection->getFirstItem();
}

// Normalise to a physical theme if possible
if ($theme->getId()) {
    $theme->setType(0)->save();
}

echo $theme->getId() ?: "";
')

if [ -z "$HYVA_THEME_ID" ]; then
  echo "⚠️  Could not detect Hyvä theme in DB; leaving default theme unchanged."
else
  echo "  - Found Hyvä Default theme_id=${HYVA_THEME_ID}; setting as default..."
  bin/magento config:set design/theme/theme_id "$HYVA_THEME_ID"
fi

HYVA

  echo "✅ Hyvä theme installed and (if detected) set as default."
  echo ""
fi

### ---- Multi-store: domain → website code routing (pub/index.php) ----

if [[ "${USE_EXISTING_DB}" == "yes" && "${ENABLE_MULTISTORE}" == "yes" ]]; then
  echo "➡️  Ensuring pub/index.php sets website based on HTTP_HOST (mage.test → base, app.mage.test → multi-store)..."

  warden env exec -T php-fpm bash <<'MULTISTORE'
set -e
cd /var/www/html/pub

if grep -q 'MAGE_RUN_CODE' index.php; then
  echo "ℹ️  pub/index.php already contains MAGE_RUN_CODE logic; skipping patch."
else
  echo "  - Injecting host-based website switch into pub/index.php..."
  tmp="index.php.new"
  {
    echo "<?php"
    echo '$host = $_SERVER["HTTP_HOST"] ?? "";'
    echo 'switch ($host) {'
    echo '    case "mage.test":'
    echo '        $_SERVER["MAGE_RUN_TYPE"] = "website";'
    echo '        $_SERVER["MAGE_RUN_CODE"] = "base";'
    echo '        break;'
    echo '    case "app.mage.test":'
    echo '        $_SERVER["MAGE_RUN_TYPE"] = "website";'
    echo '        $_SERVER["MAGE_RUN_CODE"] = "subcats";'
    echo '        break;'
    echo '    default:'
    echo '        $_SERVER["MAGE_RUN_TYPE"] = "website";'
    echo '        $_SERVER["MAGE_RUN_CODE"] = "base";'
    echo '        break;'
    echo '}'
    tail -n +2 index.php
  } > "$tmp"

  mv "$tmp" index.php
fi

MULTISTORE
fi


echo ""
echo "➡️  Running final Magento deployment (setup:upgrade, di:compile, static content, cache)..."
warden env exec -T php-fpm bash <<'FINAL_DEPLOY'
set -e
cd /var/www/html

echo "  - Running setup:upgrade..."
bin/magento setup:upgrade

echo "  - Running setup:di:compile..."
bin/magento setup:di:compile

echo "  - Running setup:static-content:deploy -f..."
bin/magento setup:static-content:deploy -f

echo "  - Checking for Hyvä theme to set as default (if present)..."
HYVA_THEME_ID=$(php -r '
require "app/bootstrap.php";
use Magento\Framework\App\Bootstrap;

$bootstrap = Bootstrap::create(BP, $_SERVER);
$objectManager = $bootstrap->getObjectManager();

/** @var \Magento\Theme\Model\ResourceModel\Theme\Collection $collection */
$collection = $objectManager->get(\Magento\Theme\Model\ResourceModel\Theme\Collection::class);

// Prefer the Hyvä Default theme (theme_path = "Hyva/default")
$collection->addFieldToFilter("area", "frontend");
$collection->addFieldToFilter("theme_path", "Hyva/default");
$theme = $collection->getFirstItem();

// Fallback: any Hyvä frontend theme if explicit default is missing
if (!$theme->getId()) {
    $collection = $objectManager->get(\Magento\Theme\Model\ResourceModel\Theme\Collection::class);
    $collection->addFieldToFilter("area", "frontend");
    $collection->addFieldToFilter(
        ["theme_path", "theme_title", "code"],
        [
            ["like" => "%Hyva%"],
            ["like" => "%Hyva%"],
            ["like" => "%Hyva%"]
        ]
    );
    $collection->setOrder("theme_id", "ASC");
    $theme = $collection->getFirstItem();
}

// Normalise to a physical theme if possible
if ($theme->getId()) {
    $theme->setType(0)->save();
}

echo $theme->getId() ?: "";
')

if [ -n "$HYVA_THEME_ID" ]; then
  echo "  - Found Hyvä theme_id=${HYVA_THEME_ID}; setting as default design/theme/theme_id..."
  echo "    bin/magento config:set design/theme/theme_id $HYVA_THEME_ID"
  bin/magento config:set design/theme/theme_id "$HYVA_THEME_ID"
else
  echo "  - No Hyvä theme detected in DB; leaving default theme unchanged."
fi

echo "  - Reindexing and installing cron..."
bin/magento indexer:reindex || true
bin/magento cron:install || true

echo "  - Flushing & cleaning caches..."
bin/magento cache:flush || true
bin/magento cache:clean || true
FINAL_DEPLOY

echo "=========================================="
echo " ✅ Warden + Magento install finished"
echo "=========================================="
echo ""
echo "Storefront (Warden) : https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
echo "Admin               : https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/${ADMIN_FRONTNAME}"
echo ""
echo "Notes:"
echo "  • If you provide config/composer-auth.json, it is copied to auth.json and used by Composer."
echo "    Otherwise, configure Magento repo auth manually inside the container if needed:"
echo "       composer global config http-basic.repo.magento.com <pub-key> <priv-key>"
echo "  • /etc/hosts: this script adds ${TRAEFIK_DOMAIN} + ${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN};"
echo "  • This script does NOT change Docker ports; it assumes Warden uses its defaults."
echo ""
