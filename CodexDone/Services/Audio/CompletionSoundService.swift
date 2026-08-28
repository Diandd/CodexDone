import AVFoundation
import AppKit
import Foundation
import Observation

enum CompletionSoundError: LocalizedError, Equatable {
  case unsupportedFormat
  case fileTooLarge
  case invalidAudio
  case durationTooLong

  var errorDescription: String? {
    switch self {
    case .unsupportedFormat: L10n.text("请选择支持的音频文件。")
    case .fileTooLarge: L10n.text("音频文件不能超过 10 MB。")
    case .invalidAudio: L10n.text("该文件不是可播放的音频。")
    case .durationTooLong: L10n.text("音频不能超过 30 秒。")
    }
  }
}

@MainActor
@Observable
final class CompletionSoundService {
  static let builtInSounds = ["Glass", "Ping", "Pop", "Purr", "Sosumi", "Tink"]
  static let supportedExtensions: Set<String> = [
    "aac", "aif", "aiff", "caf", "m4a", "mp3", "wav",
  ]
  static let maximumFileBytes = 10 * 1_024 * 1_024
  static let maximumDuration: TimeInterval = 30

  private(set) var customSoundDisplayName: String?
  private(set) var lastErrorMessage: String?
  private(set) var lastPlaybackAt: Date?
  private(set) var lastPlaybackUsedCustomSound = false

  @ObservationIgnored private var activeSounds: [String: NSSound] = [:]
  @ObservationIgnored private var cleanupTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let fileManager: FileManager
  @ObservationIgnored private let customSoundURL: URL

  init(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    customSoundURL: URL = HookRuntimePaths.customSoundURL
  ) {
    self.defaults = defaults
    self.fileManager = fileManager
    self.customSoundURL = customSoundURL
    if fileManager.fileExists(atPath: customSoundURL.path) {
      customSoundDisplayName = defaults.string(forKey: "alerts.customSoundDisplayName")
    } else {
      customSoundDisplayName = nil
      defaults.removeObject(forKey: "alerts.customSoundDisplayName")
      for situation in AlertSituation.allCases {
        defaults.set(false, forKey: situation.useCustomSoundKey)
      }
    }
  }

  func soundEnabled(for situation: AlertSituation) -> Bool {
    defaults.object(forKey: situation.soundEnabledKey) as? Bool ?? situation.defaultSoundEnabled
  }

  func selectedBuiltInSound(for situation: AlertSituation) -> String {
    defaults.string(forKey: situation.builtInSoundKey) ?? situation.defaultBuiltInSound
  }

  func usesCustomSound(for situation: AlertSituation) -> Bool {
    defaults.bool(forKey: situation.useCustomSoundKey)
      && fileManager.fileExists(atPath: customSoundURL.path)
  }

  var playbackStatusTitle: String {
    if let lastErrorMessage { return lastErrorMessage }
    guard lastPlaybackAt != nil else { return L10n.text("尚未播放") }
    return lastPlaybackUsedCustomSound
      ? L10n.text("自定义音频已播放")
      : L10n.text("系统声音已播放")
  }

  @discardableResult
  func play(sessionID: String, situation: AlertSituation) -> Bool {
    guard soundEnabled(for: situation) else { return false }
    let sound: NSSound?
    let shouldUseCustomSound = usesCustomSound(for: situation)
    if shouldUseCustomSound {
      sound = NSSound(contentsOf: customSoundURL, byReference: false)
    } else {
      sound = NSSound(named: NSSound.Name(selectedBuiltInSound(for: situation)))
    }
    let storedVolume = defaults.object(forKey: situation.soundVolumeKey) as? Double ?? 1
    return startPlayback(
      sound,
      sessionID: sessionID,
      volume: storedVolume,
      usedCustomSound: shouldUseCustomSound
    )
  }

  @discardableResult
  func preview(situation: AlertSituation) -> Bool {
    play(sessionID: "sound-preview", situation: situation)
  }

  @discardableResult
  func previewBuiltIn(named name: String, volume: Double = 1) -> Bool {
    startPlayback(
      NSSound(named: NSSound.Name(name)),
      sessionID: "sound-preview",
      volume: volume,
      usedCustomSound: false
    )
  }

  @discardableResult
  func previewCustom(volume: Double = 1) -> Bool {
    guard fileManager.fileExists(atPath: customSoundURL.path) else {
      lastErrorMessage = L10n.text("提醒音无法加载")
      return false
    }
    return startPlayback(
      NSSound(contentsOf: customSoundURL, byReference: false),
      sessionID: "sound-preview",
      volume: volume,
      usedCustomSound: true
    )
  }

  func stop(sessionID: String) {
    cleanupTasks.removeValue(forKey: sessionID)?.cancel()
    activeSounds.removeValue(forKey: sessionID)?.stop()
  }

  func stopAll() {
    for task in cleanupTasks.values { task.cancel() }
    cleanupTasks.removeAll()
    for sound in activeSounds.values { sound.stop() }
    activeSounds.removeAll()
  }

  func importAudio(from sourceURL: URL) throws {
    guard Self.supportedExtensions.contains(sourceURL.pathExtension.lowercased()) else {
      throw CompletionSoundError.unsupportedFormat
    }
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

    let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw CompletionSoundError.invalidAudio }
    guard (values.fileSize ?? 0) <= Self.maximumFileBytes else {
      throw CompletionSoundError.fileTooLarge
    }
    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: sourceURL)
    } catch {
      throw CompletionSoundError.invalidAudio
    }
    let sampleRate = audioFile.processingFormat.sampleRate
    guard sampleRate > 0, audioFile.length > 0 else {
      throw CompletionSoundError.invalidAudio
    }
    let duration = Double(audioFile.length) / sampleRate
    guard duration <= Self.maximumDuration else { throw CompletionSoundError.durationTooLong }
    guard NSSound(contentsOf: sourceURL, byReference: false) != nil else {
      throw CompletionSoundError.invalidAudio
    }

    let destination = customSoundURL
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let staging = directory.appendingPathComponent(".completion-\(UUID().uuidString).audio")
    defer { try? fileManager.removeItem(at: staging) }
    try fileManager.copyItem(at: sourceURL, to: staging)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
    } else {
      try fileManager.moveItem(at: staging, to: destination)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    customSoundDisplayName = String(sourceURL.lastPathComponent.prefix(80))
    defaults.set(customSoundDisplayName, forKey: "alerts.customSoundDisplayName")
    lastErrorMessage = nil
    AppLog.alerts.notice("A validated custom alert sound was imported")
  }

  func removeCustomSound() throws {
    if fileManager.fileExists(atPath: customSoundURL.path) {
      try fileManager.removeItem(at: customSoundURL)
    }
    customSoundDisplayName = nil
    defaults.removeObject(forKey: "alerts.customSoundDisplayName")
    for situation in AlertSituation.allCases {
      defaults.set(false, forKey: situation.useCustomSoundKey)
    }
    AppLog.alerts.notice("The custom alert sound was removed")
  }

  @discardableResult
  private func startPlayback(
    _ sound: NSSound?,
    sessionID: String,
    volume: Double,
    usedCustomSound: Bool
  ) -> Bool {
    stop(sessionID: sessionID)
    guard let sound else {
      lastErrorMessage = L10n.text("提醒音无法加载")
      AppLog.alerts.error("Completion sound could not be loaded")
      return false
    }
    let normalizedVolume = min(max(volume, 0), 1)
    guard normalizedVolume > 0 else {
      lastErrorMessage = L10n.text("提醒音量为零")
      AppLog.alerts.error("Completion sound volume is zero")
      return false
    }
    sound.volume = Float(normalizedVolume)
    guard sound.play() else {
      lastErrorMessage = L10n.text("提醒音无法播放")
      AppLog.alerts.error("Completion sound playback failed")
      return false
    }
    activeSounds[sessionID] = sound
    let cleanupDelay = max(sound.duration + 0.25, 0.25)
    cleanupTasks[sessionID] = Task { @MainActor [weak self, weak sound] in
      try? await Task.sleep(for: .seconds(cleanupDelay))
      guard
        !Task.isCancelled,
        let self,
        let sound,
        self.activeSounds[sessionID] === sound
      else {
        return
      }
      self.activeSounds.removeValue(forKey: sessionID)
      self.cleanupTasks.removeValue(forKey: sessionID)
    }
    lastPlaybackAt = .now
    lastPlaybackUsedCustomSound = usedCustomSound
    lastErrorMessage = nil
    AppLog.alerts.notice("Completion sound playback started")
    return true
  }
}

extension AlertSituation {
  var settingsKeyPrefix: String { "alerts.completion" }

  var soundEnabledKey: String { "\(settingsKeyPrefix).soundEnabled" }
  var builtInSoundKey: String { "\(settingsKeyPrefix).builtInSound" }
  var useCustomSoundKey: String { "\(settingsKeyPrefix).useCustomSound" }
  var soundVolumeKey: String { "\(settingsKeyPrefix).soundVolume" }

  var defaultBuiltInSound: String { "Glass" }
  var defaultSoundEnabled: Bool { true }
}
