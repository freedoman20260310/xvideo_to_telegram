#!/usr/bin/env bash
# One-command installer for Ubuntu EC2.
#
# Usage on the EC2 instance:
#   chmod +x deploy_ec2.sh
#   ./deploy_ec2.sh
#
# Non-interactive usage:
#   XVIDEO_BOT_TOKEN=... TELEGRAM_API_ID=... TELEGRAM_API_HASH=... ./deploy_ec2.sh

set -euo pipefail

APP_NAME="xvideo-to-telegram"
APP_USER="${APP_USER:-xvideo}"
APP_DIR="${APP_DIR:-/opt/xvideo-to-telegram}"
APP_SRC_DIR="${APP_DIR}/app"
ENV_FILE="${ENV_FILE:-/etc/xvideo-to-telegram.env}"
BOT_SERVICE="xvideo-to-telegram.service"
API_SERVICE="telegram-bot-api.service"
TELEGRAM_BOT_API_IMAGE="${TELEGRAM_BOT_API_IMAGE:-aiogram/telegram-bot-api:latest}"
BOT_API_PORT="${BOT_API_PORT:-8081}"
UPLOAD_TIMEOUT="${XVIDEO_UPLOAD_TIMEOUT:-1800}"
LOCAL_UPLOAD_CAP="${XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP:-12}"
TELEGRAM_UPLOAD_EST_MBPS="${XVIDEO_TELEGRAM_UPLOAD_EST_MBPS:-0.35}"
COOKIES_FILE="${XVIDEO_COOKIES_FILE:-/var/lib/xvideo-to-telegram/x-cookies.txt}"
ADMIN_CHAT_IDS="${XVIDEO_ADMIN_CHAT_IDS:-}"
COOKIE_MAX_BYTES="${XVIDEO_COOKIE_MAX_BYTES:-2097152}"
STAGING_DIR="${XVIDEO_STAGING_DIR:-/var/lib/xvideo-to-telegram/staging/default}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_SOURCE="${BOT_SOURCE:-${SCRIPT_DIR}/xvideo_to_telegram_bot.py}"

log() {
  printf '[%s] %s\n' "$APP_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$APP_NAME" "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo \
      XVIDEO_BOT_TOKEN="${XVIDEO_BOT_TOKEN:-}" \
      TELEGRAM_API_ID="${TELEGRAM_API_ID:-}" \
      TELEGRAM_API_HASH="${TELEGRAM_API_HASH:-}" \
      XVIDEO_ADMIN_CHAT_IDS="${XVIDEO_ADMIN_CHAT_IDS:-}" \
      XVIDEO_COOKIES_FILE="${XVIDEO_COOKIES_FILE:-}" \
      XVIDEO_COOKIE_MAX_BYTES="${XVIDEO_COOKIE_MAX_BYTES:-}" \
      XVIDEO_STAGING_DIR="${XVIDEO_STAGING_DIR:-}" \
      FFMPEG_BIN="${FFMPEG_BIN:-}" \
      CALL_TELEGRAM_LOGOUT="${CALL_TELEGRAM_LOGOUT:-}" \
      bash "$0" "$@"
  fi
}

load_existing_env() {
  local input_bot_token="${XVIDEO_BOT_TOKEN:-}"
  local input_api_id="${TELEGRAM_API_ID:-}"
  local input_api_hash="${TELEGRAM_API_HASH:-}"
  local input_admin_chat_ids="${XVIDEO_ADMIN_CHAT_IDS:-}"
  local input_cookies_file="${XVIDEO_COOKIES_FILE:-}"
  local input_cookie_max_bytes="${XVIDEO_COOKIE_MAX_BYTES:-}"
  local input_staging_dir="${XVIDEO_STAGING_DIR:-}"
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${ENV_FILE}"
    set +a
  fi
  if [[ -n "${input_bot_token}" ]]; then
    XVIDEO_BOT_TOKEN="${input_bot_token}"
  fi
  if [[ -n "${input_api_id}" ]]; then
    TELEGRAM_API_ID="${input_api_id}"
  fi
  if [[ -n "${input_api_hash}" ]]; then
    TELEGRAM_API_HASH="${input_api_hash}"
  fi
  if [[ -n "${input_admin_chat_ids}" ]]; then
    XVIDEO_ADMIN_CHAT_IDS="${input_admin_chat_ids}"
  fi
  if [[ -n "${input_cookies_file}" ]]; then
    XVIDEO_COOKIES_FILE="${input_cookies_file}"
  fi
  if [[ -n "${input_cookie_max_bytes}" ]]; then
    XVIDEO_COOKIE_MAX_BYTES="${input_cookie_max_bytes}"
  fi
  if [[ -n "${input_staging_dir}" ]]; then
    XVIDEO_STAGING_DIR="${input_staging_dir}"
  fi
  XVIDEO_BOT_TOKEN="${XVIDEO_BOT_TOKEN:-}"
  TELEGRAM_API_ID="${TELEGRAM_API_ID:-}"
  TELEGRAM_API_HASH="${TELEGRAM_API_HASH:-}"
  XVIDEO_ADMIN_CHAT_IDS="${XVIDEO_ADMIN_CHAT_IDS:-${ADMIN_CHAT_IDS}}"
  XVIDEO_COOKIES_FILE="${XVIDEO_COOKIES_FILE:-${COOKIES_FILE}}"
  XVIDEO_COOKIE_MAX_BYTES="${XVIDEO_COOKIE_MAX_BYTES:-${COOKIE_MAX_BYTES}}"
  XVIDEO_STAGING_DIR="${XVIDEO_STAGING_DIR:-${STAGING_DIR}}"
}

prompt_value() {
  local var_name="$1"
  local label="$2"
  local secret="${3:-0}"
  local current="${!var_name:-}"

  if [[ -n "${current}" ]]; then
    log "Using existing ${var_name}"
    return
  fi
  if [[ ! -t 0 ]]; then
    die "${var_name} is required in non-interactive mode"
  fi

  local value=""
  while [[ -z "${value}" ]]; do
    if [[ "${secret}" == "1" ]]; then
      read -r -s -p "${label}: " value
      printf '\n'
    else
      read -r -p "${label}: " value
    fi
  done
  printf -v "${var_name}" '%s' "${value}"
}

prompt_optional_value() {
  local var_name="$1"
  local label="$2"
  local current="${!var_name:-}"

  if [[ -n "${current}" ]]; then
    log "Using existing ${var_name}"
    return
  fi
  if [[ ! -t 0 ]]; then
    return
  fi

  local value=""
  read -r -p "${label} (optional): " value
  printf -v "${var_name}" '%s' "${value}"
}

trim_value() {
  local value="$1"
  value="${value//$'\r'/}"
  value="${value//$'\n'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "${value}"
}

normalize_optional_settings() {
  XVIDEO_ADMIN_CHAT_IDS="$(trim_value "${XVIDEO_ADMIN_CHAT_IDS:-${ADMIN_CHAT_IDS}}")"
  XVIDEO_COOKIES_FILE="$(trim_value "${XVIDEO_COOKIES_FILE:-${COOKIES_FILE}}")"
  XVIDEO_COOKIE_MAX_BYTES="$(trim_value "${XVIDEO_COOKIE_MAX_BYTES:-${COOKIE_MAX_BYTES}}")"
  XVIDEO_STAGING_DIR="$(trim_value "${XVIDEO_STAGING_DIR:-${STAGING_DIR}}")"

  if [[ -z "${XVIDEO_COOKIES_FILE}" ]]; then
    XVIDEO_COOKIES_FILE="/var/lib/xvideo-to-telegram/x-cookies.txt"
  fi
  if [[ -z "${XVIDEO_STAGING_DIR}" ]]; then
    XVIDEO_STAGING_DIR="/var/lib/xvideo-to-telegram/staging/default"
  fi
  if [[ ! "${XVIDEO_COOKIE_MAX_BYTES}" =~ ^[0-9]+$ ]]; then
    die "XVIDEO_COOKIE_MAX_BYTES must be numeric."
  fi
  if [[ -n "${XVIDEO_ADMIN_CHAT_IDS}" ]] && ! grep -Eq '^[-0-9,[:space:];]+$' <<<"${XVIDEO_ADMIN_CHAT_IDS}"; then
    die "XVIDEO_ADMIN_CHAT_IDS must contain only Telegram numeric IDs separated by commas, semicolons, or spaces."
  fi
}

normalize_and_validate_credentials() {
  XVIDEO_BOT_TOKEN="$(trim_value "${XVIDEO_BOT_TOKEN}")"
  TELEGRAM_API_ID="$(trim_value "${TELEGRAM_API_ID}")"
  TELEGRAM_API_HASH="$(trim_value "${TELEGRAM_API_HASH}")"

  if [[ ! "${XVIDEO_BOT_TOKEN}" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
    die "XVIDEO_BOT_TOKEN does not look like a BotFather token. Expected something like 123456789:AA..., with no quotes or spaces."
  fi
  if [[ ! "${TELEGRAM_API_ID}" =~ ^[0-9]+$ ]]; then
    die "TELEGRAM_API_ID must be numeric."
  fi
  if [[ -z "${TELEGRAM_API_HASH}" || "${TELEGRAM_API_HASH}" =~ [[:space:]] ]]; then
    die "TELEGRAM_API_HASH must be a non-empty string without spaces."
  fi
}

credentials_are_valid() {
  local bot_token api_id api_hash
  bot_token="$(trim_value "${XVIDEO_BOT_TOKEN}")"
  api_id="$(trim_value "${TELEGRAM_API_ID}")"
  api_hash="$(trim_value "${TELEGRAM_API_HASH}")"

  [[ "${bot_token}" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || return 1
  [[ "${api_id}" =~ ^[0-9]+$ ]] || return 1
  [[ -n "${api_hash}" && ! "${api_hash}" =~ [[:space:]] ]] || return 1
  return 0
}

prompt_credentials_until_valid() {
  while true; do
    prompt_value XVIDEO_BOT_TOKEN "Telegram bot token from BotFather" 1
    prompt_value TELEGRAM_API_ID "Telegram application api_id from my.telegram.org" 0
    prompt_value TELEGRAM_API_HASH "Telegram application api_hash from my.telegram.org" 1

    if credentials_are_valid; then
      normalize_and_validate_credentials
      return
    fi

    if [[ ! -t 0 ]]; then
      normalize_and_validate_credentials
    fi

    log "Existing credentials are invalid. Please re-enter them."
    XVIDEO_BOT_TOKEN=""
    TELEGRAM_API_ID=""
    TELEGRAM_API_HASH=""
  done
}

escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

install_packages() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS. Use Ubuntu 22.04/24.04 LTS for this script."
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID}" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y \
        ca-certificates curl docker.io ffmpeg \
        python3 python3-pip python3-venv
      ;;
    *)
      die "Unsupported OS '${ID}'. Launch an Ubuntu 22.04/24.04 LTS EC2 instance."
      ;;
  esac

  systemctl enable --now docker
}

install_app_user_and_files() {
  [[ -f "${BOT_SOURCE}" ]] || die "Missing bot source: ${BOT_SOURCE}"

  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
  fi

  install -d -m 755 -o "${APP_USER}" -g "${APP_USER}" "${APP_SRC_DIR}"
  install -d -m 755 -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}/.hermes/scripts"
  install -d -m 755 -o "${APP_USER}" -g "${APP_USER}" "${XVIDEO_STAGING_DIR}"
  install -d -m 700 -o "${APP_USER}" -g "${APP_USER}" "$(dirname "${XVIDEO_COOKIES_FILE}")"
  install -m 755 -o "${APP_USER}" -g "${APP_USER}" "${BOT_SOURCE}" "${APP_SRC_DIR}/xvideo_to_telegram_bot.py"

  python3 -m venv "${APP_DIR}/venv"
  "${APP_DIR}/venv/bin/python" -m pip install --upgrade pip wheel
  "${APP_DIR}/venv/bin/python" -m pip install --upgrade httpx yt-dlp
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
}

write_env_file() {
  install -m 600 -o root -g root /dev/null "${ENV_FILE}"
  {
    printf 'XVIDEO_BOT_TOKEN=%s\n' "$(escape_env_value "${XVIDEO_BOT_TOKEN}")"
    printf 'TELEGRAM_API_ID=%s\n' "$(escape_env_value "${TELEGRAM_API_ID}")"
    printf 'TELEGRAM_API_HASH=%s\n' "$(escape_env_value "${TELEGRAM_API_HASH}")"
    printf 'TELEGRAM_BOT_API_IMAGE=%s\n' "$(escape_env_value "${TELEGRAM_BOT_API_IMAGE}")"
    printf 'BOT_API_BASE_URL=%s\n' "$(escape_env_value "http://127.0.0.1:${BOT_API_PORT}")"
    printf 'YT_DLP_BIN=%s\n' "$(escape_env_value "${APP_DIR}/venv/bin/yt-dlp")"
    printf 'FFMPEG_BIN=%s\n' "$(escape_env_value "/usr/bin/ffmpeg")"
    printf 'FFPROBE_BIN=%s\n' "$(escape_env_value "/usr/bin/ffprobe")"
    printf 'CURL_BIN=%s\n' "$(escape_env_value "/usr/bin/curl")"
    printf 'XVIDEO_UPLOAD_TIMEOUT=%s\n' "$(escape_env_value "${UPLOAD_TIMEOUT}")"
    printf 'XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP=%s\n' "$(escape_env_value "${LOCAL_UPLOAD_CAP}")"
    printf 'XVIDEO_TELEGRAM_UPLOAD_EST_MBPS=%s\n' "$(escape_env_value "${TELEGRAM_UPLOAD_EST_MBPS}")"
    printf 'XVIDEO_COOKIES_FILE=%s\n' "$(escape_env_value "${XVIDEO_COOKIES_FILE}")"
    printf 'XVIDEO_ADMIN_CHAT_IDS=%s\n' "$(escape_env_value "${XVIDEO_ADMIN_CHAT_IDS}")"
    printf 'XVIDEO_COOKIE_MAX_BYTES=%s\n' "$(escape_env_value "${XVIDEO_COOKIE_MAX_BYTES}")"
    printf 'XVIDEO_STAGING_DIR=%s\n' "$(escape_env_value "${XVIDEO_STAGING_DIR}")"
  } > "${ENV_FILE}"
}

write_systemd_units() {
  install -d -m 755 /var/lib/telegram-bot-api
  chown 101:101 /var/lib/telegram-bot-api || true

  cat > "/etc/systemd/system/${API_SERVICE}" <<EOF
[Unit]
Description=Local Telegram Bot API server
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStartPre=-/usr/bin/docker rm -f telegram-bot-api
ExecStartPre=/usr/bin/docker pull \${TELEGRAM_BOT_API_IMAGE}
ExecStart=/usr/bin/docker run --name telegram-bot-api --rm \\
  --publish 127.0.0.1:${BOT_API_PORT}:8081 \\
  --volume /var/lib/telegram-bot-api:/var/lib/telegram-bot-api \\
  --env TELEGRAM_API_ID=\${TELEGRAM_API_ID} \\
  --env TELEGRAM_API_HASH=\${TELEGRAM_API_HASH} \\
  --env TELEGRAM_LOCAL=1 \\
  --env TELEGRAM_HTTP_PORT=8081 \\
  \${TELEGRAM_BOT_API_IMAGE}
ExecStop=/usr/bin/docker stop telegram-bot-api
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/${BOT_SERVICE}" <<EOF
[Unit]
Description=X/Twitter video downloader Telegram bot
Requires=${API_SERVICE}
After=${API_SERVICE} network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_SRC_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
ExecStart=${APP_DIR}/venv/bin/python ${APP_SRC_DIR}/xvideo_to_telegram_bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${API_SERVICE}" "${BOT_SERVICE}"
}

smoke_test_token() {
  local url="https://api.telegram.org/bot${XVIDEO_BOT_TOKEN}/getMe"
  local response_file http_code
  log "Smoke-testing bot token against official Telegram API"
  response_file="$(mktemp)"
  http_code="$(curl -sS --max-time 20 -o "${response_file}" -w '%{http_code}' "${url}" || true)"
  if [[ "${http_code}" != "200" ]]; then
    local body
    body="$(head -c 500 "${response_file}" | tr '\n' ' ')"
    rm -f "${response_file}"
    die "Official Telegram /getMe returned HTTP ${http_code}. Check XVIDEO_BOT_TOKEN. Response: ${body:-<empty>}"
  fi
  if ! python3 - "${response_file}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d=json.load(f)
if not d.get("ok"):
    raise SystemExit(f"getMe returned ok=false: {d}")
print("Bot:", d.get("result", {}).get("username", "unknown"))
PY
  then
    rm -f "${response_file}"
    die "Could not parse official Telegram /getMe response. Check network access and XVIDEO_BOT_TOKEN."
  fi
  rm -f "${response_file}"
}

maybe_logout_cloud_api() {
  if [[ "${CALL_TELEGRAM_LOGOUT:-0}" != "1" ]]; then
    return
  fi
  log "Calling official /logOut before switching to local Bot API"
  curl -fsS --max-time 20 "https://api.telegram.org/bot${XVIDEO_BOT_TOKEN}/logOut" >/dev/null || true
}

start_and_verify() {
  systemctl restart "${API_SERVICE}"
  sleep 3
  curl -fsS --max-time 20 "http://127.0.0.1:${BOT_API_PORT}/bot${XVIDEO_BOT_TOKEN}/getMe" >/dev/null

  maybe_logout_cloud_api

  systemctl restart "${BOT_SERVICE}"
  sleep 3
  systemctl --no-pager --full status "${API_SERVICE}" "${BOT_SERVICE}" || true
  log "Recent bot logs:"
  journalctl -u "${BOT_SERVICE}" -n 30 --no-pager || true
}

main() {
  require_root "$@"
  load_existing_env

  prompt_credentials_until_valid
  prompt_optional_value XVIDEO_ADMIN_CHAT_IDS "Admin Telegram user/chat IDs for cookie upload"
  normalize_optional_settings

  install_packages
  install_app_user_and_files
  write_env_file
  smoke_test_token
  write_systemd_units
  start_and_verify

  log "Done."
  log "Services: systemctl status ${API_SERVICE} ${BOT_SERVICE}"
  log "Logs: journalctl -u ${BOT_SERVICE} -f"
  log "Secrets: ${ENV_FILE}"
}

main "$@"
