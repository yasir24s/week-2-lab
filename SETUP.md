# Running the Claude port on your MacBook + Meta Ray-Bans

## What's in this bundle

```
samples/CameraAccess/CameraAccess/
├── Claude/
│   ├── ClaudeConfig.swift             API key, model, system prompt
│   ├── ClaudeService.swift            HTTP + SSE client for Anthropic Messages API
│   ├── ClaudeSessionViewModel.swift   Drop-in for GeminiSessionViewModel
│   ├── ClaudeToolModels.swift         tool_use / tool_result types + adapter
│   ├── SpeechManager.swift            SFSpeechRecognizer + AVSpeechSynthesizer
│   └── SettingsManager+Claude.swift   Adds anthropicAPIKey, claudeModel, etc.
└── Secrets.swift.example              Anthropic key template

setup.sh                               One-command installer
```

## Prerequisites (one-time)

- **macOS** with **Xcode 15 or later**
- An iPhone running **iOS 17+**
- **Meta Ray-Bans** paired in the Meta AI app with **Developer Mode** enabled
- The **Meta Wearables DAT SDK** (follow VisionClaw's README for the access link)
- An **Anthropic API key** from <https://console.anthropic.com/settings/keys>

## Fast path (recommended)

```bash
cd /path/to/this/bundle
./setup.sh
```

The script asks you where to put VisionClaw (default `~/code/VisionClaw`), clones it, drops in the Claude module, rewires the views, writes your API key into `Secrets.swift`, adds the speech-recognition Info.plist key, and opens Xcode.

When Xcode opens, do the **one click** it can't do for you:

> Right-click the `CameraAccess` group in the project navigator → **Add Files to "CameraAccess"…** → select the `Claude` folder → check the **CameraAccess** target → Add.

Then plug in your iPhone and hit Cmd-R.

## What the script changes in VisionClaw

| File | Change |
|---|---|
| `samples/CameraAccess/CameraAccess/Claude/*.swift` | New (6 files) |
| `ViewModels/StreamSessionViewModel.swift` | `GeminiSessionViewModel` → `ClaudeSessionViewModel`; `geminiSessionVM` → `claudeSessionVM` |
| `Views/StreamSessionView.swift` | Same renames; `isGeminiActive` → `isClaudeActive` |
| `Views/StreamView.swift` | Same renames |
| `Views/Components/GeminiOverlayView.swift` | `GeminiStatusBar` → `ClaudeStatusBar` and friends |
| `Info.plist` | Adds `NSSpeechRecognitionUsageDescription` |
| `Secrets.swift` | Created from template + your API key |

The script tags the pre-port state as `pre-claude-port` inside the VisionClaw git repo, so you can revert with:

```bash
cd ~/code/VisionClaw
git reset --hard pre-claude-port
rm -rf samples/CameraAccess/CameraAccess/Claude
```

## Manual fallback

If you'd rather do it by hand:

1. `git clone https://github.com/Intent-Lab/VisionClaw.git ~/code/VisionClaw`
2. Copy `samples/CameraAccess/CameraAccess/Claude/` from this bundle into `~/code/VisionClaw/samples/CameraAccess/CameraAccess/`
3. Copy `Secrets.swift.example` to `~/code/VisionClaw/samples/CameraAccess/CameraAccess/Secrets.swift`, paste your Anthropic key into `anthropicAPIKey`
4. In `~/code/VisionClaw/samples/CameraAccess/CameraAccess/`, run:
   ```bash
   sed -i '' \
     -e 's/\bGeminiSessionViewModel\b/ClaudeSessionViewModel/g' \
     -e 's/\bgeminiSessionVM\b/claudeSessionVM/g' \
     -e 's/\bgeminiVM\b/claudeVM/g' \
     -e 's/\bisGeminiActive\b/isClaudeActive/g' \
     -e 's/\bGeminiStatusBar\b/ClaudeStatusBar/g' \
     -e 's/\bgeminiStatusColor\b/claudeStatusColor/g' \
     -e 's/\bgeminiStatusText\b/claudeStatusText/g' \
     ViewModels/StreamSessionViewModel.swift \
     Views/StreamSessionView.swift \
     Views/StreamView.swift \
     Views/Components/GeminiOverlayView.swift
   ```
5. Add to `Info.plist`:
   ```xml
   <key>NSSpeechRecognitionUsageDescription</key>
   <string>Used to transcribe what you say so Claude can respond.</string>
   ```
6. Open `CameraAccess.xcodeproj` in Xcode, drag the `Claude` folder into the project navigator under `CameraAccess`, check the target.
7. Cmd-R with your iPhone connected.

## On-glasses run

1. Power on the Ray-Bans, confirm they're paired in the Meta AI app.
2. Launch the CameraAccess app on the iPhone.
3. Tap **Stream** — WebRTC pulls the glasses' camera feed.
4. Tap **Start AI Session** — grant Mic + Speech Recognition permissions.
5. Speak naturally. Each utterance is transcribed on-device, sent to Claude with the latest glasses frame, and the reply is streamed back through TTS.

## Knobs

In Xcode you can edit:

- `Claude/ClaudeConfig.swift` — `defaultModel` (`claude-haiku-4-5-20251001`, or swap for `claude-sonnet-4-6` if you want higher quality at higher latency)
- `Claude/ClaudeConfig.swift` — `videoFrameInterval` (default 1.0 s; lower = more vision context per turn but more tokens)
- `Claude/ClaudeConfig.swift` — `endOfUtteranceSilence` (default 0.8 s of silence to finalise a turn)
- The system prompt: edit `defaultSystemInstruction` in the same file
