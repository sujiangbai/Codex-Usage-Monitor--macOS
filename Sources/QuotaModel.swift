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
    private var refreshTimer: Timer?
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

    var retryText: String? {
        guard monitoringAllowed, errorMessage != nil else { return nil }
        if loading { return "正在重新查询…" }
        let seconds = max(0, Int(ceil(nextRefresh.timeIntervalSince(now))))
        if seconds <= 0 { return "即将自动重试，也可点右上角刷新" }
        return seconds < 60 ? "约 \(seconds) 秒后自动重试" : "约 \(Int(ceil(Double(seconds) / 60))) 分钟后自动重试"
    }

    func quotaDetail(for period: QuotaPeriod) -> String {
        if loading && bucket == nil { return "正在查询…" }
        if errorMessage != nil { return "暂未取得有效额度，不代表额度已用完" }
        if let window = bucket?.window(for: period) { return resetDescription(window, now: now) }
        return lastUpdated == nil ? "等待查询额度" : "当前未返回此周期额度"
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
        refreshTimer?.invalidate(); refreshTimer = nil
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

    private func scheduleRefresh(at date: Date) {
        nextRefresh = date
        refreshTimer?.invalidate()
        guard !demo, monitoringAllowed else { return }
        let timer = Timer(timeInterval: max(0.1, date.timeIntervalSince(clock())), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshAutomatically() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleSuccess() {
        var deadline = max((lastUpdated ?? clock()).addingTimeInterval(300), nextManualRefresh)
        if let reset = selectedWindow?.resetDate {
            deadline = min(deadline, max(reset, nextManualRefresh))
        }
        scheduleRefresh(at: deadline)
    }

    private func scheduleFailure(_ error: QuotaError) {
        failures = min(failures + 1, 6)
        // Recover promptly from transient failures; avoid frequent auth/permission retries.
        let base: Double = error == .incompleteQuota ? 10 : 30
        let delay = max(error.retryFloor, min(300, base * pow(2, Double(failures - 1))))
        scheduleRefresh(at: clock().addingTimeInterval(delay))
    }

    func choose(_ period: QuotaPeriod) {
        selected = period
        hasSelected = true
        if !demo { preferences.set(period.rawValue, forKey: "displayPeriod") }
        if lastUpdated != nil, errorMessage == nil, !loading { scheduleSuccess() }
    }

    static func locateCodex() -> URL? {
        var applications: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            applications.append(app)
        }
        applications += ["/Applications/ChatGPT.app", "/Applications/Codex.app"].map { URL(fileURLWithPath: $0) }
        return locateCodex(in: applications,
            cliCandidates: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map { URL(fileURLWithPath: $0) })
    }

    static func locateCodex(in applications: [URL], cliCandidates: [URL],
                            isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> URL? {
        // New packaged entrypoint prepares the CLI resources before exec; keep the legacy layout.
        let layouts = ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"]
        let candidates = applications.flatMap { app in layouts.map { app.appendingPathComponent($0) } } + cliCandidates
        return candidates.first(where: isExecutable)
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
        refreshTimer?.invalidate(); refreshTimer = nil
        nextRefresh = now.addingTimeInterval(300)
        let executable = resolveExecutable.map { $0() } ?? Self.locateCodex()
        guard let executable else {
            bucket = nil; errorMessage = QuotaError.missingCodex.message; scheduleFailure(.missingCodex); return
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
                    let candidate = response.codex
                    let period = self.hasSelected ? self.selected : (candidate?.initialPeriod ?? self.selected)
                    let windows = QuotaPeriod.allCases.compactMap { candidate?.window(for: $0) }
                    let selectedWindow = candidate?.window(for: period)
                    // A decoded RPC result is not necessarily a usable quota snapshot.
                    // Do not stamp empty, missing-usage or pre-reset data as a successful update.
                    let hasUsableWindow = windows.contains { $0.remaining != nil && !$0.hasElapsed(at: self.now) }
                    let selectedInvalid = selectedWindow.map { $0.remaining == nil || $0.hasElapsed(at: self.now) } ?? false
                    let selectedDisappeared = selectedWindow == nil && self.bucket?.window(for: period) != nil
                    if !hasUsableWindow || selectedInvalid || selectedDisappeared {
                        self.bucket = nil
                        self.errorMessage = QuotaError.incompleteQuota.message
                        self.scheduleFailure(.incompleteQuota)
                        return
                    }
                    self.failures = 0
                    self.bucket = candidate
                    self.lastUpdated = self.now
                    self.errorMessage = nil
                    if !self.hasSelected, let bucket = response.codex {
                        self.choose(bucket.initialPeriod)
                    }
                    self.scheduleSuccess()
                case .failure(let error):
                    let classified = error as? QuotaError ?? .queryFailed
                    self.scheduleFailure(classified)
                    self.bucket = nil
                    self.errorMessage = classified.message
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
