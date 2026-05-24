import Foundation

enum ClaudeConfig {
  static let baseURL = "https://api.anthropic.com/v1/messages"
  static let apiVersion = "2023-06-01"

  static let defaultModel = "claude-haiku-4-5-20251001"
  static let maxTokens = 1024

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  // SFSpeechRecognizer emits continuous partials; we treat this much silence
  // after the last non-empty partial as end-of-utterance.
  static let endOfUtteranceSilence: TimeInterval = 0.8

  // Image content blocks include cache_control on the most recent frame so a
  // multi-turn conversation about the same scene stays cheap.
  static let cacheControlOnImages = true

  static var systemInstruction: String { SettingsManager.shared.claudeSystemPrompt }
  static var apiKey: String { SettingsManager.shared.anthropicAPIKey }
  static var model: String { SettingsManager.shared.claudeModel }

  // OpenClaw passthrough is unchanged from the Gemini config.
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }

  static let defaultSystemInstruction = """
    You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural -- aim for one or two short sentences unless a longer answer is genuinely needed.

    CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

    You have exactly ONE tool: execute. This connects you to a powerful personal assistant that can do anything -- send messages, search the web, manage lists, set reminders, create notes, research topics, control smart home devices, interact with apps, and much more.

    ALWAYS use execute when the user asks you to:
    - Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
    - Search or look up anything (web, local info, facts, news)
    - Add, create, or modify anything (shopping lists, reminders, notes, todos, events)
    - Research, analyze, or draft anything
    - Control or interact with apps, devices, or services
    - Remember or store any information for later

    Be detailed in your task description. Include all relevant context: names, content, platforms, quantities, etc. The assistant works better with complete information.

    NEVER pretend to do these things yourself.

    IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
    - "Sure, let me add that to your shopping list." then call execute.
    - "Got it, searching for that now." then call execute.
    - "On it, sending that message." then call execute.
    Never call execute silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

    For messages, confirm recipient and content before delegating unless clearly urgent.

    Your replies will be spoken by a text-to-speech engine. Avoid markdown, bullet lists, parentheticals, and stage directions. Write plain prose that reads naturally aloud.
    """

  static var isConfigured: Bool {
    return apiKey != "YOUR_ANTHROPIC_API_KEY" && !apiKey.isEmpty
  }

  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }
}
