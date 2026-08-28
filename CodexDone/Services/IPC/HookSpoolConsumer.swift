import Foundation

actor HookSpoolConsumer {
  private let directoryURL: URL
  private let fileManager: FileManager

  init(
    directoryURL: URL = HookRuntimePaths.spoolDirectoryURL,
    fileManager: FileManager = .default
  ) {
    self.directoryURL = directoryURL
    self.fileManager = fileManager
  }

  func pendingCount() -> Int {
    (try? eventFiles().count) ?? 0
  }

  @discardableResult
  func drain(
    _ handler: @Sendable (DesktopCompletionHookEvent) async -> Bool
  ) async -> Int {
    guard let files = try? eventFiles() else { return 0 }
    var delivered = 0
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970

    for file in files {
      guard
        let data = try? Data(contentsOf: file),
        let event = try? decoder.decode(DesktopCompletionHookEvent.self, from: data),
        event.version == DesktopCompletionHookEvent.schemaVersion
      else {
        try? fileManager.removeItem(at: file)
        continue
      }
      guard await handler(event) else {
        break
      }
      do {
        try fileManager.removeItem(at: file)
      } catch {
        break
      }
      delivered += 1
    }
    return delivered
  }

  private func eventFiles() throws -> [URL] {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    let urls = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    )
    return urls
      .filter { url in
        guard url.pathExtension == "json" else { return false }
        return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
      }
      .sorted { lhs, rhs in
        let leftDate = try? lhs.resourceValues(forKeys: keys).contentModificationDate
        let rightDate = try? rhs.resourceValues(forKeys: keys).contentModificationDate
        if leftDate == rightDate { return lhs.lastPathComponent < rhs.lastPathComponent }
        return (leftDate ?? .distantPast) < (rightDate ?? .distantPast)
      }
  }
}
