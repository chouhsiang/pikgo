//
//  AppFeature.swift
//  PikGo
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case home
    case scripts
    case tools
    case console
    case deviceInfo = "deviceinfo"
    case profiles
    case processes
    case status
    case location
    case coordinates
    case steps
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .status:
            return "狀態"
        case .home:
            return "Apps"
        case .scripts:
            return "Scripts"
        case .tools:
            return "工具"
        case .console:
            return "Console"
        case .deviceInfo:
            return "Device Info"
        case .profiles:
            return "App Expiry"
        case .processes:
            return "Processes"
        case .location:
            return "地圖"
        case .coordinates:
            return "座標"
        case .steps:
            return "步數"
        case .settings:
            return "設定"
        }
    }

    var detail: String {
        switch self {
        case .status:
            return "檢查配對檔與 LocalDevVPN"
        case .home:
            return "Manage installed apps"
        case .scripts:
            return "Manage and run JS scripts"
        case .tools:
            return "Apps, logs, and debugger tools"
        case .console:
            return "Live device logs"
        case .deviceInfo:
            return "View detailed device metadata"
        case .profiles:
            return "Check app expiration dates"
        case .processes:
            return "Inspect running apps"
        case .location:
            return "點地圖即可跳到該位置"
        case .coordinates:
            return "從線上清單選座標並模擬位置"
        case .steps:
            return "把步數寫入「健康」App"
        case .settings:
            return "配對、路線與背景執行"
        }
    }

    var toolTitle: String {
        switch self {
        case .location:
            return "位置模擬"
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .status:
            return "checkmark.shield.fill"
        case .home:
            return "square.grid.2x2"
        case .scripts:
            return "scroll"
        case .tools:
            return "wrench.and.screwdriver"
        case .console:
            return "terminal"
        case .deviceInfo:
            return "iphone.and.arrow.forward"
        case .profiles:
            return "calendar.badge.clock"
        case .processes:
            return "rectangle.stack.person.crop"
        case .location:
            return "location"
        case .coordinates:
            return "mappin.and.ellipse"
        case .steps:
            return "figure.walk"
        case .settings:
            return "gearshape.fill"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .status:
            StatusView()
        case .home:
            HomeView()
        case .scripts:
            ScriptListView()
        case .tools:
            ToolsView()
        case .console:
            ConsoleLogsView()
        case .deviceInfo:
            DeviceInfoView()
        case .profiles:
            ProfileView()
        case .processes:
            ProcessInspectorView()
        case .location:
            NavigationStack {
                LocationSimulationView()
            }
        case .coordinates:
            SavedCoordinatesView()
        case .steps:
            StepPatchView()
        case .settings:
            SettingsView()
        }
    }
}

extension AppFeature {
    static let mainTabs: [AppFeature] = [.status, .location, .coordinates, .steps, .settings]
    static let toolList: [AppFeature] = [.home, .scripts, .console, .deviceInfo, .profiles, .processes]
}
