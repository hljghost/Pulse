import Foundation

/// WorkBuddy 签到状态模型。
struct WorkBuddyCheckinStatus: Equatable, Codable, Sendable {
    var active: Bool = false
    var todayCheckedIn: Bool = false
    var streakDays: Int = 0
    var todayCredit: Int = 0
    var totalCredits: Int = 0
    var isStreakDay: Bool = false
    var nextStreakDay: Int = 0
    var themeName: String?
    var activityName: String?
}

/// WorkBuddy 成长中心状态模型。
struct WorkBuddyGrowthStatus: Equatable, Codable, Sendable {
    var buddyState: String? // "arrived", "idle", "traveling"
    var buddyLocation: String?
    var buddyEta: String?
    var energy: Int?
    var makeupCards: Int?
    var lotteryChances: Int?
    var creditsGained: Int = 0
    var report: String = ""
}

/// WorkBuddy 每日综合执行结果汇报。
struct WorkBuddyDailyReport: Equatable, Sendable {
    var result: String // "CLAIMED", "ALREADY", "INACTIVE", "GROWTH", "ERROR"
    var report: String
    var creditsGained: Int
    var checkinStatus: WorkBuddyCheckinStatus?
    var growthStatus: WorkBuddyGrowthStatus?
    var executedAt: Date = Date()
    var needsAttention: Bool = false
}

/// WorkBuddy 自动签到与成长中心原生服务。
///
/// 融合 88lin/workbuddy-auto-signin 的全部自动化业务逻辑：
/// 1. 每日签到查询与积分领取；
/// 2. Buddy 旅行礼物自动收取与派出；
/// 3. 成长任务自动接单与完成奖励领取；
/// 4. 连登断登自动补登（保住连签）；
/// 5. 连登 7d/14d/28d 阶梯大礼包兑换；
/// 6. 免费盲盒抽奖与能量开启新 Buddy；
/// 7. 纯 Swift 原生实现，零第三方依赖。
@MainActor
final class WorkBuddySignInService {
    static let shared = WorkBuddySignInService()

    private(set) var latestReport: WorkBuddyDailyReport?
    private(set) var isRunning: Bool = false
    private(set) var cachedCheckin: WorkBuddyCheckinStatus?
    private(set) var cachedGrowth: WorkBuddyGrowthStatus?

    private let defaultEndpoint = "https://copilot.tencent.com"
    private let userDefaultsKey = "pulse.workbuddy.last_checkin_day"

    private init() {}

    /// 检查今日是否已自动执行过。
    var hasRunToday: Bool {
        guard let lastDay = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return false
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return lastDay == formatter.string(from: Date())
    }

    private func markRunToday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        UserDefaults.standard.setValue(formatter.string(from: Date()), forKey: userDefaultsKey)
    }

    /// 执行完整的每日任务流程（先查签到→未签则领→再跑成长中心各子项）。
    @discardableResult
    func runDailyTasks(force: Bool = false) async -> WorkBuddyDailyReport {
        guard !isRunning else {
            return latestReport ?? WorkBuddyDailyReport(
                result: "RUNNING",
                report: "签到任务正在执行中，请稍候…",
                creditsGained: 0
            )
        }

        guard let auth = WorkBuddyDesktopSession.readSession() else {
            let rep = WorkBuddyDailyReport(
                result: "NO_AUTH",
                report: "未找到 WorkBuddy 桌面端登录凭据，请先在 WorkBuddy 桌面端登录。",
                creditsGained: 0,
                needsAttention: true
            )
            self.latestReport = rep
            return rep
        }

        isRunning = true
        defer { isRunning = false }

        let endpoint = (auth.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? auth.endpoint!.trimmingCharacters(in: .whitespacesAndNewlines)
            : defaultEndpoint

        // 1. 每日签到
        var checkinStatus: WorkBuddyCheckinStatus?
        var checkinReport = ""
        var checkinCredits = 0
        var checkinResult = "ALREADY"

        do {
            let status = try await fetchCheckinStatus(auth: auth, endpoint: endpoint)
            checkinStatus = status
            self.cachedCheckin = status

            if !status.active {
                checkinResult = "INACTIVE"
                checkinReport = "签到活动未开启"
            } else if status.todayCheckedIn {
                checkinResult = "ALREADY"
                checkinReport = "今日已签到（连续 \(status.streakDays) 天，累计 \(status.totalCredits) 积分）"
            } else {
                // 执行签到领取
                let claimRes = try await claimCheckin(auth: auth, endpoint: endpoint)
                if claimRes.claimed {
                    checkinResult = "CLAIMED"
                    checkinCredits = claimRes.credit
                    // 重新获取最新连签状态
                    let refreshed = (try? await fetchCheckinStatus(auth: auth, endpoint: endpoint)) ?? status
                    checkinStatus = refreshed
                    self.cachedCheckin = refreshed
                    checkinReport = "成功领取今日签到 +\(claimRes.credit) 积分（连续 \(refreshed.streakDays) 天，累计 \(refreshed.totalCredits) 积分）"
                } else {
                    checkinResult = "ALREADY"
                    checkinReport = "今日已签过"
                }
            }
        } catch {
            checkinResult = "ERROR"
            checkinReport = "签到接口异常：\(error.localizedDescription)"
        }

        // 2. 成长中心自动化
        let (growthReport, growthCredits, growthStatus) = await runGrowthAutomation(auth: auth, endpoint: endpoint)
        self.cachedGrowth = growthStatus

        let totalCreditsGained = checkinCredits + growthCredits
        var combinedReportParts: [String] = []
        if !checkinReport.isEmpty {
            combinedReportParts.append(checkinReport)
        }
        if !growthReport.isEmpty {
            combinedReportParts.append(growthReport)
        }

        let fullReportText = combinedReportParts.joined(separator: "；")

        let finalReport = WorkBuddyDailyReport(
            result: checkinResult,
            report: fullReportText,
            creditsGained: totalCreditsGained,
            checkinStatus: checkinStatus,
            growthStatus: growthStatus,
            executedAt: Date(),
            needsAttention: checkinResult == "ERROR"
        )

        self.latestReport = finalReport
        self.markRunToday()
        return finalReport
    }

    /// 仅查询签到与成长状态（轻量级只读，用于面板状态刷新）。
    func refreshStatusOnly() async {
        guard let auth = WorkBuddyDesktopSession.readSession() else { return }
        let endpoint = (auth.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? auth.endpoint!.trimmingCharacters(in: .whitespacesAndNewlines)
            : defaultEndpoint

        if let status = try? await fetchCheckinStatus(auth: auth, endpoint: endpoint) {
            self.cachedCheckin = status
        }
        if let gStatus = try? await fetchGrowthOverview(auth: auth, endpoint: endpoint) {
            self.cachedGrowth = gStatus
        }
    }

    // MARK: - 网络请求辅助

    private func makeHeaders(auth: WorkBuddyDesktopSession.AuthInfo) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": "Bearer \(auth.token)",
            "User-Agent": "WorkBuddy"
        ]
        if let uid = auth.uid, !uid.isEmpty {
            headers["X-User-Id"] = uid
        }
        if let enterpriseId = auth.enterpriseId, !enterpriseId.isEmpty {
            headers["X-Enterprise-Id"] = enterpriseId
            headers["X-Tenant-Id"] = enterpriseId
        }
        if let domain = auth.domain, !domain.isEmpty {
            headers["X-Domain"] = domain
        }
        return headers
    }

    private func request(
        url: URL,
        method: String,
        headers: [String: String],
        body: [String: Any]? = nil
    ) async throws -> (Int, [String: Any]?) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (httpCode, json)
    }

    // MARK: - 签到接口实现

    private func fetchCheckinStatus(auth: WorkBuddyDesktopSession.AuthInfo, endpoint: String) async throws -> WorkBuddyCheckinStatus {
        guard let url = URL(string: "\(endpoint)/v2/billing/meter/checkin-activity-status") else {
            throw URLError(.badURL)
        }
        let headers = makeHeaders(auth: auth)
        let (code, json) = try await request(url: url, method: "POST", headers: headers, body: [:])

        guard code == 200, let json = json else {
            throw URLError(.badServerResponse)
        }

        let data = (json["data"] as? [String: Any]) ?? json
        let active = data["active"] as? Bool ?? true
        let todayChecked = (data["today_checked_in"] as? Bool) ?? ((data["today_checked_in"] as? Int) == 1)
        let streak = data["streak_days"] as? Int ?? 0
        let todayCredit = (data["today_credit"] as? Int) ?? (data["daily_credit"] as? Int) ?? 100
        let totalCredits = data["total_credits"] as? Int ?? 0
        let isStreakDay = data["is_streak_day"] as? Bool ?? false
        let nextStreakDay = data["next_streak_day"] as? Int ?? 0
        let themeName = data["theme_name"] as? String
        let activityName = data["activity_name"] as? String

        return WorkBuddyCheckinStatus(
            active: active,
            todayCheckedIn: todayChecked,
            streakDays: streak,
            todayCredit: todayCredit,
            totalCredits: totalCredits,
            isStreakDay: isStreakDay,
            nextStreakDay: nextStreakDay,
            themeName: themeName,
            activityName: activityName
        )
    }

    private func claimCheckin(auth: WorkBuddyDesktopSession.AuthInfo, endpoint: String) async throws -> (claimed: Bool, credit: Int) {
        guard let url = URL(string: "\(endpoint)/v2/billing/meter/daily-checkin") else {
            throw URLError(.badURL)
        }
        let headers = makeHeaders(auth: auth)
        let (code, json) = try await request(url: url, method: "POST", headers: headers, body: [:])

        if code == 200, let json = json {
            let data = (json["data"] as? [String: Any]) ?? json
            let credit = data["credit"] as? Int ?? 100
            return (true, credit)
        }

        // 已经签到返回 400 且 msg 含已签到，或 null
        if code == 400 || code == 200 {
            if let json = json {
                let codeVal = json["code"] as? Int ?? 0
                let msg = (json["msg"] as? String ?? "").lowercased()
                if codeVal == 10001 || msg.contains("已签") {
                    return (false, 0)
                }
            }
        }

        return (false, 0)
    }

    // MARK: - 成长中心接口实现

    private func fetchGrowthOverview(auth: WorkBuddyDesktopSession.AuthInfo, endpoint: String) async throws -> WorkBuddyGrowthStatus {
        let headers = makeHeaders(auth: auth)
        var status = WorkBuddyGrowthStatus()

        // 查旅行
        if let travelUrl = URL(string: "\(endpoint)/v2/activity/growth/buddy/travel/status") {
            if let (code, json) = try? await request(url: travelUrl, method: "GET", headers: headers),
               code == 200, let json = json {
                let data = (json["data"] as? [String: Any]) ?? json
                status.buddyState = data["state"] as? String
                if let loc = data["location"] as? [String: Any] {
                    status.buddyLocation = loc["name"] as? String
                }
                if let arrive = data["arrive_at"] as? Double, let now = data["server_now"] as? Double {
                    let diff = arrive - now
                    if diff <= 0 {
                        status.buddyEta = "已到达待领取"
                    } else if diff < 3600 {
                        status.buddyEta = "\(max(1, Int(round(diff / 60))))分钟后回"
                    } else {
                        status.buddyEta = String(format: "%.1f小时后回", diff / 3600)
                    }
                }
            }
        }

        // 查能量
        if let energyUrl = URL(string: "\(endpoint)/v2/activity/growth/energy") {
            if let (code, json) = try? await request(url: energyUrl, method: "GET", headers: headers),
               code == 200, let json = json {
                let data = (json["data"] as? [String: Any]) ?? json
                status.energy = data["balance"] as? Int
            }
        }

        // 查补登卡
        if let streakUrl = URL(string: "\(endpoint)/v2/activity/growth/streak") {
            if let (code, json) = try? await request(url: streakUrl, method: "GET", headers: headers),
               code == 200, let json = json {
                let data = (json["data"] as? [String: Any]) ?? json
                if let cardsObj = data["makeup_cards"] as? [String: Any] {
                    status.makeupCards = cardsObj["balance"] as? Int
                } else if let cardsInt = data["makeup_cards"] as? Int {
                    status.makeupCards = cardsInt
                }
            }
        }

        return status
    }

    private func runGrowthAutomation(
        auth: WorkBuddyDesktopSession.AuthInfo,
        endpoint: String
    ) async -> (report: String, creditsGained: Int, growth: WorkBuddyGrowthStatus) {
        let headers = makeHeaders(auth: auth)
        let base = "\(endpoint)/v2/activity/growth"
        var parts: [String] = []
        var totalGained = 0
        var growth = WorkBuddyGrowthStatus()

        // 1. Buddy 旅行：领礼物 + 派出发
        do {
            if let sUrl = URL(string: "\(base)/buddy/travel/status") {
                let (code, json) = try await request(url: sUrl, method: "GET", headers: headers)
                if code == 200, let json = json {
                    let data = (json["data"] as? [String: Any]) ?? json
                    var travelState = data["state"] as? String
                    let dailyLimit = data["daily_limit_reached"] as? Bool ?? false
                    growth.buddyState = travelState

                    if travelState == "arrived" {
                        let recordId = data["record_id"]
                        if let claimUrl = URL(string: "\(base)/buddy/travel/claim"), let rId = recordId {
                            let (ccode, cjson) = try await request(url: claimUrl, method: "POST", headers: headers, body: ["record_id": rId])
                            if ccode == 200, let cjson = cjson {
                                let cdata = (cjson["data"] as? [String: Any]) ?? cjson
                                if let reward = cdata["reward_credit"] as? Int {
                                    totalGained += reward
                                    parts.append("领旅行礼物 +\(reward) 积分")
                                    travelState = "idle"
                                }
                            }
                        }
                    }

                    if travelState == "idle" && !dailyLimit {
                        if let cfgUrl = URL(string: "\(base)/buddy/travel/config") {
                            let (cfCode, cfJson) = try await request(url: cfgUrl, method: "GET", headers: headers)
                            if cfCode == 200, let cfJson = cfJson {
                                let cfData = (cfJson["data"] as? [String: Any]) ?? cfJson
                                if let locs = cfData["locations"] as? [[String: Any]], let firstLoc = locs.first,
                                   let locId = firstLoc["id"] {
                                    if let depUrl = URL(string: "\(base)/buddy/travel/depart") {
                                        let (dCode, dJson) = try await request(url: depUrl, method: "POST", headers: headers, body: ["location_id": locId])
                                        if dCode == 200, let dJson = dJson {
                                            let dData = (dJson["data"] as? [String: Any]) ?? dJson
                                            let locName = (dData["location"] as? [String: Any])?["name"] as? String ?? "目的地"
                                            let dur = dData["duration_hours"] ?? 2
                                            parts.append("派 Buddy 去\(locName)（\(dur) 小时后回）")
                                            growth.buddyState = "traveling"
                                            growth.buddyLocation = locName
                                        }
                                    }
                                }
                            }
                        }
                    } else if travelState == "traveling" {
                        let locName = (data["location"] as? [String: Any])?["name"] as? String ?? ""
                        growth.buddyLocation = locName
                        parts.append("Buddy 旅行中" + (locName.isEmpty ? "" : "（\(locName)）"))
                    }
                }
            }
        } catch {}

        // 2. 任务接单与完成奖励领取
        do {
            if let tUrl = URL(string: "\(base)/tasks") {
                let (code, json) = try await request(url: tUrl, method: "GET", headers: headers)
                if code == 200, let json = json {
                    let data = (json["data"] as? [String: Any]) ?? json
                    if let tasks = data["tasks"] as? [[String: Any]] {
                        // 接单未开始的任务
                        let pendingCodes = tasks.compactMap { t -> String? in
                            guard let code = t["task_code"] as? String,
                                  !(t["locked"] as? Bool ?? false),
                                  (t["accept_status"] as? String) == "not_accepted" else { return nil }
                            return code
                        }
                        if !pendingCodes.isEmpty, let accUrl = URL(string: "\(base)/tasks/accept") {
                            _ = try? await request(url: accUrl, method: "POST", headers: headers, body: ["task_codes": pendingCodes])
                            parts.append("自动接单 \(pendingCodes.count) 项新任务")
                        }

                        // 领取已完成任务
                        for t in tasks {
                            guard !(t["locked"] as? Bool ?? false),
                                  (t["accept_status"] as? String) == "completed",
                                  let tCode = t["task_code"] as? String,
                                  let claimTUrl = URL(string: "\(base)/tasks/\(tCode)/claim") else { continue }
                            let title = t["title"] as? String ?? tCode
                            if let (cCode, cJson) = try? await request(url: claimTUrl, method: "POST", headers: headers, body: [:]),
                               cCode == 200, let cJson = cJson {
                                let cData = (cJson["data"] as? [String: Any]) ?? cJson
                                if !(cData["already_claimed"] as? Bool ?? false) {
                                    let rc = (cData["credit"] as? Int) ?? (t["reward_credit"] as? Int) ?? 0
                                    totalGained += rc
                                    parts.append("领任务奖「\(title)」+\(rc) 积分")
                                }
                            }
                        }
                    }
                }
            }
        } catch {}

        // 3. 补登卡使用
        do {
            if let mUrl = URL(string: "\(base)/streak") {
                let (code, json) = try await request(url: mUrl, method: "GET", headers: headers)
                if code == 200, let json = json {
                    let data = (json["data"] as? [String: Any]) ?? json
                    let cardsObj = data["makeup_cards"]
                    let cards = (cardsObj as? [String: Any])?["balance"] as? Int ?? (cardsObj as? Int ?? 0)
                    let streakObj = data["streak"] as? [String: Any]
                    let dates = (streakObj?["makeup_dates"] as? [String]) ?? (data["makeup_dates"] as? [String]) ?? []

                    if cards > 0, let firstDate = dates.first, let useCardUrl = URL(string: "\(base)/makeup-cards/use") {
                        let tokenStr = "u-\(UUID().uuidString)"
                        let (ucode, _) = try await request(url: useCardUrl, method: "POST", headers: headers, body: [
                            "target_date": firstDate,
                            "client_token": tokenStr
                        ])
                        if ucode == 200 {
                            parts.append("使用补登卡补救 \(firstDate) 断登")
                        }
                    }
                }
            }
        } catch {}

        // 4. 连登兑换（7d/14d/28d）
        do {
            if let rUrl = URL(string: "\(base)/redeem/summary") {
                let (code, json) = try await request(url: rUrl, method: "GET", headers: headers)
                if code == 200, let json = json {
                    let data = (json["data"] as? [String: Any]) ?? json
                    let tiers: [(tier: String, key: String, name: String)] = [
                        ("7d", "starter_status", "入门"),
                        ("14d", "advanced_status", "进阶"),
                        ("28d", "legendary_status", "巅峰")
                    ]
                    for item in tiers {
                        if let st = data[item.key] as? String, st != "claimed" && st != "locked",
                           let redeemUrl = URL(string: "\(base)/redeem") {
                            let (c2Code, c2Json) = try await request(url: redeemUrl, method: "POST", headers: headers, body: [
                                "tier": item.tier,
                                "client_token": "u-\(UUID().uuidString)"
                            ])
                            if c2Code == 200, let c2Json = c2Json {
                                let c2Data = (c2Json["data"] as? [String: Any]) ?? c2Json
                                let credit = c2Data["credit_granted"] as? Int ?? 0
                                totalGained += credit
                                parts.append("连登兑换「\(item.name)」+\(credit) 积分")
                            }
                        }
                    }
                }
            }
        } catch {}

        // 5. 盲盒抽奖
        do {
            if let lUrl = URL(string: "\(base)/lottery/chances") {
                let (code, json) = try await request(url: lUrl, method: "GET", headers: headers)
                if code == 200, let json = json {
                    let data = (json["data"] as? [String: Any]) ?? json
                    let chances = data["balance"] as? Int ?? 0
                    if chances > 0, let drawUrl = URL(string: "\(base)/lottery/draw") {
                        let (dCode, dJson) = try await request(url: drawUrl, method: "POST", headers: headers, body: [
                            "client_token": "u-\(UUID().uuidString)"
                        ])
                        if dCode == 200, let dJson = dJson {
                            let dData = (dJson["data"] as? [String: Any]) ?? dJson
                            let prize = (dData["prize_name"] as? String) ?? (dData["prize"] as? String) ?? "奖品"
                            parts.append("开盲盒抽中：\(prize)")
                        }
                    }
                }
            }
        } catch {}

        // 6. Buddy 盲盒
        do {
            if let qUrl = URL(string: "\(base)/buddy/quota") {
                let (code, json) = try await request(url: qUrl, method: "GET", headers: headers)
                if code == 200, let json = json {
                    let data = (json["data"] as? [String: Any]) ?? json
                    let affordable = data["affordable"] as? Int ?? 0
                    if affordable > 0, let openUrl = URL(string: "\(base)/buddy/open") {
                        let (oCode, oJson) = try await request(url: openUrl, method: "POST", headers: headers, body: [
                            "count": 1,
                            "client_token": "u-\(UUID().uuidString)"
                        ])
                        if oCode == 200, let oJson = oJson {
                            let oData = (oJson["data"] as? [String: Any]) ?? oJson
                            let name = (oData["buddy"] as? String) ?? (oData["name"] as? String) ?? "新伙伴"
                            parts.append("开 Buddy 盲盒获得：\(name)")
                        }
                    }
                }
            }
        } catch {}

        // 7. 查询最新能量余额
        if let energyUrl = URL(string: "\(base)/energy") {
            if let (code, json) = try? await request(url: energyUrl, method: "GET", headers: headers),
               code == 200, let json = json {
                let data = (json["data"] as? [String: Any]) ?? json
                growth.energy = data["balance"] as? Int
            }
        }

        growth.creditsGained = totalGained
        growth.report = parts.isEmpty ? "成长中心暂无待处理项" : parts.joined(separator: "；")
        return (growth.report, totalGained, growth)
    }
}
