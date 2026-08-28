import Foundation

struct GitHubRepository: Equatable, Sendable {
  let owner: String
  let name: String

  init?(owner: String, name: String) {
    let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidComponent(owner), Self.isValidComponent(name) else { return nil }
    self.owner = owner
    self.name = name
  }

  var webURL: URL {
    URL(string: "https://github.com/\(owner)/\(name)")!
  }

  var latestReleaseAPIURL: URL {
    URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest")!
  }

  private static func isValidComponent(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}

struct GitHubRelease: Equatable, Sendable {
  let version: String
  let pageURL: URL
}

enum GitHubReleaseCheckResult: Equatable, Sendable {
  case upToDate(latestVersion: String)
  case updateAvailable(GitHubRelease)
}

enum GitHubReleaseUpdateError: Error, Equatable, Sendable {
  case connectionFailed
  case rateLimited
  case releaseUnavailable
  case invalidResponse
  case server(statusCode: Int)
}

struct GitHubReleaseUpdateService: Sendable {
  static let apiVersion = "2026-03-10"

  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func check(
    repository: GitHubRepository,
    currentVersion: String
  ) async throws -> GitHubReleaseCheckResult {
    let request = Self.request(repository: repository, currentVersion: currentVersion)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw GitHubReleaseUpdateError.connectionFailed
    }
    return try Self.result(data: data, response: response, currentVersion: currentVersion)
  }

  static func request(
    repository: GitHubRepository,
    currentVersion: String
  ) -> URLRequest {
    var request = URLRequest(url: repository.latestReleaseAPIURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("CodexDone/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    return request
  }

  static func result(
    data: Data,
    response: URLResponse,
    currentVersion: String
  ) throws -> GitHubReleaseCheckResult {
    guard let response = response as? HTTPURLResponse else {
      throw GitHubReleaseUpdateError.invalidResponse
    }
    switch response.statusCode {
    case 200:
      break
    case 403, 429:
      throw GitHubReleaseUpdateError.rateLimited
    case 404:
      throw GitHubReleaseUpdateError.releaseUnavailable
    default:
      throw GitHubReleaseUpdateError.server(statusCode: response.statusCode)
    }

    let payload: LatestReleasePayload
    do {
      payload = try JSONDecoder().decode(LatestReleasePayload.self, from: data)
    } catch {
      throw GitHubReleaseUpdateError.invalidResponse
    }
    guard
      let current = ReleaseVersion(currentVersion),
      let latest = ReleaseVersion(payload.tagName),
      payload.htmlURL.scheme == "https",
      payload.htmlURL.host?.lowercased() == "github.com"
    else {
      throw GitHubReleaseUpdateError.invalidResponse
    }

    let displayVersion = ReleaseVersion.displayValue(payload.tagName)
    if current < latest {
      return .updateAvailable(
        GitHubRelease(version: displayVersion, pageURL: payload.htmlURL)
      )
    }
    return .upToDate(latestVersion: displayVersion)
  }
}

private struct LatestReleasePayload: Decodable {
  let tagName: String
  let htmlURL: URL

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
}

struct ReleaseVersion: Comparable, Sendable {
  private let components: [Int]

  init?(_ rawValue: String) {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.first == "v" || value.first == "V" {
      value.removeFirst()
    }
    value = String(value.split(separator: "+", maxSplits: 1)[0])
    value = String(value.split(separator: "-", maxSplits: 1)[0])
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return nil }
    let components = parts.compactMap { Int($0) }
    guard components.count == parts.count else { return nil }
    self.components = components
  }

  static func displayValue(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.first == "v" || trimmed.first == "V" {
      return String(trimmed.dropFirst())
    }
    return trimmed
  }

  static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
    let length = max(lhs.components.count, rhs.components.count)
    for index in 0..<length {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }
}
