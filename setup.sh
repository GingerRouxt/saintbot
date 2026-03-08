#!/usr/bin/env bash
# SaintBot Setup — Link signal-cli to your Signal account
# Run this ONCE to connect signal-cli as a linked device.

set -euo pipefail

SIGNAL_CLI="${SIGNAL_CLI:-$HOME/bin/signal-cli}"

echo "=== SaintBot Setup ==="
echo ""
echo "This links signal-cli to your existing Signal account"
echo "as a secondary device (like Signal Desktop)."
echo ""
echo "Steps:"
echo "  1. A QR code will appear in your terminal"
echo "  2. Open Signal on your phone"
echo "  3. Settings > Linked Devices > Link New Device"
echo "  4. Scan the QR code from your terminal"
echo ""
read -p "Ready? (y/n) " -n 1 -r
echo ""

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "Generating link request..."
echo ""

# signal-cli link outputs the URI on stdout then blocks waiting for confirmation.
# We run it in background, read the URI from a temp file, render QR, then wait.

URIFILE=$(mktemp)

# Start link process — redirect stdout to file, but keep it running
"$SIGNAL_CLI" link -n "SaintBot" > "$URIFILE" 2>/dev/null &
LINK_PID=$!

# Wait for the URI to appear in the file (up to 30 seconds)
for i in $(seq 1 30); do
  if [[ -s "$URIFILE" ]]; then
    break
  fi
  sleep 1
done

# Strip whitespace/newlines from the URI
URI=$(head -1 "$URIFILE" | tr -d '\n\r ')
rm -f "$URIFILE"

if [[ -z "$URI" ]]; then
  echo "ERROR: Timed out waiting for link URI from signal-cli."
  kill $LINK_PID 2>/dev/null || true
  exit 1
fi

echo "Scan this QR code with Signal on your phone:"
echo ""
printf '%s' "$URI" | qrencode -l H -t ANSIUTF8
echo ""
echo "URI: $URI"
echo ""
echo "Waiting for you to scan... (Ctrl+C to cancel)"

# Wait for signal-cli link to finish (it exits when phone confirms)
wait $LINK_PID 2>/dev/null
STATUS=$?

echo ""
if [[ $STATUS -eq 0 ]]; then
  echo "Linked successfully!"
  echo ""
  echo "Now run:"
  echo "  signal-cli -a YOUR_NUMBER receive"
  echo "to find your account number, then fill in saintbot.conf:"
  echo "  cp saintbot.conf.example saintbot.conf"
else
  echo "Linking may have failed (exit code $STATUS)."
  echo "Try running again."
fi
