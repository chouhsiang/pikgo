//  SettingsView.swift
//  PikGo
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

private enum SettingsLinks {
    static let pairingFileGuide = URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!
}

struct SettingsView: View {
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress
    @AppStorage(UserDefaults.Keys.routeSpeedAutomobileKilometersPerHour) private var automobileSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.routeSpeedCyclingKilometersPerHour) private var cyclingSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.routeSpeedWalkingKilometersPerHour) private var walkingSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.routeSpeedAirplaneKilometersPerHour) private var airplaneSpeed = RouteSimulationSpeed.defaultKilometersPerHour
    @AppStorage(UserDefaults.Keys.addStepsWhileMoving) private var addStepsWhileMoving = RouteMovingSteps.defaultEnabled
    @AppStorage(UserDefaults.Keys.stepsPerMinuteWhileMoving) private var stepsPerMinuteWhileMoving = RouteMovingSteps.defaultStepsPerMinute

    @State private var isShowingPairingFilePicker = false
    @State private var isImportingFile = false
    @State private var pairingImportMessage: (text: String, isError: Bool)?
    @State private var isRestoringLocation = false
    @State private var restoreMessage: (text: String, isError: Bool)?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        restoreRealLocation()
                    } label: {
                        HStack {
                            Label("恢復實際位置", systemImage: "location.slash.fill")
                            Spacer()
                            if isRestoringLocation {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRestoringLocation)

                    if let restoreMessage {
                        Label(
                            restoreMessage.text,
                            systemImage: restoreMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(restoreMessage.isError ? .red : .green)
                    }
                } header: {
                    Text("位置")
                } footer: {
                    Text("清除模擬座標，改回裝置的實際定位。")
                }

                Section {
                    ForEach(RouteNavigationMode.allCases) { mode in
                        Stepper(
                            value: speedBinding(for: mode),
                            in: RouteSimulationSpeed.minimumKilometersPerHour...RouteSimulationSpeed.maximumKilometersPerHour,
                            step: 1.0
                        ) {
                            HStack {
                                Label(mode.title, systemImage: mode.systemImage)
                                Spacer()
                                Text("\(Int(speedBinding(for: mode).wrappedValue)) km/h")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("路線速度")
                } footer: {
                    Text("各交通方式可分別設定移動速度，預設都是 18 km/h。開車會避開高速公路，飛機走兩點直線。")
                }

                Section {
                    Toggle("邊移動邊增加步數", isOn: $addStepsWhileMoving)
                        .onChange(of: addStepsWhileMoving) { _, enabled in
                            MovementStepInjector.shared.configurationDidChange()
                            if enabled {
                                Task {
                                    try? await HealthKitManager.shared.requestAuthorization()
                                }
                            }
                        }

                    if addStepsWhileMoving {
                        Stepper(
                            value: $stepsPerMinuteWhileMoving,
                            in: RouteMovingSteps.minimumStepsPerMinute...RouteMovingSteps.maximumStepsPerMinute,
                            step: 10
                        ) {
                            HStack {
                                Text("每分鐘步數")
                                Spacer()
                                Text("\(Int(stepsPerMinuteWhileMoving)) 步")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("移動步數")
                } footer: {
                    Text("導航移動時，每 5 秒把對應步數寫入「健康」。預設開啟，每分鐘 200 步。")
                }

                Section("配對檔") {
                    Button {
                        isShowingPairingFilePicker = true
                    } label: {
                        Label("匯入配對檔", systemImage: "doc.badge.plus")
                    }
                    .disabled(isImportingFile)

                    if isImportingFile {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在匯入配對檔…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let pairingImportMessage {
                        Label(
                            pairingImportMessage.text,
                            systemImage: pairingImportMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pairingImportMessage.isError ? .red : .green)
                    }
                }

                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("無聲音訊")
                            Text("播放幾乎聽不到的音訊，讓系統較不容易把 App 殺掉。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        handleAudioKeepAliveChange(enabled)
                    }

                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("背景定位")
                            Text("使用低精度定位，讓位置模擬能在背景繼續。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        handleLocationKeepAliveChange(enabled)
                    }
                } header: {
                    Text("背景持續執行")
                }

                Section("連線") {
                    HStack {
                        Text("裝置 IP")
                        Spacer()
                        TextField(DeviceConnectionContext.defaultTargetIPAddress, text: $targetDeviceIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.numbersAndPunctuation)
                            .frame(maxWidth: 160)
                    }
                    Button { openAppFolder() } label: {
                        Label("開啟 App 資料夾", systemImage: "folder")
                    }.foregroundStyle(.primary)
                }

                Section("說明") {
                    Link(destination: SettingsLinks.pairingFileGuide) {
                        Label("配對檔說明", systemImage: "questionmark.circle")
                    }
                    Button {
                        StatusRemediation.openLocalDevVPN()
                    } label: {
                        Label("開啟或下載 LocalDevVPN", systemImage: "arrow.down.circle")
                    }
                }

                Section {
                    Text("版本 \(appVersion)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("設定")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPairingImporter)) { _ in
            isShowingPairingFilePicker = true
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }

                let fileManager = FileManager.default
                isImportingFile = true
                pairingImportMessage = nil

                do {
                    try PairingFileStore.importFromPicker(url, fileManager: fileManager)
                    isImportingFile = false
                    pairingImportMessage = ("匯入成功", false)
                    startTunnelInBackground()
                    schedulePairingStatusDismiss()
                } catch {
                    isImportingFile = false
                    pairingImportMessage = ("匯入失敗：\(error.localizedDescription)", true)
                    schedulePairingStatusDismiss()
                }
            case .failure(let error):
                isImportingFile = false
                pairingImportMessage = ("匯入失敗：\(error.localizedDescription)", true)
                schedulePairingStatusDismiss()
            }
        }
    }

    private func speedBinding(for mode: RouteNavigationMode) -> Binding<Double> {
        switch mode {
        case .automobile:
            return $automobileSpeed
        case .cycling:
            return $cyclingSpeed
        case .walking:
            return $walkingSpeed
        case .airplane:
            return $airplaneSpeed
        }
    }

    private func restoreRealLocation() {
        isRestoringLocation = true
        restoreMessage = nil
        LocationSimulationControl.restoreRealLocation { code in
            isRestoringLocation = false
            if code == 0 {
                restoreMessage = ("已恢復實際位置", false)
            } else if code == 12 {
                restoreMessage = ("目前已是實際位置", false)
            } else {
                restoreMessage = ("無法恢復實際位置（錯誤 \(code)）。請確認 LocalDevVPN 已連線。", true)
            }
        }
    }

    private func handleAudioKeepAliveChange(_ enabled: Bool) {
        if !enabled, !keepAliveLocation {
            keepAliveLocation = true
            BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
        }
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }

    private func handleLocationKeepAliveChange(_ enabled: Bool) {
        if enabled {
            BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
        } else if !keepAliveAudio {
            keepAliveAudio = true
        }
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }

    private func openAppFolder() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = documentsURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        if let url = URL(string: path) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func schedulePairingStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isImportingFile {
                    pairingImportMessage = nil
                }
            }
        }
    }
}
