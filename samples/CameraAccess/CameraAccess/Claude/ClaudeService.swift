import Foundation
import UIKit

enum ClaudeConnectionState: Equatable {
  case disconnected
  case connecting
  case ready
  case error(String)
}

// HTTP+SSE replacement for GeminiLiveService.
//
// Anthropic's Messages API isn't a persistent socket -- each user turn is a
// separate POST that streams Server-Sent Events back. We still expose the
// same callback surface as GeminiLiveService (onTextDelta replaces
// onAudioReceived; everything else maps 1:1) so the rest of the app doesn't
// care which backend is wired up.
//
// Conversation history is kept in memory; the image attached to the *latest*
// user turn carries cache_control so subsequent questions about the same
// scene re-use the vision tokens.

@MainActor
final class ClaudeService: ObservableObject {
  @Published var connectionState: ClaudeConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false

  var onTextDelta: ((String) -> Void)?
  var onTurnComplete: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?
  var onInputTranscription: ((String) -> Void)?   // user STT result, fired by SessionViewModel
  var onOutputTranscription: ((String) -> Void)?  // Claude text deltas (same as onTextDelta but stringified per chunk)
  var onToolCall: ((ClaudeToolCall) -> Void)?
  var onToolCallCancellation: ((ClaudeToolCallCancellation) -> Void)?

  // Latest throttled video frame -- attached to the next user turn as an
  // `image` content block. nil if the user disabled video streaming or no
  // frame has arrived yet.
  private var pendingImageJPEG: Data?

  // Conversation history in Anthropic JSON shape.
  // Each element is `{"role": "user"|"assistant", "content": [...]}`.
  private var messages: [[String: Any]] = []

  // Pending tool_use ids whose results we're still waiting on. When the dict
  // empties out, we resume the conversation with all collected results.
  private var pendingToolResults: [String: [String: Any]?] = [:]

  private var streamTask: Task<Void, Never>?
  private var urlSession: URLSession

  // Latency tracking
  private var lastUserSpeechEnd: Date?
  private var responseLatencyLogged = false

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 300
    self.urlSession = URLSession(configuration: config)
  }

  // MARK: - Connection lifecycle

  /// "Connect" is a logical handshake. Anthropic uses per-request HTTP, so all
  /// we do here is validate the API key shape -- the first send will surface
  /// auth errors.
  func connect() async -> Bool {
    guard ClaudeConfig.isConfigured else {
      connectionState = .error("No Anthropic API key configured")
      return false
    }
    messages.removeAll()
    pendingToolResults.removeAll()
    connectionState = .ready
    return true
  }

  func disconnect() {
    streamTask?.cancel()
    streamTask = nil
    messages.removeAll()
    pendingToolResults.removeAll()
    onToolCall = nil
    onToolCallCancellation = nil
    isModelSpeaking = false
    connectionState = .disconnected
  }

  // MARK: - Input

  /// Equivalent of Gemini's `sendVideoFrame` -- but instead of pushing live
  /// frames over the wire we cache the most recent one and attach it to the
  /// next user turn.
  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready else { return }
    guard let jpeg = image.jpegData(compressionQuality: ClaudeConfig.videoJPEGQuality) else { return }
    pendingImageJPEG = jpeg
  }

  /// Called by the session view-model when the user finishes an utterance.
  /// Builds a user message (text + most recent frame) and kicks off a stream.
  func sendUserUtterance(_ text: String) {
    guard connectionState == .ready, !text.isEmpty else { return }
    cancelInFlightStream()  // user spoke again before we finished -- new turn wins.

    var content: [[String: Any]] = []
    if let jpeg = pendingImageJPEG {
      var imageBlock: [String: Any] = [
        "type": "image",
        "source": [
          "type": "base64",
          "media_type": "image/jpeg",
          "data": jpeg.base64EncodedString()
        ]
      ]
      if ClaudeConfig.cacheControlOnImages {
        imageBlock["cache_control"] = ["type": "ephemeral"]
      }
      content.append(imageBlock)
      pendingImageJPEG = nil
    }
    content.append(["type": "text", "text": text])
    messages.append(["role": "user", "content": content])

    lastUserSpeechEnd = Date()
    responseLatencyLogged = false
    startStream()
  }

  /// Called by ToolCallRouter (via the session view-model) once OpenClaw
  /// returns. Mirrors `GeminiLiveService.sendToolResponse(_:)`.
  /// `response` is expected in the same shape the router already produces:
  /// `{"functionResponses": [{"id": "...", "response": {"result"|"error": "..."}}]}`
  func sendToolResponse(_ response: [String: Any]) {
    guard let functionResponses = response["functionResponses"] as? [[String: Any]] else { return }
    for fr in functionResponses {
      guard let id = fr["id"] as? String else { continue }
      pendingToolResults[id] = fr["response"] as? [String: Any]
    }
    flushToolResultsIfReady()
  }

  /// User started speaking again mid-response. Cancel TTS upstream, drop the
  /// in-flight stream, and roll the (partial) assistant turn out of history.
  func interrupt() {
    guard isModelSpeaking || streamTask != nil else { return }
    isModelSpeaking = false
    cancelInFlightStream()
    rollBackPartialAssistantTurn()
    let cancelled = Array(pendingToolResults.keys)
    pendingToolResults.removeAll()
    if !cancelled.isEmpty {
      onToolCallCancellation?(ClaudeToolCallCancellation(ids: cancelled))
    }
    onInterrupted?()
  }

  // MARK: - Streaming

  private func startStream() {
    guard let url = URL(string: ClaudeConfig.baseURL) else { return }

    let body: [String: Any] = [
      "model": ClaudeConfig.model,
      "max_tokens": ClaudeConfig.maxTokens,
      "system": [
        [
          "type": "text",
          "text": ClaudeConfig.systemInstruction,
          "cache_control": ["type": "ephemeral"]
        ]
      ],
      "tools": ClaudeToolDeclarations.allDeclarations(),
      "messages": messages,
      "stream": true
    ]

    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(ClaudeConfig.apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(ClaudeConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
    request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
    request.httpBody = payload

    streamTask = Task { [weak self] in
      guard let self else { return }
      do {
        let (bytes, response) = try await self.urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
          await MainActor.run { self.fail("No HTTP response") }
          return
        }
        if http.statusCode != 200 {
          var bodyText = ""
          for try await line in bytes.lines { bodyText.append(line + "\n") }
          await MainActor.run { self.fail("HTTP \(http.statusCode): \(bodyText.prefix(400))") }
          return
        }
        await self.consumeSSE(bytes)
      } catch {
        if Task.isCancelled { return }
        await MainActor.run { self.fail(error.localizedDescription) }
      }
    }
  }

  private func cancelInFlightStream() {
    streamTask?.cancel()
    streamTask = nil
  }

  // MARK: - SSE parser
  //
  // Anthropic sends events in this shape:
  //   event: content_block_delta
  //   data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
  //
  // We only need the `data:` payload -- the `event:` line is duplicated inside
  // the JSON as a `type` field.

  private struct AssemblingBlock {
    var type: String       // "text" or "tool_use"
    var text: String = ""
    var toolUseId: String = ""
    var toolUseName: String = ""
    var toolUseInputJSON: String = ""  // accumulated input_json_delta chunks
  }

  private var assemblingBlocks: [Int: AssemblingBlock] = [:]
  private var stopReason: String?
  private var assistantContentForHistory: [[String: Any]] = []
  // Holds blocks Claude already finalised so an interrupt can roll the whole
  // assistant turn out of `messages` cleanly.
  private var assistantTurnAppendedToHistory = false

  private func consumeSSE(_ bytes: URLSession.AsyncBytes) async {
    assemblingBlocks.removeAll()
    stopReason = nil
    assistantContentForHistory.removeAll()
    assistantTurnAppendedToHistory = false

    do {
      for try await line in bytes.lines {
        if Task.isCancelled { return }
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          continue
        }
        await MainActor.run { self.handleSSEEvent(json) }
      }
    } catch {
      if !Task.isCancelled {
        await MainActor.run { self.fail(error.localizedDescription) }
      }
    }
  }

  private func handleSSEEvent(_ json: [String: Any]) {
    guard let type = json["type"] as? String else { return }
    switch type {
    case "message_start":
      isModelSpeaking = true
      if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
        let latency = Date().timeIntervalSince(speechEnd)
        NSLog("[Latency] %.0fms (user speech end -> first SSE event)", latency * 1000)
        responseLatencyLogged = true
      }

    case "content_block_start":
      guard let index = json["index"] as? Int,
            let block = json["content_block"] as? [String: Any],
            let blockType = block["type"] as? String else { return }
      var assembling = AssemblingBlock(type: blockType)
      if blockType == "tool_use" {
        assembling.toolUseId = block["id"] as? String ?? ""
        assembling.toolUseName = block["name"] as? String ?? ""
      } else if blockType == "text", let text = block["text"] as? String {
        assembling.text = text
        if !text.isEmpty {
          onTextDelta?(text)
          onOutputTranscription?(text)
        }
      }
      assemblingBlocks[index] = assembling

    case "content_block_delta":
      guard let index = json["index"] as? Int,
            let delta = json["delta"] as? [String: Any],
            let deltaType = delta["type"] as? String,
            var assembling = assemblingBlocks[index] else { return }
      switch deltaType {
      case "text_delta":
        if let text = delta["text"] as? String {
          assembling.text.append(text)
          onTextDelta?(text)
          onOutputTranscription?(text)
        }
      case "input_json_delta":
        if let partial = delta["partial_json"] as? String {
          assembling.toolUseInputJSON.append(partial)
        }
      default:
        break
      }
      assemblingBlocks[index] = assembling

    case "content_block_stop":
      guard let index = json["index"] as? Int,
            let assembling = assemblingBlocks.removeValue(forKey: index) else { return }
      finaliseBlock(assembling)

    case "message_delta":
      if let delta = json["delta"] as? [String: Any],
         let reason = delta["stop_reason"] as? String {
        stopReason = reason
      }

    case "message_stop":
      finaliseTurn()

    case "error":
      let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
      fail(msg)

    case "ping":
      break

    default:
      break
    }
  }

  private func finaliseBlock(_ block: AssemblingBlock) {
    switch block.type {
    case "text":
      assistantContentForHistory.append(["type": "text", "text": block.text])
    case "tool_use":
      let inputDict: [String: Any]
      if let data = block.toolUseInputJSON.data(using: .utf8),
         let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        inputDict = parsed
      } else {
        inputDict = [:]
      }
      assistantContentForHistory.append([
        "type": "tool_use",
        "id": block.toolUseId,
        "name": block.toolUseName,
        "input": inputDict
      ])
      pendingToolResults[block.toolUseId] = nil   // sentinel: awaiting result
      let call = ClaudeFunctionCall(id: block.toolUseId, name: block.toolUseName, args: inputDict)
      NSLog("[Claude] Tool call: %@", block.toolUseName)
      onToolCall?(ClaudeToolCall(functionCalls: [call]))
    default:
      break
    }
  }

  private func finaliseTurn() {
    // Persist the assistant turn in history exactly once.
    if !assistantTurnAppendedToHistory, !assistantContentForHistory.isEmpty {
      messages.append(["role": "assistant", "content": assistantContentForHistory])
      assistantTurnAppendedToHistory = true
    }

    streamTask = nil

    if stopReason == "tool_use" {
      // We'll resume once all tool results land via sendToolResponse.
      flushToolResultsIfReady()
    } else {
      isModelSpeaking = false
      onTurnComplete?()
    }
  }

  private func flushToolResultsIfReady() {
    // All results landed iff there's no `nil` value left in the dict.
    let awaiting = pendingToolResults.values.contains { $0 == nil }
    guard !awaiting, !pendingToolResults.isEmpty else { return }

    var resultBlocks: [[String: Any]] = []
    for (id, result) in pendingToolResults {
      guard let result else { continue }
      let contentString: String
      let isError: Bool
      if let err = result["error"] as? String {
        contentString = err
        isError = true
      } else if let ok = result["result"] as? String {
        contentString = ok
        isError = false
      } else {
        contentString = (try? String(
          data: JSONSerialization.data(withJSONObject: result), encoding: .utf8)) ?? ""
        isError = false
      }
      var block: [String: Any] = [
        "type": "tool_result",
        "tool_use_id": id,
        "content": contentString
      ]
      if isError { block["is_error"] = true }
      resultBlocks.append(block)
    }
    pendingToolResults.removeAll()
    messages.append(["role": "user", "content": resultBlocks])

    // Kick off the follow-up turn that lets Claude react to the tool results.
    startStream()
  }

  private func rollBackPartialAssistantTurn() {
    if assistantTurnAppendedToHistory, !messages.isEmpty {
      messages.removeLast()
      assistantTurnAppendedToHistory = false
    }
    assemblingBlocks.removeAll()
    assistantContentForHistory.removeAll()
    stopReason = nil
  }

  private func fail(_ message: String) {
    streamTask = nil
    isModelSpeaking = false
    connectionState = .error(message)
    onDisconnected?(message)
  }
}
