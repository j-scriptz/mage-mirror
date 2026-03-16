#!/usr/bin/env bash
set -euo pipefail

# _mage-mirror-upload.sh
# Upload local Magento (Warden project) back to a live server via SSH + rsync + streamed MySQL import.
#
# Modes:
#   1) All code + media + DB
#   2) Code Only
#   3) DB Only
#   4) Media Only
#   5) App folder only (app/)
#   6) App code only (app/code/)
#   7) App design only (app/design/)
#
# Non-interactive knobs:
#   UPLOAD_MODE=all|code|db|media|app|appcode|appdesign
#   RSYNC_DELETE=ask|yes|no
  RSYNC_RETRIES=2
  RSYNC_RETRY_SLEEP=3
#   REMOTE_MAINTENANCE=yes|no
#   REAL_DEPLOY=yes|no
#   REAL_REINDEX=yes|no
#   SCD_LOCALES="en_US"            # optional (space-separated or quoted)
#   SCD_JOBS=4                      # optional
#
# Live URL knobs (recommended to set in _mage-mirror.config):
#   LIVE_BASE_URL=https://example.com/
#   LIVE_SUBCATS_URL=https://sub.example.com/   # optional
#
# Remote Docker knobs (for running bin/magento inside container on live):
#   DOCKER_MODE=auto|yes|no
#   REMOTE_DOCKER_COMPOSE_YML=/path/to/docker-compose.yml
#   REMOTE_PHP_SERVICE=php-fpm
#   REMOTE_MAGENTO_ROOT_CONTAINER=/var/www/html   # path INSIDE container where bin/magento lives
#   REMOTE_DB_SERVICE=db                          # optional: if set, imports DB via mysql inside this container

CONFIG_FILE="${CONFIG_FILE:-_mage-mirror.config}"
if [[ -f "${CONFIG_FILE}" ]]; then
  echo "ℹ️  Loading configuration from ${CONFIG_FILE}..."
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

# ---- Required remote settings ----
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_PATH="${REMOTE_PATH:-}"
REMOTE_SSH_KEY="${REMOTE_SSH_KEY:-}"

# ---- Remote DB settings (required for DB upload) ----
REMOTE_DB_HOST="${REMOTE_DB_HOST:-${REMOTE_HOST:-}}"
REMOTE_DB_PORT="${REMOTE_DB_PORT:-3306}"
REMOTE_DB_NAME="${REMOTE_DB_NAME:-}"
REMOTE_DB_USER="${REMOTE_DB_USER:-}"
REMOTE_DB_PASSWORD="${REMOTE_DB_PASSWORD:-}"
REMOTE_DB_AUTODETECT="${REMOTE_DB_AUTODETECT:-yes}"  # yes|no (read DB creds from remote app/etc/env.php)

# ---- Local DB settings (Warden defaults; override if you changed them) ----
MAGENTO_DB_NAME="${MAGENTO_DB_NAME:-magento}"
MAGENTO_DB_USER="${MAGENTO_DB_USER:-magento}"
MAGENTO_DB_PASSWORD="${MAGENTO_DB_PASSWORD:-magento}"


# ---- DB dump tuning / excludes ----
# Space- or comma-separated table names (without DB prefix) to exclude from dumps.
# Default excludes importexport_importdata (often huge / blob-heavy) to prevent mysqldump connection drops.
DB_EXCLUDE_TABLES="${DB_EXCLUDE_TABLES:-importexport_importdata}"
# mysqldump stability knobs (bytes)
MYSQLDUMP_MAX_ALLOWED_PACKET="${MYSQLDUMP_MAX_ALLOWED_PACKET:-1073741824}"   # 1 GiB
MYSQLDUMP_NET_BUFFER_LENGTH="${MYSQLDUMP_NET_BUFFER_LENGTH:-16384}"          # 16 KiB
MYSQLDUMP_SKIP_EXTENDED_INSERT="${MYSQLDUMP_SKIP_EXTENDED_INSERT:-no}"       # yes|no (auto enabled on retry)


# ---- Live URLs ----
LIVE_BASE_URL="${LIVE_BASE_URL:-}"
LIVE_SUBCATS_URL="${LIVE_SUBCATS_URL:-}"

# Default live base URL if not provided
if [[ -z "${LIVE_BASE_URL}" ]]; then
  LIVE_BASE_URL="https://${REMOTE_HOST}/"
fi
# Ensure trailing slashes for Magento base urls
[[ "${LIVE_BASE_URL}" == */ ]] || LIVE_BASE_URL="${LIVE_BASE_URL}/"
if [[ -n "${LIVE_SUBCATS_URL}" ]]; then
  [[ "${LIVE_SUBCATS_URL}" == */ ]] || LIVE_SUBCATS_URL="${LIVE_SUBCATS_URL}/"
fi


# ---- Remote Docker (optional) ----
DOCKER_MODE="${DOCKER_MODE:-auto}"  # auto|yes|no
REMOTE_DOCKER_COMPOSE_YML="${REMOTE_DOCKER_COMPOSE_YML:-}"
REMOTE_PHP_SERVICE="${REMOTE_PHP_SERVICE:-php-fpm}"
REMOTE_MAGENTO_ROOT_CONTAINER="${REMOTE_MAGENTO_ROOT_CONTAINER:-/var/www/html}"
REMOTE_DB_SERVICE="${REMOTE_DB_SERVICE:-}"
DOCKER_COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-}"  # autodetected on remote

# ---- Behavior toggles ----
REMOTE_MAINTENANCE="${REMOTE_MAINTENANCE:-yes}"   # yes|no
RSYNC_DELETE="${RSYNC_DELETE:-ask}"               # ask|yes|no
RSYNC_RETRIES="${RSYNC_RETRIES:-2}"               # retry rsync on exit 12
RSYNC_RETRY_SLEEP="${RSYNC_RETRY_SLEEP:-3}"        # seconds between retries
REAL_DEPLOY="${REAL_DEPLOY:-no}"                  # yes|no
REAL_REINDEX="${REAL_REINDEX:-no}"                # yes|no
SCD_LOCALES="${SCD_LOCALES:-en_US}"
SCD_JOBS="${SCD_JOBS:-4}"

usage() {
  cat <<'EOF'
_mage-mirror-upload.sh

Modes:
  1) All code + media + DB
  2) Code Only
  3) DB Only
  4) Media Only
  5) App folder only (app/)
  6) App code only (app/code/)
  7) App design only (app/design/)

Env overrides:
  CONFIG_FILE=_mage-mirror.config
  UPLOAD_MODE=all|code|db|media|app|appcode|appdesign
  RSYNC_DELETE=ask|yes|no
  RSYNC_RETRIES=2
  RSYNC_RETRY_SLEEP=3
  REMOTE_MAINTENANCE=yes|no
  REAL_DEPLOY=yes|no
  REAL_REINDEX=yes|no
  SCD_LOCALES="en_US"
  SCD_JOBS=4
  LIVE_BASE_URL=https://example.com/
  LIVE_SUBCATS_URL=https://sub.example.com/
  DB_EXCLUDE_TABLES="importexport_importdata,cache,cache_tag"   # optional
  MYSQLDUMP_MAX_ALLOWED_PACKET=1073741824
  MYSQLDUMP_NET_BUFFER_LENGTH=16384
  MYSQLDUMP_SKIP_EXTENDED_INSERT=yes|no

Docker on live (bin/magento runs inside container):
  DOCKER_MODE=auto|yes|no
  REMOTE_DOCKER_COMPOSE_YML=/path/to/docker-compose.yml
  REMOTE_PHP_SERVICE=php-fpm
  REMOTE_MAGENTO_ROOT_CONTAINER=/var/www/html
  REMOTE_DB_SERVICE=db   # optional (imports DB inside DB container)
  REMOTE_DB_AUTODETECT=yes|no  # pull creds from remote app/etc/env.php
EOF
}

die() { echo "❌ $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

is_tty() {
  # Prompting should work even when stdout is piped (e.g., | tee).
  [[ -t 0 ]]
}

escape_squotes() {
  # abc'def -> abc'\''def
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

# ---- SSH helpers ----
build_ssh_cmd() {
  local -a cmd
  # Important for rsync stability:
  # - RequestTTY=no prevents any ssh config from allocating a tty (tty can trigger banners)
  # - LogLevel=ERROR suppresses noisy ssh messages
  # - KnownHostsFile=/dev/null avoids writes + noise in automated use
  # - Keepalives help long transfers
  cmd=(
    ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=yes
    -o RequestTTY=no
    -o ConnectTimeout=20
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=6
    -o TCPKeepAlive=yes
  )
  if [[ -n "${REMOTE_SSH_KEY}" ]]; then
    [[ -f "${REMOTE_SSH_KEY}" ]] || die "REMOTE_SSH_KEY is set but file not found: ${REMOTE_SSH_KEY}"
    cmd=(
      ssh
      -i "${REMOTE_SSH_KEY}"
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o GlobalKnownHostsFile=/dev/null
      -o LogLevel=ERROR
      -o BatchMode=yes
      -o RequestTTY=no
      -o ConnectTimeout=20
      -o ServerAliveInterval=30
      -o ServerAliveCountMax=6
      -o TCPKeepAlive=yes
    )
  fi
  printf '%q ' "${cmd[@]}"
}
SSH_CMD_STR="$(build_ssh_cmd)"
# rsync expects a single string after -e
RSYNC_SSH_CMD="${SSH_CMD_STR}"

check_remote_shell_quiet() {
  # rsync uses SSH as its transport; if the remote prints ANY extra output (MOTD/echo in shell rc),
  # rsync can fail with "protocol stream error". This check warns early.
  local marker="__MAGE_MIRROR_RSYNC_OK__"
  local out
  # shellcheck disable=SC2086
  out="$(${SSH_CMD_STR} -T "${REMOTE_USER}@${REMOTE_HOST}" "printf '%s' '${marker}'" 2>&1 || true)"
  if [[ "${out}" != "${marker}" ]]; then
    echo "⚠️  Warning: remote SSH session produced unexpected output. This can break rsync." >&2
    echo "    Output was:" >&2
    echo "    --------------------" >&2
    printf "%s\n" "${out}" >&2
    echo "    --------------------" >&2
    echo "    Fix: remove/guard any 'echo' or banner text in ~/.bashrc, ~/.profile, ~/.bash_profile for non-interactive shells." >&2
    echo "    Example guard (top of ~/.bashrc):  [[ \$- != *i* ]] && return" >&2
  fi
}

SHELL_QUIET_CHECKED=0

remote_exec() {
  local cmd="$1"
  local safe
  safe="$(escape_squotes "${cmd}")"
  # shellcheck disable=SC2086
  ${SSH_CMD_STR} "${REMOTE_USER}@${REMOTE_HOST}" "bash -lc '${safe}'"
}

remote_exec_tty() {
  local cmd="$1"
  local safe
  safe="$(escape_squotes "${cmd}")"
  # shellcheck disable=SC2086
  ${SSH_CMD_STR} -t "${REMOTE_USER}@${REMOTE_HOST}" "bash -lc '${safe}'"
}

# ---- Remote docker helpers ----
remote_compose_prefix() {
  [[ -n "${REMOTE_DOCKER_COMPOSE_YML}" ]] || die "REMOTE_DOCKER_COMPOSE_YML is not set (set it in ${CONFIG_FILE})."
  [[ -n "${DOCKER_COMPOSE_BIN}" ]] || DOCKER_COMPOSE_BIN="docker compose"
  echo "${DOCKER_COMPOSE_BIN} -f '${REMOTE_DOCKER_COMPOSE_YML}'"
}

remote_container_exec() {
  local service="$1"; shift
  local cmd="$1"
  local prefix safe
  prefix="$(remote_compose_prefix)"
  safe="$(escape_squotes "${cmd}")"
  remote_exec "${prefix} exec -T '${service}' bash -lc '${safe}'"
}

remote_container_exec_tty() {
  local service="$1"; shift
  local cmd="$1"
  local prefix safe
  prefix="$(remote_compose_prefix)"
  safe="$(escape_squotes "${cmd}")"

  if is_tty; then
    remote_exec_tty "${prefix} exec '${service}' bash -lc '${safe}'"
  else
    remote_exec "${prefix} exec -T '${service}' bash -lc '${safe}'"
  fi
}

remote_magento_exec() {
  local cmd="$1"
  if [[ "${DOCKER_MODE}" == "yes" ]]; then
    remote_container_exec "${REMOTE_PHP_SERVICE}" "cd '${REMOTE_MAGENTO_ROOT_CONTAINER}' && env -u MAGE_RUN_CODE -u MAGE_RUN_TYPE ${cmd}"
  else
    local safe
    safe="$(escape_squotes "cd '${REMOTE_PATH}' && env -u MAGE_RUN_CODE -u MAGE_RUN_TYPE ${cmd}")"
    remote_exec "${safe}"
  fi
}

remote_magento_exec_tty() {
  local cmd="$1"
  if [[ "${DOCKER_MODE}" == "yes" ]]; then
    remote_container_exec_tty "${REMOTE_PHP_SERVICE}" "cd '${REMOTE_MAGENTO_ROOT_CONTAINER}' && env -u MAGE_RUN_CODE -u MAGE_RUN_TYPE ${cmd}"
  else
    local safe
    safe="$(escape_squotes "cd '${REMOTE_PATH}' && env -u MAGE_RUN_CODE -u MAGE_RUN_TYPE ${cmd}")"
    remote_exec_tty "${safe}"
  fi
}

remote_guess_db_service() {
  # Best-effort: look for a DB-ish service name in the remote docker-compose file.
  # Returns empty string if not found.
  [[ "${DOCKER_MODE}" == "yes" ]] || return 0
  [[ -n "${REMOTE_DOCKER_COMPOSE_YML}" ]] || return 0

  local prefix services svc
  prefix="$(remote_compose_prefix)"
  services="$(remote_exec "bash -lc \"${prefix} config --services 2>/dev/null || ${prefix} ps --services 2>/dev/null\"" || true)"
  services="$(printf "%s\n" "${services}" | tr -d '\r')"

  for svc in db mysql mariadb percona; do
    if printf "%s\n" "${services}" | grep -qx "${svc}"; then
      printf "%s" "${svc}"
      return 0
    fi
  done

  return 0
}

remote_detect_env_db_creds() {
  # Reads DB creds from remote Magento app/etc/env.php.
  # Prints: dbname<TAB>username<TAB>password<TAB>host<TAB>port
  local php_cmd
  php_cmd='php -r '"'"'$env=@require "app/etc/env.php"; $c=$env["db"]["connection"]["default"]??[]; echo ($c["dbname"]??"")."\t".($c["username"]??"")."\t".($c["password"]??"")."\t".($c["host"]??"")."\t".($c["port"]??"");'"'"''

  if [[ "${DOCKER_MODE}" == "yes" ]]; then
    remote_container_exec "${REMOTE_PHP_SERVICE}" "cd '${REMOTE_MAGENTO_ROOT_CONTAINER}' && ${php_cmd}"
  else
    remote_exec "cd '${REMOTE_PATH}' && ${php_cmd}"
  fi
}


remote_docker_detect() {
  local requested="${DOCKER_MODE:-auto}"

  if [[ "${requested}" == "no" ]]; then
    DOCKER_MODE="no"
    return 0
  fi

  if [[ "${requested}" == "yes" || ( "${requested}" == "auto" && -n "${REMOTE_DOCKER_COMPOSE_YML}" ) ]]; then
    DOCKER_MODE="yes"

    [[ -n "${REMOTE_DOCKER_COMPOSE_YML}" ]] || die "DOCKER_MODE=yes but REMOTE_DOCKER_COMPOSE_YML is not set."
    [[ -n "${REMOTE_PHP_SERVICE}" ]] || die "DOCKER_MODE=yes but REMOTE_PHP_SERVICE is not set."
    [[ -n "${REMOTE_MAGENTO_ROOT_CONTAINER}" ]] || die "DOCKER_MODE=yes but REMOTE_MAGENTO_ROOT_CONTAINER is not set."

    echo "➡️  Detecting Docker Compose on remote..."
    remote_exec "test -f '${REMOTE_DOCKER_COMPOSE_YML}'" || die "Remote docker-compose.yml not found: ${REMOTE_DOCKER_COMPOSE_YML}"

    if remote_exec "docker compose version >/dev/null 2>&1"; then
      DOCKER_COMPOSE_BIN="docker compose"
    elif remote_exec "docker-compose version >/dev/null 2>&1"; then
      DOCKER_COMPOSE_BIN="docker-compose"
    else
      die "Docker Compose not found on remote (need either 'docker compose' or 'docker-compose')."
    fi

    # Best-effort validate service exists
    local prefix
    prefix="$(remote_compose_prefix)"
    remote_exec "${prefix} config --services 2>/dev/null | grep -qx '${REMOTE_PHP_SERVICE}'" || true
    return 0
  fi

  DOCKER_MODE="no"
  return 0
}

# ---- Rsync excludes ----
RSYNC_ALWAYS_EXCLUDES=(
  # VCS / tooling
  --exclude ".git"
  --exclude ".git/"
  --exclude ".git/***"
  --exclude ".github/"
  --exclude ".gitignore"
  --exclude ".gitattributes"
  --exclude ".gitmodules"
  --exclude ".idea/"
  --exclude ".vscode/"
  --exclude ".claude"
  --exclude ".claude/"
  --exclude ".claude/***"

  # OS / editor junk
  --exclude ".DS_Store"
  --exclude "._*"

  # Local-only secrets & build artifacts
  --exclude ".env"
  --exclude "auth.json"

  # Magento generated / cache
  --exclude "var/"
  --exclude "generated/"
  --exclude "pub/static/"
  --exclude "pub/media/cache/"
  --exclude "pub/media/tmp/"
  --exclude "pub/media/catalog/product/cache/"

  # Never overwrite live config
  --exclude "app/etc/env.php"
  --exclude "app/etc/config.php"

  # Reduce noise / massive test suites
  --exclude "dev/tests/"
  --exclude "vendor/*/dev/tests/"
  --exclude "vendor/magento/magento2-base/dev/tests/"
)


# ---- Prompts ----
pick_mode() {
  local mode="${UPLOAD_MODE:-}"
  if [[ -n "${mode}" ]]; then
    case "${mode}" in
      all|code|db|media|app|appcode|appdesign) echo "${mode}"; return 0 ;;
      *) die "UPLOAD_MODE must be one of: all|code|db|media|app|appcode|appdesign" ;;
    esac
  fi

  # Non-interactive defaults to code to avoid accidental destructive actions.
  if ! is_tty; then
    echo "code"
    return 0
  fi

  # IMPORTANT: print prompts to STDERR so command substitution doesn't capture them.
  {
    echo ""
    echo "How would you like to upload to live?"
    echo "  1) All code + media + DB"
    echo "  2) Code Only"
    echo "  3) DB Only"
    echo "  4) Media Only"
    echo "  5) App folder only (app/)"
    echo "  6) App code only (app/code/)"
    echo "  7) App design only (app/design/)"
  } >&2

  local reply=""
  # Read from the terminal explicitly (works even if STDIN is redirected).
  if [[ -r /dev/tty ]]; then
    read -r -p "Enter choice [1-7, default: 2]: " reply </dev/tty || true
  else
    read -r -p "Enter choice [1-7, default: 2]: " reply || true
  fi

  case "${reply}" in
    1) echo "all" ;;
    3) echo "db" ;;
    4) echo "media" ;;
    5) echo "app" ;;
    6) echo "appcode" ;;
    7) echo "appdesign" ;;
    2|"") echo "code" ;;
    *) echo "code" ;;
  esac
}

pick_rsync_delete() {
  local v="${RSYNC_DELETE:-ask}"
  case "${v}" in
    yes|no) echo "${v}"; return 0 ;;
    ask)
      if is_tty; then
        {
          echo ""
          echo "Rsync --delete removes files on the server that no longer exist locally."
        } >&2
        local reply=""
        if [[ -r /dev/tty ]]; then
          read -r -p "Use --delete for rsync? (y/N): " reply </dev/tty || true
        else
          read -r -p "Use --delete for rsync? (y/N): " reply || true
        fi
        [[ "${reply}" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
      else
        echo "no"
      fi
      ;;
    *) echo "no" ;;
  esac
}

# ---- Config checks ----
ensure_required_config() {
  [[ -n "${REMOTE_HOST}" ]] || die "REMOTE_HOST is not set (set it in ${CONFIG_FILE})."
  [[ -n "${REMOTE_USER}" ]] || die "REMOTE_USER is not set (set it in ${CONFIG_FILE})."
  [[ -n "${REMOTE_PATH}" ]] || die "REMOTE_PATH is not set (set it in ${CONFIG_FILE})."

  # Provide a reasonable default for LIVE_BASE_URL if not set
  if [[ -z "${LIVE_BASE_URL}" ]]; then
    LIVE_BASE_URL="https://${REMOTE_HOST}/"
    if is_tty; then
      echo ""
      echo "LIVE_BASE_URL is not set. Defaulting to: ${LIVE_BASE_URL}"
      read -r -p "Press Enter to accept or type the correct LIVE_BASE_URL: " reply
      [[ -n "${reply}" ]] && LIVE_BASE_URL="${reply}"
    else
      echo "ℹ️  LIVE_BASE_URL not set; using ${LIVE_BASE_URL}"
    fi
  fi
}

ensure_live_magento_cli() {
  echo "➡️  Checking remote Magento CLI..."
  remote_docker_detect

  # Host path must exist for rsync targets
  remote_exec "test -d '${REMOTE_PATH}'" || die "Remote path not found: ${REMOTE_PATH}"

  if [[ "${DOCKER_MODE}" == "yes" ]]; then
    remote_container_exec "${REMOTE_PHP_SERVICE}" "cd '${REMOTE_MAGENTO_ROOT_CONTAINER}' && test -f bin/magento" \
      || die "Remote bin/magento not found inside container at ${REMOTE_MAGENTO_ROOT_CONTAINER} (service: ${REMOTE_PHP_SERVICE})"
  else
    remote_exec "cd '${REMOTE_PATH}' && test -f bin/magento" || die "Remote bin/magento not found at ${REMOTE_PATH}"
  fi
}

# ---- Remote Magento actions ----
remote_maintenance_on() {
  [[ "${REMOTE_MAINTENANCE}" == "yes" ]] || return 0
  echo "➡️  Enabling maintenance mode on live..."
  remote_magento_exec "php -d memory_limit=-1 bin/magento maintenance:enable" || true
}

remote_maintenance_off() {
  [[ "${REMOTE_MAINTENANCE}" == "yes" ]] || return 0
  echo "➡️  Disabling maintenance mode on live..."
  remote_magento_exec "php -d memory_limit=-1 bin/magento maintenance:disable" || true
}

remote_set_live_base_urls() {
  echo "➡️  Resetting live base URLs..."

  if [[ -z "${LIVE_BASE_URL:-}" ]]; then
    echo "ℹ️  LIVE_BASE_URL is not set; skipping base URL reset."
    return 0
  fi

  # Normalize trailing slash
  [[ "${LIVE_BASE_URL}" == */ ]] || LIVE_BASE_URL="${LIVE_BASE_URL}/"
  if [[ -n "${LIVE_SUBCATS_URL}" ]]; then
    [[ "${LIVE_SUBCATS_URL}" == */ ]] || LIVE_SUBCATS_URL="${LIVE_SUBCATS_URL}/"
  fi

  # Grab website list once (best-effort) so we don't spam errors for missing scope codes
  local websites=""
  websites="$(remote_magento_exec "php -d memory_limit=-1 bin/magento store:website:list" 2>/dev/null || true)"
  websites="$(printf "%s\n" "${websites}" | tr -d '\r')"

  local main_code="${LIVE_MAIN_WEBSITE_CODE:-base}"
  local subcats_code="${LIVE_SUBCATS_WEBSITE_CODE:-subcats}"

  local has_main="no"
  local has_subcats="no"
  if printf "%s\n" "${websites}" | grep -qE "\|[[:space:]]*${main_code}[[:space:]]*\|"; then
    has_main="yes"
  fi
  if [[ -n "${LIVE_SUBCATS_URL}" ]] && printf "%s\n" "${websites}" | grep -qE "\|[[:space:]]*${subcats_code}[[:space:]]*\|"; then
    has_subcats="yes"
  fi

  # Default scope (always)
  remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/unsecure/base_url '${LIVE_BASE_URL}'" || true
  remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/secure/base_url '${LIVE_BASE_URL}'" || true
  remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/unsecure/base_link_url '${LIVE_BASE_URL}'" || true
  remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/secure/base_link_url '${LIVE_BASE_URL}'" || true

  # Website scope: main (only if the website code exists)
  if [[ "${has_main}" == "yes" ]]; then
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/unsecure/base_url '${LIVE_BASE_URL}' --scope=websites --scope-code='${main_code}'" || true
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/secure/base_url '${LIVE_BASE_URL}' --scope=websites --scope-code='${main_code}'" || true
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/unsecure/base_link_url '${LIVE_BASE_URL}' --scope=websites --scope-code='${main_code}'" || true
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/secure/base_link_url '${LIVE_BASE_URL}' --scope=websites --scope-code='${main_code}'" || true
  fi

  # Website scope: subcats (only if code exists and URL provided)
  if [[ "${has_subcats}" == "yes" ]]; then
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/unsecure/base_url '${LIVE_SUBCATS_URL}' --scope=websites --scope-code='${subcats_code}'" || true
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/secure/base_url '${LIVE_SUBCATS_URL}' --scope=websites --scope-code='${subcats_code}'" || true
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/unsecure/base_link_url '${LIVE_SUBCATS_URL}' --scope=websites --scope-code='${subcats_code}'" || true
    remote_magento_exec "php -d memory_limit=-1 bin/magento config:set web/secure/base_link_url '${LIVE_SUBCATS_URL}' --scope=websites --scope-code='${subcats_code}'" || true
  fi

  remote_magento_exec "php -d memory_limit=-1 bin/magento cache:flush" || true
  echo "✅ Base URLs reset (best-effort)."
}

remote_real_deploy() {
  echo "➡️  REAL_DEPLOY=yes → running full remote deployment..."
  echo "    - setup:upgrade"
  remote_magento_exec_tty "php -d memory_limit=-1 bin/magento setup:upgrade" || die "Remote setup:upgrade failed"

  echo "    - setup:di:compile"
  remote_magento_exec_tty "php -d memory_limit=-1 bin/magento setup:di:compile" || die "Remote di:compile failed"

  echo "    - setup:static-content:deploy (-f) [locales: ${SCD_LOCALES}, jobs: ${SCD_JOBS}]"
  # shellcheck disable=SC2086
  remote_magento_exec_tty "php -d memory_limit=-1 bin/magento setup:static-content:deploy -f --jobs ${SCD_JOBS} ${SCD_LOCALES}" || die "Remote static-content:deploy failed"

  echo "    - cache:flush"
  remote_magento_exec_tty "php -d memory_limit=-1 bin/magento cache:flush" || true

  echo "✅ Remote deployment completed."
}

remote_real_reindex() {
  echo "➡️  REAL_REINDEX=yes → running remote reindex (this may take a while)..."
  echo "    - indexer:reindex"
  remote_magento_exec_tty "php -d memory_limit=-1 bin/magento indexer:reindex" || die "Remote indexer:reindex failed"

  echo "    - cache:flush"
  remote_magento_exec_tty "php -d memory_limit=-1 bin/magento cache:flush" || true

  echo "✅ Remote reindex completed."
}

remote_post_deploy() {
  if [[ "${REAL_DEPLOY}" == "yes" ]]; then
    remote_real_deploy
  fi

  if [[ "${REAL_REINDEX}" == "yes" ]]; then
    remote_real_reindex
    return 0
  fi

  if [[ "${REAL_DEPLOY}" == "yes" ]]; then
    return 0
  fi

  echo "➡️  Remote post-deploy: cache flush (REAL_DEPLOY=no, REAL_REINDEX=no)"
  remote_magento_exec "php -d memory_limit=-1 bin/magento cache:flush" || true
}

# ---- Rsync runner (better errors) ----
run_rsync() {
  # Usage: run_rsync <rsync ...args...>
  # Preflight (once): warn if remote SSH session is noisy (can break rsync)
  if [[ ${SHELL_QUIET_CHECKED} -eq 0 ]]; then
    check_remote_shell_quiet || true
    SHELL_QUIET_CHECKED=1
  fi

  local attempt=0
  local rc=0
  while :; do
    attempt=$((attempt + 1))
    set +e
    rsync "$@"
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      return 0
    fi

    if [[ $rc -eq 12 && $attempt -le ${RSYNC_RETRIES} ]]; then
      echo "⚠️  rsync exit 12 (protocol stream error). Retrying (${attempt}/${RSYNC_RETRIES}) after ${RSYNC_RETRY_SLEEP}s..." >&2
      sleep "${RSYNC_RETRY_SLEEP}"
      continue
    fi

    if [[ $rc -eq 12 ]]; then
      echo "❌ rsync failed with exit status 12 (protocol stream error)." >&2
      echo "   Common causes:" >&2
      echo "    • Remote shell prints output (MOTD/echo in .bashrc). Ensure non-interactive shells are quiet." >&2
      echo "    • SSH connection drops mid-transfer. Try again; keepalives/timeouts are enabled." >&2
    fi
    return $rc
  done
}

# ---- Upload tasks ----
upload_code() {
  need_cmd rsync

  local del_flag
  del_flag="$(pick_rsync_delete)"

  echo "➡️  Uploading code to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"

  local -a rsync_args
  rsync_args=(
    -rlvz
    --compress
    --timeout=600
    --contimeout=60
    --partial
    --partial-dir=.mage-mirror-rsync-partial
    --delay-updates
    --no-perms
    --no-owner
    --no-group
    --no-times
    --omit-dir-times
    "${RSYNC_ALWAYS_EXCLUDES[@]}"
  )
  [[ "${del_flag}" == "yes" ]] && rsync_args+=(--delete)

  # Code sync: project root -> remote root, but exclude pub/media entirely (media has its own mode)
  rsync_args+=(--exclude "pub/media/")

  remote_exec "mkdir -p '${REMOTE_PATH}'" || true

  run_rsync "${rsync_args[@]}" -e "${RSYNC_SSH_CMD}" \
    "./" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

  echo "✅ Code upload completed."
}

upload_app() {
  need_cmd rsync

  local del_flag
  del_flag="$(pick_rsync_delete)"

  echo "➡️  Uploading app/ to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/app"

  [[ -d "app" ]] || die "Local app/ not found. Run this from your Magento project root."
  remote_exec "mkdir -p '${REMOTE_PATH}/app'" || true

  local -a rsync_args
  rsync_args=(
    -rlvz
    --compress
    --timeout=600
    --contimeout=60
    --partial
    --partial-dir=.mage-mirror-rsync-partial
    --delay-updates
    --no-perms
    --no-owner
    --no-group
    --no-times
    --omit-dir-times
    --exclude ".DS_Store"
    --exclude "._*"
    --exclude "app/etc/env.php"
    --exclude "app/etc/config.php"
  )
  [[ "${del_flag}" == "yes" ]] && rsync_args+=(--delete)

  run_rsync "${rsync_args[@]}" -e "${RSYNC_SSH_CMD}"     "app/"     "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/app/"

  echo "✅ app/ upload completed."
}

upload_app_code() {
  need_cmd rsync

  local del_flag
  del_flag="$(pick_rsync_delete)"

  echo "➡️  Uploading app/code/ to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/app/code"

  [[ -d "app/code" ]] || die "Local app/code/ not found."
  remote_exec "mkdir -p '${REMOTE_PATH}/app/code'" || true

  local -a rsync_args
  rsync_args=(
    -rlvz
    --compress
    --timeout=600
    --contimeout=60
    --partial
    --partial-dir=.mage-mirror-rsync-partial
    --delay-updates
    --no-perms
    --no-owner
    --no-group
    --no-times
    --omit-dir-times
    --exclude ".DS_Store"
    --exclude "._*"
  )
  [[ "${del_flag}" == "yes" ]] && rsync_args+=(--delete)

  run_rsync "${rsync_args[@]}" -e "${RSYNC_SSH_CMD}"     "app/code/"     "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/app/code/"

  echo "✅ app/code/ upload completed."
}

upload_app_design() {
  need_cmd rsync

  local del_flag
  del_flag="$(pick_rsync_delete)"

  echo "➡️  Uploading app/design/ to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/app/design"

  [[ -d "app/design" ]] || die "Local app/design/ not found."
  remote_exec "mkdir -p '${REMOTE_PATH}/app/design'" || true

  local -a rsync_args
  rsync_args=(
    -rlvz
    --compress
    --timeout=600
    --contimeout=60
    --partial
    --partial-dir=.mage-mirror-rsync-partial
    --delay-updates
    --no-perms
    --no-owner
    --no-group
    --no-times
    --omit-dir-times
    --exclude ".DS_Store"
    --exclude "._*"
  )
  [[ "${del_flag}" == "yes" ]] && rsync_args+=(--delete)

  run_rsync "${rsync_args[@]}" -e "${RSYNC_SSH_CMD}"     "app/design/"     "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/app/design/"

  echo "✅ app/design/ upload completed."
}

upload_media() {
  need_cmd rsync

  echo "➡️  Uploading media (pub/media) to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/pub/media"

  [[ -d "pub/media" ]] || die "Local pub/media not found. Run this from your Magento project root."
  remote_exec "mkdir -p '${REMOTE_PATH}/pub/media'" || true

  local -a rsync_args
  rsync_args=(
    -rlvz
    --compress
    --timeout=600
    --contimeout=60
    --partial
    --partial-dir=.mage-mirror-rsync-partial
    --delay-updates
    --no-perms
    --no-owner
    --no-group
    --no-times
    --omit-dir-times
    --exclude "cache/"
    --exclude "tmp/"
    --exclude "catalog/product/cache/"
    --exclude ".DS_Store"
    --exclude "._*"
  )
  run_rsync "${rsync_args[@]}" -e "${RSYNC_SSH_CMD}" \
    "pub/media/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/pub/media/"

  echo "✅ Media upload completed."
}

upload_db() {
  need_cmd warden
  need_cmd gzip

  # Best-effort: if we're targeting a dockerized live environment, guess the DB service
  if [[ "${REMOTE_DB_AUTODETECT}" == "yes" && "${DOCKER_MODE}" == "yes" && -z "${REMOTE_DB_SERVICE}" ]]; then
    REMOTE_DB_SERVICE="$(remote_guess_db_service || true)"
  fi

  # Best-effort: pull DB creds from remote app/etc/env.php (avoids wrong REMOTE_DB_USER/PASSWORD)
  if [[ "${REMOTE_DB_AUTODETECT}" == "yes" ]]; then
    local env_line env_db env_user env_pass env_host env_port
    env_line="$(remote_detect_env_db_creds 2>/dev/null | tail -n 1 || true)"
    if [[ -n "${env_line}" ]]; then
      IFS=$'	' read -r env_db env_user env_pass env_host env_port <<<"${env_line}"
      [[ -n "${env_db}"   ]] && REMOTE_DB_NAME="${env_db}"
      [[ -n "${env_user}" ]] && REMOTE_DB_USER="${env_user}"
      [[ -n "${env_pass}" ]] && REMOTE_DB_PASSWORD="${env_pass}"
      [[ -n "${env_host}" ]] && REMOTE_DB_HOST="${env_host}"
      [[ -n "${env_port}" ]] && REMOTE_DB_PORT="${env_port}"
    fi
  fi

  [[ -n "${REMOTE_DB_NAME}" ]] || die "REMOTE_DB_NAME is not set (set it in ${CONFIG_FILE} or enable REMOTE_DB_AUTODETECT=yes)."
  [[ -n "${REMOTE_DB_USER}" ]] || die "REMOTE_DB_USER is not set (set it in ${CONFIG_FILE} or enable REMOTE_DB_AUTODETECT=yes)."
  [[ -n "${REMOTE_DB_PASSWORD}" ]] || die "REMOTE_DB_PASSWORD is not set (set it in ${CONFIG_FILE} or enable REMOTE_DB_AUTODETECT=yes)."


  if [[ -n "${REMOTE_DB_SERVICE}" ]]; then
    echo "➡️  Uploading DB: local '${MAGENTO_DB_NAME}' -> remote '${REMOTE_DB_NAME}' (docker service: ${REMOTE_DB_SERVICE})"
  else
    echo "➡️  Uploading DB: local '${MAGENTO_DB_NAME}' -> remote '${REMOTE_DB_NAME}' (${REMOTE_DB_HOST}:${REMOTE_DB_PORT})"
  fi

  echo "    (creating a compressed dump locally and importing on live)"
  # Detect optional mysqldump flags inside Warden DB container (MySQL vs MariaDB)
  local gtid_flag="" colstats_flag="" notablespaces_flag=""
  if warden env exec -T db mysqldump --help 2>/dev/null | grep -q "set-gtid-purged"; then
    gtid_flag="--set-gtid-purged=OFF"
  fi
  if warden env exec -T db mysqldump --help 2>/dev/null | grep -q "column-statistics"; then
    colstats_flag="--column-statistics=0"
  fi
  if warden env exec -T db mysqldump --help 2>/dev/null | grep -q "no-tablespaces"; then
    notablespaces_flag="--no-tablespaces"
  fi

  # Build ignore-table flags
  local ignore_lines=""
  local ex_list="${DB_EXCLUDE_TABLES}"
  ex_list="${ex_list//,/ }"
  if [[ -n "${ex_list// /}" ]]; then
    for t in ${ex_list}; do
      [[ -n "${t}" ]] || continue
      ignore_lines+="  --ignore-table='${MAGENTO_DB_NAME}.${t}' \\"$'\n'
    done
  fi

  local extended_flag=""
  if [[ "${MYSQLDUMP_SKIP_EXTENDED_INSERT}" == "yes" ]]; then
    extended_flag="--skip-extended-insert"
  fi

  local dump_cmd
  dump_cmd=$(cat <<EOF
set -e
export MYSQL_PWD='${MAGENTO_DB_PASSWORD}'
mysqldump \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --hex-blob \
  --add-drop-table \
  --add-drop-trigger \
  --max_allowed_packet=${MYSQLDUMP_MAX_ALLOWED_PACKET} \
  --net_buffer_length=${MYSQLDUMP_NET_BUFFER_LENGTH} \
  ${notablespaces_flag} \
  ${colstats_flag} \
  ${gtid_flag} \
  ${extended_flag} \
${ignore_lines}  -u'${MAGENTO_DB_USER}' \
  '${MAGENTO_DB_NAME}'
EOF
)

  # Remote temp file (dump is staged on live before importing so a failed dump won't partially overwrite DB)
  local ts remote_tmp
  ts="$(date +%Y%m%d%H%M%S)"
  remote_tmp="/tmp/mage-mirror-upload-${REMOTE_DB_NAME}-${ts}.sql.gz"

  echo "    • Writing compressed dump to ${remote_tmp} on live..."
  if ! ( warden env exec -T db bash -lc "${dump_cmd}" | gzip -1 | ${SSH_CMD_STR} "${REMOTE_USER}@${REMOTE_HOST}" "cat > '${remote_tmp}'" ); then
    # Clean up partial file
    remote_exec "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true

    echo "⚠️  mysqldump failed. Retrying with safer settings (skip extended inserts, exclude importexport_importdata)..." >&2
    # Ensure retry excludes importexport_importdata
    local retry_ex="${DB_EXCLUDE_TABLES}"
    if [[ "${retry_ex}" != *"importexport_importdata"* ]]; then
      retry_ex="${retry_ex},importexport_importdata"
    fi
    local retry_ignore_lines=""
    local retry_list="${retry_ex//,/ }"
    for t in ${retry_list}; do
      [[ -n "${t}" ]] || continue
      retry_ignore_lines+="  --ignore-table='${MAGENTO_DB_NAME}.${t}' \\"$'\n'
    done

    local dump_cmd_retry
    dump_cmd_retry=$(cat <<EOF
set -e
export MYSQL_PWD='${MAGENTO_DB_PASSWORD}'
mysqldump \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --hex-blob \
  --add-drop-table \
  --add-drop-trigger \
  --max_allowed_packet=${MYSQLDUMP_MAX_ALLOWED_PACKET} \
  --net_buffer_length=${MYSQLDUMP_NET_BUFFER_LENGTH} \
  ${notablespaces_flag} \
  ${colstats_flag} \
  ${gtid_flag} \
  --skip-extended-insert \
${retry_ignore_lines}  -u'${MAGENTO_DB_USER}' \
  '${MAGENTO_DB_NAME}'
EOF
)

    if ! ( warden env exec -T db bash -lc "${dump_cmd_retry}" | gzip -1 | ${SSH_CMD_STR} "${REMOTE_USER}@${REMOTE_HOST}" "cat > '${remote_tmp}'" ); then
      remote_exec "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
      die "DB dump failed even after retry. Consider increasing MYSQLDUMP_MAX_ALLOWED_PACKET or excluding additional large tables via DB_EXCLUDE_TABLES."
    fi
  fi

    # Import: ensure we fail if gzip/cat fails (pipefail), and avoid container file-path issues.
  echo "    • Importing dump into live DB..."
  if [[ -n "${REMOTE_DB_SERVICE}" ]]; then
    local prefix import_host_cmd
    prefix="$(remote_compose_prefix)"
    import_host_cmd=$(cat <<EOF
set -euo pipefail
test -s '${remote_tmp}'
gzip -dc '${remote_tmp}' | ${prefix} exec -T '${REMOTE_DB_SERVICE}' bash -lc "set -euo pipefail; export MYSQL_PWD='${REMOTE_DB_PASSWORD}'; mysql -u '${REMOTE_DB_USER}' '${REMOTE_DB_NAME}'"
EOF
)
    remote_exec "${import_host_cmd}"
  else
    local import_host_cmd
    import_host_cmd=$(cat <<EOF
set -euo pipefail
test -s '${remote_tmp}'
export MYSQL_PWD='${REMOTE_DB_PASSWORD}'
gzip -dc '${remote_tmp}' | mysql -h '${REMOTE_DB_HOST}' -P '${REMOTE_DB_PORT}' -u '${REMOTE_DB_USER}' '${REMOTE_DB_NAME}'
EOF
)
    remote_exec "${import_host_cmd}"
  fi

# Cleanup dump file
  remote_exec "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true

  echo "✅ DB upload completed."
}

main() {
  need_cmd ssh
  need_cmd rsync
  ensure_required_config
  ensure_live_magento_cli

  local mode
  mode="$(pick_mode)"

  echo ""
  echo "=========================================="
  echo " Mage Mirror Upload → LIVE"
  echo " Mode         : ${mode}"
  echo " Remote host  : ${REMOTE_USER}@${REMOTE_HOST}"
  echo " Remote path  : ${REMOTE_PATH}"
  echo " Docker mode  : ${DOCKER_MODE}"
  echo " Live base URL: ${LIVE_BASE_URL:-}"
  echo " Real deploy  : ${REAL_DEPLOY}"
  echo " Real reindex : ${REAL_REINDEX}"
  echo "=========================================="

  case "${mode}" in
    all)
      remote_maintenance_on
      upload_code
      upload_media
      upload_db
      remote_set_live_base_urls
      remote_post_deploy
      remote_maintenance_off
      ;;
    code)
      remote_maintenance_on
      upload_code
      remote_set_live_base_urls
      remote_post_deploy
      remote_maintenance_off
      ;;
    db)
      remote_maintenance_on
      upload_db
      remote_set_live_base_urls
      remote_post_deploy
      remote_maintenance_off
      ;;
    media)
      remote_maintenance_on
      upload_media
      remote_post_deploy
      remote_maintenance_off
      ;;
    app)
      remote_maintenance_on
      upload_app
      remote_post_deploy
      remote_maintenance_off
      ;;
    appcode)
      remote_maintenance_on
      upload_app_code
      remote_post_deploy
      remote_maintenance_off
      ;;
    appdesign)
      remote_maintenance_on
      upload_app_design
      remote_post_deploy
      remote_maintenance_off
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  echo ""
  echo "✅ Upload finished."
}

main "$@"
