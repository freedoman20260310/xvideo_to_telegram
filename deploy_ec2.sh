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
    exec sudo -E bash "$0" "$@"
  fi
}

load_existing_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${ENV_FILE}"
    set +a
  fi
  XVIDEO_BOT_TOKEN="${XVIDEO_BOT_TOKEN:-}"
  TELEGRAM_API_ID="${TELEGRAM_API_ID:-}"
  TELEGRAM_API_HASH="${TELEGRAM_API_HASH:-}"
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
  install -d -m 755 -o "${APP_USER}" -g "${APP_USER}" /tmp/xvideo-dl
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
    printf 'FFPROBE_BIN=%s\n' "$(escape_env_value "/usr/bin/ffprobe")"
    printf 'CURL_BIN=%s\n' "$(escape_env_value "/usr/bin/curl")"
    printf 'XVIDEO_UPLOAD_TIMEOUT=%s\n' "$(escape_env_value "${UPLOAD_TIMEOUT}")"
    printf 'XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP=%s\n' "$(escape_env_value "${LOCAL_UPLOAD_CAP}")"
    printf 'XVIDEO_TELEGRAM_UPLOAD_EST_MBPS=%s\n' "$(escape_env_value "${TELEGRAM_UPLOAD_EST_MBPS}")"
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
  log "Smoke-testing bot token against official Telegram API"
  curl -fsS --max-time 20 "${url}" | python3 -c '
import json, sys
d=json.load(sys.stdin)
if not d.get("ok"):
    raise SystemExit("getMe returned ok=false")
print("Bot:", d.get("result", {}).get("username", "unknown"))
'
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

  prompt_value XVIDEO_BOT_TOKEN "Telegram bot token from BotFather" 1
  prompt_value TELEGRAM_API_ID "Telegram application api_id from my.telegram.org" 0
  prompt_value TELEGRAM_API_HASH "Telegram application api_hash from my.telegram.org" 1

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
