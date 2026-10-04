//
//  UserDefaults+Keys.swift
//  PikGo
//

import Foundation

extension UserDefaults {
    enum Keys {
        /// Forces the device layer to treat the current device as TXM-capable.
        static let txmOverride = "overrideTXMForScripts"
        static let targetDeviceIP = "TunnelDeviceIP"
        /// Attaches processes with MallocGuardEdges and MallocScribble.
        static let mallocDebug = "enableMallocDebug"
        static let mallocGuardEdges = "enableMallocGuardEdges"
        static let mallocScribble = "enableMallocScribble"
        /// Legacy single route speed. Used only if a per-mode speed has not been set.
        static let routeSpeedKilometersPerHour = "routeSpeedKilometersPerHour"
        static let routeSpeedAutomobileKilometersPerHour = "routeSpeedKilometersPerHour.automobile"
        static let routeSpeedCyclingKilometersPerHour = "routeSpeedKilometersPerHour.cycling"
        static let routeSpeedWalkingKilometersPerHour = "routeSpeedKilometersPerHour.walking"
        static let routeSpeedAirplaneKilometersPerHour = "routeSpeedKilometersPerHour.airplane"
        /// MKDirections transport type: automobile, cycling, walking, or airplane.
        static let routeNavigationMode = "routeNavigationMode"
        static let addStepsWhileMoving = "addStepsWhileMoving"
        static let stepsPerMinuteWhileMoving = "stepsPerMinuteWhileMoving"
    }
}

enum RouteSimulationSpeed {
    static let defaultKilometersPerHour: Double = 18
    static let minimumKilometersPerHour: Double = 1
    static let maximumKilometersPerHour: Double = 120

    static func storageKey(for mode: RouteNavigationMode) -> String {
        switch mode {
        case .automobile:
            return UserDefaults.Keys.routeSpeedAutomobileKilometersPerHour
        case .cycling:
            return UserDefaults.Keys.routeSpeedCyclingKilometersPerHour
        case .walking:
            return UserDefaults.Keys.routeSpeedWalkingKilometersPerHour
        case .airplane:
            return UserDefaults.Keys.routeSpeedAirplaneKilometersPerHour
        }
    }

    static func kilometersPerHour(for mode: RouteNavigationMode = .current) -> Double {
        let defaults = UserDefaults.standard
        let raw: Double
        if let number = defaults.object(forKey: storageKey(for: mode)) as? NSNumber {
            raw = number.doubleValue
        } else if let legacy = defaults.object(forKey: UserDefaults.Keys.routeSpeedKilometersPerHour) as? NSNumber {
            raw = legacy.doubleValue
        } else {
            raw = defaultKilometersPerHour
        }
        return min(max(raw, minimumKilometersPerHour), maximumKilometersPerHour)
    }

    static func metersPerSecond(for mode: RouteNavigationMode = .current) -> Double {
        kilometersPerHour(for: mode) / 3.6
    }

    static var kilometersPerHour: Double {
        kilometersPerHour(for: .current)
    }

    static var metersPerSecond: Double {
        metersPerSecond(for: .current)
    }
}

enum RouteNavigationMode: String, CaseIterable, Identifiable {
    case automobile
    case cycling
    case walking
    case airplane

    var id: String { rawValue }

    static let defaultMode: RouteNavigationMode = .cycling

    var title: String {
        switch self {
        case .automobile:
            return "開車"
        case .cycling:
            return "腳踏車"
        case .walking:
            return "走路"
        case .airplane:
            return "飛機"
        }
    }

    var systemImage: String {
        switch self {
        case .automobile:
            return "car.fill"
        case .cycling:
            return "bicycle"
        case .walking:
            return "figure.walk"
        case .airplane:
            return "airplane"
        }
    }

    var missingRouteMessage: String {
        switch self {
        case .automobile:
            return "找不到可用的開車路線。"
        case .cycling:
            return "找不到可用的腳踏車路線。"
        case .walking:
            return "找不到可用的走路路線。"
        case .airplane:
            return "無法建立直線航線。"
        }
    }

    static var current: RouteNavigationMode {
        let raw = UserDefaults.standard.string(forKey: UserDefaults.Keys.routeNavigationMode)
        return raw.flatMap(RouteNavigationMode.init(rawValue:)) ?? defaultMode
    }
}

enum RouteMovingSteps {
    static let defaultEnabled = true
    static let defaultStepsPerMinute: Double = 200
    static let minimumStepsPerMinute: Double = 10
    static let maximumStepsPerMinute: Double = 600
    static let writeInterval: TimeInterval = 5

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: UserDefaults.Keys.addStepsWhileMoving) == nil {
            return defaultEnabled
        }
        return UserDefaults.standard.bool(forKey: UserDefaults.Keys.addStepsWhileMoving)
    }

    static var stepsPerMinute: Double {
        let stored = UserDefaults.standard.object(forKey: UserDefaults.Keys.stepsPerMinuteWhileMoving)
        let raw: Double
        if let number = stored as? NSNumber {
            raw = number.doubleValue
        } else {
            raw = defaultStepsPerMinute
        }
        return min(max(raw, minimumStepsPerMinute), maximumStepsPerMinute)
    }
}
