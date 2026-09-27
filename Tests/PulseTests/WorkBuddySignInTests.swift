import Foundation
import Testing
@testable import Pulse

@Suite("WorkBuddy Sign-In & Growth Tests")
struct WorkBuddySignInTests {
    @Test("Checkin status parses successfully")
    func checkinStatusParsing() {
        let jsonString = """
        {
            "code": 0,
            "msg": "OK",
            "data": {
                "active": true,
                "today_checked_in": true,
                "streak_days": 11,
                "daily_credit": 100,
                "today_credit": 100,
                "is_streak_day": false,
                "total_credits": 1100,
                "theme_name": "Buddy加油站"
            }
        }
        """
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subData = json["data"] as? [String: Any] else {
            Issue.record("Failed to parse json")
            return
        }

        let status = WorkBuddyCheckinStatus(
            active: subData["active"] as? Bool ?? false,
            todayCheckedIn: subData["today_checked_in"] as? Bool ?? false,
            streakDays: subData["streak_days"] as? Int ?? 0,
            todayCredit: subData["today_credit"] as? Int ?? 0,
            totalCredits: subData["total_credits"] as? Int ?? 0,
            isStreakDay: subData["is_streak_day"] as? Bool ?? false,
            nextStreakDay: subData["next_streak_day"] as? Int ?? 0,
            themeName: subData["theme_name"] as? String,
            activityName: subData["activity_name"] as? String
        )

        #expect(status.active == true)
        #expect(status.todayCheckedIn == true)
        #expect(status.streakDays == 11)
        #expect(status.todayCredit == 100)
        #expect(status.totalCredits == 1100)
        #expect(status.themeName == "Buddy加油站")
    }

    @Test("Growth status parses buddy travel and energy")
    func growthStatusParsing() {
        var growth = WorkBuddyGrowthStatus()
        growth.buddyState = "traveling"
        growth.buddyLocation = "咖啡馆"
        growth.buddyEta = "2小时后回"
        growth.energy = 5
        growth.makeupCards = 2
        growth.lotteryChances = 1
        growth.creditsGained = 7

        #expect(growth.buddyState == "traveling")
        #expect(growth.buddyLocation == "咖啡馆")
        #expect(growth.buddyEta == "2小时后回")
        #expect(growth.energy == 5)
        #expect(growth.makeupCards == 2)
        #expect(growth.lotteryChances == 1)
        #expect(growth.creditsGained == 7)
    }

    @Test("Daily report determines success state")
    func dailyReportState() {
        let rep1 = WorkBuddyDailyReport(
            result: "CLAIMED",
            report: "成功领取 100 积分",
            creditsGained: 100
        )
        #expect(rep1.result == "CLAIMED")
        #expect(rep1.creditsGained == 100)
        #expect(rep1.needsAttention == false)

        let rep2 = WorkBuddyDailyReport(
            result: "ERROR",
            report: "未找到凭据",
            creditsGained: 0,
            needsAttention: true
        )
        #expect(rep2.result == "ERROR")
        #expect(rep2.needsAttention == true)
    }

    @Test("WorkBuddyAuthHelper handles plaintext token directly")
    func authHelperPlaintext() {
        let plain = "test_plain_jwt_token_123456"
        let resolved = WorkBuddyAuthHelper.resolveToken(plain)
        #expect(resolved == plain)
    }

    @Test("WorkBuddyAuthHelper ignores non-token types")
    func authHelperInvalid() {
        let num = 12345
        let resolved = WorkBuddyAuthHelper.resolveToken(num)
        #expect(resolved == nil)
    }
}
