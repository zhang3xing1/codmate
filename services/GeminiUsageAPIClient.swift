import Foundation
import Security

struct GeminiUsageAPIClient {
  enum ClientError: Error, LocalizedError {
    case credentialNotFound
    case keychainAccess(OSStatus)
    case malformedCredential
    case missingAccessToken
    case credentialExpired(Date)
    case projectNotFound
    case requestFailed(Int)
    case emptyResponse
    case decodingFailed

    var errorDescription: String? {
      switch self {
      case .credentialNotFound:
        return "Gemini credential not found."
      case .keychainAccess(let status):
        return SecCopyErrorMessageString(status, nil) as String?
      case .malformedCredential:
        return "Gemini credential is invalid."
      case .missingAccessToken:
        return "Gemini credential is missing an access token."
      case .credentialExpired(let date):
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Gemini credential expired on \(formatter.string(from: date))."
      case .projectNotFound:
        return "Gemini project ID not found. Set GOOGLE_CLOUD_PROJECT or run gemini login."
      case .requestFailed(let code):
        return "Gemini usage API returned status \(code)."
      case .emptyResponse:
        return "Gemini usage API returned no data."
      case .decodingFailed:
        return "Failed to decode Gemini usage response."
      }
    }
  }

  private struct CredentialEnvelope: Decodable {
    struct Token: Decodable {
      let accessToken: String
      let refreshToken: String?
      let expiresAt: TimeInterval?
      let tokenType: String?
    }

    let serverName: String?
    let token: Token
    let updatedAt: TimeInterval?
  }

  private struct LoadProjectResponse: Decodable {
    struct Project: Decodable { let id: String?; let name: String? }
    let cloudaicompanionProjectId: String?
    let project: Project?

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let rawString = try? container.decodeIfPresent(String.self, forKey: .cloudaicompanionProject) {
        self.cloudaicompanionProjectId = rawString
        self.project = nil
        return
      }
      if let obj = try? container.decodeIfPresent(Project.self, forKey: .cloudaicompanionProject) {
        self.cloudaicompanionProjectId = obj.id ?? obj.name
        self.project = obj
        return
      }
      self.cloudaicompanionProjectId = nil
      self.project = nil
    }

    private enum CodingKeys: String, CodingKey { case cloudaicompanionProject }
  }

  private struct QuotaResponse: Decodable {
    struct Bucket: Decodable {
      let remainingAmount: String?
      let remainingFraction: Double?
      let resetTime: String?
      let tokenType: String?
      let modelId: String?
    }

    let buckets: [Bucket]?
  }

  private struct OAuthFile: Decodable {
    let access_token: String?
    let expiry_date: TimeInterval?
  }

  func fetchUsageStatus(now: Date = Date()) async throws -> GeminiUsageStatus {
    let credential = try fetchCredential()
    if let expires = credential.token.expiresAt {
      let expiry = Date(timeIntervalSince1970: expires / 1000)
      if expiry.addingTimeInterval(-300) < now {
        throw ClientError.credentialExpired(expiry)
      }
    }

    guard !credential.token.accessToken.isEmpty else { throw ClientError.missingAccessToken }
    let token = credential.token.accessToken

    guard let projectId = try await resolveProjectId(token: token) else {
      throw ClientError.projectNotFound
    }
    let buckets = try await retrieveQuota(token: token, projectId: projectId)

    let status = GeminiUsageStatus(
      updatedAt: now,
      projectId: projectId,
      buckets: buckets
    )
    return status
  }

  // MARK: - Credential loading

  private func fetchCredential() throws -> CredentialEnvelope {
    if let keychain = try fetchCredentialFromKeychain() {
      return keychain
    }
    if let file = fetchCredentialFromPlaintextFile() {
      return file
    }
    throw ClientError.credentialNotFound
  }

  private func fetchCredentialFromKeychain() throws -> CredentialEnvelope? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "gemini-cli-oauth",
      kSecAttrAccount as String: "main-account",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw ClientError.keychainAccess(status) }
    guard let data = item as? Data else { throw ClientError.malformedCredential }

    do {
      let envelope = try JSONDecoder().decode(CredentialEnvelope.self, from: data)
      return envelope
    } catch {
      throw ClientError.malformedCredential
    }
  }

  private func fetchCredentialFromPlaintextFile() -> CredentialEnvelope? {
    let fm = FileManager.default
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let paths = [
      home.appendingPathComponent(".gemini/mcp-oauth-tokens-v2.json"),
      home.appendingPathComponent(".gemini/mcp-oauth-tokens.json"),
      home.appendingPathComponent(".gemini/oauth_creds.json")
    ]

    for url in paths {
      guard fm.fileExists(atPath: url.path) else { continue }
      if let data = try? Data(contentsOf: url) {
        // Try OAuthCredentials shape first
        if let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data) {
          return envelope
        }
        // Try legacy google creds
        if let legacy = try? JSONDecoder().decode(OAuthFile.self, from: data),
          let token = legacy.access_token
        {
          let expires = legacy.expiry_date
          let tokenObj = CredentialEnvelope.Token(
            accessToken: token,
            refreshToken: nil,
            expiresAt: expires,
            tokenType: "Bearer"
          )
          return CredentialEnvelope(serverName: "legacy", token: tokenObj, updatedAt: nil)
        }
      }
    }
    return nil
  }

  // MARK: - Network

  private func resolveProjectId(token: String) async throws -> String? {
    let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
      ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]

    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
    else {
      return envProject
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10

    var metadata: [String: String] = [
      "ideType": "IDE_UNSPECIFIED",
      "platform": "PLATFORM_UNSPECIFIED",
      "pluginType": "GEMINI"
    ]
    if let env = envProject, !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      metadata["duetProject"] = env
    }

    var body: [String: Any] = ["metadata": metadata]
    if let env = envProject, !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body["cloudaicompanionProject"] = env
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { return envProject }
    guard (200..<300).contains(http.statusCode) else { throw ClientError.requestFailed(http.statusCode) }

    if let parsed = try? JSONDecoder().decode(LoadProjectResponse.self, from: data) {
      if let id = parsed.cloudaicompanionProjectId, !id.isEmpty { return id }
      if let name = parsed.project?.name, !name.isEmpty { return name }
      if let id = parsed.project?.id, !id.isEmpty { return id }
    }

    return envProject
  }

  private func retrieveQuota(token: String, projectId: String?) async throws -> [GeminiUsageStatus.Bucket] {
    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
      return []
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 10

    var body: [String: Any] = [:]
    if let projectId, !projectId.isEmpty {
      body["project"] = projectId
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ClientError.requestFailed(-1) }
    guard (200..<300).contains(http.statusCode) else { throw ClientError.requestFailed(http.statusCode) }

    guard let payload = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
      throw ClientError.decodingFailed
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let buckets: [GeminiUsageStatus.Bucket] = (payload.buckets ?? []).map { bucket in
      let reset: Date? = bucket.resetTime.flatMap { formatter.date(from: $0) }
      return GeminiUsageStatus.Bucket(
        modelId: bucket.modelId,
        tokenType: bucket.tokenType,
        remainingFraction: bucket.remainingFraction,
        remainingAmount: bucket.remainingAmount,
        resetTime: reset
      )
    }
    return buckets
  }

  private func userAgent() -> String {
    let version = Bundle.main.shortVersionString
    let platform = ProcessInfo.processInfo.operatingSystemVersionString
    return "CodMate/\(version) (\(platform))"
  }
}
