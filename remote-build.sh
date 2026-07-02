#!/bin/bash
# remote-build.sh — Build on the M1 Mini and rsync the .app back to this Mac.
#
# Usage: ./remote-build.sh [Debug|Release]
#
# Xcode integration: add an External Build System target whose "Build Tool"
# is this script, then create a scheme that builds that target.
#
# ── Project-specific config (update these per project) ────────────────────────
SCHEME="XOInventory"
REPO="https://github.com/camerongary/XOInventory.git"
PROJECT_DIR="~/Projects/XOInventory_v2"        # path on the Mini
DERIVED_DATA="~/build/XOInventory"             # build output on the Mini
# ──────────────────────────────────────────────────────────────────────────────

# ── Infrastructure (unlikely to change) ───────────────────────────────────────
MINI_HOST="192.168.12.20"
MINI_USER="cameron"
MINI="$MINI_USER@$MINI_HOST"
# ──────────────────────────────────────────────────────────────────────────────

CONFIGURATION="${1:-Debug}"
APP_NAME="$SCHEME.app"
REMOTE_APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
LOCAL_DEST="/Applications/$APP_NAME"

set -euo pipefail

log() { echo "▶ $*"; }

# ── 1. Ensure the repo exists on the Mini (clone or pull) ─────────────────────
log "Syncing source on Mini..."
ssh "$MINI" bash <<ENDSSH
  set -euo pipefail
  if [ -d "$PROJECT_DIR/.git" ]; then
    echo "  Pulling latest..."
    git -C "$PROJECT_DIR" pull --ff-only
  else
    echo "  Cloning repo..."
    mkdir -p "$(dirname "$PROJECT_DIR")"
    git clone "$REPO" "$PROJECT_DIR"
  fi
ENDSSH

# ── 2. Build on the Mini ───────────────────────────────────────────────────────
log "Building $SCHEME ($CONFIGURATION) on Mini..."
ssh "$MINI" bash <<ENDSSH
  set -euo pipefail
  cd "$PROJECT_DIR"
  xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | xcpretty || xcodebuild \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      -destination "platform=macOS" \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGNING_ALLOWED=NO \
      build
ENDSSH

# ── 3. Rsync .app back to this Mac ────────────────────────────────────────────
log "Fetching $APP_NAME from Mini → $LOCAL_DEST..."
rm -rf "$LOCAL_DEST"
rsync -az --progress "$MINI:$REMOTE_APP_PATH" /Applications/

log "Done. $APP_NAME is at $LOCAL_DEST"
