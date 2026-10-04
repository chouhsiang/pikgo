//
//  StatusView.swift
//  PikGo
//

import SwiftUI

struct StatusView: View {
    @ObservedObject private var readiness = ReadinessMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    statusHero
                    if readiness.shouldPromptAirplaneToggle {
                        airplaneReminder
                    }
                    checklist
                    actionHints
                    Button {
                        readiness.refresh(requestHealthAuthorization: true)
                    } label: {
                        Label("重新檢查", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(readiness.isChecking)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            readiness.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                readiness.refresh()
            }
        }
    }

    private var statusHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(heroAccent.opacity(0.16))
                    .frame(width: 168, height: 168)

                Circle()
                    .stroke(heroAccent.opacity(0.35), lineWidth: 8)
                    .frame(width: 168, height: 168)

                Image(systemName: heroSymbol)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(heroAccent)
            }

            VStack(spacing: 6) {
                Text(heroTitle)
                    .font(.title.bold())
                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var heroTitle: String {
        readiness.isReady ? "可以使用" : "尚未就緒"
    }

    private var heroSymbol: String {
        readiness.isReady ? "checkmark.shield.fill" : "xmark.shield.fill"
    }

    private var heroAccent: Color {
        readiness.isReady ? .green : .red
    }

    private var heroSubtitle: String {
        if readiness.isReady {
            return "前置條件都通過了，可以模擬位置。"
        }
        if readiness.shouldPromptAirplaneToggle {
            return readiness.airplanePromptMessage
        }
        return "請先完成下面的前置條件。"
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("前置條件")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                StatusCheckRow(
                    title: "配對檔",
                    detail: pairingDetail,
                    isSatisfied: readiness.pairingImported,
                    action: readiness.pairingImported ? nil : StatusRemediation.openPairingImporter
                )
                Divider().padding(.leading, 52)
                StatusCheckRow(
                    title: "LocalDevVPN",
                    detail: vpnDetail,
                    isSatisfied: readiness.vpnRequirementSatisfied,
                    action: readiness.vpnRequirementSatisfied ? nil : StatusRemediation.openLocalDevVPN
                )
                Divider().padding(.leading, 52)
                StatusCheckRow(
                    title: "位置模擬",
                    detail: ddiDetail,
                    isSatisfied: readiness.ddiRequirementSatisfied,
                    action: readiness.ddiRequirementSatisfied ? nil : { readiness.refresh() }
                )
                Divider().padding(.leading, 52)
                StatusCheckRow(
                    title: "健康步數",
                    detail: healthStepsDetail,
                    isSatisfied: readiness.healthStepsRequirementSatisfied,
                    action: readiness.healthStepsRequirementSatisfied ? nil : promptHealthAuthorization
                )
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var pairingDetail: String {
        readiness.pairingImported ? "已匯入" : "尚未匯入，點這裡到設定匯入"
    }

    private var vpnDetail: String {
        if readiness.vpnReachable {
            return "已連線"
        }
        if readiness.vpnSatisfiedThisSession {
            return "本階段已連線，目前為行動網路仍可繼續使用"
        }
        return "尚未連線，點這裡開啟 LocalDevVPN 或前往 App Store"
    }

    private var healthStepsDetail: String {
        if !readiness.healthStepsAvailable {
            return "這台裝置不支援健康步數"
        }
        return readiness.healthStepsAuthorized ? "已允許讀寫" : "尚未允許讀寫，點這裡授權"
    }

    private var ddiDetail: String {
        switch readiness.ddiStatus {
        case .mounted:
            return "已就緒"
        case .notMounted, .unreachable:
            if readiness.shouldPromptAirplaneToggle {
                return readiness.isLikelyAirplaneMode
                    ? "建立中，請關閉飛航前等已就緒"
                    : "尚未就緒，請開啟飛航再關閉"
            }
            return "尚未就緒，點這裡再試一次"
        case .filesMissing:
            return "尚未下載，點這裡繼續準備"
        case .unknown:
            return "檢查中"
        }
    }

    private func promptHealthAuthorization() {
        Task {
            await HealthKitManager.shared.promptAuthorizationOrOpenSettings()
            readiness.refresh()
        }
    }

    private var airplaneReminder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("4G 無法直接建立位置模擬", systemImage: "airplane")
                .font(.subheadline.weight(.semibold))
            Text(readiness.airplanePromptMessage)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            readiness.refresh()
        }
    }

    @ViewBuilder
    private var actionHints: some View {
        if !readiness.isReady {
            Text("橘色項目可以點，會直接帶到對應的解決方式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private struct StatusCheckRow: View {
    let title: String
    let detail: String
    let isSatisfied: Bool
    var action: (() -> Void)?

    var body: some View {
        let row = HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSatisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isSatisfied ? Color.green : Color.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }
}
