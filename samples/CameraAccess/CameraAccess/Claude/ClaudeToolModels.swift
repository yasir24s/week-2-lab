import Foundation

// Parsed from Anthropic Messages API `tool_use` content blocks.
// Field names mirror GeminiFunctionCall so the existing ToolCallRouter can
// keep working unchanged after the rename in ClaudeSessionViewModel.
struct ClaudeFunctionCall {
  let id: String        // Anthropic tool_use id (e.g. "toolu_01A09q9rs")
  let name: String
  let args: [String: Any]
}

struct ClaudeToolCall {
  let functionCalls: [ClaudeFunctionCall]
}

// Claude doesn't push tool-call cancellations from the server; the only way a
// tool call gets cancelled is locally when the user interrupts mid-turn. We
// keep the type so the rest of the app can match Gemini's interface.
struct ClaudeToolCallCancellation {
  let ids: [String]
}

// MARK: - Anthropic tool declarations

enum ClaudeToolDeclarations {
  static func allDeclarations() -> [[String: Any]] {
    return [execute]
  }

  // Anthropic schema differs from Gemini's:
  //   - `parameters` -> `input_schema`
  //   - JSON Schema is required (with `type`, `properties`, `required`)
  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.",
    "input_schema": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
        ]
      ],
      "required": ["task"]
    ] as [String: Any]
  ]
}

// MARK: - Bridge to the existing GeminiFunctionCall-based ToolCallRouter
//
// ToolCallRouter (in OpenClaw/) is written against the Gemini types. Rather
// than fork it, we provide a tiny adapter that exposes ClaudeFunctionCall
// values as GeminiFunctionCall so the router compiles against either backend.
// If your local ToolCallRouter has already been generalised, you can delete
// this extension.

extension ClaudeFunctionCall {
  var asGeminiFunctionCall: GeminiFunctionCall {
    return GeminiFunctionCall(id: id, name: name, args: args)
  }
}

extension ClaudeToolCall {
  var asGeminiToolCall: GeminiToolCall {
    // GeminiToolCall has a failable JSON init; we go through a synthetic JSON
    // payload that matches its expected shape so we don't need to change it.
    let callsJSON: [[String: Any]] = functionCalls.map {
      ["id": $0.id, "name": $0.name, "args": $0.args]
    }
    let envelope: [String: Any] = ["toolCall": ["functionCalls": callsJSON]]
    return GeminiToolCall(json: envelope)!
  }
}
