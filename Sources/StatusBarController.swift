import AppKit
import SwiftUI
import ServiceManagement

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var rateLimitService: RateLimitService
    private var currentInfo: RateLimitInfo?
    private var updateTimer: Timer?
    private var lastError: String?
    private var eventMonitor: Any?

    override init() {
        self.rateLimitService = RateLimitService()
        super.init()
        setupStatusBar()
        setupPopover()
        startPeriodicUpdates()
        fetchRateLimit()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusBarDisplay(percentage: nil, color: .gray)
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 200)
        popover.behavior = .transient
        popover.animates = true
    }

    private func updateStatusBarDisplay(percentage: Int?, color: NSColor) {
        guard let button = statusItem.button else { return }

        let batteryIcon = createBatteryIcon(percentage: percentage, color: color)
        button.image = batteryIcon

        if let pct = percentage {
            button.title = " \(pct)%"
        } else {
            button.title = " --%"
        }
    }

    private func createBatteryIcon(percentage: Int?, color: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            // 電池の外枠
            let bodyRect = NSRect(x: 0, y: 1, width: 18, height: 10)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2, yRadius: 2)
            NSColor.gray.setStroke()
            bodyPath.lineWidth = 1.0
            bodyPath.stroke()

            // 電池の端子
            let terminalRect = NSRect(x: 18, y: 3, width: 3, height: 6)
            let terminalPath = NSBezierPath(roundedRect: terminalRect, xRadius: 1, yRadius: 1)
            NSColor.gray.setFill()
            terminalPath.fill()

            // 充電レベル
            if let pct = percentage, pct > 0 {
                let fillWidth = CGFloat(pct) / 100.0 * 15.0
                let fillRect = NSRect(x: 2, y: 3, width: fillWidth, height: 6)
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1)
                color.setFill()
                fillPath.fill()
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        let contentView = PopoverContentView(
            rateLimitInfo: currentInfo,
            lastError: lastError,
            planName: rateLimitService.getPlanName(),
            onRefresh: { [weak self] in
                self?.fetchRateLimit()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )

        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // ポップオーバー外クリックで閉じる
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func startPeriodicUpdates() {
        // 1分ごとに更新
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchRateLimit()
        }
    }

    private func fetchRateLimit() {
        Task {
            do {
                let info = try await rateLimitService.fetchRateLimitInfo()
                await MainActor.run {
                    self.currentInfo = info
                    self.lastError = nil
                    self.updateStatusBarDisplay(
                        percentage: info.displayPercentage,
                        color: info.batteryColor.nsColor
                    )
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.updateStatusBarDisplay(percentage: nil, color: .gray)
                }
            }
        }
    }

    deinit {
        updateTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Login Item Manager

class LoginItemManager: ObservableObject {
    @Published var isEnabled: Bool

    init() {
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            print("Failed to set login item: \(error)")
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Popover Content View

struct PopoverContentView: View {
    let rateLimitInfo: RateLimitInfo?
    let lastError: String?
    let planName: String
    let onRefresh: () -> Void
    let onQuit: () -> Void
    @StateObject private var loginItemManager = LoginItemManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ヘッダー
            HStack {
                Text("Claude Token Battery")
                    .font(.headline)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            if let error = lastError {
                // エラー表示
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Error")
                            .font(.subheadline.bold())
                    }
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let info = rateLimitInfo {
                // Rate Limit 情報表示
                VStack(alignment: .leading, spacing: 10) {
                    // トークン残量
                    BatteryGaugeView(
                        title: "5時間トークン制限",
                        percentage: info.displayPercentage,
                        remaining: info.tokensRemaining,
                        limit: info.tokensLimit,
                        resetDate: info.tokensReset,
                        color: info.batteryColor.color
                    )

                    Divider()

                    // リセット時間
                    HStack {
                        Text("リセット時刻:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatResetTime(info.tokensReset))
                            .font(.caption.monospacedDigit())
                    }
                }
            } else {
                // 読み込み中
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("読み込み中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // ログイン時に起動
            Toggle(isOn: Binding(
                get: { loginItemManager.isEnabled },
                set: { loginItemManager.setEnabled($0) }
            )) {
                Text("ログイン時に起動")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            Divider()

            // フッター
            HStack {
                Text("Claude \(planName)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("終了") {
                    onQuit()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding()
        .frame(width: 260)
    }

    private func formatResetTime(_ date: Date) -> String {
        // 時間の最大値に丸める (14:56:23 -> 14:59:59)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour], from: date)
        var roundedComponents = DateComponents()
        roundedComponents.hour = components.hour
        roundedComponents.minute = 59
        roundedComponents.second = 59

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone.current

        if let roundedDate = calendar.date(from: roundedComponents) {
            return formatter.string(from: roundedDate)
        }
        return formatter.string(from: date)
    }
}

// MARK: - Battery Gauge View

struct BatteryGaugeView: View {
    let title: String
    let percentage: Int
    let remaining: Int
    let limit: Int
    let resetDate: Date
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text("\(percentage)%")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundColor(color)
            }

            // プログレスバー
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100, height: 8)
                }
            }
            .frame(height: 8)

            HStack {
                Text(formatTokens(remaining))
                    .font(.caption2.monospacedDigit())
                Text("/")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(formatTokens(limit))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - BatteryColor Extension

extension BatteryColor {
    var color: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}
