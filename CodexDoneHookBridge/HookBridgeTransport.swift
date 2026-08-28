import Darwin
import Foundation

enum HookBridgeTransport {
  private enum FileLockResult {
    case acquired
    case busy
    case failed
  }

  #if DEBUG
    private static let wakeExecutableOverrideKey = "CODEXDONE_BRIDGE_WAKE_EXECUTABLE"
    private static let disableWakeKey = "CODEXDONE_BRIDGE_DISABLE_WAKE"
  #endif
  private static let mainApplicationBundleIdentifier = "com.dianstudios.codexdone"
  private static let socketAcknowledgement: UInt8 = 0x06
  private static let socketTimeoutMilliseconds: Int32 = 50
  private static let wakeCooldownSeconds: TimeInterval = 30
  private static let wakeCooldownFileName = ".wake-cooldown"

  static func deliver(_ event: DesktopCompletionHookEvent) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(event) else { return }
    if sendToSocket(data, socketURL: HookRuntimePaths.socketURL) {
      return
    }
    if spool(data, eventID: event.eventID, directoryURL: HookRuntimePaths.spoolDirectoryURL) {
      wakeMainApplication(cooldownDirectoryURL: HookRuntimePaths.spoolDirectoryURL)
    }
  }

  private static func sendToSocket(_ data: Data, socketURL: URL) -> Bool {
    let deadline =
      ProcessInfo.processInfo.systemUptime
      + (TimeInterval(socketTimeoutMilliseconds) / 1_000)
    let pathBytes = Array(socketURL.path.utf8) + [UInt8.zero]
    guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      return false
    }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var noSigPipe: Int32 = 1
    guard
      Darwin.setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      return false
    }

    let originalFlags = fcntl(descriptor, F_GETFL, 0)
    guard
      originalFlags >= 0,
      fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0
    else {
      return false
    }

    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
    }
    let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectionResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    if connectionResult != 0 {
      guard errno == EINPROGRESS else { return false }
      guard waitForSocket(descriptor, events: Int16(POLLOUT), deadline: deadline) else {
        return false
      }
      var socketError: Int32 = 0
      var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
      guard
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorSize) == 0,
        socketError == 0
      else {
        return false
      }
    }

    return data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return false }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let sent = Darwin.write(descriptor, pointer, remaining)
        if sent > 0 {
          remaining -= sent
          pointer = pointer.advanced(by: sent)
          continue
        }
        if sent < 0, errno == EINTR {
          continue
        }
        guard sent < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
          return false
        }
        guard waitForSocket(descriptor, events: Int16(POLLOUT), deadline: deadline) else {
          return false
        }
      }
      guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else { return false }

      guard waitForSocket(descriptor, events: Int16(POLLIN), deadline: deadline) else {
        return false
      }
      var acknowledgement: UInt8 = 0
      let acknowledgementCount = Darwin.read(descriptor, &acknowledgement, 1)
      return acknowledgementCount == 1 && acknowledgement == socketAcknowledgement
    }
  }

  private static func waitForSocket(
    _ descriptor: Int32,
    events: Int16,
    deadline: TimeInterval
  ) -> Bool {
    while true {
      let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
      guard remainingSeconds > 0 else { return false }
      let remainingMilliseconds = Int32(
        min(
          Double(socketTimeoutMilliseconds),
          ceil(remainingSeconds * 1_000)
        )
      )
      var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
      let result = Darwin.poll(&pollDescriptor, 1, max(1, remainingMilliseconds))
      if result < 0, errno == EINTR {
        continue
      }
      return result == 1
    }
  }

  private static func spool(_ data: Data, eventID: UUID, directoryURL: URL) -> Bool {
    let fileManager = FileManager.default
    var temporaryURL: URL?
    do {
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directoryURL.path
      )
      let directoryAttributes = try fileManager.attributesOfItem(atPath: directoryURL.path)
      guard
        let directoryPermissions = directoryAttributes[.posixPermissions] as? NSNumber,
        directoryPermissions.intValue & 0o777 == 0o700
      else {
        return false
      }
      let finalURL = directoryURL.appendingPathComponent(
        "\(eventID.uuidString.lowercased()).json"
      )
      if fileManager.fileExists(atPath: finalURL.path) {
        return secureSpoolFile(finalURL, fileManager: fileManager)
      }
      let stagingURL = directoryURL.appendingPathComponent(
        ".\(UUID().uuidString.lowercased()).tmp"
      )
      temporaryURL = stagingURL
      guard
        fileManager.createFile(
          atPath: stagingURL.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else {
        return false
      }
      let handle = try FileHandle(forWritingTo: stagingURL)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: stagingURL.path
      )
      do {
        try fileManager.moveItem(at: stagingURL, to: finalURL)
      } catch {
        try? fileManager.removeItem(at: stagingURL)
        return fileManager.fileExists(atPath: finalURL.path)
          && secureSpoolFile(finalURL, fileManager: fileManager)
      }
      temporaryURL = nil
      guard secureSpoolFile(finalURL, fileManager: fileManager) else {
        try? fileManager.removeItem(at: finalURL)
        return false
      }
      synchronizeDirectory(directoryURL)
      return true
    } catch {
      if let temporaryURL {
        try? fileManager.removeItem(at: temporaryURL)
      }
      return false
    }
  }

  private static func secureSpoolFile(_ url: URL, fileManager: FileManager) -> Bool {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
      return permissions.intValue & 0o777 == 0o600
    } catch {
      return false
    }
  }

  private static func synchronizeDirectory(_ directoryURL: URL) {
    let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
    guard descriptor >= 0 else { return }
    defer { Darwin.close(descriptor) }
    _ = Darwin.fsync(descriptor)
  }

  private static func wakeMainApplication(cooldownDirectoryURL: URL) {
    let executablePath: String
    let waitsForCompletion: Bool
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      guard environment[disableWakeKey] != "1" else { return }
      if let override = environment[wakeExecutableOverrideKey] {
        executablePath = override
        waitsForCompletion = true
      } else {
        executablePath = "/usr/bin/open"
        waitsForCompletion = false
      }
    #else
      executablePath = "/usr/bin/open"
      waitsForCompletion = false
    #endif
    guard FileManager.default.isExecutableFile(atPath: executablePath) else { return }

    let cooldownURL = cooldownDirectoryURL.appendingPathComponent(wakeCooldownFileName)
    let descriptor = Darwin.open(cooldownURL.path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else {
      _ = launchMainApplication(
        executablePath: executablePath,
        waitsForCompletion: waitsForCompletion
      )
      return
    }
    defer { Darwin.close(descriptor) }
    _ = Darwin.fchmod(descriptor, 0o600)
    let descriptorFlags = fcntl(descriptor, F_GETFD, 0)
    if descriptorFlags >= 0 {
      _ = fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC)
    }

    switch acquireFileLock(descriptor) {
    case .busy:
      return
    case .failed:
      _ = launchMainApplication(
        executablePath: executablePath,
        waitsForCompletion: waitsForCompletion
      )
      return
    case .acquired:
      break
    }
    defer { releaseFileLock(descriptor) }

    let now = Date().timeIntervalSince1970
    if let previousWake = readWakeTimestamp(from: descriptor) {
      let elapsed = now - previousWake
      if elapsed >= 0, elapsed < wakeCooldownSeconds {
        return
      }
    }

    guard
      launchMainApplication(
        executablePath: executablePath,
        waitsForCompletion: waitsForCompletion
      )
    else {
      return
    }
    writeWakeTimestamp(now, to: descriptor)
  }

  private static func acquireFileLock(_ descriptor: Int32) -> FileLockResult {
    var lock = Darwin.flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    guard fcntl(descriptor, F_SETLK, &lock) == 0 else {
      if errno == EACCES || errno == EAGAIN {
        return .busy
      }
      return .failed
    }
    return .acquired
  }

  private static func releaseFileLock(_ descriptor: Int32) {
    var lock = Darwin.flock()
    lock.l_type = Int16(F_UNLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    _ = fcntl(descriptor, F_SETLK, &lock)
  }

  private static func launchMainApplication(
    executablePath: String,
    waitsForCompletion: Bool
  ) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["-g", "-b", mainApplicationBundleIdentifier]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      #if DEBUG
        if waitsForCompletion {
          process.waitUntilExit()
        }
      #endif
      return true
    } catch {
      return false
    }
  }

  private static func readWakeTimestamp(from descriptor: Int32) -> TimeInterval? {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: 64)
    let count = bytes.withUnsafeMutableBytes { rawBuffer in
      Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
    }
    guard count > 0 else { return nil }
    let text = String(decoding: bytes.prefix(count), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return TimeInterval(text)
  }

  private static func writeWakeTimestamp(_ timestamp: TimeInterval, to descriptor: Int32) {
    let data = Data(String(timestamp).utf8)
    guard
      Darwin.ftruncate(descriptor, 0) == 0,
      Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
    else {
      return
    }
    let didWriteAllBytes = data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return false }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        if written > 0 {
          remaining -= written
          pointer = pointer.advanced(by: written)
        } else if written < 0, errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
    if didWriteAllBytes {
      _ = Darwin.fsync(descriptor)
    }
  }
}
