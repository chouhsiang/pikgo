//
//  AppBootstrapper.swift
//  PikGo
//

import Foundation
import ObjectiveC.runtime
import UIKit

enum AppBootstrapper {
    static func configure() {
        IdeviceLogFileManager.shared.prepareForLogging()
        disablePerformanceOverlays()
        registerDefaultSettings()
        ensureKeepAliveSelection()
        applyDocumentPickerCopyWorkaround()
    }

    private static func disablePerformanceOverlays() {
        setenv("MTL_HUD_ENABLED", "0", 1)
        unsetenv("MTL_HUD")
    }

    private static func registerDefaultSettings() {
        UserDefaults.standard.register(defaults: [
            "keepAliveAudio": true,
            "keepAliveLocation": true,
            UserDefaults.Keys.routeSpeedKilometersPerHour: RouteSimulationSpeed.defaultKilometersPerHour,
            UserDefaults.Keys.routeSpeedAutomobileKilometersPerHour: RouteSimulationSpeed.defaultKilometersPerHour,
            UserDefaults.Keys.routeSpeedCyclingKilometersPerHour: RouteSimulationSpeed.defaultKilometersPerHour,
            UserDefaults.Keys.routeSpeedWalkingKilometersPerHour: RouteSimulationSpeed.defaultKilometersPerHour,
            UserDefaults.Keys.routeSpeedAirplaneKilometersPerHour: RouteSimulationSpeed.defaultKilometersPerHour,
            UserDefaults.Keys.routeNavigationMode: RouteNavigationMode.defaultMode.rawValue,
            UserDefaults.Keys.addStepsWhileMoving: RouteMovingSteps.defaultEnabled,
            UserDefaults.Keys.stepsPerMinuteWhileMoving: RouteMovingSteps.defaultStepsPerMinute
        ])
    }

    private static func ensureKeepAliveSelection() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "keepAliveAudio"), !defaults.bool(forKey: "keepAliveLocation") {
            defaults.set(true, forKey: "keepAliveAudio")
        }
    }

    private static func applyDocumentPickerCopyWorkaround() {
        let fixedSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        let originalSelector = #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))

        guard let fixedMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, fixedSelector),
              let originalMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, originalSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, fixedMethod)
    }
}
