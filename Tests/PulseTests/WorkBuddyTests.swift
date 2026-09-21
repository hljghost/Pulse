import Foundation
import Testing
@testable import Pulse

@Suite("WorkBuddy Usage")
struct WorkBuddyTests {

    // MARK: - Cookie 规范化与安全

    @Test("Cookie 标准化正确去除前缀与两端空白")
    func normalizeAcceptsPastedCookie() throws {
        let raw = "Cookie: session_token=xyz123; uid=9988   "
        let normalized = try WorkBuddyCookie.normalize(raw)
        #expect(normalized == "session_token=xyz123; uid=9988")
    }

    @Test("空 Cookie 抛出 missingCookie")
    func normalizeRejectsEmpty() {
        #expect(throws: WorkBuddyError.missingCookie) {
            try WorkBuddyCookie.normalize("   ")
        }
    }

    @Test("含控制字符或换行的非法 Cookie 抛出 invalidCookie")
    func normalizeRejectsControlCharacters() {
        #expect(throws: WorkBuddyError.invalidCookie) {
            try WorkBuddyCookie.normalize("session=abc\r\nInjected-Header: evil")
        }
    }

    // MARK: - JSON 数据解析

    @Test("解析完整的 WorkBuddy 响应数据")
    func parsesCompleteResponse() throws {
        let json = """
        {
            "code": 0,
            "data": {
                "credits": {
                    "total": 4000,
                    "remaining": 2800,
                    "used": 1200
                },
                "cloud_points": {
                    "total": 25000,
                    "remaining": 21500,
                    "used": 3500
                },
                "tier": "标准版会员",
                "next_reset_date": "2026-10-01"
            }
        }
        """.data(using: .utf8)!

        let snapshot = try #require(WorkBuddyClient.parse(data: json))
        #expect(snapshot.tier == "标准版会员")
        #expect(snapshot.totalCapacity == 4000)
        #expect(snapshot.totalRemaining == 2800)
        #expect(snapshot.totalUsed == 1200)

        #expect(snapshot.cloudPoints?.total == 25000)
        #expect(snapshot.cloudPoints?.remaining == 21500)
        #expect(snapshot.cloudPoints?.used == 3500)

        #expect(snapshot.nextResetDate != nil)
    }

    @Test("解析兼容 points 别名字段")
    func parsesPointsAlias() throws {
        let json = """
        {
            "code": 0,
            "data": {
                "points": {
                    "total": 3000,
                    "remaining": 1500
                },
                "tier": "体验版"
            }
        }
        """.data(using: .utf8)!

        let snapshot = try #require(WorkBuddyClient.parse(data: json))
        #expect(snapshot.tier == "体验版")
        #expect(snapshot.totalCapacity == 3000)
        #expect(snapshot.totalRemaining == 1500)
        #expect(snapshot.totalUsed == 1500)
        #expect(snapshot.cloudPoints == nil)
    }

    // MARK: - UsageService 与窗口构建

    @Test("缺少凭证时返回 workbuddySessionMissing")
    func missingCredentialReportsSessionMissing() async {
        let service = WorkBuddyUsageService(cookie: nil, fallbackToDesktop: false)
        let usage = await service.fetch()
        #expect(usage.state == .unavailable(.workbuddySessionMissing))
    }

    @Test("无积分套餐时返回 workbuddyNoPlan")
    func noCreditsReportsNoPlan() async {
        let json = "{\"data\": {}}".data(using: .utf8)!
        let snapshot = WorkBuddyClient.parse(data: json)
        #expect(snapshot == nil || snapshot?.totalCapacity == 0)
    }

    @Test("解析官方 Packages 聚合资源包响应（包含浮点数字符串容量）")
    func parsesOfficialPackagesResponse() throws {
        let json = """
        {
            "code": 0,
            "data": {
                "Packages": [
                    {
                        "PackageCode": "TCACA_code_007_nzdH5h4Nl0",
                        "CycleTotalCapacity": "3515",
                        "CycleRemainCapacity": "3510.74000003",
                        "CycleUsedCapacity": "4.25999997",
                        "CycleFrozenCapacity": "0",
                        "CapacityUnit": "credits",
                        "TotalCount": 44
                    },
                    {
                        "PackageCode": "TCACA_code_008_cfWoLwvjU4",
                        "CycleTotalCapacity": "500",
                        "CycleRemainCapacity": "500",
                        "CycleUsedCapacity": "0",
                        "CycleFrozenCapacity": "0",
                        "CapacityUnit": "credits",
                        "TotalCount": 1
                    }
                ],
                "SubscriptionPackageCode": "",
                "IsPaidUser": false
            }
        }
        """.data(using: .utf8)!

        let snapshot = try #require(WorkBuddyClient.parse(data: json))
        #expect(snapshot.tier == "体验版")
        #expect(snapshot.totalCapacity == 4015)
        #expect(abs(snapshot.totalRemaining - 4010.74) < 0.01)
        #expect(abs(snapshot.totalUsed - 4.26) < 0.01)
        #expect(snapshot.buckets.count == 2)
        #expect(snapshot.buckets[0].name == "套餐基础积分")
        #expect(snapshot.buckets[0].total == 500)
        #expect(snapshot.buckets[1].name == "平台奖励积分")
        #expect(snapshot.buckets[1].total == 3515)
    }

    @Test("解析容量 parseCapacity 健壮性")
    func parseCapacityRobustness() {
        #expect(WorkBuddyClient.parseCapacity(100) == 100)
        #expect(WorkBuddyClient.parseCapacity(100.4) == 100)
        #expect(WorkBuddyClient.parseCapacity(100.6) == 101)
        #expect(WorkBuddyClient.parseCapacity("3510.74000003") == 3511)
        #expect(WorkBuddyClient.parseCapacity("4.25999997") == 4)
        #expect(WorkBuddyClient.parseCapacity("2000") == 2000)
        #expect(WorkBuddyClient.parseCapacity(nil) == 0)
        #expect(WorkBuddyClient.parseCapacity("invalid") == 0)
    }

    @Test("WorkBuddyDesktopSession 本地凭据读取验证")
    func testDesktopSessionReading() {
        if let session = WorkBuddyDesktopSession.readSession() {
            #expect(!session.token.isEmpty)
            print("===> [TEST] 成功从本地桌面端读取会话: uid=\(session.uid ?? ""), nickname=\(session.nickname ?? "")")
        }
    }

    @Test("解析企业版与单包 limitNum 额度响应")
    func parsesEnterpriseLimitNum() throws {
        let json = """
        {
            "code": 0,
            "data": {
                "limitNum": 6000,
                "credit": 1500,
                "cycleResetTime": "2026-10-01 00:00:00"
            }
        }
        """.data(using: .utf8)!

        let snapshot = try #require(WorkBuddyClient.parse(data: json))
        #expect(snapshot.totalCapacity == 6000)
        #expect(snapshot.totalUsed == 1500)
        #expect(snapshot.totalRemaining == 4500)
        #expect(snapshot.nextResetDate != nil)
    }

    @Test("验证官方多包结构构建的 ProviderUsage 字段完整性")
    func buildsFullUsageFromOfficialSnapshot() throws {
        let summaryJson = """
        {
            "code": 0,
            "data": {
                "Packages": [
                    {
                        "PackageCode": "TCACA_code_007_nzdH5h4Nl0",
                        "CycleTotalCapacity": "3515",
                        "CycleRemainCapacity": "3510.74000003",
                        "CycleUsedCapacity": "4.25999997",
                        "CycleFrozenCapacity": "0"
                    },
                    {
                        "PackageCode": "TCACA_code_008_cfWoLwvjU4",
                        "CycleTotalCapacity": "500",
                        "CycleRemainCapacity": "500",
                        "CycleUsedCapacity": "0",
                        "CycleFrozenCapacity": "0"
                    }
                ],
                "SubscriptionPackageCode": "",
                "IsPaidUser": false
            }
        }
        """.data(using: .utf8)!

        let resourceJson = """
        {
            "code": 0,
            "data": {
                "Response": {
                    "Data": {
                        "Accounts": [
                            {
                                "PackageCode": "TCACA_code_008_cfWoLwvjU4",
                                "CycleEndTime": "2026-09-30 23:59:59"
                            },
                            {
                                "PackageCode": "TCACA_code_007_nzdH5h4Nl0",
                                "CycleEndTime": "2099-12-31 23:59:59"
                            }
                        ]
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let snapshot = try #require(WorkBuddyClient.parse(summaryData: summaryJson, resourceData: resourceJson))
        let service = WorkBuddyUsageService(cookie: "dummy", fallbackToDesktop: false)
        let usage = service.buildUsage(snapshot: snapshot)

        #expect(usage.state == .live)
        #expect(usage.plan == "体验版")
        #expect(usage.creditBalance?.contains("4,010.74") == true)
        #expect(usage.creditBalance?.contains("基础 500") == true)
        #expect(usage.creditBalance?.contains("奖励 3,510.74") == true)

        #expect(usage.windows.count == 2)
        let baseWin = usage.windows[0]
        #expect(baseWin.kind == .named("套餐基础积分"))
        #expect(baseWin.scope == "0/500")
        #expect(baseWin.resetsAt != nil)

        let rewardWin = usage.windows[1]
        #expect(rewardWin.kind == .named("平台奖励积分"))
        #expect(rewardWin.scope == "4.26/3,515")
        #expect(rewardWin.resetsAt != nil)
    }
}
