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
                    detail: readiness.pairingImported ? "已匯入" : "尚未匯入，請到設定匯入",
                    isSatisfied: readiness.pairingImported
                )
                Divider().padding(.leading, 52)
                StatusCheckRow(
                    title: "LocalDevVPN",
                    detail: vpnDetail,
                    isSatisfied: readiness.vpnRequirementSatisfied
                )
                Divider().padding(.leading, 52)
                StatusCheckRow(
                    title: "位置模擬",
                    detail: ddiDetail,
                    isSatisfied: readiness.ddiRequirementSatisfied
                )
                Divider().padding(.leading, 52)
                StatusCheckRow(
                    title: "健康步數",
                    detail: healthStepsDetail,
                    isSatisfied: readiness.healthStepsRequirementSatisfied
                )
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var vpnDetail: String {
        if readiness.vpnReachable {
            return "已連線"
        }
        if readiness.vpnSatisfiedThisSession {
            return "本階段已連線，目前為行動網路仍可繼續使用"
        }
        return "尚未連線，請開啟並 Connect"
    }

    private var healthStepsDetail: String {
        if !readiness.healthStepsAvailable {
            return "這台裝置不支援健康步數"
        }
        return readiness.healthStepsAuthorized ? "已允許讀寫" : "尚未允許讀寫"
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
            return readiness.ddiStatus == .notMounted
                ? "尚未就緒，無法改座標"
                : "尚未就緒，請確認裝置已連線"
        case .filesMissing:
            return "尚未下載，請保持網路後再重新檢查"
        case .unknown:
            return "檢查中"
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
    }

    @ViewBuilder
    private var actionHints: some View {
        if !readiness.isReady {
            VStack(alignment: .leading, spacing: 10) {
                if !readiness.pairingImported {
                    hint("到「設定」匯入這台裝置的配對檔。")
                }
                if !readiness.vpnRequirementSatisfied {
                    hint("打開 LocalDevVPN，確認狀態列出現 VPN 圖示。")
                }
                if !readiness.healthStepsRequirementSatisfied {
                    hint("點「重新檢查」允許讀寫健康步數，或到系統設定 → 健康開啟。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "lightbulb")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

}

private struct StatusCheckRow: View {
    let title: String
    let detail: String
    let isSatisfied: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
