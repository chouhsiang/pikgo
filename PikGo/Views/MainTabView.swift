//
//  MainTabView.swift
//  PikGo
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI
import Foundation
import CoreLocation
import UIKit

private enum ExternalLocationAction: Identifiable {
    case simulate(URL, Double, Double)
    case clear

    var id: String {
        switch self {
        case .simulate(let url, _, _):
            return "simulate-\(url.absoluteString)"
        case .clear:
            return "clear-location"
        }
    }

    var title: String {
        switch self {
        case .simulate:
            return "要模擬位置嗎？"
        case .clear:
            return "要清除位置嗎？"
        }
    }

    var message: String {
        switch self {
        case .simulate(_, let latitude, let longitude):
            return String(format: "外部連結要把模擬位置設成 %.6f, %.6f。", latitude, longitude)
        case .clear:
            return "外部連結要清除模擬位置。"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .simulate:
            return "設定位置"
        case .clear:
            return "清除位置"
        }
    }
}

struct MainTabView: View {
    @AppStorage("primaryTabSelection") private var selection: String = AppFeature.status.id
    @ObservedObject private var readiness = ReadinessMonitor.shared
    @State private var detachedFeature: AppFeature?
    @State private var didSetInitialHome = false
    @State private var pendingLocationAction: ExternalLocationAction?

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(AppFeature.mainTabs) { feature in
                    feature.destination
                        .tabItem {
                            if feature == .status {
                                StatusTabLabel(canModifyCoordinates: readiness.isReady)
                            } else {
                                Label(feature.title, systemImage: feature.systemImage)
                            }
                        }
                        .tag(feature.id)
                }
            }
            .modifier(BottomTabBarStyle())
            .onAppear {
                ReadinessMonitor.shared.start()
                ensureSelectionIsValid()
                if !didSetInitialHome {
                    selection = AppFeature.status.id
                    didSetInitialHome = true
                }
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .confirmationDialog(
                pendingLocationAction?.title ?? "外部位置請求",
                isPresented: Binding(
                    get: { pendingLocationAction != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingLocationAction = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingLocationAction
            ) { action in
                Button(action.confirmationTitle, role: .destructive) {
                    performLocationAction(action)
                    pendingLocationAction = nil
                }
                Button("取消", role: .cancel) {
                    pendingLocationAction = nil
                }
            } message: { action in
                Text(action.message)
            }
            .sheet(item: $detachedFeature) { feature in
                NavigationStack {
                    feature.destination
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("關閉") {
                                    detachedFeature = nil
                                }
                            }
                        }
                }
            }
        }
    }

    private func ensureSelectionIsValid() {
        let ids = AppFeature.mainTabs.map { $0.id }
        if ids.contains(selection) {
            return
        }
        selection = AppFeature.status.id
    }

    private func handleURL(_ url: URL) {
        guard let host = url.host()?.lowercased() else { return }

        switch host {
        case "simulate-location", "set-location":
            confirmSimulatedLocation(from: url)
        case "location", "location-simulation":
            if coordinate(from: url) == nil {
                openFeature(id: AppFeature.location.id)
            } else {
                confirmSimulatedLocation(from: url)
            }
        case "clear-location", "stop-location":
            pendingLocationAction = .clear
        default:
            break
        }
    }

    private func openFeature(id: String) {
        guard let feature = AppFeature(rawValue: id) else {
            return
        }

        if AppFeature.mainTabs.contains(feature) {
            selection = feature.id
        } else {
            detachedFeature = feature
        }
    }

    private func confirmSimulatedLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: "位置網址無效",
                message: "請使用 pikgo://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }

        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: "座標無效",
                message: "緯度必須介於 -90 到 90，經度必須介於 -180 到 180。",
                showOk: true
            )
            return
        }

        pendingLocationAction = .simulate(url, coordinate.latitude, coordinate.longitude)
    }

    private func performLocationAction(_ action: ExternalLocationAction) {
        switch action {
        case .simulate(let url, _, _):
            simulateLocation(from: url)
        case .clear:
            clearSimulatedLocation()
        }
    }

    private func simulateLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: "位置網址無效",
                message: "請使用 pikgo://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }

        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: "座標無效",
                message: "緯度必須介於 -90 到 90，經度必須介於 -180 到 180。",
                showOk: true
            )
            return
        }

        let pairingFile = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFile.path) else {
            showAlert(
                title: "需要配對檔",
                message: "請先匯入配對檔，才能用網址模擬位置。",
                showOk: true
            )
            return
        }

        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                coordinate.latitude,
                coordinate.longitude,
                pairingFile.path
            )

            DispatchQueue.main.async {
                if code == 0 {
                    LocationSimulationSession.shared.clearRoute()
                    LocationSimulationSession.shared.startResending(
                        at: CLLocationCoordinate2D(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    ) {
                        LocationSimulationCommandQueue.shared.async {
                            _ = simulate_location(
                                DeviceConnectionContext.targetIPAddress,
                                coordinate.latitude,
                                coordinate.longitude,
                                pairingFile.path
                            )
                        }
                    }
                    LogManager.shared.addInfoLog(
                        String(format: "Simulated location from URL: %.6f, %.6f", coordinate.latitude, coordinate.longitude)
                    )
                } else {
                    showAlert(
                        title: "位置模擬失敗",
                        message: "無法從網址模擬位置（錯誤 \(code)）。請確認裝置已連線，且位置模擬已就緒。",
                        showOk: true
                    )
                }
            }
        }
    }

    private func clearSimulatedLocation() {
        LocationSimulationControl.restoreRealLocation { code in
            if code == 0 {
                LogManager.shared.addInfoLog("Cleared simulated location from URL")
            } else {
                showAlert(
                    title: "清除位置失敗",
                    message: "無法從網址清除模擬位置（錯誤 \(code)）。",
                    showOk: true
                )
            }
        }
    }

    private func coordinate(from url: URL) -> (latitude: Double, longitude: Double)? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value {
                    return value
                }
            }
            return nil
        }

        if let latitudeText = queryValue(["lat", "latitude"]),
           let longitudeText = queryValue(["lon", "lng", "long", "longitude"]),
           let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (latitude, longitude)
        }

        let coordinateText = queryValue(["coordinate", "coordinates", "coords", "q", "ll"])
            ?? components?.path
            ?? ""
        let values = numbers(in: coordinateText)
        guard values.count >= 2 else { return nil }
        return (values[0], values[1])
    }

    private func coordinateIsValid(latitude: Double, longitude: Double) -> Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    private func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

private struct StatusTabLabel: View {
    let canModifyCoordinates: Bool

    var body: some View {
        Label {
            Text("狀態")
        } icon: {
            Image(uiImage: statusImage)
        }
        .accessibilityLabel(canModifyCoordinates ? "狀態，可以修改座標" : "狀態，還不能修改座標")
    }

    private var statusImage: UIImage {
        let symbolName = canModifyCoordinates ? "checkmark.shield.fill" : "xmark.shield.fill"
        let color: UIColor = canModifyCoordinates ? .systemGreen : .systemRed
        let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        let image = UIImage(systemName: symbolName, withConfiguration: configuration) ?? UIImage()
        return image.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

private struct BottomTabBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.tabBarOnly)
        } else {
            content
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
