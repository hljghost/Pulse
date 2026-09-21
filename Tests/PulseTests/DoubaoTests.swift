import Foundation
import Testing
@testable import Pulse

@Suite("Doubao Work Usage")
struct DoubaoTests {

    // MARK: - Cookie 规范化与安全

    @Test("Cookie 标准化正确去除前缀与两端空白")
    func normalizeAcceptsPastedCookie() throws {
        let raw = "Cookie: sessionid=test12345; passport_csrf_token=csrf999   "
        let normalized = try DoubaoCookie.normalize(raw)
        #expect(normalized == "sessionid=test12345; passport_csrf_token=csrf999")
    }

    @Test("空 Cookie 抛出 missingCookie")
    func normalizeRejectsEmpty() {
        #expect(throws: DoubaoError.missingCookie) {
            try DoubaoCookie.normalize("   ")
        }
    }

    @Test("含控制字符或换行的非法 Cookie 抛出 invalidCookie")
    func normalizeRejectsControlCharacters() {
        #expect(throws: DoubaoError.invalidCookie) {
            try DoubaoCookie.normalize("session=abc\r\nInjected-Header: evil")
        }
    }

    // MARK: - JSON 数据解析

    @Test("解析官方 overview 响应（包含 5小时与周期额度窗口）")
    func parsesOfficialOverviewResponse() throws {
        let jsonStr = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "current_subscription": {
              "sku_key": "doubao_personal_std",
              "display": {
                "short_name": "标准套餐",
                "product_name": "个人订阅"
              },
              "start_time": 1787666917062,
              "end_time": 1790258917062,
              "status": 3
            },
            "service_current_time": 1789968086240,
            "window_limit_section": {
              "entitlement_count": 1,
              "usage_exhausted": false,
              "window_limit_groups": [
                {
                  "feature_group": "general",
                  "window_limits": [
                    {
                      "start_time": 1789953353864,
                      "end_time": 1789971353864,
                      "item_type": 0,
                      "less_than_one_percent": true,
                      "used_percent": 0,
                      "window_type": 1
                    },
                    {
                      "start_time": 1789906134630,
                      "end_time": 1790258917062,
                      "item_type": 0,
                      "less_than_one_percent": false,
                      "used_percent": 2,
                      "window_type": 2
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let data = jsonStr.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let client = DoubaoClient()
        let snapshot = try client.parseOverview(json)

        #expect(snapshot.planName == "标准套餐")
        #expect(snapshot.productName == "个人订阅")
        #expect(snapshot.skuKey == "doubao_personal_std")
        #expect(snapshot.windows.count == 2)

        let fiveHour = snapshot.windows.first(where: { $0.windowType == 1 })
        #expect(fiveHour != nil)
        #expect(fiveHour?.usedPercent == 0)
        #expect(fiveHour?.isLessThanOnePercent == true)

        let monthly = snapshot.windows.first(where: { $0.windowType == 2 })
        #expect(monthly != nil)
        #expect(monthly?.usedPercent == 2)
        #expect(monthly?.isLessThanOnePercent == false)
    }

    // MARK: - 构建 ProviderUsage

    @Test("验证构建的 ProviderUsage 包含 5小时与月度窗口")
    func buildsProviderUsage() {
        let now = Date()
        let fiveEnd = now.addingTimeInterval(18000)
        let monthEnd = now.addingTimeInterval(30 * 86400)

        let snapshot = DoubaoSnapshot(
            planName: "标准套餐",
            productName: "个人订阅",
            skuKey: "doubao_personal_std",
            windows: [
                .init(
                    startTime: now,
                    endTime: fiveEnd,
                    usedPercent: 0,
                    isLessThanOnePercent: true,
                    windowType: 1
                ),
                .init(
                    startTime: now,
                    endTime: monthEnd,
                    usedPercent: 15,
                    isLessThanOnePercent: false,
                    windowType: 2
                )
            ],
            serviceCurrentTime: now
        )

        let service = DoubaoUsageService(cookie: "dummy")
        let usage = service.buildUsage(snapshot: snapshot)

        #expect(usage.account.provider == .doubao)
        #expect(usage.plan == "标准套餐")
        #expect(usage.windows.count == 2)

        let fiveWindow = usage.windows.first(where: { $0.kind == .fiveHour })
        #expect(fiveWindow != nil)
        #expect(fiveWindow?.usedFraction == 0.005) // lessThanOnePercent 且 0% 时为 0.005
        #expect(fiveWindow?.windowSeconds == 18000)

        let monthWindow = usage.windows.first(where: { $0.kind == .monthly })
        #expect(monthWindow != nil)
        #expect(monthWindow?.usedFraction == 0.15)
        #expect(monthWindow?.windowSeconds == 30 * 86400)

        #expect(usage.creditBalance?.contains("5小时已用") == true)
        #expect(usage.creditBalance?.contains("本周期已用 15%") == true)
    }

    // MARK: - 错误判定与缺少凭据

    @Test("缺少凭证时返回 doubaoSessionMissing")
    func returnsMissingWhenNoCredentials() async {
        let service = DoubaoUsageService(cookie: nil, fallbackToDesktop: false)
        let usage = await service.fetch()

        guard case .unavailable(let reason) = usage.state else {
            Issue.record("应当返回不可用状态")
            return
        }
        #expect(reason == .doubaoSessionMissing)
    }

    @Test("桌面端 cookieStore 检测不崩溃")
    func desktopStoreLocation() {
        _ = DoubaoDesktopSession.cookieStore()
        _ = DoubaoDesktopSession.isAvailable
    }
}
