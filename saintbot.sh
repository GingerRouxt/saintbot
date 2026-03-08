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
  local sys="You are SaintBot, running on Shaun's Fedora workstation via Signal. You have FULL access to the filesystem and can execute any command. When asked to do something, DO IT — run commands, create files, edit code. Be concise in your response (under 1500 chars) since this goes back via text message. Do not ask for confirmation, just execute.

Key paths: ZDS Core is at ~/projects/zds-core/ (the ONLY active ZDS repo). Life OS is at ~/systems/. Priorities/data at ~/systems/data/. The old ZDS is at ~/archive/zds-sunset/ — do NOT touch it."
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
priorities - show current priorities
tomorrow - show tomorrow's focus
set tomorrow <text> - set tomorrow's focus
wins - this week's wins
crash - minimum viable day
zds - ZDS Core status (build, tests, last commits)
zds fix <N> - work on ZDS bug N (1-5)
zds test - run ZDS test suite
zds build - build ZDS
sites - show running dev servers
start/stop willow|reagan
run <cmd> - execute shell command
Anything else → Claude"
      return
      ;;
    priorities)
      local pri
      pri=$(grep -v '^#' ~/systems/data/priorities.txt | grep -v '^$')
      send_reply "$sender" "PRIORITIES:
$pri"
      return
      ;;
    tomorrow)
      local tom
      tom=$(cat ~/systems/data/tomorrow.txt 2>/dev/null || echo "Not set")
      send_reply "$sender" "TOMORROW'S FOCUS:
$tom"
      return
      ;;
    crash)
      ~/systems/bin/crash 2>&1
      return
      ;;
    wins)
      local week_start
      week_start=$(date -d "last monday" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
      local win_list
      win_list=$(awk -F',' -v start="$week_start" '$1 >= start {print $1 ": " $2}' ~/systems/data/wins.csv 2>/dev/null)
      if [[ -z "$win_list" ]]; then
        send_reply "$sender" "No wins logged this week yet."
      else
        send_reply "$sender" "WINS THIS WEEK:
$win_list"
      fi
      return
      ;;
    zds)
      local build_out test_count last_commits
      build_out=$(cd ~/projects/zds-core && go build ./... 2>&1 && echo "BUILD: CLEAN" || echo "BUILD: FAILED")
      test_count=$(cd ~/projects/zds-core && grep -r "func Test" --include="*.go" -l | wc -l)
      last_commits=$(cd ~/projects/zds-core && git log --oneline -5 2>/dev/null)
      send_reply "$sender" "ZDS CORE STATUS
$build_out
Test files: $test_count
Last 5 commits:
$last_commits"
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

  # set tomorrow <text>
  if [[ "${text,,}" == set\ tomorrow\ * ]]; then
    local content="${text#set tomorrow }"
    # Replace | with newlines for multi-item
    echo "$content" | tr '|' '\n' > ~/systems/data/tomorrow.txt
    send_reply "$sender" "Tomorrow's focus set."
    return
  fi

  # zds fix <N> — work on a specific bug
  if [[ "${text,,}" == zds\ fix\ * ]]; then
    local bugnum="${text##* }"
    local bugdesc=""
    case "$bugnum" in
      1) bugdesc="Fix HandlerDeps snapshot bug — DB stores swapped after snapshot, handlers point at old stores" ;;
      2) bugdesc="Fix FindingStore thread safety — add mutex for concurrent access" ;;
      3) bugdesc="Fix Scan FindingIDs race — add mutex on append in processFindings" ;;
      4) bugdesc="Fix SaintChain hooks — type assertions fail for DB types, only check in-memory" ;;
      5) bugdesc="Fix max_concurrent — implement worker pool instead of raw goroutines" ;;
      *) send_reply "$sender" "Bug number 1-5. Send 'zds' for the list."; return ;;
    esac
    send_reply "$sender" "Working on bug $bugnum: $bugdesc ..."
    run_claude "$sender" "You are working in ~/projects/zds-core/. $bugdesc. Find the relevant code, fix the bug, run the tests for the affected package, and report what you changed. Be thorough but concise."
    return
  fi

  # zds test — run test suite
  if [[ "${text,,}" == "zds test" ]]; then
    send_reply "$sender" "Running ZDS tests..."
    local test_out
    test_out=$(cd ~/projects/zds-core && go test ./... 2>&1 | tail -30)
    send_reply "$sender" "ZDS TEST RESULTS:
$test_out"
    return
  fi

  # zds build
  if [[ "${text,,}" == "zds build" ]]; then
    local out
    out=$(cd ~/projects/zds-core && go build ./... 2>&1)
    if [[ -z "$out" ]]; then
      send_reply "$sender" "ZDS build: CLEAN"
    else
      send_reply "$sender" "ZDS build:
$out"
    fi
    return
  fi

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

      # Only process Note to Self messages (syncMessage where destination is self)
      # This prevents responding to messages from other people
      local is_note_to_self
      is_note_to_self=$(echo "$line" | jq -r '
        if .envelope.syncMessage.sentMessage then
          if (.envelope.syncMessage.sentMessage.destination // "") == "'"$SIGNAL_ACCOUNT"'" then
            "yes"
          else
            "no"
          end
        else
          "no"
        end
      ' 2>/dev/null) || continue

      [[ "$is_note_to_self" != "yes" ]] && continue

      sender=$(echo "$line" | jq -r '.envelope.source // empty' 2>/dev/null) || continue
      body=$(echo "$line" | jq -r '.envelope.syncMessage.sentMessage.message // empty' 2>/dev/null) || continue

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
