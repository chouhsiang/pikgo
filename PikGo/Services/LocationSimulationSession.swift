import Foundation
import CoreLocation
import Combine

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    private var resendTimer: Timer?
    private var routeID: UUID?

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        }
    }

    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping () -> Void) {
        start(at: coordinate)
        resendTimer?.invalidate()
        var lastFire = Date.distantPast
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            let interval: TimeInterval = AppRuntimeState.shared.isActive ? 4 : 8
            guard Date().timeIntervalSince(lastFire) >= interval - 0.05 else { return }
            lastFire = Date()
            operation()
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        routeID = nil
        routeCoordinates = nil
    }

    func pauseResending() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D, publish: Bool = true) {
        if publish {
            self.coordinate = coordinate
        }
    }

    func stop() {
        pauseResending()
        clearRoute()
        guard isActive else { return }
        isActive = false
        coordinate = nil
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }
}

enum LocationSimulationControl {
    enum SimulateResult {
        case success
        case missingPairing
        case failed(Int32)
    }

    static func restoreRealLocation(completion: ((Int32) -> Void)? = nil) {
        NotificationCenter.default.post(name: .restoreRealLocation, object: nil)
        LocationSimulationSession.shared.pauseResending()
        LocationSimulationCommandQueue.shared.async {
            let code = clear_simulated_location()
            DispatchQueue.main.async {
                LocationSimulationSession.shared.stop()
                completion?(code)
            }
        }
    }

    static func simulateCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        completion: ((SimulateResult) -> Void)? = nil
    ) {
        let pairingPath = PairingFileStore.prepareURL().path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            DispatchQueue.main.async {
                completion?(.missingPairing)
            }
            return
        }

        LocationSimulationSession.shared.pauseResending()
        LocationSimulationSession.shared.clearRoute()
        NotificationCenter.default.post(
            name: .simulateSavedCoordinate,
            object: nil,
            userInfo: [
                "latitude": coordinate.latitude,
                "longitude": coordinate.longitude
            ]
        )

        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                coordinate.latitude,
                coordinate.longitude,
                pairingPath
            )
            DispatchQueue.main.async {
                if code == 0 {
                    LocationSimulationSession.shared.startResending(at: coordinate) {
                        LocationSimulationCommandQueue.shared.async {
                            _ = simulate_location(
                                DeviceConnectionContext.targetIPAddress,
                                coordinate.latitude,
                                coordinate.longitude,
                                pairingPath
                            )
                        }
                    }
                    completion?(.success)
                } else {
                    completion?(.failed(code))
                }
            }
        }
    }
}
