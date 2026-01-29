import Foundation

class RateLimitService {
    private let claudeDir: String
    private var cachedCredentials: ClaudeCredentials?
    private let dateFormatter: ISO8601DateFormatter
    private let logFile: URL

    // 2026年1月時点の実測値ベースの上限
    private let planLimits: [String: Int] = [
        "20x": 150_000,  // 推定（元220K）
        "5x": 60_000,    // 実測ベース（元88K）
        "pro": 30_000    // 推定（元44K）
    ]

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeDir = "\(homeDir)/.claude"
        self.logFile = URL(fileURLWithPath: "/tmp/claude-battery-debug.log")

        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        log("RateLimitService initialized")
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    func loadCredentials() throws -> ClaudeCredentials {
        if let cached = cachedCredentials {
            return cached
        }

        let url = URL(fileURLWithPath: "\(claudeDir)/.credentials.json")
        let data = try Data(contentsOf: url)
        let credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
        cachedCredentials = credentials
        return credentials
    }

    func getTokenLimit() -> Int {
        guard let credentials = try? loadCredentials(),
              let tier = credentials.claudeAiOauth.rateLimitTier?.lowercased() else {
            return 88_000
        }

        for (key, limit) in planLimits {
            if tier.contains(key) {
                return limit
            }
        }

        return 88_000
    }

    func getPlanName() -> String {
        guard let credentials = try? loadCredentials(),
              let tier = credentials.claudeAiOauth.rateLimitTier else {
            return "Max5"
        }

        if tier.contains("20x") { return "Max20" }
        if tier.contains("5x") { return "Max5" }
        if tier.lowercased().contains("pro") { return "Pro" }
        return "Max"
    }

    func fetchRateLimitInfo() async throws -> RateLimitInfo {
        let fiveHoursAgo = Date().addingTimeInterval(-5 * 60 * 60)
        log("Starting calculateUsage since: \(fiveHoursAgo)")
        let (tokensUsed, earliestTime) = calculateUsage(since: fiveHoursAgo)
        log("tokensUsed: \(tokensUsed), earliestTime: \(String(describing: earliestTime))")
        let tokenLimit = getTokenLimit()
        let tokensRemaining = max(0, tokenLimit - tokensUsed)
        let resetDate = earliestTime?.addingTimeInterval(5 * 60 * 60) ?? Date().addingTimeInterval(5 * 60 * 60)
        log("tokenLimit: \(tokenLimit), tokensRemaining: \(tokensRemaining)")

        return RateLimitInfo(
            tokensLimit: tokenLimit,
            tokensRemaining: tokensRemaining,
            tokensReset: resetDate,
            requestsLimit: 0,
            requestsRemaining: 0,
            requestsReset: Date()
        )
    }

    private func calculateUsage(since startDate: Date) -> (tokens: Int, earliestTime: Date?) {
        var totalTokens = 0
        var earliestTime: Date?
        let projectsDir = "\(claudeDir)/projects"
        log("projectsDir: \(projectsDir)")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            log("Failed to read projects directory")
            return (0, nil)
        }
        log("Found \(projectDirs.count) project directories")

        for projectDir in projectDirs where !projectDir.hasPrefix(".") {
            let projectPath = "\(projectsDir)/\(projectDir)"
            processDirectory(projectPath, since: startDate, tokens: &totalTokens, earliest: &earliestTime)
        }
        log("After processing: totalTokens=\(totalTokens)")

        return (totalTokens, earliestTime)
    }

    private func processDirectory(_ dirPath: String, since startDate: Date, tokens: inout Int, earliest: inout Date?) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }

        var filesProcessed = 0
        for item in items {
            let itemPath = "\(dirPath)/\(item)"
            var isDir: ObjCBool = false

            if FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    processDirectory(itemPath, since: startDate, tokens: &tokens, earliest: &earliest)
                } else if item.hasSuffix(".jsonl") {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: itemPath),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate >= startDate {
                        filesProcessed += 1
                        let (fileTokens, fileEarliest) = parseFile(itemPath, since: startDate)
                        if fileTokens > 0 {
                            log("File \(item): \(fileTokens) tokens")
                        }
                        tokens += fileTokens
                        if let fe = fileEarliest {
                            if earliest == nil || fe < earliest! {
                                earliest = fe
                            }
                        }
                    }
                }
            }
        }
        if filesProcessed > 0 {
            log("Processed \(filesProcessed) files in \(dirPath.components(separatedBy: "/").last ?? "")")
        }
    }

    private func parseFile(_ path: String, since startDate: Date) -> (tokens: Int, earliest: Date?) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (0, nil)
        }

        var totalTokens = 0
        var earliest: Date?
        var processedUUIDs = Set<String>()

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestampStr = json["timestamp"] as? String,
                  let timestamp = dateFormatter.date(from: timestampStr),
                  timestamp >= startDate else {
                continue
            }

            // 最も早いタイムスタンプを記録
            if earliest == nil || timestamp < earliest! {
                earliest = timestamp
            }

            // usageを処理（UUIDで重複を避ける）
            if let uuid = json["uuid"] as? String,
               let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               !processedUUIDs.contains(uuid) {

                processedUUIDs.insert(uuid)

                // Rate limitはinput_tokens + output_tokensでカウント
                var tokens = 0
                if let input = usage["input_tokens"] as? Int { tokens += input }
                if let output = usage["output_tokens"] as? Int { tokens += output }
                totalTokens += tokens
            }
        }

        return (totalTokens, earliest)
    }
}

enum RateLimitError: Error, LocalizedError {
    case invalidResponse
    case credentialsNotFound
    case parsingError

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .credentialsNotFound: return "Claude credentials not found"
        case .parsingError: return "Failed to parse usage data"
        }
    }
}
