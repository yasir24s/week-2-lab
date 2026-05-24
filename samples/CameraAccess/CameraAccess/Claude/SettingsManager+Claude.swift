import Foundation

// Additive extension to the existing SettingsManager. Keep your local
// SettingsManager.swift unchanged; just drop this file in to gain the Claude
// keys without merge conflicts.
//
// If you've already merged these into the main SettingsManager (so the
// `claude*` keys appear in `enum Key`), delete this file.

extension SettingsManager {
  private enum ClaudeKey: String {
    case anthropicAPIKey
    case claudeSystemPrompt
    case claudeModel
  }

  // The base SettingsManager owns the UserDefaults handle. We use .standard
  // directly here to avoid re-declaring its `defaults` property.
  var anthropicAPIKey: String {
    get { UserDefaults.standard.string(forKey: ClaudeKey.anthropicAPIKey.rawValue) ?? Secrets.anthropicAPIKey }
    set { UserDefaults.standard.set(newValue, forKey: ClaudeKey.anthropicAPIKey.rawValue) }
  }

  var claudeSystemPrompt: String {
    get { UserDefaults.standard.string(forKey: ClaudeKey.claudeSystemPrompt.rawValue) ?? ClaudeConfig.defaultSystemInstruction }
    set { UserDefaults.standard.set(newValue, forKey: ClaudeKey.claudeSystemPrompt.rawValue) }
  }

  var claudeModel: String {
    get { UserDefaults.standard.string(forKey: ClaudeKey.claudeModel.rawValue) ?? ClaudeConfig.defaultModel }
    set { UserDefaults.standard.set(newValue, forKey: ClaudeKey.claudeModel.rawValue) }
  }
}
