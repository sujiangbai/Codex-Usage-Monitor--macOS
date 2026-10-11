import Foundation
import Darwin

var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: \(name)") }
    passed += 1
    print("PASS: \(name)")
}
func decode(_ text: String) throws -> QuotaResponse {
    try JSONDecoder().decode(QuotaResponse.self, from: Data(text.utf8))
}

let multi = try decode(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":16,"windowDurationMins":10080},"secondary":{"usedPercent":26,"windowDurationMins":300}},"other":{"primary":{"usedPercent":100,"windowDurationMins":10080}}}}"#)
check(multi.codex?.window(for: .weekly)?.remaining == 84, "prefer Codex bucket and actual duration over primary/secondary order")
check(multi.codex?.window(for: .fiveHour)?.remaining == 74, "future five-hour limit available without subscription branching")
check(multi.codex?.initialPeriod == .weekly, "Pro defaults to weekly")
let plus = try decode(#"{"rateLimits":{"planType":"plus","primary":{"usedPercent":20,"windowDurationMins":300}}}"#)
check(plus.codex?.initialPeriod == .fiveHour, "Plus defaults to five-hour")
check(plus.codex?.window(for: .weekly) == nil, "missing window stays unavailable")
let unrelatedMap = try decode(#"{"rateLimitsByLimitId":{"other":{}},"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300}}}"#)
check(unrelatedMap.codex == nil, "do not substitute another metered bucket")
let unrelatedLegacy = try decode(#"{"rateLimits":{"limitId":"other"}}"#)
check(unrelatedLegacy.codex == nil, "reject unrelated legacy bucket")
let unknown = try decode(#"{"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":60},"secondary":{"usedPercent":null,"windowDurationMins":10080}},"accountId":"ignore-me","rateLimitResetCredits":{"availableCount":5}}"#)
check(unknown.codex?.window(for: .fiveHour) == nil, "unknown duration is not assumed to be five-hour")
check(unknown.codex?.window(for: .weekly)?.remaining == nil, "missing usage is not zero usage")
check(QuotaWindow(usedPercent: 110, windowDurationMins: 300, resetsAt: nil).remaining == 0, "clamp exhausted quota")
check(QuotaWindow(usedPercent: -5, windowDurationMins: 300, resetsAt: nil).remaining == 100, "clamp negative usage")
check(QuotaWindow(usedPercent: 99.8, windowDurationMins: 300, resetsAt: nil).remaining == 0, "never round almost-empty quota up")
check(QuotaWindow(usedPercent: .nan, windowDurationMins: 300, resetsAt: nil).remaining == nil, "nonfinite value is unavailable")
let past = QuotaWindow(usedPercent: 70, windowDurationMins: 300, resetsAt: 100)
check(past.hasElapsed(at: Date(timeIntervalSince1970: 101)), "expired reset remains unconfirmed")
check(resetDescription(past, now: Date(timeIntervalSince1970: 101)).contains("等待刷新确认"), "do not invent quota recovery at reset time")
check(resetDescription(QuotaWindow(usedPercent: 5, windowDurationMins: 300, resetsAt: nil), now: Date()) == "重置时间暂不可用", "null reset time")

let newPlan = try decode(#"{"rateLimitsByLimitId":{"codex":{"planType":"prolite","primary":{"usedPercent":13,"windowDurationMins":10080,"resetsAt":2000000000}},"other":{"primary":{"usedPercent":0,"windowDurationMins":300}}}}"#)
check(newPlan.codex?.window(for: .weekly)?.remaining == 87 && newPlan.codex?.window(for: .fiveHour) == nil, "unfamiliar plan type keeps weekly quota and never substitutes another bucket")
for (code, message, expected) in [
    (-32000, "request failed: HTTP 401 unauthorized TOKEN_SECRET", QuotaError.authentication),
    (-32000, "failed to refresh token TOKEN_SECRET", .authentication),
    (-32000, "error sending request for url (https://example.invalid/private) TOKEN_SECRET", .network),
    (-32000, "TLS certificate rejected TOKEN_SECRET", .network),
    (-32000, "HTTP 503 Service Unavailable TOKEN_SECRET", .serviceUnavailable),
    (429, "too many requests TOKEN_SECRET", .rateLimited),
    (-32000, "HTTP 403 Forbidden TOKEN_SECRET", .accessDenied),
    (-32602, "Invalid params TOKEN_SECRET", .incompatibleProtocol),
    (-32000, "unknown variant `future_plan` TOKEN_SECRET", .invalidResponse),
    (-32000, "request timed out TOKEN_SECRET", .timeout),
    (-32000, "unrecognized failure TOKEN_SECRET", .queryFailed)
] {
    let result = QuotaError.fromServer(code: code, message: message)
    check(result == expected && !result.message.contains("TOKEN_SECRET") && !result.message.contains("example.invalid"), "classified RPC error: \(expected), no raw data exposure")
}
check(QuotaError.authentication.retryFloor == 300 && QuotaError.rateLimited.retryFloor == 300, "authentication and server throttling do not trigger rapid retry")

signal(SIGPIPE, SIG_IGN)
if let index = CommandLine.arguments.firstIndex(of: "--fake"), CommandLine.arguments.indices.contains(index + 1) {
    let fake = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    setenv("QUOTA_FAKE_MODE", "success", 1)
    let data = try CodexClient().fetch(executable: fake, timeout: 3)
    check(data.codex?.window(for: .weekly)?.remaining == 64, "IPC handshake, fragmented response, ignored unsolicited events")
    setenv("QUOTA_FAKE_MODE", "error", 1)
    do { _ = try CodexClient().fetch(executable: fake, timeout: 3); fatalError("Expected error") }
    catch let error as QuotaError { check(error.message.contains("登录状态不可用") && !error.message.contains("SECRET"), "server errors are classified without exposing raw text") }
    setenv("QUOTA_FAKE_MODE", "service-error", 1)
    do { _ = try CodexClient().fetch(executable: fake, timeout: 3); fatalError("Expected error") }
    catch let error as QuotaError { check(error == .serviceUnavailable, "transport routes service failure to specific error category") }
    setenv("QUOTA_FAKE_MODE", "timeout", 1)
    let start = Date()
    do { _ = try CodexClient().fetch(executable: fake, timeout: 0.4); fatalError("Expected timeout") }
    catch let error as QuotaError { check(error.message.contains("超时") && Date().timeIntervalSince(start) < 3, "bounded timeout and child cleanup") }
    unsetenv("QUOTA_FAKE_MODE")
}
print("\(passed) checks passed")
