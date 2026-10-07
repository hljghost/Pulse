// Copyright (c) 2026 qunqin24. Licensed under the Apache License, Version 2.0.
import SwiftUI

/// WorkBuddy's auto sign-in and growth tasks management group.
struct WorkBuddySignInGroup: View {
    let account: AccountKey
    let store: UsageStore
    let settings: AppSettings

    @State private var isExecutingWorkBuddy = false
    @State private var workbuddyManualReport: WorkBuddyDailyReport?

    var body: some View {
        let signIn = WorkBuddySignInService.shared
        let desktop = WorkBuddyDesktopSession.readSession()

        SettingsGroup(String.localized("WorkBuddy auto sign-in and growth tasks")) {
            SettingsRow(
                String.localized("Auto sign-in & tasks"),
                subtitle: String.localized("Automatically claim daily check-in points, send/collect Buddy travel gifts, accept and claim tasks, use makeup cards, and open blind boxes.")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.workbuddyAutoSignIn },
                    set: { settings.workbuddyAutoSignIn = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsRowDivider()

            SettingsRow(
                String.localized("WorkBuddy session status"),
                subtitle: desktop != nil
                    ? (desktop?.nickname != nil
                       ? String(format: String.localized("Connected: Desktop session (%@)"), desktop!.nickname!)
                       : String.localized("Connected: Desktop session (AES-256-GCM decrypted)"))
                    : String.localized("No desktop session found. Please sign in to WorkBuddy desktop app.")
            ) {
                Button {
                    guard !isExecutingWorkBuddy else { return }
                    isExecutingWorkBuddy = true
                    Task {
                        let rep = await signIn.runDailyTasks(force: true)
                        isExecutingWorkBuddy = false
                        workbuddyManualReport = rep
                        store.refresh(account)
                    }
                } label: {
                    if isExecutingWorkBuddy {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(String.localized("Executing…"))
                        }
                    } else {
                        Text(String.localized("Execute now"))
                    }
                }
                .disabled(isExecutingWorkBuddy || desktop == nil)
            }

            if let rep = workbuddyManualReport ?? signIn.latestReport {
                SettingsRowDivider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rep.result == "CLAIMED" || rep.creditsGained > 0 ? "✅ " + String.localized("Success") : "ℹ️ " + String.localized("Status"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)

                        Spacer()

                        if rep.creditsGained > 0 {
                            Text("+\(rep.creditsGained) 积分")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.tint)
                        }
                    }

                    Text(rep.report)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
