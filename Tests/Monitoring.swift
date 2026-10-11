import AppKit
import Foundation

final class QueryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failing = false
    private var responseOverride: QuotaResponse?
    private var pendingGate: DispatchSemaphore?
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func respond(_ value: QuotaResponse?) { lock.lock(); responseOverride = value; lock.unlock() }
    func fail(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func blockNext(_ gate: DispatchSemaphore) { lock.lock(); pendingGate = gate; lock.unlock() }
    func fetch() throws -> QuotaResponse {
        lock.lock()
        calls += 1
        let gate = pendingGate; pendingGate = nil
        let shouldFail = failing
        let response = responseOverride
        lock.unlock()
        if let gate { _ = gate.wait(timeout: .now() + 5) }
        if shouldFail { throw QuotaError.queryFailed }
        if let response { return response }
        return QuotaResponse(rateLimits: QuotaBucket(limitId: "codex", planType: "pro",
            primary: QuotaWindow(usedPercent: 30, windowDurationMins: 10080,
                resetsAt: Date().addingTimeInterval(86400).timeIntervalSince1970), secondary: nil), rateLimitsByLimitId: nil)
    }
}

@main
struct MonitoringTests {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        precondition(value(), name)
        print("PASS: \(name)")
    }
    @MainActor static func waitFor(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out waiting for synthetic query")
    }
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--live") {
            guard let executable = QuotaModel.locateCodex() else { preconditionFailure("Codex executable unavailable") }
            do {
                let response = try CodexClient().fetch(executable: executable)
                check(response.codex?.window(for: .weekly)?.remaining != nil || response.codex?.window(for: .fiveHour)?.remaining != nil,
                      "live quota query uses production executable resolution")
            } catch { preconditionFailure("Live quota query failed: \(error)") }
        }
        let app = URL(fileURLWithPath: "/synthetic/ChatGPT.app")
        let modern = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let legacy = app.appendingPathComponent("Contents/Resources/codex")
        let cli = URL(fileURLWithPath: "/synthetic/bin/codex")
        for (available, expected) in [([modern], modern), ([legacy], legacy), ([modern, legacy], modern), ([cli], cli)] {
            check(QuotaModel.locateCodex(in: [app], cliCandidates: [cli], isExecutable: { available.contains($0) }) == expected,
                  "resolve supported Codex layout: \(expected.lastPathComponent), modern=\(expected == modern)")
        }
        check(QuotaModel.locateCodex(in: [app], cliCandidates: [cli], isExecutable: { _ in false }) == nil,
              "missing executable does not resolve a nonexistent path")
        let domain = "local.codexquota.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set("weekly", forKey: "displayPeriod")
        preferences.set(true, forKey: "startupChoiceMade")
        let fixture = QueryFixture()
        var time = Date()
        func makeModel() -> QuotaModel {
            QuotaModel(preferences: preferences, clock: { time },
                resolveExecutable: { URL(fileURLWithPath: "/synthetic/codex") },
                fetchQuota: { _, _ in try fixture.fetch() })
        }
        let model = makeModel()
        model.start(); model.refresh(); model.refreshAutomatically()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(!model.monitoringAllowed && fixture.count == 0, "legacy preferences do not consent; launch, manual and wake cannot query")
        model.allowMonitoring()
        await waitFor { !model.loading }
        check(fixture.count == 1 && model.bucket != nil, "explicit consent starts query")
        check(preferences.bool(forKey: "monitoringConsentV1"), "consent persists")
        model.refresh()
        check(fixture.count == 1 && !model.loading, "manual refresh is rate limited")
        time = time.addingTimeInterval(11)
        model.refresh()
        await waitFor { !model.loading }
        check(fixture.count == 2, "manual refresh resumes after cooldown")

        let gate = DispatchSemaphore(value: 0)
        fixture.blockNext(gate)
        time = time.addingTimeInterval(11)
        model.refresh()
        await waitFor { fixture.count == 3 }
        model.withdrawMonitoring()
        check(!model.loading && model.bucket == nil && model.lastUpdated == nil, "withdrawal clears data and active state")
        gate.signal()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(model.bucket == nil && !model.monitoringAllowed, "late response cannot restore withdrawn data")
        model.refresh(); model.refreshAutomatically()
        let reopened = makeModel()
        reopened.start()
        check(!reopened.monitoringAllowed && fixture.count == 3, "withdrawal persists across restart and blocks refresh")

        fixture.fail(true)
        reopened.allowMonitoring()
        await waitFor { !reopened.loading }
        check(fixture.count == 4 && reopened.errorMessage != nil, "query failure is visible")
        check(reopened.quotaDetail(for: .weekly).contains("不代表额度已用完") && reopened.retryText != nil, "query failure is distinct from an absent quota window and includes retry status")
        for (index, delay) in [30.0, 60, 120, 240, 300, 300].enumerated() {
            let previous = fixture.count
            time = time.addingTimeInterval(delay - 1)
            reopened.refreshAutomatically()
            check(fixture.count == previous && !reopened.loading, "automatic backoff blocks early attempt \(index)")
            time = time.addingTimeInterval(1)
            reopened.refreshAutomatically()
            await waitFor { !reopened.loading }
            check(fixture.count == previous + 1, "automatic retry at backoff boundary \(index)")
        }
        fixture.fail(false)
        time = time.addingTimeInterval(300)
        reopened.refreshAutomatically()
        await waitFor { !reopened.loading }
        check(reopened.displayRemaining == 70 && reopened.retryText == nil, "automatic retry restores valid quota without manual action")
        check(reopened.quotaDetail(for: .fiveHour) == "当前未返回此周期额度", "successful query with absent window stays distinct from transport failure")
        let recoveredCount = fixture.count
        time = time.addingTimeInterval(300)
        reopened.refreshAutomatically()
        await waitFor { !reopened.loading }
        check(fixture.count == recoveredCount + 1 && reopened.errorMessage == nil, "success restores five-minute schedule")
        // Syntactically successful RPCs must not postpone recovery for five minutes.
        let successDate = reopened.lastUpdated
        for response in [
            QuotaResponse(rateLimits: nil, rateLimitsByLimitId: nil),
            QuotaResponse(rateLimits: QuotaBucket(limitId: "codex", planType: "pro",
                primary: QuotaWindow(usedPercent: nil, windowDurationMins: 10080, resetsAt: nil), secondary: nil), rateLimitsByLimitId: nil),
            QuotaResponse(rateLimits: QuotaBucket(limitId: "codex", planType: "pro",
                primary: QuotaWindow(usedPercent: 30, windowDurationMins: 10080,
                    resetsAt: time.addingTimeInterval(-1).timeIntervalSince1970), secondary: nil), rateLimitsByLimitId: nil)
        ] {
            fixture.respond(response)
            time = time.addingTimeInterval(301)
            reopened.refreshAutomatically()
            await waitFor { !reopened.loading }
            check(reopened.errorMessage == QuotaError.incompleteQuota.message && reopened.lastUpdated == successDate,
                  "empty, null-usage or expired success is not marked fresh")
        }
        fixture.respond(nil)
        time = time.addingTimeInterval(40)
        reopened.refreshAutomatically()
        await waitFor { !reopened.loading }
        check(reopened.displayRemaining == 70, "incomplete responses recover automatically before five minutes")

        fixture.respond(QuotaResponse(rateLimits: QuotaBucket(limitId: "codex", planType: "pro",
            primary: QuotaWindow(usedPercent: 0, windowDurationMins: 10080,
                resetsAt: time.addingTimeInterval(50).timeIntervalSince1970), secondary: nil), rateLimitsByLimitId: nil))
        time = time.addingTimeInterval(11)
        reopened.refresh()
        await waitFor { !reopened.loading }
        check(reopened.displayRemaining == 100, "zero used remains valid")
        let beforeReset = fixture.count
        time = time.addingTimeInterval(38)
        reopened.refreshAutomatically()
        check(fixture.count == beforeReset, "do not refresh before reset deadline")
        fixture.respond(nil)
        time = time.addingTimeInterval(1)
        reopened.refreshAutomatically()
        await waitFor { !reopened.loading }
        check(fixture.count == beforeReset + 1 && reopened.displayRemaining == 70,
              "reset triggers query without waiting for regular five-minute interval")
        reopened.withdrawMonitoring()
        check(preferences.string(forKey: "displayPeriod") == "weekly" && preferences.bool(forKey: "startupChoiceMade"), "withdrawal preserves period and startup choice")
        print("PASS: privacy gate, late response isolation, restart, cooldown and backoff")
    }
}
