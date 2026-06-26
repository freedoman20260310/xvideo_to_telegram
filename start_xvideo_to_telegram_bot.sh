#!/bin/bash
# Start/restart the xvideo_to_telegram_bot via launchd.
# Usage: ./start_xvideo_to_telegram_bot.sh

set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/ai.xvideo-to-telegram.bot.plist"
LABEL="ai.xvideo-to-telegram.bot"
SCRIPT="$HOME/.hermes/scripts/xvideo_to_telegram_bot.py"
LOG="$HOME/.hermes/scripts/xvideo_to_telegram_bot.log"

cd "$(dirname "$0")"

# Verify prerequisites
[ -f "$SCRIPT" ] || { echo "❌ missing $SCRIPT"; exit 1; }
[ -f "$PLIST" ] || { echo "❌ missing $PLIST"; exit 1; }

# 1. Smoke-test the token before touching launchd
TOKEN=$(grep '^XVIDEO_BOT_TOKEN=' ~/.hermes/scripts/.xvideo_to_telegram_bot.env | cut -d= -f2-)
if [ -z "$TOKEN" ]; then
    echo "❌ XVIDEO_BOT_TOKEN is empty in ~/.hermes/scripts/.xvideo_to_telegram_bot.env"
    exit 1
fi
echo "🔎 Smoke-testing token via /getMe ..."
GETME=$(curl -sS "https://api.telegram.org/bot${TOKEN}/getMe")
OK=$(printf '%s' "$GETME" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('ok') else 'bad')")
USERNAME=$(printf '%s' "$GETME" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('username',''))")
if [ "$OK" != "ok" ]; then
    echo "❌ getMe failed: $GETME"
    exit 1
fi
echo "✅ Token valid for @$USERNAME"

# 2. Verify plist parses
plutil -lint "$PLIST" >/dev/null || { echo "❌ plist invalid"; exit 1; }

# 3. Atomic restart via launchctl kickstart (sends SIGTERM, waits, respawns)
if launchctl list | grep -q "$LABEL"; then
    echo "🔄 Bot already loaded — kickstart to restart cleanly"
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
    echo "🚀 Loading bot via launchctl load"
    launchctl load "$PLIST"
fi

sleep 2

# 4. Verify it's running and healthy
PID=$(pgrep -fl xvideo_to_telegram_bot.py | head -1 | awk '{print $1}')
if [ -z "$PID" ]; then
    echo "❌ process not running — check $LOG and ~/Library/Logs/xvideo-bot.err.log"
    exit 1
fi
echo "✅ Bot running (pid $PID)"
echo "📜 Recent log lines:"
tail -5 "$LOG" 2>/dev/null || echo "  (no log entries yet — give it a few seconds)"