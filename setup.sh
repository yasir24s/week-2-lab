#!/usr/bin/env bash
#
# VisionClaw -> Claude integration installer.
#
# Run this once on your Mac. It:
#   1. Clones (or updates) Intent-Lab/VisionClaw
#   2. Drops the Claude/ Swift module into the iOS project
#   3. Patches the view-models/views to use ClaudeSessionViewModel
#      instead of GeminiSessionViewModel
#   4. Copies Secrets.swift from the template and prompts for your
#      Anthropic API key
#   5. Opens the Xcode project so you can finish the one click that
#      requires Xcode (adding the Claude folder to the target)
#
# After the script: tap Run in Xcode with your iPhone plugged in.

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { printf "${BLUE}>>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}OK${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!!${RESET} %s\n" "$*"; }
die()  { printf "${RED}xx${RESET} %s\n" "$*"; exit 1; }

# ---------- Preflight ----------
[ "$(uname)" = "Darwin" ] || die "This installer requires macOS. The Meta Wearables DAT SDK and Xcode are macOS-only."

if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode command line tools not found. Install Xcode from the Mac App Store, then run: xcode-select --install"
fi

if ! command -v git >/dev/null 2>&1; then
  die "git not found. Install Xcode command line tools: xcode-select --install"
fi

# ---------- Locate sources ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SRC="$SCRIPT_DIR/samples/CameraAccess/CameraAccess/Claude"
SECRETS_SRC="$SCRIPT_DIR/samples/CameraAccess/CameraAccess/Secrets.swift.example"
[ -d "$CLAUDE_SRC" ] || die "Cannot find Claude/ at $CLAUDE_SRC -- run this script from inside the week-2-lab repo root."

# ---------- Choose VisionClaw checkout location ----------
DEFAULT_DEST="$HOME/code/VisionClaw"
read -r -p "Where should VisionClaw live? [$DEFAULT_DEST] " DEST
DEST="${DEST:-$DEFAULT_DEST}"

if [ -d "$DEST/.git" ]; then
  log "VisionClaw already at $DEST -- pulling latest"
  git -C "$DEST" fetch --quiet origin
  git -C "$DEST" pull --quiet --ff-only || warn "Could not fast-forward; continuing with current checkout"
else
  log "Cloning VisionClaw into $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --quiet https://github.com/Intent-Lab/VisionClaw.git "$DEST"
fi

PROJECT_DIR="$DEST/samples/CameraAccess/CameraAccess"
[ -d "$PROJECT_DIR" ] || die "Expected iOS project at $PROJECT_DIR but it doesn't exist."

# ---------- Snapshot for easy revert ----------
log "Creating a 'pre-claude-port' git tag inside VisionClaw so you can revert later"
git -C "$DEST" tag --force pre-claude-port >/dev/null

# ---------- Copy Claude module ----------
log "Copying Claude/ into the iOS project"
mkdir -p "$PROJECT_DIR/Claude"
cp "$CLAUDE_SRC"/*.swift "$PROJECT_DIR/Claude/"
ok "$(ls "$PROJECT_DIR/Claude/" | wc -l | tr -d ' ') Swift files in place"

# ---------- Patch consumer files ----------
log "Rewiring view-model references to ClaudeSessionViewModel"
patch_file() {
  local f="$1"
  [ -f "$f" ] || { warn "Skipping $f (not present)"; return; }
  # Each sed swap is bounded so it can't bleed into the original Gemini/ files,
  # which we explicitly do not touch.
  /usr/bin/sed -i '' \
    -e 's/\bGeminiSessionViewModel\b/ClaudeSessionViewModel/g' \
    -e 's/\bgeminiSessionVM\b/claudeSessionVM/g' \
    -e 's/\bgeminiVM\b/claudeVM/g' \
    -e 's/\bisGeminiActive\b/isClaudeActive/g' \
    -e 's/\bGeminiStatusBar\b/ClaudeStatusBar/g' \
    -e 's/\bgeminiStatusColor\b/claudeStatusColor/g' \
    -e 's/\bgeminiStatusText\b/claudeStatusText/g' \
    "$f"
}

patch_file "$PROJECT_DIR/ViewModels/StreamSessionViewModel.swift"
patch_file "$PROJECT_DIR/Views/StreamSessionView.swift"
patch_file "$PROJECT_DIR/Views/StreamView.swift"
patch_file "$PROJECT_DIR/Views/Components/GeminiOverlayView.swift"
ok "Patched 4 consumer files"

# ---------- Secrets.swift ----------
SECRETS_DST="$PROJECT_DIR/Secrets.swift"
if [ -f "$SECRETS_DST" ]; then
  log "Secrets.swift already exists -- checking for anthropicAPIKey field"
  if ! grep -q "anthropicAPIKey" "$SECRETS_DST"; then
    # Append the missing key under the enum block.
    /usr/bin/sed -i '' '/^enum Secrets {$/a\
\
  static let anthropicAPIKey = "YOUR_ANTHROPIC_API_KEY"
' "$SECRETS_DST"
    ok "Added anthropicAPIKey field to existing Secrets.swift"
  fi
else
  log "Copying Secrets.swift.example -> Secrets.swift"
  cp "$SECRETS_SRC" "$SECRETS_DST"
fi

# ---------- API key prompt ----------
echo
read -r -p "Paste your Anthropic API key (or press Enter to edit Secrets.swift later): " API_KEY
if [ -n "${API_KEY:-}" ]; then
  /usr/bin/sed -i '' "s|YOUR_ANTHROPIC_API_KEY|${API_KEY}|g" "$SECRETS_DST"
  ok "API key written to Secrets.swift (this file is in .gitignore)"
else
  warn "Edit $SECRETS_DST manually to set anthropicAPIKey"
fi

# ---------- Info.plist Speech Recognition key ----------
INFO_PLIST="$PROJECT_DIR/Info.plist"
if [ -f "$INFO_PLIST" ] && ! /usr/libexec/PlistBuddy -c "Print :NSSpeechRecognitionUsageDescription" "$INFO_PLIST" >/dev/null 2>&1; then
  log "Adding NSSpeechRecognitionUsageDescription to Info.plist"
  /usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string Used to transcribe what you say so Claude can respond." "$INFO_PLIST"
  ok "Speech permission string added"
fi

# ---------- Open Xcode ----------
echo
log "Opening Xcode so you can finish the one manual step"
open "$DEST/samples/CameraAccess/CameraAccess.xcodeproj"

cat <<'EOF'

------------------------------------------------------------
FINISH IN XCODE (90 seconds):

  1. In the project navigator (left sidebar), right-click the
     "CameraAccess" group -> "Add Files to CameraAccess..."
  2. Select the Claude folder that the script just created
     inside CameraAccess/. Make sure:
        - "Create groups" is selected
        - The CameraAccess target is checked
     Click Add.

  3. Plug your iPhone into the Mac. In Xcode's top bar,
     pick your iPhone as the run destination.

  4. First time only: in iPhone Settings -> Privacy & Security,
     toggle Developer Mode on, then trust the dev cert under
     Settings -> General -> VPN & Device Management.

  5. Cmd-R to build & install. Grant Mic + Speech Recognition
     when the app asks.

THEN, with the Meta Ray-Bans paired + Developer Mode on:
  - Tap "Stream" to start the WebRTC video pull from the glasses
  - Tap "Start AI Session" to begin the Claude voice loop
  - Speak naturally; Claude sees the glasses frame each turn
------------------------------------------------------------

To revert the integration:
  cd "$DEST"
  git reset --hard pre-claude-port
  rm -rf samples/CameraAccess/CameraAccess/Claude

EOF
