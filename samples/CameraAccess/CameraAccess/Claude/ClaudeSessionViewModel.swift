import Foundation
import SwiftUI

// Drop-in replacement for GeminiSessionViewModel.
//
// Same @Published surface, same start/stop/sendVideoFrameIfThrottled API, so
// StreamSessionViewModel / the SwiftUI views can switch between Gemini and
// Claude with a single type rename (or a protocol if you keep both around).
//
// The big internal shape change: instead of streaming raw mic PCM out and
// receiving raw PCM back, we run SFSpeechRecognizer + AVSpeechSynthesizer
// locally and exchange text with Claude over HTTP+SSE.

@MainActor
final class ClaudeSessionViewModel: ObservableObject {
  @Published var isClaudeActive: Bool = false
  @Published var connectionState: ClaudeConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured

  private let claudeService = ClaudeService()
  private let speech = SpeechManager()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isClaudeActive else { return }

    guard ClaudeConfig.isConfigured else {
      errorMessage = "Anthropic API key not configured. Open Secrets.swift and set anthropicAPIKey -- get a key at https://console.anthropic.com/settings/keys"
      return
    }

    // Speech + mic permissions
    let permissionsOK = await SpeechManager.requestPermissions()
    guard permissionsOK else {
      errorMessage = "Microphone or speech recognition permission denied. Enable in Settings."
      return
    }

    isClaudeActive = true

    // Wire speech -> Claude
    speech.onUtteranceCaptured = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = text
        self.aiTranscript = ""
        self.claudeService.onInputTranscription?(text)
        self.claudeService.sendUserUtterance(text)
      }
    }

    speech.onUtteranceStarted = { [weak self] in
      // User started speaking again -- interrupt any in-flight reply.
      self?.claudeService.interrupt()
      self?.speech.cancelTTS()
    }

    // Wire Claude -> speech
    claudeService.onTextDelta = { [weak self] delta in
      self?.speech.speak(delta: delta)
    }

    claudeService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in self.aiTranscript += text }
    }

    claudeService.onInterrupted = { [weak self] in
      self?.speech.cancelTTS()
    }

    claudeService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.speech.flush()
        self.userTranscript = ""
      }
    }

    claudeService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isClaudeActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    // OpenClaw remains the action backend
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    claudeService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          // ToolCallRouter speaks Gemini's vocabulary; the adapter on
          // ClaudeFunctionCall translates for us.
          self.toolCallRouter?.handleToolCall(call.asGeminiFunctionCall) { [weak self] response in
            self?.claudeService.sendToolResponse(response)
          }
        }
      }
    }

    claudeService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.connectionState = self.claudeService.connectionState
        self.isModelSpeaking = self.claudeService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    do {
      try speech.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isClaudeActive = false
      return
    }

    let ok = await claudeService.connect()
    if !ok {
      let msg: String
      if case .error(let err) = claudeService.connectionState { msg = err }
      else { msg = "Failed to initialise Claude" }
      errorMessage = msg
      claudeService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isClaudeActive = false
      connectionState = .disconnected
      return
    }

    do {
      try speech.startListening()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      claudeService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isClaudeActive = false
      connectionState = .disconnected
      return
    }

    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isClaudeActive, self.connectionState == .ready else { return }
          // Inject server-pushed notifications as if the user had said them.
          self.claudeService.sendUserUtterance(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    speech.cancelTTS()
    speech.stopListening()
    claudeService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isClaudeActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isClaudeActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= ClaudeConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    claudeService.sendVideoFrame(image: image)
  }
}
