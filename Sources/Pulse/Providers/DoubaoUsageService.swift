import Foundation

/// 豆包工作 (Doubao Work / 字节跳动) 配额与额度窗口读取服务。
///
/// **基于 Web / 桌面客户端 Session 会话鉴权。**
/// 豆包工作针对个人/商业订阅采用了多窗口配额限制（如 5小时窗口限制与月度周期额度限制）。
///
/// **读取通道：**
/// 1. 优先使用在设置面板中填入/保存的 Cookie；
/// 2. 本地已安装 DoubaoWork.app 客户端时，支持从 `~/Library/Application Support/DoubaoWork/Default/Cookies` 自动无感读取；
/// 3. 接口端点：`POST https://www.doubao.com/alice/commerce/sale/subscription/overview/`；
/// 4. 提取当前订阅套餐（如“标准套餐”）、5小时额度窗口（`fiveHour`）与月度周期额度窗口（`monthly`）。
enum DoubaoError: Error, Equatable {
    case missingCookie
    case invalidCookie
    case sessionExpired
    case noPlan
    case unreadableReply(String)
    case rateLimited
    case serverError
    case unreachable
}

/// 豆包工作单次接口查询的数据快照。
struct DoubaoSnapshot: Equatable, Sendable {
    struct LimitWindow: Equatable, Sendable {
        let startTime: Date
        let endTime: Date
        let usedPercent: Int
        let isLessThanOnePercent: Bool
        let windowType: Int // 1: 5小时额度窗口, 2: 周期额度窗口
    }

    let planName: String
    let productName: String?
    let skuKey: String?
    let windows: [LimitWindow]
    let serviceCurrentTime: Date?
}

/// 豆包 Cookie 规范化与安全校验。
enum DoubaoCookie {
    static let host = "doubao.com"

    /// 标准化输入的 Cookie 字符串，防范 Header 注入。
    static func normalize(_ input: String) throws -> String {
        guard !input.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) else {
            throw DoubaoError.invalidCookie
        }
        var header = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !header.isEmpty else { throw DoubaoError.missingCookie }
        guard header.utf8.count <= 32_768 else { throw DoubaoError.invalidCookie }
        return header
    }
}

/// 客户端网络请求与响应解析封装。
struct DoubaoClient: Sendable {
    static let host = "doubao.com"
    static let overviewURL = URL(string: "https://www.doubao.com/alice/commerce/sale/subscription/overview/")!

    var session: URLSession?

    func fetch(cookie: String) async throws -> DoubaoSnapshot {
        let cred = try DoubaoCookie.normalize(cookie)
        let sess = session ?? URLSession.shared

        var request = URLRequest(url: Self.overviewURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www.doubao.com/member/quota-management", forHTTPHeaderField: "Referer")
        request.setValue("https://www.doubao.com", forHTTPHeaderField: "Origin")
        request.setValue(cred, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sess.data(for: request)
        } catch {
            throw DoubaoError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw DoubaoError.unreadableReply("no HTTP response")
        }

        switch http.statusCode {
        case 200:
            if let text = String(data: data, encoding: .utf8) {
                let lower = text.lowercased()
                if lower.contains("<html") || lower.contains("<!doctype html") {
                    throw DoubaoError.sessionExpired
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DoubaoError.unreadableReply("Invalid JSON")
            }

            let code = json["code"] as? Int ?? -1
            let msg = (json["msg"] as? String ?? json["message"] as? String ?? "").lowercased()
            if code != 0 {
                if code == 401 || code == 14051 || msg.contains("login") || msg.contains("auth") || msg.contains("unauthorized") {
                    throw DoubaoError.sessionExpired
                }
                throw DoubaoError.unreadableReply("code \(code): \(msg)")
            }

            return try parseOverview(json)

        case 401, 403:
            throw DoubaoError.sessionExpired
        case 429:
            throw DoubaoError.rateLimited
        case 500...599:
            throw DoubaoError.serverError
        default:
            throw DoubaoError.unreachable
        }
    }

    /// 从 overview JSON 中解析套餐与配额窗口信息。
    func parseOverview(_ json: [String: Any]) throws -> DoubaoSnapshot {
        guard let data = json["data"] as? [String: Any] else {
            throw DoubaoError.unreadableReply("Missing data object")
        }

        var planName = "标准套餐"
        var productName: String?
        var skuKey: String?

        if let currentSub = data["current_subscription"] as? [String: Any] {
            skuKey = currentSub["sku_key"] as? String
            if let display = currentSub["display"] as? [String: Any] {
                if let short = display["short_name"] as? String, !short.isEmpty {
                    planName = short
                }
                productName = display["product_name"] as? String
            }
        }

        var limitWindows: [DoubaoSnapshot.LimitWindow] = []

        if let limitSection = data["window_limit_section"] as? [String: Any],
           let groups = limitSection["window_limit_groups"] as? [[String: Any]] {
            for group in groups {
                guard let limits = group["window_limits"] as? [[String: Any]] else { continue }
                for item in limits {
                    guard let startMs = item["start_time"] as? Double,
                          let endMs = item["end_time"] as? Double,
                          let winType = item["window_type"] as? Int else {
                        continue
                    }
                    let usedPercent = item["used_percent"] as? Int ?? 0
                    let lessThanOne = item["less_than_one_percent"] as? Bool ?? false

                    let start = Date(timeIntervalSince1970: startMs / 1000)
                    let end = Date(timeIntervalSince1970: endMs / 1000)

                    limitWindows.append(.init(
                        startTime: start,
                        endTime: end,
                        usedPercent: usedPercent,
                        isLessThanOnePercent: lessThanOne,
                        windowType: winType
                    ))
                }
            }
        }

        var serverTime: Date?
        if let srvMs = data["service_current_time"] as? Double {
            serverTime = Date(timeIntervalSince1970: srvMs / 1000)
        }

        return DoubaoSnapshot(
            planName: planName,
            productName: productName,
            skuKey: skuKey,
            windows: limitWindows,
            serviceCurrentTime: serverTime
        )
    }
}

/// 豆包工作本地桌面客户端会话提取器。
enum DoubaoDesktopSession {
    static var supportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/DoubaoWork")
    }

    static let keychainService = "DoubaoWork Safe Storage"
    static let host = "doubao.com"

    struct DesktopSession: Sendable {
        let cookie: String
        let nickname: String?
    }

    /// 搜索 DoubaoWork 的 Cookies 数据库路径。
    static func cookieStore() -> URL? {
        let candidates = [
            "Default/Network/Cookies",
            "Default/Cookies",
            "Network/Cookies",
            "Cookies"
        ].map { supportDirectory.appending(path: $0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 是否检测到本机已安装 DoubaoWork 并且存在 Cookie 存储。
    static var isAvailable: Bool { cookieStore() != nil }

    /// 从本地桌面端解密并读取会话 Cookie。
    static func readSession() -> DesktopSession? {
        guard let store = cookieStore() else { return nil }
        guard let key = BrowserCookies.safeStorageKey(service: keychainService) else { return nil }

        let cookies = BrowserCookies.chromiumCookies(at: store, host: host, key: key)
        guard !cookies.isEmpty else { return nil }

        // 优先筛选并按序拼接有效凭据 Cookie
        var dict: [String: String] = [:]
        for (name, val) in cookies {
            if !val.isEmpty && dict[name] == nil {
                dict[name] = val
            }
        }

        guard !dict.isEmpty else { return nil }

        let header = dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return DesktopSession(cookie: header, nickname: nil)
    }

    /// 获取当前有效的 Cookie。
    static func activeCookie() -> String? {
        readSession()?.cookie
    }
}

/// 豆包工作用量监控服务入口。
struct DoubaoUsageService: Sendable {
    let cookie: String?
    var fallbackToDesktop: Bool = true
    var client = DoubaoClient()

    func fetch() async -> ProviderUsage {
        var cred = cookie?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cred == nil || cred?.isEmpty == true) && fallbackToDesktop {
            cred = DoubaoDesktopSession.activeCookie()
        }

        guard let cookieStr = cred, !cookieStr.isEmpty else {
            return .unavailable(.doubao, reason: .doubaoSessionMissing)
        }

        do {
            let snapshot = try await client.fetch(cookie: cookieStr)
            return buildUsage(snapshot: snapshot)
        } catch let error as DoubaoError {
            // 如果原本凭据已过期且允许回退，尝试从本地桌面端获取最新凭证重试
            if fallbackToDesktop, error == .sessionExpired,
               let desktopCookie = DoubaoDesktopSession.activeCookie(),
               desktopCookie != cookieStr {
                if let snapshot = try? await client.fetch(cookie: desktopCookie) {
                    _ = APIKeyStore.setKey(desktopCookie, for: .doubao)
                    return buildUsage(snapshot: snapshot)
                }
            }

            let reason: ProviderUsage.Unavailability = switch error {
            case .missingCookie, .invalidCookie: .doubaoSessionMissing
            case .sessionExpired: .doubaoSessionExpired
            case .noPlan: .doubaoNoPlan
            case .rateLimited: .rateLimited
            case .serverError: .serverError
            case .unreadableReply: .unreadableReply
            case .unreachable: .unreachable
            }
            return .unavailable(.doubao, reason: reason)
        } catch {
            return .unavailable(.doubao, reason: .unreachable)
        }
    }

    /// 将解析出来的快照构建为 Pulse 的 ProviderUsage。
    func buildUsage(snapshot: DoubaoSnapshot) -> ProviderUsage {
        var windows: [UsageWindow] = []

        var fiveHourWindow: DoubaoSnapshot.LimitWindow?
        var monthlyWindow: DoubaoSnapshot.LimitWindow?

        for limit in snapshot.windows {
            if limit.windowType == 1 {
                fiveHourWindow = limit
            } else if limit.windowType == 2 {
                monthlyWindow = limit
            }
        }

        // 1. 5小时窗口 (fiveHour)
        if let five = fiveHourWindow {
            let durationSeconds = Int(round(five.endTime.timeIntervalSince(five.startTime)))
            let fraction: Double
            if five.usedPercent == 0 && five.isLessThanOnePercent {
                fraction = 0.005
            } else {
                fraction = min(max(Double(five.usedPercent) / 100.0, 0), 1)
            }

            windows.append(UsageWindow(
                id: "doubao.window.fiveHour",
                kind: .fiveHour,
                scope: nil,
                usedFraction: fraction,
                windowSeconds: durationSeconds > 0 ? durationSeconds : 18000,
                resetsAt: five.endTime,
                reportsLength: true,
                isExhausted: five.usedPercent >= 100
            ))
        }

        // 2. 周期月度窗口 (monthly)
        if let month = monthlyWindow {
            let durationSeconds = Int(round(month.endTime.timeIntervalSince(month.startTime)))
            let fraction: Double
            if month.usedPercent == 0 && month.isLessThanOnePercent {
                fraction = 0.005
            } else {
                fraction = min(max(Double(month.usedPercent) / 100.0, 0), 1)
            }

            windows.append(UsageWindow(
                id: "doubao.window.monthly",
                kind: .monthly,
                scope: nil,
                usedFraction: fraction,
                windowSeconds: durationSeconds > 0 ? durationSeconds : 30 * 86_400,
                resetsAt: month.endTime,
                reportsLength: true,
                isExhausted: month.usedPercent >= 100
            ))
        }

        // 3. 构建概览摘要
        var summaryParts: [String] = []
        if let five = fiveHourWindow {
            let label = five.usedPercent == 0 && five.isLessThanOnePercent ? "<1%" : "\(five.usedPercent)%"
            summaryParts.append("5小时已用 \(label)")
        }
        if let month = monthlyWindow {
            let label = month.usedPercent == 0 && month.isLessThanOnePercent ? "<1%" : "\(month.usedPercent)%"
            summaryParts.append("本周期已用 \(label)")
        }

        let creditText: String?
        if summaryParts.count >= 2 {
            creditText = "\(summaryParts[0]) (\(summaryParts[1]))"
        } else {
            creditText = summaryParts.first
        }

        return .init(
            account: AccountKey(.doubao),
            windows: windows,
            observedAt: Date(),
            state: .live,
            plan: snapshot.planName,
            creditBalance: creditText
        )
    }
}
