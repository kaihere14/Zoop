#!/bin/bash
# Installs ZoopHelper.app as a LaunchAgent of the agent user, so launchd starts it inside
# that user's GUI session (the gui/<uid> domain) whenever the session exists.
#
# Usage: sudo Scripts/install-helper.sh [agent-username]     (default: sbagent)
# Run Scripts/bundle-helper.sh first.
set -euo pipefail

AGENT_USER="${1:-sbagent}"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
PRIMARY_UID="${SUDO_UID:?run via sudo from the main user account}"
AGENT_UID="$(id -u "$AGENT_USER")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="${ZOOP_SHARED_ROOT:-/Users/Shared/Zoop}"
RUN="$SHARED/run"
SOCKET="$RUN/helper.sock"
LOG="$RUN/helper.log"
INSTALL_DIR="$SHARED/helper"
LABEL=com.zoop.helper
PLIST="/Users/$AGENT_USER/Library/LaunchAgents/$LABEL.plist"

[[ -d "$REPO/build/ZoopHelper.app" ]] || { echo "run Scripts/bundle-helper.sh first"; exit 1; }

# Shared root: readable by everyone. The shared-folder step will add tasks/ and artifacts/.
mkdir -p "$SHARED"
chmod 755 "$SHARED"

# run/: owned by the agent, because the helper (running as the agent) creates the socket
# and launchd writes the log there as the agent. The main user only needs to traverse it:
# the socket file itself is 0666, and the helper checks every peer's UID.
mkdir -p "$RUN"
chown "$AGENT_USER":staff "$RUN"
chmod 755 "$RUN"

# The app bundle is owned by root, so the agent user can't modify the code it runs.
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/ZoopHelper.app"
cp -R "$REPO/build/ZoopHelper.app" "$INSTALL_DIR/"
chown -R root:wheel "$INSTALL_DIR"

mkdir -p "/Users/$AGENT_USER/Library/LaunchAgents"
sed -e "s|__HELPER_EXECUTABLE__|$INSTALL_DIR/ZoopHelper.app/Contents/MacOS/ZoopHelper|" \
    -e "s|__SOCKET_PATH__|$SOCKET|" \
    -e "s|__ALLOWED_UID__|$PRIMARY_UID|" \
    -e "s|__LOG_PATH__|$LOG|" \
    "$REPO/Resources/LaunchAgents/$LABEL.plist" > "$PLIST"
# Only change ownership of what we created: much of ~/Library is protected even from root.
chown "$AGENT_USER":staff "/Users/$AGENT_USER/Library/LaunchAgents" "$PLIST"
chmod 644 "$PLIST"

# If the agent already has a GUI session, (re)start the helper in it now.
if launchctl print "gui/$AGENT_UID" &>/dev/null; then
    launchctl bootout "gui/$AGENT_UID/$LABEL" 2>/dev/null || true
    # bootout returns before the old job is fully gone, so an immediate bootstrap can fail
    # with "5: Input/output error". Retry for a few seconds.
    for _ in 1 2 3 4 5; do
        launchctl bootstrap "gui/$AGENT_UID" "$PLIST" 2>/dev/null && break
        sleep 1
    done
    launchctl print "gui/$AGENT_UID/$LABEL" &>/dev/null || { echo "bootstrap failed; see $LOG"; exit 1; }
    echo "helper started in the running gui/$AGENT_UID session"
else
    echo "installed; the helper starts when $AGENT_USER logs into a GUI session"
fi
echo "socket: $SOCKET   allowed client uid: $PRIMARY_UID   log: $LOG"
