import AppKit
import Combine
import ServiceManagement

@MainActor
final class QuotaModel: ObservableObject {
    @Published var bucket: QuotaBucket?
    @Published var selected: QuotaPeriod
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var now = Date()
    @Published var startupChosen: Bool
    @Published private(set) var monitoringAllowed: Bool
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var loginError: String?
    let demo: Bool
    private var hasSelected: Bool
    private var timer: Timer?
    private var client: CodexClient?
    private var nextRefresh = Date.distantPast
    private var nextManualRefresh = Date.distantPast
    private var failures = 0
    private var generation = 0
    private let preferences: UserDefaults
    private let clock: () -> Date
    private let resolveExecutable: (() -> URL?)?
    private let fetchQuota: @Sendable (CodexClient, URL) throws -> QuotaResponse

    init(demo: Bool = false, samplePeriod: QuotaPeriod = .weekly, welcome: Bool = false,
         preferences: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         resolveExecutable: (() -> URL?)? = nil,
         fetchQuota: @escaping @Sendable (CodexClient, URL) throws -> QuotaResponse = { try $0.fetch(executable: $1) }) {
        self.demo = demo
        self.preferences = preferences
        self.clock = clock
        self.resolveExecutable = resolveExecutable
        self.fetchQuota = fetchQuota
        monitoringAllowed = demo || preferences.bool(forKey: "monitoringConsentV1")
        let saved = demo ? nil : preferences.string(forKey: "displayPeriod")
        selected = saved.flatMap(QuotaPeriod.init(rawValue:)) ?? samplePeriod
        hasSelected = saved != nil
        startupChosen = demo ? !welcome : preferences.bool(forKey: "startupChoiceMade")
        if demo {
            let future = Date().addingTimeInterval(60 * 60 * 48)
            bucket = QuotaBucket(limitId: "codex", planType: "pro",
                primary: QuotaWindow(usedPercent: 18, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(11520).timeIntervalSince1970),
                secondary: QuotaWindow(usedPercent: 36, windowDurationMins: 10080, resetsAt: future.timeIntervalSince1970))
            lastUpdated = Date()
        } else { syncLoginStatus() }
    }

    var selectedWindow: QuotaWindow? { bucket?.window(for: selected) }
    var canRefresh: Bool { monitoringAllowed && !loading && (demo || clock() >= nextManualRefresh) }
    var isStale: Bool { lastUpdated.map { now.timeIntervalSince($0) > 360 } ?? true }
    var displayRemaining: Int? {
        guard monitoringAllowed, errorMessage == nil, !isStale, let window = selectedWindow, !window.hasElapsed(at: now) else { return nil }
        return window.remaining
    }
    var menuTitle: String { displayRemaining.map { "\($0)%" } ?? (loading && bucket == nil ? "···" : "—") }
    var accessibleSummary: String {
        "Codex · \(selected.title)" + (displayRemaining.map { "剩余 \($0)%" } ?? "额度暂不可用")
    }
    var updateText: String {
        guard let lastUpdated else { return loading ? "正在查询额度…" : "尚未成功更新" }
        let minutes = max(0, Int(now.timeIntervalSince(lastUpdated) / 60))
        return (errorMessage != nil || isStale ? "上次成功：" : "") + (minutes < 1 ? "刚刚更新" : "\(minutes) 分钟前更新")
    }

    func start() {
        guard !demo, monitoringAllowed, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = self.clock()
                if self.now >= self.nextRefresh { self.refreshAutomatically() }
            }
        }
        timer?.tolerance = 5
    }

    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        client?.cancel(); client = nil
        loading = false
    }

    func allowMonitoring() {
        monitoringAllowed = true
        if !demo { preferences.set(true, forKey: "monitoringConsentV1") }
        nextRefresh = .distantPast; nextManualRefresh = .distantPast; failures = 0
        start()
    }

    func withdrawMonitoring() {
        monitoringAllowed = false
        if !demo { preferences.set(false, forKey: "monitoringConsentV1") }
        stop()
        bucket = nil; lastUpdated = nil; errorMessage = nil
    }

    func openPrivacy() {
        if let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshAutomatically() {
        guard clock() >= nextRefresh else { return }
        refresh()
    }

    private func scheduleFailure() {
        failures = min(failures + 1, 4)
        nextRefresh = clock().addingTimeInterval(min(1800, 300 * pow(2, Double(failures - 1))))
    }

    func choose(_ period: QuotaPeriod) {
        selected = period
        hasSelected = true
        if !demo { preferences.set(period.rawValue, forKey: "displayPeriod") }
    }

    static func locateCodex() -> URL? {
        // Resolve only the official application and standard CLI locations.
        var candidates: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex"))
        }
        candidates += ["/Applications/ChatGPT.app/Contents/Resources/codex",
                       "/Applications/Codex.app/Contents/Resources/codex",
                       "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func refresh() {
        guard monitoringAllowed, !loading else { return }
        now = clock()
        if demo { lastUpdated = now; return }
        guard now >= nextManualRefresh else { return }
        nextManualRefresh = now.addingTimeInterval(10)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.objectWillChange.send()
        }
        nextRefresh = now.addingTimeInterval(300)
        let executable = resolveExecutable.map { $0() } ?? Self.locateCodex()
        guard let executable else {
            bucket = nil; errorMessage = QuotaError.missingCodex.message; scheduleFailure(); return
        }
        loading = true
        let request = CodexClient()
        client = request
        let queryGeneration = generation
        let fetchQuota = self.fetchQuota
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try fetchQuota(request, executable) }
            DispatchQueue.main.async {
                guard let self, self.monitoringAllowed, self.generation == queryGeneration else { return }
                self.loading = false
                self.client = nil
                self.now = self.clock()
                switch result {
                case .success(let response):
                    self.failures = 0
                    self.nextRefresh = self.now.addingTimeInterval(300)
                    self.bucket = response.codex
                    self.lastUpdated = self.now
                    self.errorMessage = nil
                    if !self.hasSelected, let bucket = response.codex {
                        self.choose(bucket.initialPeriod)
                    }
                case .failure(let error):
                    self.scheduleFailure()
                    self.bucket = nil
                    self.errorMessage = (error as? QuotaError ?? .queryFailed).message
                }
            }
        }
    }

    func syncLoginStatus() {
        guard !demo else { return }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginNeedsApproval = status == .requiresApproval
    }

    func chooseStartup(_ enabled: Bool) {
        if demo { loginEnabled = enabled; startupChosen = true; return }
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            startupChosen = true
            preferences.set(true, forKey: "startupChoiceMade")
        } catch {
            loginError = "未能更改启动设置，可在系统设置的「登录项」中调整。"
        }
        syncLoginStatus()
    }

    func openLoginSettings() {
        guard !demo else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
