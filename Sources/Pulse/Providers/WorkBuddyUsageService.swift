import Foundation

/// WorkBuddy (腾讯云开发助手 / 原 CodeBuddy) 配额与积分读取服务。
///
/// **基于 Web / 客户端 Session 会话鉴权。**
/// WorkBuddy 采用基于套餐积分 (Credits) 的配额管理机制，对话请求均消耗积分。
/// 积分按月发放、当月有效、不结转，新购当日~次月当日有效，到期降为体验版额度。
/// 此外账号还包含云服务资源点 (Cloud Points) 等附加资源池。
///
/// **读取通道：**
/// 1. 优先使用在设置面板中填入/保存的 Cookie；
/// 2. 接口端点：国内站 `https://www.workbuddy.cn/api/user/subscription/usage` 与 `https://workbuddy.cn/api/user/subscription/usage`，以及国际站 `https://workbuddy.ai/api/user/subscription/usage`；
/// 3. 圆环主度量绑定当月套餐积分 (Credits)，悬停卡片展示积分条、重置日期与云资源点明细。
enum WorkBuddyError: Error, Equatable {
    case missingCookie
    case invalidCookie
    case sessionExpired
    case noPlan
    case unreadableReply(String)
    case rateLimited
    case serverError
    case unreachable
}

/// WorkBuddy 单次接口查询的数据快照。
struct WorkBuddySnapshot: Equatable, Sendable {
    struct Bucket: Equatable, Sendable {
        let code: String
        let name: String
        let total: Double
        let remaining: Double
        let used: Double
        let resetsAt: Date?
    }

    struct CloudPoints: Equatable, Sendable {
        let total: Int
        let remaining: Int
        let used: Int
    }

    let buckets: [Bucket]
    let totalCapacity: Double
    let totalRemaining: Double
    let totalUsed: Double
    let cloudPoints: CloudPoints?
    let tier: String?
    let nextResetDate: Date?
}

/// WorkBuddy Cookie 规范化与安全校验。
enum WorkBuddyCookie {
    static let host = "workbuddy.cn"

    /// 标准化输入的 Cookie 字符串，防范 Header 注入。
    static func normalize(_ input: String) throws -> String {
        guard !input.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) else {
            throw WorkBuddyError.invalidCookie
        }
        var header = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !header.isEmpty else { throw WorkBuddyError.missingCookie }
        guard header.utf8.count <= 32_768 else { throw WorkBuddyError.invalidCookie }
        return header
    }
}

/// 客户端网络请求与响应解析封装。
struct WorkBuddyClient: Sendable {
    static let host = "workbuddy.cn"
    static let fallbackHost = "codebuddy.cn"

    static let hosts = [
        "www.codebuddy.cn",
        "codebuddy.cn",
        "www.workbuddy.cn",
        "workbuddy.cn",
        "copilot.tencent.com",
        "workbuddy.ai"
    ]

    var session: URLSession?

    func fetch(cookie: String) async throws -> WorkBuddySnapshot {
        let cred = try WorkBuddyCookie.normalize(cookie)
        let sess = session ?? URLSession.shared

        var lastError: WorkBuddyError = .unreachable

        for hostName in Self.hosts {
            guard let summaryUrl = URL(string: "https://\(hostName)/billing/meter/get-user-resource-summary") else { continue }
            let request = buildRequest(url: summaryUrl, cred: cred, hostName: hostName)

            do {
                let (data, response) = try await sess.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = .unreadableReply("no HTTP response")
                    continue
                }

                switch http.statusCode {
                case 200:
                    if let text = String(data: data, encoding: .utf8) {
                        let lower = text.lowercased()
                        if lower.contains("<html") || lower.contains("login-pf") || lower.contains("<!doctype html") {
                            throw WorkBuddyError.sessionExpired
                        }
                    }

                    // 检查回包中的业务错误码
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let code = json["code"] as? Int ?? -1
                        let msg = (json["msg"] as? String ?? json["message"] as? String ?? "").lowercased()
                        if code == 14051 || code == 401 || msg.contains("login") || msg.contains("auth") {
                            throw WorkBuddyError.sessionExpired
                        }
                    }

                    // 尝试并行获取详细的各包到期时间
                    var resourceData: Data?
                    if let resUrl = URL(string: "https://\(hostName)/billing/meter/get-user-resource") {
                        let resReq = buildRequest(url: resUrl, cred: cred, hostName: hostName)
                        resourceData = try? (await sess.data(for: resReq)).0
                    }

                    if let snapshot = Self.parse(summaryData: data, resourceData: resourceData) {
                        return snapshot
                    }

                    lastError = .unreadableReply("unrecognized JSON payload")
                case 300..<400, 401, 403:
                    throw WorkBuddyError.sessionExpired
                case 429:
                    throw WorkBuddyError.rateLimited
                case 500...599:
                    lastError = .serverError
                default:
                    lastError = .unreadableReply("HTTP \(http.statusCode)")
                }
            } catch let err as WorkBuddyError {
                throw err
            } catch {
                lastError = .unreachable
            }
        }

        throw lastError
    }

    private func buildRequest(url: URL, cred: String, hostName: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "{}".data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "X-Client-Platform")
        request.setValue("https://\(hostName)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(hostName)/profile/plan", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        if cred.hasPrefix("Bearer ") || cred.starts(with: "ey") {
            let token = cred.hasPrefix("Bearer ") ? String(cred.dropFirst(7)).trimmingCharacters(in: .whitespaces) : cred
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(cred, forHTTPHeaderField: "Cookie")
        }
        request.timeoutInterval = 10
        return request
    }

    /// 解析容量数值为 Double。
    static func parseDouble(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return 0
    }

    /// 解析容量数值为 Int。
    static func parseCapacity(_ value: Any?) -> Int {
        Int(round(parseDouble(value)))
    }

    /// 解析接口返回的 JSON 结构，提取多积分池与到期时间。
    static func parse(summaryData: Data, resourceData: Data? = nil) -> WorkBuddySnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            return nil
        }

        // 解析 resourceData 获取各账号到期时间
        var baseResetsAt: Date?
        var rewardResetsAt: Date?
        var purchasedResetsAt: Date?

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        if let resData = resourceData,
           let resJson = try? JSONSerialization.jsonObject(with: resData) as? [String: Any],
           let resObj = (resJson["data"] as? [String: Any])?["Response"] as? [String: Any] ?? resJson["data"] as? [String: Any],
           let accounts = (resObj["Data"] as? [String: Any])?["Accounts"] as? [[String: Any]] ?? resObj["Accounts"] as? [[String: Any]] {

            for acc in accounts {
                let code = (acc["PackageCode"] as? String ?? "").lowercased()
                guard let endStr = acc["CycleEndTime"] as? String ?? acc["ExpiredTime"] as? String,
                      let date = dateFormatter.date(from: endStr) else { continue }

                if code.contains("008") || code.contains("free") {
                    // 基础积分重置时间（加 1 秒对齐次月 1 日 0 点）
                    let nextRefresh = date.addingTimeInterval(1)
                    if baseResetsAt == nil || nextRefresh > baseResetsAt! {
                        baseResetsAt = nextRefresh
                    }
                } else if code.contains("007") || code.contains("reward") || code.contains("fission") {
                    // 奖励积分：取未过期的最近到期时间
                    if date > now {
                        if rewardResetsAt == nil || date < rewardResetsAt! {
                            rewardResetsAt = date
                        }
                    }
                } else if code.contains("009") || code.contains("addon") {
                    if date > now {
                        if purchasedResetsAt == nil || date < purchasedResetsAt! {
                            purchasedResetsAt = date
                        }
                    }
                }
            }
        }

        // 云资源点解析
        var cloudPoints: WorkBuddySnapshot.CloudPoints?
        if let cloudDict = dataObj["cloud_points"] as? [String: Any] {
            let total = parseCapacity(cloudDict["total"])
            let used = parseCapacity(cloudDict["used"])
            let remaining = parseCapacity(cloudDict["remaining"] ?? (total - used))
            cloudPoints = WorkBuddySnapshot.CloudPoints(total: total, remaining: remaining, used: used)
        }

        // 1. 优先解析官方套餐包结构 (Packages: [...])
        if let packages = dataObj["Packages"] as? [[String: Any]], !packages.isEmpty {
            var buckets: [WorkBuddySnapshot.Bucket] = []
            var totalCap: Double = 0
            var totalRem: Double = 0
            var totalUsed: Double = 0

            var hasFreePackage = false

            for pkg in packages {
                let code = pkg["PackageCode"] as? String ?? ""
                let codeLower = code.lowercased()
                let total = parseDouble(pkg["CycleTotalCapacity"])
                let remain = parseDouble(pkg["CycleRemainCapacity"])
                let usedRaw = parseDouble(pkg["CycleUsedCapacity"])
                let used = usedRaw > 0 ? usedRaw : max(0, total - remain)

                totalCap += total
                totalRem += remain
                totalUsed += used

                let name: String
                let resets: Date?

                if codeLower.contains("008") || codeLower.contains("free") {
                    name = "套餐基础积分"
                    resets = baseResetsAt
                    hasFreePackage = true
                } else if codeLower.contains("007") || codeLower.contains("fission") {
                    name = "平台奖励积分"
                    resets = rewardResetsAt
                } else if codeLower.contains("009") || codeLower.contains("addon") {
                    name = "购买积分"
                    resets = purchasedResetsAt
                } else {
                    name = resolvePackageName(code: code)
                    resets = nil
                }

                buckets.append(WorkBuddySnapshot.Bucket(
                    code: code,
                    name: name,
                    total: total,
                    remaining: remain,
                    used: used,
                    resetsAt: resets
                ))
            }

            // 按重要性排序：基础积分排在第一位，奖励积分第二位，购买积分第三位
            buckets.sort { a, b in
                func rank(_ name: String) -> Int {
                    if name.contains("基础") { return 1 }
                    if name.contains("奖励") { return 2 }
                    if name.contains("购买") { return 3 }
                    return 4
                }
                return rank(a.name) < rank(b.name)
            }

            let subCode = dataObj["SubscriptionPackageCode"] as? String ?? ""
            let isPaid = dataObj["IsPaidUser"] as? Bool ?? false
            let tier = resolveTier(packageCode: subCode, isPaid: isPaid, hasFree: hasFreePackage)

            if totalCap > 0 {
                return WorkBuddySnapshot(
                    buckets: buckets,
                    totalCapacity: totalCap,
                    totalRemaining: totalRem,
                    totalUsed: totalUsed,
                    cloudPoints: cloudPoints,
                    tier: tier,
                    nextResetDate: baseResetsAt ?? rewardResetsAt
                )
            }
        }

        // 2. 兼容兜底解析 (credits / points / limitNum)
        let creditsDict = (dataObj["credits"] as? [String: Any]) ?? (dataObj["points"] as? [String: Any])
        if let cDict = creditsDict {
            let total = parseDouble(cDict["total"] ?? 4000)
            let remaining = parseDouble(cDict["remaining"] ?? (total - parseDouble(cDict["used"])))
            let used = parseDouble(cDict["used"] ?? max(0, total - remaining))
            var nextDate = baseResetsAt
            if let dateStr = dataObj["next_reset_date"] as? String {
                let simpleFormatter = DateFormatter()
                simpleFormatter.dateFormat = "yyyy-MM-dd"
                nextDate = simpleFormatter.date(from: dateStr) ?? baseResetsAt
            }
            let bucket = WorkBuddySnapshot.Bucket(
                code: "default",
                name: "套餐基础积分",
                total: total,
                remaining: remaining,
                used: used,
                resetsAt: nextDate
            )
            return WorkBuddySnapshot(
                buckets: [bucket],
                totalCapacity: total,
                totalRemaining: remaining,
                totalUsed: used,
                cloudPoints: cloudPoints,
                tier: dataObj["tier"] as? String ?? "体验版",
                nextResetDate: nextDate
            )
        }

        // 3. 企业版或单包 limitNum 格式
        if let limitNum = dataObj["limitNum"] {
            let total = parseDouble(limitNum)
            let used = parseDouble(dataObj["credit"] ?? dataObj["usedCredit"])
            let remaining = max(0, total - used)
            var resetDate: Date?
            if let resetStr = dataObj["cycleResetTime"] as? String {
                resetDate = dateFormatter.date(from: resetStr)
            }
            let bucket = WorkBuddySnapshot.Bucket(
                code: "limit",
                name: "套餐基础积分",
                total: total,
                remaining: remaining,
                used: used,
                resetsAt: resetDate
            )
            return WorkBuddySnapshot(
                buckets: [bucket],
                totalCapacity: total,
                totalRemaining: remaining,
                totalUsed: used,
                cloudPoints: cloudPoints,
                tier: dataObj["tier"] as? String ?? "标准版",
                nextResetDate: resetDate
            )
        }

        return nil
    }

    /// 便捷解析方法（单接口响应）。
    static func parse(data: Data) -> WorkBuddySnapshot? {
        parse(summaryData: data, resourceData: nil)
    }

    /// 根据商品码识别名称。
    static func resolvePackageName(code: String) -> String {
        let lower = code.lowercased()
        if lower.contains("008") || lower.contains("free") { return "套餐基础积分" }
        if lower.contains("007") || lower.contains("fission") { return "平台奖励积分" }
        if lower.contains("009") || lower.contains("addon") { return "购买积分" }
        return "套餐积分"
    }

    /// 根据商品码或付费状态识别套餐展示名。
    static func resolveTier(packageCode: String, isPaid: Bool, hasFree: Bool = false) -> String {
        let lower = packageCode.lowercased()
        if !isPaid && (hasFree || lower.contains("008") || lower.contains("free")) {
            return "体验版"
        }
        if lower.contains("tcaca_code_023") || lower.contains("youth") {
            return "青春版"
        } else if lower.contains("flagship") {
            return "旗舰版"
        } else if lower.contains("premium") || lower.contains("advanced") {
            return "高级版"
        } else if lower.contains("tcaca_code_002") || lower.contains("standard") || lower.contains("pro") {
            return "标准版"
        } else if isPaid {
            return "会员版"
        } else {
            return "体验版"
        }
    }
}

/// 本地 WorkBuddy 官方客户端凭据提取服务。
///
/// 官方 Electron 客户端登录后会将 OAuth 会话以 JSON 格式存储于
/// `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/` 目录下。
/// Pulse 可直接读取此本地凭据，实现零配置自动鉴权。
enum WorkBuddyDesktopSession {
    static var authDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/CodeBuddyExtension/Data/Public/auth")
    }

    struct AuthInfo: Sendable {
        let token: String
        let uid: String?
        let nickname: String?
        let expiresAt: Date?
    }

    static func activeToken() -> String? {
        readSession()?.token
    }

    static func readSession() -> AuthInfo? {
        let dir = authDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let candidates = ["workbuddy-desktop.info", "workbuddy-desktop-ai.info"]
        for name in candidates {
            let file = dir.appending(path: name)
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let auth = json["auth"] as? [String: Any],
                  let token = auth["accessToken"] as? String, !token.isEmpty
            else { continue }

            let account = json["account"] as? [String: Any]
            let uid = account?["uid"] as? String
            let nickname = account?["nickname"] as? String

            var expiresAt: Date?
            if let expMs = auth["expiresAt"] as? Double {
                expiresAt = Date(timeIntervalSince1970: expMs / 1000)
            }

            if let expiresAt, expiresAt < Date() {
                continue
            }

            return AuthInfo(token: token, uid: uid, nickname: nickname, expiresAt: expiresAt)
        }

        return nil
    }
}

/// WorkBuddy 监控服务入口。
struct WorkBuddyUsageService: Sendable {
    let cookie: String?
    var fallbackToDesktop: Bool = true
    var client = WorkBuddyClient()

    func fetch() async -> ProviderUsage {
        var cred = cookie?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cred == nil || cred?.isEmpty == true) && fallbackToDesktop {
            cred = WorkBuddyDesktopSession.activeToken()
        }

        guard let tokenOrCookie = cred, !tokenOrCookie.isEmpty else {
            return .unavailable(.workbuddy, reason: .workbuddySessionMissing)
        }

        do {
            let snapshot = try await client.fetch(cookie: tokenOrCookie)
            return buildUsage(snapshot: snapshot)
        } catch let error as WorkBuddyError {
            // 如果原本凭据已过期且允许回退，尝试从本地桌面端获取最新 Token 重试
            if fallbackToDesktop, error == .sessionExpired,
               let desktopToken = WorkBuddyDesktopSession.activeToken(),
               desktopToken != tokenOrCookie {
                if let snapshot = try? await client.fetch(cookie: desktopToken) {
                    _ = APIKeyStore.setKey(desktopToken, for: .workbuddy)
                    return buildUsage(snapshot: snapshot)
                }
            }

            let reason: ProviderUsage.Unavailability = switch error {
            case .missingCookie, .invalidCookie: .workbuddySessionMissing
            case .sessionExpired: .workbuddySessionExpired
            case .noPlan: .workbuddyNoPlan
            case .rateLimited: .rateLimited
            case .serverError: .serverError
            case .unreadableReply: .unreadableReply
            case .unreachable: .unreachable
            }
            return .unavailable(.workbuddy, reason: reason)
        } catch {
            return .unavailable(.workbuddy, reason: .unreachable)
        }
    }

    func buildUsage(snapshot: WorkBuddySnapshot) -> ProviderUsage {
        guard snapshot.totalCapacity > 0 else {
            return .unavailable(.workbuddy, reason: .workbuddyNoPlan)
        }

        var windows: [UsageWindow] = []

        func formatPoints(_ num: Double) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 0
            return formatter.string(from: NSNumber(value: num)) ?? String(format: "%.2f", num)
        }

        // 1. 遍历各独立积分池 (基础积分、平台奖励积分、购买积分)
        for (index, bucket) in snapshot.buckets.enumerated() {
            guard bucket.total > 0 else { continue }

            let usedStr = formatPoints(bucket.used)
            let totalStr = formatPoints(bucket.total)
            let scopeLabel = "\(usedStr)/\(totalStr)"

            let window = UsageWindow(
                id: "workbuddy.bucket.\(bucket.code.isEmpty ? String(index) : bucket.code)",
                kind: .named(bucket.name),
                scope: scopeLabel,
                usedFraction: min(max(bucket.used / bucket.total, 0), 1),
                windowSeconds: 30 * 86_400,
                resetsAt: bucket.resetsAt,
                reportsLength: false,
                isExhausted: bucket.used >= bucket.total
            )
            windows.append(window)
        }

        // 2. 次级额度池：云资源点
        if let cloud = snapshot.cloudPoints, cloud.total > 0 {
            let cloudWindow = UsageWindow(
                id: "workbuddy.cloud_points",
                kind: .monthly,
                scope: "云资源点",
                usedFraction: Double(cloud.used) / Double(cloud.total),
                windowSeconds: 30 * 86_400,
                resetsAt: nil,
                reportsLength: false,
                isExhausted: cloud.used >= cloud.total
            )
            windows.append(cloudWindow)
        }

        // 3. 构建详细分类汇总文字 (对齐官方控制台展示)
        let totalRemStr = formatPoints(snapshot.totalRemaining)
        var detailParts: [String] = []

        if let baseBucket = snapshot.buckets.first(where: { $0.name.contains("基础") }) {
            detailParts.append("基础 \(formatPoints(baseBucket.remaining))")
        }
        if let rewardBucket = snapshot.buckets.first(where: { $0.name.contains("奖励") }) {
            detailParts.append("奖励 \(formatPoints(rewardBucket.remaining))")
        }
        if let buyBucket = snapshot.buckets.first(where: { $0.name.contains("购买") }) {
            detailParts.append("购买 \(formatPoints(buyBucket.remaining))")
        }

        let summaryText: String
        if !detailParts.isEmpty {
            summaryText = "\(totalRemStr) (\(detailParts.joined(separator: " · ")))"
        } else {
            summaryText = "\(totalRemStr) 积分"
        }

        return .init(
            account: AccountKey(.workbuddy),
            windows: windows,
            observedAt: Date(),
            state: .live,
            plan: snapshot.tier ?? "体验版",
            creditBalance: summaryText
        )
    }
}
