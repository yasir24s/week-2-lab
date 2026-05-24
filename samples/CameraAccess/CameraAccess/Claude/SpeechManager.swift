import AVFoundation
import Foundation
import Speech
import UIKit

// Replaces the Gemini AudioManager. Claude's Messages API is text-only, so we
// run speech-to-text and text-to-speech on-device:
//   - SFSpeechRecognizer streams partial transcripts from the mic tap.
//   - A silence timer detects end-of-utterance and fires onUtteranceCaptured.
//   - AVSpeechSynthesizer speaks Claude's text deltas as they arrive, with
//     sentence-level buffering so prosody sounds natural.
//
// The mic is muted whenever TTS is speaking (loudspeaker + co-located mic
// would otherwise feed back through the recognizer).

@MainActor
final class SpeechManager: NSObject {
  // Called once per detected utterance with the final transcript.
  var onUtteranceCaptured: ((String) -> Void)?

  // Called as soon as the user begins speaking (used to interrupt Claude
  // mid-response, mirroring Gemini's START_OF_ACTIVITY_INTERRUPTS behavior).
  var onUtteranceStarted: (() -> Void)?

  // Called for each line of Claude's output that finished speaking; lets the
  // session view-model clear stale "AI is speaking" UI state.
  var onSpeakingFinished: (() -> Void)?

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?

  private let synthesizer = AVSpeechSynthesizer()
  private var ttsBuffer = ""
  private var isCapturing = false
  private var isMuted = false
  private var useIPhoneMode = false

  private var silenceWorkItem: DispatchWorkItem?
  private var lastFinalisedTranscript = ""
  private var hasEmittedStart = false

  // Notification observers for background resilience (mirrors AudioManager).
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  // MARK: - Permissions

  static func requestPermissions() async -> Bool {
    let mic = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
    }
    let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { status in
        cont.resume(returning: status == .authorized)
      }
    }
    return mic && speech
  }

  // MARK: - Audio session

  func setupAudioSession(useIPhoneMode: Bool = false) throws {
    self.useIPhoneMode = useIPhoneMode
    let session = AVAudioSession.sharedInstance()
    let forceSpeaker = SettingsManager.shared.speakerOutputEnabled
    if useIPhoneMode || forceSpeaker {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
      )
    } else {
      try session.setCategory(
        .playAndRecord,
        mode: .videoChat,
        options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker]
      )
    }
    try session.setPreferredIOBufferDuration(0.064)
    try session.setActive(true)
    if forceSpeaker {
      try session.overrideOutputAudioPort(.speaker)
    }
    NSLog("[Speech] Session mode: %@", useIPhoneMode ? "voiceChat (iPhone)" : "videoChat (glasses)")
    setupInterruptionHandling()
  }

  // MARK: - Capture (STT)

  func startListening() throws {
    guard !isCapturing else { return }
    guard let recognizer, recognizer.isAvailable else {
      throw NSError(
        domain: "SpeechManager", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if #available(iOS 16.0, *) {
      request.addsPunctuation = true
    }
    recognitionRequest = request

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      // Drop mic input while we're playing TTS so we don't transcribe ourselves.
      if self.isMuted { return }
      self.recognitionRequest?.append(buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        Task { @MainActor in
          self.handlePartialResult(result.bestTranscription.formattedString, isFinal: result.isFinal)
        }
      }
      if let error {
        NSLog("[Speech] Recognition error: %@", error.localizedDescription)
      }
    }

    lastFinalisedTranscript = ""
    hasEmittedStart = false
    isCapturing = true
    NSLog("[Speech] Listening")
  }

  func stopListening() {
    guard isCapturing else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    silenceWorkItem?.cancel()
    silenceWorkItem = nil
    isCapturing = false
    removeObservers()
    NSLog("[Speech] Stopped")
  }

  func setMuted(_ muted: Bool) {
    isMuted = muted
  }

  // MARK: - Playback (TTS)

  /// Accumulates streamed deltas from Claude and speaks them at sentence
  /// boundaries so we get natural prosody without waiting for the full reply.
  func speak(delta: String) {
    ttsBuffer.append(delta)
    flushCompletedSentences()
  }

  /// Speak whatever remains in the buffer (called on turn complete).
  func flush() {
    let remaining = ttsBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    ttsBuffer = ""
    if !remaining.isEmpty { utter(remaining) }
  }

  func cancelTTS() {
    ttsBuffer = ""
    synthesizer.stopSpeaking(at: .immediate)
  }

  // MARK: - Private

  private func flushCompletedSentences() {
    // Pull off everything up to and including the last sentence-ending
    // punctuation. Anything after (the partial sentence) stays buffered.
    let terminators: Set<Character> = [".", "!", "?", "\n"]
    guard let lastIdx = ttsBuffer.lastIndex(where: { terminators.contains($0) }) else { return }
    let upTo = ttsBuffer.index(after: lastIdx)
    let chunk = String(ttsBuffer[..<upTo]).trimmingCharacters(in: .whitespacesAndNewlines)
    ttsBuffer = String(ttsBuffer[upTo...])
    if !chunk.isEmpty { utter(chunk) }
  }

  private func utter(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    synthesizer.speak(utterance)
  }

  private func handlePartialResult(_ text: String, isFinal: Bool) {
    guard !text.isEmpty else { return }

    // First non-empty partial of a fresh utterance -> signal start so the
    // session can interrupt any in-flight Claude response.
    if !hasEmittedStart {
      hasEmittedStart = true
      onUtteranceStarted?()
    }

    lastFinalisedTranscript = text

    // Reset the silence timer; if the user keeps talking we keep accumulating.
    silenceWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor in self?.finaliseUtterance() }
    }
    silenceWorkItem = work
    let delay = isFinal ? 0.0 : ClaudeConfig.endOfUtteranceSilence
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func finaliseUtterance() {
    let final = lastFinalisedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    lastFinalisedTranscript = ""
    hasEmittedStart = false
    guard !final.isEmpty else { return }

    // Restart the recognition request for the next utterance. SFSpeechRecognizer
    // requires a fresh task per turn to avoid the 1-minute continuous limit.
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil

    onUtteranceCaptured?(final)

    // Rearm for the next utterance, but only if still capturing.
    if isCapturing {
      do {
        try restartRecogniser()
      } catch {
        NSLog("[Speech] Failed to rearm recogniser: %@", error.localizedDescription)
      }
    }
  }

  private func restartRecogniser() throws {
    guard let recognizer, recognizer.isAvailable else { return }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if #available(iOS 16.0, *) { request.addsPunctuation = true }
    recognitionRequest = request
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
      guard let self, let result else { return }
      Task { @MainActor in
        self.handlePartialResult(result.bestTranscription.formattedString, isFinal: result.isFinal)
      }
    }
  }

  private func setupInterruptionHandling() {
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }
      Task { @MainActor in
        switch type {
        case .began:
          self.cancelTTS()
          if self.isCapturing { self.audioEngine.pause() }
        case .ended:
          if self.isCapturing {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.audioEngine.start()
          }
        @unknown default: break
        }
      }
    }
  }

  private func removeObservers() {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
    if let observer = routeChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeChangeObserver = nil
    }
  }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechManager: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                     didStart utterance: AVSpeechUtterance) {
    Task { @MainActor in self.setMuted(true) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                     didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      // Only unmute once the queue is empty -- another utterance may already
      // be playing if Claude is streaming faster than we can speak.
      if !synthesizer.isSpeaking {
        self.setMuted(false)
        self.onSpeakingFinished?()
      }
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                     didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in
      self.setMuted(false)
      self.onSpeakingFinished?()
    }
  }
}
