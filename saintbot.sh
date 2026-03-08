#!/usr/bin/env bash
# SaintBot — Signal-to-Claude command relay
# Polls Signal for new messages, pipes them to Claude, sends response back.

set -uo pipefail

# Allow Claude to run even if launched from within a Claude session
unset CLAUDECODE 2>/dev/null || true
export -n CLAUDECODE 2>/dev/null || true
# Nuke it from the environment entirely so subshells don't inherit it
env -u CLAUDECODE >/dev/null 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/saintbot.conf"
LOG="$SCRIPT_DIR/saintbot.log"
SIGNAL_CLI="${SIGNAL_CLI:-$HOME/bin/signal-cli}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# ── Load config ──
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG not found. Copy saintbot.conf.example and fill in your number." >&2
  exit 1
fi
source "$CONFIG"

if [[ -z "${SIGNAL_ACCOUNT:-}" ]]; then
  echo "ERROR: SIGNAL_ACCOUNT not set in $CONFIG" >&2
  exit 1
fi

if [[ -z "${ALLOWED_NUMBERS:-}" ]]; then
  echo "ERROR: ALLOWED_NUMBERS not set in $CONFIG" >&2
  exit 1
fi

# ── Helpers ──
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

is_allowed() {
  local sender="$1"
  for num in "${ALLOWED_NUMBERS[@]}"; do
    if [[ "$sender" == "$num" ]]; then
      return 0
    fi
  done
  return 1
}

run_claude() {
  local sender="$1"
  local prompt="$2"
  local tmpfile
  tmpfile=$(mktemp /tmp/saintbot-claude-XXXXXX)

  # Run Claude with full permissions, write output to file (no pipe = no SIGPIPE)
  # Timeout after 120 seconds so it doesn't hang forever
  local sys="You are SaintBot, running on Shaun's Fedora workstation via Signal. You have FULL access to the filesystem and can execute any command. When asked to do something, DO IT — run commands, create files, edit code. Be concise in your response (under 1500 chars) since this goes back via text message. Do not ask for confirmation, just execute."
  timeout 120 env -u CLAUDECODE claude -p \
    --dangerously-skip-permissions \
    --permission-mode bypassPermissions \
    --system-prompt "$sys" \
    "$prompt" > "$tmpfile" 2>&1 || true

  local output
  output=$(head -c 3800 "$tmpfile")
  rm -f "$tmpfile"

  if [[ -z "$output" ]]; then
    output="(no response)"
  fi
  send_reply "$sender" "$output"
}

send_reply() {
  local recipient="$1"
  local message="$2"
  # Signal has a ~2000 char limit per message, chunk if needed
  if [[ ${#message} -gt 1900 ]]; then
    while [[ -n "$message" ]]; do
      local chunk="${message:0:1900}"
      "$SIGNAL_CLI" -a "$SIGNAL_ACCOUNT" send -m "$chunk" "$recipient" 2>>"$LOG" || true
      message="${message:1900}"
      [[ -n "$message" ]] && sleep 1
    done
  else
    "$SIGNAL_CLI" -a "$SIGNAL_ACCOUNT" send -m "$message" "$recipient" 2>>"$LOG" || true
  fi
}

# ── Command Processing ──
process_command() {
  local sender="$1"
  local text="$2"

  log "FROM $sender: $text"

  # Built-in commands (no Claude needed)
  case "${text,,}" in
    ping)
      send_reply "$sender" "pong"
      return
      ;;
    status)
      local uptime_str
      uptime_str=$(uptime -p)
      local load
      load=$(cat /proc/loadavg | cut -d' ' -f1-3)
      local mem
      mem=$(free -h | awk '/^Mem:/{print $3 "/" $2}')
      local disk
      disk=$(df -h / | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')
      send_reply "$sender" "UP: $uptime_str
LOAD: $load
MEM: $mem
DISK: $disk"
      return
      ;;
    help)
      send_reply "$sender" "SaintBot Commands:
ping - check if alive
status - system stats
sites - show running dev servers
start willow - start willow's site
start reagan - start reagan's site
stop willow - stop willow's site
stop reagan - stop reagan's site
run <cmd> - execute shell command
claude <prompt> - ask Claude
help - this message"
      return
      ;;
    sites)
      local result=""
      if pgrep -f "willow_site/serve.mjs" >/dev/null 2>&1; then
        result+="Willow: UP (port 3000)\n"
      else
        result+="Willow: DOWN\n"
      fi
      if pgrep -f "reagan-site/serve.mjs" >/dev/null 2>&1; then
        result+="Reagan: UP (port 3001)\n"
      else
        result+="Reagan: DOWN\n"
      fi
      send_reply "$sender" "$(echo -e "$result")"
      return
      ;;
    "start willow")
      if pgrep -f "willow_site/serve.mjs" >/dev/null 2>&1; then
        send_reply "$sender" "Willow's site already running."
      else
        cd ~/projects/willow_site && nohup node serve.mjs >>"$LOG" 2>&1 &
        sleep 1
        send_reply "$sender" "Willow's site started on port 3000."
      fi
      return
      ;;
    "stop willow")
      pkill -f "willow_site/serve.mjs" 2>/dev/null && \
        send_reply "$sender" "Willow's site stopped." || \
        send_reply "$sender" "Willow's site wasn't running."
      return
      ;;
    "start reagan")
      if pgrep -f "reagan-site/serve.mjs" >/dev/null 2>&1; then
        send_reply "$sender" "Reagan's site already running."
      else
        cd ~/projects/reagan-site && nohup node serve.mjs >>"$LOG" 2>&1 &
        sleep 1
        send_reply "$sender" "Reagan's site started on port 3001."
      fi
      return
      ;;
    "stop reagan")
      pkill -f "reagan-site/serve.mjs" 2>/dev/null && \
        send_reply "$sender" "Reagan's site stopped." || \
        send_reply "$sender" "Reagan's site wasn't running."
      return
      ;;
  esac

  # run <cmd> — execute a shell command
  if [[ "${text,,}" == run\ * ]]; then
    local cmd="${text#run }"
    local output
    output=$(eval "$cmd" 2>&1 | head -c 3800) || true
    if [[ -z "$output" ]]; then
      output="(no output)"
    fi
    send_reply "$sender" "$output"
    return
  fi

  # claude <prompt> — ask Claude (non-interactive)
  if [[ "${text,,}" == claude\ * ]]; then
    local prompt="${text#claude }"
    send_reply "$sender" "Thinking..."
    run_claude "$sender" "$prompt"
    return
  fi

  # Default: treat as Claude prompt
  send_reply "$sender" "Thinking..."
  run_claude "$sender" "$text"
}

# ── Main Poll Loop ──
log "SaintBot starting (account: $SIGNAL_ACCOUNT)"

while true; do
  # Receive messages as JSON
  messages=$("$SIGNAL_CLI" -a "$SIGNAL_ACCOUNT" -o json receive --timeout 1 2>>"$LOG") || true

  if [[ -n "$messages" ]]; then
    # Each line is a JSON object
    echo "$messages" | while IFS= read -r line; do
      [[ -z "$line" ]] && continue

      # Extract sender and message body
      # Note to Self comes as syncMessage.sentMessage, regular messages as dataMessage
      sender=$(echo "$line" | jq -r '.envelope.source // empty' 2>/dev/null) || continue
      body=$(echo "$line" | jq -r '
        .envelope.dataMessage.message //
        .envelope.syncMessage.sentMessage.message //
        empty
      ' 2>/dev/null) || continue

      [[ -z "$sender" || -z "$body" ]] && continue

      if is_allowed "$sender"; then
        process_command "$sender" "$body"
      else
        log "BLOCKED message from $sender: $body"
      fi
    done
  fi

  sleep "$POLL_INTERVAL"
done
