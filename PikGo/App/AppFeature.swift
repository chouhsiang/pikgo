//
//  AppFeature.swift
//  PikGo
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case status
    case location
    case coordinates
    case steps
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:
            return "狀態"
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

    var systemImage: String {
        switch self {
        case .status:
            return "checkmark.shield.fill"
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

    static let mainTabs: [AppFeature] = [.status, .location, .coordinates, .steps, .settings]
}
