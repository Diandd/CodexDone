import Darwin
import Foundation

enum HookSocketServerError: Error {
  case pathTooLong
  case socketCreationFailed
  case directoryPermissionFailed
  case bindFailed
  case listenFailed
  case socketPermissionFailed
}

final class HookSocketServer: @unchecked Sendable {
  static let acknowledgementByte: UInt8 = 0x06

  private let socketURL: URL
  private let queue = DispatchQueue(label: "com.dianstudios.codexdone.hook-socket")
  private let lock = NSLock()
  private var listeningFileDescriptor: Int32 = -1
  private var shouldStop = false

  init(socketURL: URL = HookRuntimePaths.socketURL) {
    self.socketURL = socketURL
  }

  func start(
    eventHandler: @escaping @Sendable (DesktopCompletionHookEvent) async -> Bool
  ) throws {
    let path = socketURL.path
    let pathBytes = Array(path.utf8) + [UInt8.zero]
    guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw HookSocketServerError.pathTooLong
    }

    let directoryURL = socketURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directoryURL.path
      )
      let attributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
      guard
        let permissions = attributes[.posixPermissions] as? NSNumber,
        permissions.intValue & 0o777 == 0o700
      else {
        throw HookSocketServerError.directoryPermissionFailed
      }
    } catch {
      throw HookSocketServerError.directoryPermissionFailed
    }
    unlink(path)

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HookSocketServerError.socketCreationFailed }

    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
    }
    let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, addressLength)
      }
    }
    guard bindResult == 0 else {
      Darwin.close(descriptor)
      throw HookSocketServerError.bindFailed
    }
    guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
      Darwin.close(descriptor)
      unlink(path)
      throw HookSocketServerError.socketPermissionFailed
    }
    guard Darwin.listen(descriptor, 16) == 0 else {
      Darwin.close(descriptor)
      unlink(path)
      throw HookSocketServerError.listenFailed
    }

    lock.lock()
    shouldStop = false
    listeningFileDescriptor = descriptor
    lock.unlock()

    queue.async { [weak self] in
      self?.acceptLoop(descriptor: descriptor, eventHandler: eventHandler)
    }
  }

  func stop() {
    lock.lock()
    shouldStop = true
    let descriptor = listeningFileDescriptor
    listeningFileDescriptor = -1
    lock.unlock()

    if descriptor >= 0 {
      Darwin.shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }
    unlink(socketURL.path)
  }

  deinit {
    stop()
  }

  private func acceptLoop(
    descriptor: Int32,
    eventHandler: @escaping @Sendable (DesktopCompletionHookEvent) async -> Bool
  ) {
    while !isStopping {
      let client = Darwin.accept(descriptor, nil, nil)
      if client < 0 {
        if isStopping { return }
        continue
      }
      var noSigPipe: Int32 = 1
      _ = withUnsafePointer(to: &noSigPipe) { pointer in
        Darwin.setsockopt(
          client,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          pointer,
          socklen_t(MemoryLayout<Int32>.size)
        )
      }
      Task.detached(priority: .userInitiated) {
        await Self.handleClient(client, eventHandler: eventHandler)
      }
    }
  }

  private static func handleClient(
    _ client: Int32,
    eventHandler: @escaping @Sendable (DesktopCompletionHookEvent) async -> Bool
  ) async {
    defer {
      Darwin.shutdown(client, SHUT_RDWR)
      Darwin.close(client)
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count <= 64 * 1_024 {
      let count = Darwin.read(client, &buffer, buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    guard data.count <= 64 * 1_024 else { return }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard
      let event = try? decoder.decode(DesktopCompletionHookEvent.self, from: data),
      event.version == DesktopCompletionHookEvent.schemaVersion,
      await eventHandler(event)
    else {
      return
    }

    var acknowledgement = acknowledgementByte
    _ = withUnsafePointer(to: &acknowledgement) { pointer in
      Darwin.write(client, pointer, MemoryLayout<UInt8>.size)
    }
  }

  private var isStopping: Bool {
    lock.lock()
    defer { lock.unlock() }
    return shouldStop
  }
}
