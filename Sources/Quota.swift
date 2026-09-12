import Foundation

enum QuotaPeriod: String, CaseIterable {
    case weekly, fiveHour
    var title: String { self == .weekly ? "每周" : "5 小时" }
    var minutes: Int { self == .weekly ? 10080 : 300 }
}

// Decode only the fields needed for presentation. Account identifiers, credits,
// reset vouchers, upsells and other payload fields are deliberately ignored.
struct QuotaWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    var remaining: Int? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return Int(floor(min(100, max(0, 100 - usedPercent))))
    }
    var resetDate: Date? {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }
    func hasElapsed(at now: Date) -> Bool { resetDate.map { $0 <= now } ?? false }
}

struct QuotaBucket: Decodable {
    let limitId: String?
    let planType: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?

    func window(for period: QuotaPeriod) -> QuotaWindow? {
        [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == period.minutes }
    }
    var initialPeriod: QuotaPeriod {
        if planType == "plus", window(for: .fiveHour) != nil { return .fiveHour }
        return window(for: .weekly) != nil ? .weekly : .fiveHour
    }
    var planLabel: String {
        switch planType {
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "free": return "Free"
        case "team", "business": return "Business"
        default: return "Codex"
        }
    }
}

struct QuotaResponse: Decodable {
    let rateLimits: QuotaBucket?
    let rateLimitsByLimitId: [String: QuotaBucket]?

    var codex: QuotaBucket? {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty { return buckets["codex"] }
        guard let legacy = rateLimits, legacy.limitId == nil || legacy.limitId == "codex" else { return nil }
        return legacy
    }
}

enum QuotaError: Error {
    case missingCodex, launchFailed, timeout, disconnected, invalidResponse, authentication, queryFailed, cancelled
    var message: String {
        switch self {
        case .missingCodex: return "未找到 Codex。请先安装并登录 Codex，再点刷新。"
        case .authentication: return "登录状态不可用，请在 Codex 中重新登录后刷新。"
        case .timeout: return "查询超时，请检查网络后刷新。"
        case .launchFailed, .disconnected: return "无法启动额度查询。请确认 Codex 能正常打开后重试。"
        case .invalidResponse: return "暂时无法识别额度数据，请更新 Codex 后重试。"
        case .queryFailed: return "额度查询失败，请检查网络或 Codex 登录状态后重试。"
        case .cancelled: return "查询已取消。"
        }
    }
}

func resetDescription(_ window: QuotaWindow, now: Date) -> String {
    guard let date = window.resetDate else { return "重置时间暂不可用" }
    guard date > now else { return "已到重置时间，等待刷新确认" }
    let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let left = minutes % 60
    let relative = days > 0 ? "\(days) 天 \(hours) 小时" : hours > 0 ? "\(hours) 小时 \(left) 分钟" : "\(left) 分钟"
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 HH:mm"
    return "\(relative)后重置 · \(formatter.string(from: date))"
}
