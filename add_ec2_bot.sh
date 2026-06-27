#!/usr/bin/env bash
# Add another bot instance on an EC2 host that was already initialized by deploy_ec2.sh.
#
# Usage:
#   sudo ./add_ec2_bot.sh bot2
#
# Non-interactive:
#   sudo BOT_NAME=bot2 XVIDEO_BOT_TOKEN=123:ABC... ./add_ec2_bot.sh

set -euo pipefail

APP_NAME="xvideo-to-telegram"
APP_USER="${APP_USER:-xvideo}"
APP_DIR="${APP_DIR:-/opt/xvideo-to-telegram}"
APP_SRC_DIR="${APP_DIR}/app"
ENV_DIR="${ENV_DIR:-/etc/xvideo-to-telegram}"
BASE_ENV_FILE="${BASE_ENV_FILE:-/etc/xvideo-to-telegram.env}"
BOT_API_SERVICE="${BOT_API_SERVICE:-telegram-bot-api.service}"
TEMPLATE_SERVICE="xvideo-to-telegram@.service"
BOT_SOURCE="${BOT_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/xvideo_to_telegram_bot.py}"
COOKIES_FILE="${XVIDEO_COOKIES_FILE:-/var/lib/xvideo-to-telegram/x-cookies.txt}"
ADMIN_CHAT_IDS="${XVIDEO_ADMIN_CHAT_IDS:-}"
COOKIE_MAX_BYTES="${XVIDEO_COOKIE_MAX_BYTES:-2097152}"
STAGING_BASE_DIR="${XVIDEO_STAGING_BASE_DIR:-/var/lib/xvideo-to-telegram/staging}"

log() {
  printf '[%s:add-bot] %s\n' "$APP_NAME" "$*"
}

die() {
  printf '[%s:add-bot] ERROR: %s\n' "$APP_NAME" "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo \
      BOT_NAME="${BOT_NAME:-}" \
      XVIDEO_BOT_TOKEN="${XVIDEO_BOT_TOKEN:-}" \
      XVIDEO_ADMIN_CHAT_IDS="${XVIDEO_ADMIN_CHAT_IDS:-}" \
      XVIDEO_COOKIES_FILE="${XVIDEO_COOKIES_FILE:-}" \
      XVIDEO_COOKIE_MAX_BYTES="${XVIDEO_COOKIE_MAX_BYTES:-}" \
      XVIDEO_STAGING_BASE_DIR="${XVIDEO_STAGING_BASE_DIR:-}" \
      XVIDEO_STAGING_DIR="${XVIDEO_STAGING_DIR:-}" \
      FFMPEG_BIN="${FFMPEG_BIN:-}" \
      OVERWRITE="${OVERWRITE:-}" \
      CALL_TELEGRAM_LOGOUT="${CALL_TELEGRAM_LOGOUT:-}" \
      bash "$0" "$@"
  fi
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

prompt_value() {
  local var_name="$1"
  local label="$2"
  local secret="${3:-0}"
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
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

validate_bot_name() {
  BOT_NAME="$(trim_value "${BOT_NAME}")"
  if [[ ! "${BOT_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; then
    die "BOT_NAME must be 1-32 chars: letters, numbers, underscore, or dash; must start with a letter/number."
  fi
}

validate_bot_token() {
  XVIDEO_BOT_TOKEN="$(trim_value "${XVIDEO_BOT_TOKEN}")"
  if [[ ! "${XVIDEO_BOT_TOKEN}" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
    die "XVIDEO_BOT_TOKEN does not look like a BotFather token."
  fi
}

escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

load_common_env() {
  local input_bot_token="${XVIDEO_BOT_TOKEN:-}"
  local input_admin_chat_ids="${XVIDEO_ADMIN_CHAT_IDS:-}"
  local input_cookies_file="${XVIDEO_COOKIES_FILE:-}"
  local input_cookie_max_bytes="${XVIDEO_COOKIE_MAX_BYTES:-}"
  local input_staging_base_dir="${XVIDEO_STAGING_BASE_DIR:-}"
  local input_staging_dir="${XVIDEO_STAGING_DIR:-}"
  BOT_API_BASE_URL="${BOT_API_BASE_URL:-http://127.0.0.1:8081}"
  YT_DLP_BIN="${YT_DLP_BIN:-${APP_DIR}/venv/bin/yt-dlp}"
  FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"
  FFPROBE_BIN="${FFPROBE_BIN:-/usr/bin/ffprobe}"
  CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
  XVIDEO_UPLOAD_TIMEOUT="${XVIDEO_UPLOAD_TIMEOUT:-1800}"
  XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP="${XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP:-12}"
  XVIDEO_TELEGRAM_UPLOAD_EST_MBPS="${XVIDEO_TELEGRAM_UPLOAD_EST_MBPS:-0.35}"
  XVIDEO_ADMIN_CHAT_IDS="${XVIDEO_ADMIN_CHAT_IDS:-${ADMIN_CHAT_IDS}}"
  XVIDEO_COOKIES_FILE="${XVIDEO_COOKIES_FILE:-${COOKIES_FILE}}"
  XVIDEO_COOKIE_MAX_BYTES="${XVIDEO_COOKIE_MAX_BYTES:-${COOKIE_MAX_BYTES}}"
  XVIDEO_STAGING_BASE_DIR="${XVIDEO_STAGING_BASE_DIR:-${STAGING_BASE_DIR}}"

  if [[ -f "${BASE_ENV_FILE}" ]]; then
    # Read common values from the original deployment, but intentionally do not
    # reuse its XVIDEO_BOT_TOKEN.
    # shellcheck disable=SC1090
    set -a
    source "${BASE_ENV_FILE}"
    set +a
    BOT_API_BASE_URL="${BOT_API_BASE_URL:-http://127.0.0.1:8081}"
    YT_DLP_BIN="${YT_DLP_BIN:-${APP_DIR}/venv/bin/yt-dlp}"
    FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"
    FFPROBE_BIN="${FFPROBE_BIN:-/usr/bin/ffprobe}"
    CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
    XVIDEO_UPLOAD_TIMEOUT="${XVIDEO_UPLOAD_TIMEOUT:-1800}"
    XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP="${XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP:-12}"
    XVIDEO_TELEGRAM_UPLOAD_EST_MBPS="${XVIDEO_TELEGRAM_UPLOAD_EST_MBPS:-0.35}"
    XVIDEO_ADMIN_CHAT_IDS="${XVIDEO_ADMIN_CHAT_IDS:-${ADMIN_CHAT_IDS}}"
    XVIDEO_COOKIES_FILE="${XVIDEO_COOKIES_FILE:-${COOKIES_FILE}}"
    XVIDEO_COOKIE_MAX_BYTES="${XVIDEO_COOKIE_MAX_BYTES:-${COOKIE_MAX_BYTES}}"
    XVIDEO_STAGING_BASE_DIR="${XVIDEO_STAGING_BASE_DIR:-${STAGING_BASE_DIR}}"
  fi
  XVIDEO_BOT_TOKEN="${input_bot_token}"
  if [[ -n "${input_admin_chat_ids}" ]]; then
    XVIDEO_ADMIN_CHAT_IDS="${input_admin_chat_ids}"
  fi
  if [[ -n "${input_cookies_file}" ]]; then
    XVIDEO_COOKIES_FILE="${input_cookies_file}"
  fi
  if [[ -n "${input_cookie_max_bytes}" ]]; then
    XVIDEO_COOKIE_MAX_BYTES="${input_cookie_max_bytes}"
  fi
  if [[ -n "${input_staging_base_dir}" ]]; then
    XVIDEO_STAGING_BASE_DIR="${input_staging_base_dir}"
  fi
  if [[ -n "${input_staging_dir}" ]]; then
    XVIDEO_STAGING_DIR="${input_staging_dir}"
  fi
}

install_or_update_app_code() {
  [[ -d "${APP_SRC_DIR}" ]] || die "${APP_SRC_DIR} missing. Run deploy_ec2.sh first."
  if [[ -f "${BOT_SOURCE}" ]]; then
    install -m 755 -o "${APP_USER}" -g "${APP_USER}" "${BOT_SOURCE}" "${APP_SRC_DIR}/xvideo_to_telegram_bot.py"
  fi
  if ! grep -q "XVIDEO_STAGING_DIR" "${APP_SRC_DIR}/xvideo_to_telegram_bot.py"; then
    die "Deployed bot code does not support per-bot staging/log env vars. Upload the latest xvideo_to_telegram_bot.py next to this script and rerun."
  fi
  if ! grep -q "XVIDEO_COOKIES_FILE" "${APP_SRC_DIR}/xvideo_to_telegram_bot.py"; then
    die "Deployed bot code does not support Telegram cookie upload. Upload the latest xvideo_to_telegram_bot.py next to this script and rerun."
  fi
  [[ -x "${APP_DIR}/venv/bin/python" ]] || die "${APP_DIR}/venv missing. Run deploy_ec2.sh first."
  "${APP_DIR}/venv/bin/python" -m py_compile "${APP_SRC_DIR}/xvideo_to_telegram_bot.py"
}

smoke_test_token() {
  local response_file http_code body
  response_file="$(mktemp)"
  http_code="$(curl -sS --max-time 20 -o "${response_file}" -w '%{http_code}' \
    "https://api.telegram.org/bot${XVIDEO_BOT_TOKEN}/getMe" || true)"
  if [[ "${http_code}" != "200" ]]; then
    body="$(head -c 500 "${response_file}" | tr '\n' ' ')"
    rm -f "${response_file}"
    die "Official Telegram /getMe returned HTTP ${http_code}. Response: ${body:-<empty>}"
  fi
  python3 - "${response_file}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
if not d.get("ok"):
    raise SystemExit(f"getMe returned ok=false: {d}")
print("Bot:", d.get("result", {}).get("username", "unknown"))
PY
  rm -f "${response_file}"
}

maybe_logout_cloud_api() {
  if [[ "${CALL_TELEGRAM_LOGOUT:-0}" != "1" ]]; then
    return
  fi
  log "Calling official /logOut for this bot token"
  curl -fsS --max-time 20 "https://api.telegram.org/bot${XVIDEO_BOT_TOKEN}/logOut" >/dev/null || true
}

write_template_service() {
  cat > "/etc/systemd/system/${TEMPLATE_SERVICE}" <<EOF
[Unit]
Description=X/Twitter video downloader Telegram bot instance %i
Requires=${BOT_API_SERVICE}
After=${BOT_API_SERVICE} network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_SRC_DIR}
EnvironmentFile=${ENV_DIR}/%i.env
Environment=PYTHONUNBUFFERED=1
ExecStart=${APP_DIR}/venv/bin/python ${APP_SRC_DIR}/xvideo_to_telegram_bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

confirm_overwrite_if_needed() {
  local env_file="${ENV_DIR}/${BOT_NAME}.env"
  if [[ ! -e "${env_file}" || "${OVERWRITE:-0}" == "1" ]]; then
    return
  fi
  if [[ ! -t 0 ]]; then
    die "${env_file} already exists. Set OVERWRITE=1 to replace it."
  fi
  local answer=""
  read -r -p "${env_file} already exists. Overwrite it? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) die "Aborted." ;;
  esac
}

write_instance_env() {
  local env_file="${ENV_DIR}/${BOT_NAME}.env"
  local staging_dir="${XVIDEO_STAGING_DIR:-${XVIDEO_STAGING_BASE_DIR}/${BOT_NAME}}"
  local log_dir="/var/log/xvideo-to-telegram"
  local log_file="${log_dir}/${BOT_NAME}.log"

  install -d -m 755 -o root -g root "${ENV_DIR}"
  install -d -m 755 -o "${APP_USER}" -g "${APP_USER}" "${staging_dir}"
  install -d -m 755 -o "${APP_USER}" -g "${APP_USER}" "${log_dir}"
  install -d -m 700 -o "${APP_USER}" -g "${APP_USER}" "$(dirname "${XVIDEO_COOKIES_FILE}")"
  touch "${log_file}"
  chown "${APP_USER}:${APP_USER}" "${log_file}"
  chmod 640 "${log_file}"

  install -m 600 -o root -g root /dev/null "${env_file}"
  {
    printf 'XVIDEO_BOT_TOKEN=%s\n' "$(escape_env_value "${XVIDEO_BOT_TOKEN}")"
    printf 'BOT_API_BASE_URL=%s\n' "$(escape_env_value "${BOT_API_BASE_URL}")"
    printf 'YT_DLP_BIN=%s\n' "$(escape_env_value "${YT_DLP_BIN}")"
    printf 'FFMPEG_BIN=%s\n' "$(escape_env_value "${FFMPEG_BIN}")"
    printf 'FFPROBE_BIN=%s\n' "$(escape_env_value "${FFPROBE_BIN}")"
    printf 'CURL_BIN=%s\n' "$(escape_env_value "${CURL_BIN}")"
    printf 'XVIDEO_UPLOAD_TIMEOUT=%s\n' "$(escape_env_value "${XVIDEO_UPLOAD_TIMEOUT}")"
    printf 'XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP=%s\n' "$(escape_env_value "${XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP}")"
    printf 'XVIDEO_TELEGRAM_UPLOAD_EST_MBPS=%s\n' "$(escape_env_value "${XVIDEO_TELEGRAM_UPLOAD_EST_MBPS}")"
    printf 'XVIDEO_STAGING_DIR=%s\n' "$(escape_env_value "${staging_dir}")"
    printf 'XVIDEO_LOG_FILE=%s\n' "$(escape_env_value "${log_file}")"
    printf 'XVIDEO_COOKIES_FILE=%s\n' "$(escape_env_value "${XVIDEO_COOKIES_FILE}")"
    printf 'XVIDEO_ADMIN_CHAT_IDS=%s\n' "$(escape_env_value "${XVIDEO_ADMIN_CHAT_IDS}")"
    printf 'XVIDEO_COOKIE_MAX_BYTES=%s\n' "$(escape_env_value "${XVIDEO_COOKIE_MAX_BYTES}")"
  } > "${env_file}"
}

start_instance() {
  systemctl is-active --quiet "${BOT_API_SERVICE}" || systemctl restart "${BOT_API_SERVICE}"
  sleep 2
  curl -fsS --max-time 20 "${BOT_API_BASE_URL}/bot${XVIDEO_BOT_TOKEN}/getMe" >/dev/null

  systemctl enable --now "xvideo-to-telegram@${BOT_NAME}.service"
  sleep 2
  systemctl --no-pager --full status "xvideo-to-telegram@${BOT_NAME}.service" || true
  log "Logs: journalctl -u xvideo-to-telegram@${BOT_NAME}.service -f"
}

main() {
  require_root "$@"
  BOT_NAME="${BOT_NAME:-${1:-}}"
  prompt_value BOT_NAME "New bot instance name, e.g. bot2" 0
  validate_bot_name

  load_common_env
  prompt_value XVIDEO_BOT_TOKEN "New Telegram bot token from BotFather" 1
  validate_bot_token

  confirm_overwrite_if_needed
  install_or_update_app_code
  smoke_test_token
  maybe_logout_cloud_api
  write_template_service
  write_instance_env
  start_instance

  log "Done. Instance: xvideo-to-telegram@${BOT_NAME}.service"
  log "Env: ${ENV_DIR}/${BOT_NAME}.env"
}

main "$@"
