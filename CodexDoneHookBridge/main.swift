import Darwin
import Foundation

private struct BoundedHookInput {
  let retainedData: Data
  let exceededMaximumSize: Bool
  let scannedEventName: String?
}

private struct TopLevelEventNameScanner {
  private enum StringRole {
    case key
    case targetValue
    case other
  }

  private static let targetKey = "hook_event_name"
  private static let maximumCapturedStringBytes = 512

  private var depth = 0
  private var isInsideString = false
  private var isEscaping = false
  private var stringRole = StringRole.other
  private var capturedBytes: [UInt8] = []
  private var captureOverflowed = false
  private var expectsTopLevelKey = false
  private var expectsColon = false
  private var expectsValue = false
  private var currentKeyIsTarget = false

  private(set) var eventName: String?

  mutating func consume(_ data: Data) {
    for byte in data {
      consume(byte)
    }
  }

  private mutating func consume(_ byte: UInt8) {
    if isInsideString {
      if isEscaping {
        appendCaptured(byte)
        isEscaping = false
      } else if byte == UInt8(ascii: "\\") {
        appendCaptured(byte)
        isEscaping = true
      } else if byte == UInt8(ascii: "\"") {
        finishString()
      } else {
        appendCaptured(byte)
      }
      return
    }

    switch byte {
    case UInt8(ascii: "{"):
      depth += 1
      if depth == 1 {
        expectsTopLevelKey = true
      }
    case UInt8(ascii: "["):
      depth += 1
    case UInt8(ascii: "}"), UInt8(ascii: "]"):
      depth = max(0, depth - 1)
      if depth == 0 {
        resetMemberState()
      }
    case UInt8(ascii: "\""):
      if depth == 1, expectsTopLevelKey {
        beginString(role: .key)
        expectsTopLevelKey = false
      } else if depth == 1, expectsValue {
        beginString(role: currentKeyIsTarget ? .targetValue : .other)
        expectsValue = false
      } else {
        beginString(role: .other)
      }
    case UInt8(ascii: ":") where depth == 1 && expectsColon:
      expectsColon = false
      expectsValue = true
    case UInt8(ascii: ",") where depth == 1:
      resetMemberState()
      expectsTopLevelKey = true
    default:
      break
    }
  }

  private mutating func beginString(role: StringRole) {
    isInsideString = true
    isEscaping = false
    stringRole = role
    capturedBytes.removeAll(keepingCapacity: true)
    captureOverflowed = false
  }

  private mutating func appendCaptured(_ byte: UInt8) {
    guard stringRole != .other else { return }
    guard capturedBytes.count < Self.maximumCapturedStringBytes else {
      captureOverflowed = true
      return
    }
    capturedBytes.append(byte)
  }

  private mutating func finishString() {
    isInsideString = false
    isEscaping = false

    switch stringRole {
    case .key:
      currentKeyIsTarget = decodedCapturedString() == Self.targetKey
      expectsColon = true
    case .targetValue:
      eventName = decodedCapturedString()
    case .other:
      break
    }
    stringRole = .other
  }

  private func decodedCapturedString() -> String? {
    guard !captureOverflowed else { return nil }
    var literal = Data([UInt8(ascii: "\"")])
    literal.append(contentsOf: capturedBytes)
    literal.append(UInt8(ascii: "\""))
    return (
      try? JSONSerialization.jsonObject(
        with: literal,
        options: [.fragmentsAllowed]
      )
    ) as? String
  }

  private mutating func resetMemberState() {
    expectsTopLevelKey = false
    expectsColon = false
    expectsValue = false
    currentKeyIsTarget = false
  }
}

private func readBoundedHookInput(from handle: FileHandle) -> BoundedHookInput {
  let maximum = HookPayloadSanitizer.maximumPayloadBytes
  let chunkSize = 64 * 1_024
  var retainedData = Data()
  retainedData.reserveCapacity(maximum)
  var exceededMaximumSize = false
  var scanner = TopLevelEventNameScanner()
  var buffer = [UInt8](repeating: 0, count: chunkSize)

  while true {
    let count = buffer.withUnsafeMutableBytes { rawBuffer in
      Darwin.read(handle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
    }
    if count < 0, errno == EINTR {
      continue
    }
    guard count > 0 else {
      break
    }
    let chunk = Data(buffer.prefix(count))

    scanner.consume(chunk)
    let remainingCapacity = max(0, maximum - retainedData.count)
    if remainingCapacity > 0 {
      retainedData.append(contentsOf: chunk.prefix(remainingCapacity))
    }
    if chunk.count > remainingCapacity {
      exceededMaximumSize = true
    }
  }

  return BoundedHookInput(
    retainedData: retainedData,
    exceededMaximumSize: exceededMaximumSize,
    scannedEventName: scanner.eventName
  )
}

if CommandLine.arguments.contains("--health-check") {
  exit(EXIT_SUCCESS)
}

private let source: AgentSource = {
  guard let index = CommandLine.arguments.firstIndex(of: "--source") else { return .codex }
  guard CommandLine.arguments.indices.contains(index + 1),
    let source = AgentSource(rawValue: CommandLine.arguments[index + 1])
  else { exit(EXIT_FAILURE) }
  return source
}()

private let boundedInput = readBoundedHookInput(from: .standardInput)
private let parsedEventName: String? = {
  guard
    !boundedInput.exceededMaximumSize,
    let object = try? JSONSerialization.jsonObject(with: boundedInput.retainedData),
    let dictionary = object as? [String: Any]
  else {
    return nil
  }
  return dictionary["hook_event_name"] as? String
}()
private let rawEventName = parsedEventName ?? boundedInput.scannedEventName

if
  !boundedInput.exceededMaximumSize,
  let event = try? HookPayloadSanitizer.event(
    from: boundedInput.retainedData,
    source: source,
    terminalSessionID: ProcessInfo.processInfo.environment["ITERM_SESSION_ID"],
    suppressionRules: AlertSuppressionRulesFile.load()
  )
{
  HookBridgeTransport.deliver(event)
}

if source == .codex, rawEventName == DesktopHookEventName.stop.rawValue {
  FileHandle.standardOutput.write(Data(#"{"continue":true}"#.utf8))
}

exit(EXIT_SUCCESS)
