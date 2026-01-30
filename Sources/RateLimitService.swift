import Foundation

// MARK: - Settings Manager

class SettingsManager {
    static let shared = SettingsManager()

    private let settingsFile: URL
    private var settings: [String: Any] = [:]

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        settingsFile = homeDir.appendingPathComponent(".claude-token-battery.json")
        loadSettings()
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        settings = json
    }

    private func saveSettings() {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) else {
            return
        }
        try? data.write(to: settingsFile)
    }

    /// リセット時刻（JST時、0-23）を取得。未設定の場合はnil
    var resetHourJST: Int? {
        get { settings["resetHourJST"] as? Int }
        set {
            if let hour = newValue {
                settings["resetHourJST"] = hour
            } else {
                settings.removeValue(forKey: "resetHourJST")
            }
            saveSettings()
        }
    }
}

// MARK: - RateLimitService

class RateLimitService {
    private let claudeDir: String
    private var cachedCredentials: ClaudeCredentials?
    private let dateFormatter: ISO8601DateFormatter
    private let logFile: URL

    // Claude-Code-Usage-Monitor の値を参考
    // https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor
    private let planLimits: [String: Int] = [
        "20x": 220_000,  // Max20
        "5x": 88_000,    // Max5
        "pro": 19_000    // Pro
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
        let (blockStart, blockEnd) = getCurrentBlock()
        log("Current block (JST): \(blockStart) - \(blockEnd)")
        let (tokensUsed, _) = calculateUsage(since: blockStart)
        log("tokensUsed: \(tokensUsed)")
        let tokenLimit = getTokenLimit()
        let tokensRemaining = max(0, tokenLimit - tokensUsed)
        log("tokenLimit: \(tokenLimit), tokensRemaining: \(tokensRemaining)")

        return RateLimitInfo(
            tokensLimit: tokenLimit,
            tokensRemaining: tokensRemaining,
            tokensReset: blockEnd,
            requestsLimit: 0,
            requestsRemaining: 0,
            requestsReset: Date()
        )
    }

    /// 現在の5時間ブロックを算出
    /// 1. ユーザー設定のリセット時刻があればそれを使用
    /// 2. なければログから推測
    private func getCurrentBlock() -> (start: Date, end: Date) {
        let now = Date()

        // ユーザー設定のリセット時刻を優先
        if let configuredHour = SettingsManager.shared.resetHourJST {
            return calculateBlockFromResetHour(configuredHour, now: now)
        }

        // ログから推測
        if let blockStart = detectCurrentBlockStart() {
            let blockEnd = blockStart.addingTimeInterval(5 * 60 * 60)
            if now >= blockStart && now < blockEnd {
                return (blockStart, blockEnd)
            }
            if now >= blockEnd {
                let newBlockStart = roundToHour(now)
                return (newBlockStart, newBlockStart.addingTimeInterval(5 * 60 * 60))
            }
        }

        // フォールバック: 現在時刻を正時に丸めてブロック開始
        let blockStart = roundToHour(now)
        let blockEnd = blockStart.addingTimeInterval(5 * 60 * 60)
        return (blockStart, blockEnd)
    }

    /// 設定されたリセット時刻（JST）からブロックを計算
    private func calculateBlockFromResetHour(_ resetHourJST: Int, now: Date) -> (start: Date, end: Date) {
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jst

        var components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        let currentHour = components.hour ?? 0

        // リセット時刻を基準に5時間ブロックの境界を計算
        // 例: resetHour=8 なら 3,8,13,18,23 がリセット時刻
        let resetHours = (0..<5).map { (resetHourJST + $0 * 5) % 24 }.sorted()

        // 現在のブロック開始時刻を見つける
        let blockStartHour = resetHours.last { $0 <= currentHour } ?? resetHours.last!

        components.hour = blockStartHour
        components.minute = 0
        components.second = 0

        // 前日のブロックの場合
        if blockStartHour > currentHour {
            components.day = (components.day ?? 1) - 1
        }

        let blockStart = calendar.date(from: components)!
        let blockEnd = blockStart.addingTimeInterval(5 * 60 * 60)

        return (blockStart, blockEnd)
    }

    /// 現在のブロック開始時刻（JST）を取得
    func getCurrentBlockStartHourJST() -> Int {
        let (blockStart, _) = getCurrentBlock()
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jst
        return calendar.component(.hour, from: blockStart)
    }

    /// タイムスタンプを最も近い正時（UTC）に丸める
    private func roundToHour(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? date
    }

    /// ログから現在のブロック開始時刻を検出
    private func detectCurrentBlockStart() -> Date? {
        let projectsDir = "\(claudeDir)/projects"
        var allTimestamps: [Date] = []

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return nil
        }

        // 直近24時間のタイムスタンプを収集
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        for projectDir in projectDirs where !projectDir.hasPrefix(".") {
            let projectPath = "\(projectsDir)/\(projectDir)"
            collectTimestamps(from: projectPath, since: cutoff, into: &allTimestamps)
        }

        guard !allTimestamps.isEmpty else { return nil }

        // タイムスタンプをソート
        allTimestamps.sort()

        // 5時間以上のギャップを見つけてブロック境界を検出
        let fiveHours: TimeInterval = 5 * 60 * 60
        var blockStart = roundToHour(allTimestamps[0])

        for i in 1..<allTimestamps.count {
            let gap = allTimestamps[i].timeIntervalSince(allTimestamps[i-1])
            let blockEnd = blockStart.addingTimeInterval(fiveHours)

            // ギャップが5時間以上、またはエントリがブロック終了を超えた場合
            if gap >= fiveHours || allTimestamps[i] >= blockEnd {
                blockStart = roundToHour(allTimestamps[i])
            }
        }

        return blockStart
    }

    /// ディレクトリからタイムスタンプを収集
    private func collectTimestamps(from dirPath: String, since cutoff: Date, into timestamps: inout [Date]) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }

        for item in items {
            let itemPath = "\(dirPath)/\(item)"
            var isDir: ObjCBool = false

            if FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    collectTimestamps(from: itemPath, since: cutoff, into: &timestamps)
                } else if item.hasSuffix(".jsonl") {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: itemPath),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate >= cutoff {
                        extractTimestamps(from: itemPath, since: cutoff, into: &timestamps)
                    }
                }
            }
        }
    }

    /// ファイルからタイムスタンプを抽出
    private func extractTimestamps(from path: String, since cutoff: Date, into timestamps: inout [Date]) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestampStr = json["timestamp"] as? String,
                  let timestamp = dateFormatter.date(from: timestampStr),
                  timestamp >= cutoff else {
                continue
            }
            timestamps.append(timestamp)
        }
    }

    private func calculateUsage(since startDate: Date) -> (tokens: Int, earliestTime: Date?) {
        var totalTokens = 0
        var earliestTime: Date?
        var globalProcessedUUIDs = Set<String>()  // グローバルでUUID重複排除
        let projectsDir = "\(claudeDir)/projects"
        log("projectsDir: \(projectsDir)")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            log("Failed to read projects directory")
            return (0, nil)
        }
        log("Found \(projectDirs.count) project directories")

        for projectDir in projectDirs where !projectDir.hasPrefix(".") {
            let projectPath = "\(projectsDir)/\(projectDir)"
            processDirectory(projectPath, since: startDate, tokens: &totalTokens, earliest: &earliestTime, processedUUIDs: &globalProcessedUUIDs)
        }
        log("After processing: totalTokens=\(totalTokens), uniqueEntries=\(globalProcessedUUIDs.count)")

        return (totalTokens, earliestTime)
    }

    private func processDirectory(_ dirPath: String, since startDate: Date, tokens: inout Int, earliest: inout Date?, processedUUIDs: inout Set<String>) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }

        var filesProcessed = 0
        for item in items {
            let itemPath = "\(dirPath)/\(item)"
            var isDir: ObjCBool = false

            if FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    processDirectory(itemPath, since: startDate, tokens: &tokens, earliest: &earliest, processedUUIDs: &processedUUIDs)
                } else if item.hasSuffix(".jsonl") {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: itemPath),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate >= startDate {
                        filesProcessed += 1
                        let (fileTokens, fileEarliest) = parseFile(itemPath, since: startDate, processedUUIDs: &processedUUIDs)
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

    private func parseFile(_ path: String, since startDate: Date, processedUUIDs: inout Set<String>) -> (tokens: Int, earliest: Date?) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (0, nil)
        }

        var totalTokens = 0
        var earliest: Date?

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

            // usageを処理（グローバルUUIDで重複を避ける）
            if let uuid = json["uuid"] as? String,
               let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               !processedUUIDs.contains(uuid) {

                processedUUIDs.insert(uuid)

                // Rate limitにカウントされるトークン:
                // - input_tokens: 入力トークン
                // - output_tokens: 出力トークン
                //
                // 以下はrate limitにはカウントされない（実測による推定）:
                // - cache_creation_input_tokens: キャッシュ作成トークン
                // - cache_read_input_tokens: キャッシュ読み込みトークン
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
