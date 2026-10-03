//
//  ReadinessMonitor.swift
//  PikGo
//

import Combine
import Foundation
import Network
import Darwin

@MainActor
final class ReadinessMonitor: ObservableObject {
    static let shared = ReadinessMonitor()

    @Published private(set) var pairingImported = false
    @Published private(set) var isOnWiFi = false
    @Published private(set) var isOnCellular = false
    @Published private(set) var isLikelyAirplaneMode = false
    @Published private(set) var vpnReachable = false
    @Published private(set) var wifiSatisfiedThisSession = false
    @Published private(set) var vpnSatisfiedThisSession = false
    @Published private(set) var ddiStatus: DDIReadiness = .unknown
    @Published private(set) var healthStepsAvailable = false
    @Published private(set) var healthStepsAuthorized = false
    @Published private(set) var isChecking = false

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.chouhsiang.pikgo.readiness.path")
    private var probeTask: Task<Void, Never>?
    private var started = false
    private var lastVPNReady = false
    private var lastDDIProbe: Date?
    private var ddiProbeInFlight = false

    var wifiRequirementSatisfied: Bool {
        isOnWiFi || wifiSatisfiedThisSession
    }

    var vpnRequirementSatisfied: Bool {
        if isOnWiFi {
            return vpnReachable
        }
        return vpnReachable || vpnSatisfiedThisSession
    }

    var ddiRequirementSatisfied: Bool {
        ddiStatus == .mounted
    }

    var healthStepsRequirementSatisfied: Bool {
        !healthStepsAvailable || healthStepsAuthorized
    }

    var isReady: Bool {
        pairingImported && vpnRequirementSatisfied && ddiRequirementSatisfied && healthStepsRequirementSatisfied
    }

    var shouldPromptAirplaneToggle: Bool {
        pairingImported &&
            vpnRequirementSatisfied &&
            !ddiRequirementSatisfied &&
            !isOnWiFi &&
            (isOnCellular || isLikelyAirplaneMode)
    }

    var airplanePromptMessage: String {
        if isLikelyAirplaneMode {
            return "正在建立位置模擬，完成後請關閉飛航。"
        }
        return "請開啟飛航模式，再關閉。"
    }

    private init() {}

    func start() {
        guard !started else {
            refresh()
            return
        }
        started = true

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSnapshot(forceDDI: true)
            }
        }
        pathMonitor.start(queue: pathQueue)

        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                let retryAirplane = await MainActor.run {
                    self?.isLikelyAirplaneMode == true && self?.ddiRequirementSatisfied == false
                }
                try? await Task.sleep(for: retryAirplane ? .milliseconds(800) : .seconds(3))
            }
        }
    }

    func refresh(requestHealthAuthorization: Bool = false) {
        Task { await refreshSnapshot(forceDDI: true, requestHealthAuthorization: requestHealthAuthorization) }
    }

    private func refreshSnapshot(forceDDI: Bool = false, requestHealthAuthorization: Bool = false) async {
        pairingImported = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
        apply(path: pathMonitor.currentPath)
        refreshHealthSteps()
        if requestHealthAuthorization {
            await requestHealthStepsIfNeeded()
        }
        await probeVPN()
        updateSessionLatch()
        let vpnJustBecameReady = vpnRequirementSatisfied && !lastVPNReady
        lastVPNReady = vpnRequirementSatisfied
        await probeDDI(force: forceDDI || vpnJustBecameReady)
    }

    private func refreshHealthSteps() {
        let healthKit = HealthKitManager.shared
        healthStepsAvailable = healthKit.isHealthDataAvailable
        healthKit.refreshAuthorizationStatus()
        healthStepsAuthorized = healthKit.isAuthorized
    }

    private func requestHealthStepsIfNeeded() async {
        guard healthStepsAvailable, !healthStepsAuthorized else { return }
        try? await HealthKitManager.shared.requestAuthorization()
        refreshHealthSteps()
    }

    private func apply(path: NWPath) {
        let interfaces = path.availableInterfaces.map(\.type)
        isOnWiFi = interfaces.contains(.wifi) || path.usesInterfaceType(.wifi)
        isOnCellular = interfaces.contains(.cellular) || path.usesInterfaceType(.cellular)
        isLikelyAirplaneMode = !isOnWiFi && !isOnCellular
    }

    private func probeVPN() async {
        isChecking = true
        defer { isChecking = false }

        if hasLocalDevVPNAddress() {
            vpnReachable = true
            updateSessionLatch()
            return
        }

        let reachable = await canReachLocalDevVPN()
        if reachable {
            vpnReachable = true
        } else if isOnWiFi {
            vpnReachable = false
            vpnSatisfiedThisSession = false
        } else if !vpnSatisfiedThisSession {
            vpnReachable = false
        }
        updateSessionLatch()
    }

    private func updateSessionLatch() {
        if vpnReachable {
            vpnSatisfiedThisSession = true
        }
        if pairingImported && isOnWiFi && vpnRequirementSatisfied {
            wifiSatisfiedThisSession = true
        }
    }

    private func hasLocalDevVPNAddress() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }

        var pointer = ifaddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }

            if ipv4String(from: current.pointee.ifa_addr).map(isLocalDevVPNAddress) == true {
                return true
            }
            if ipv4String(from: current.pointee.ifa_dstaddr).map(isLocalDevVPNAddress) == true {
                return true
            }
        }
        return false
    }

    private func isLocalDevVPNAddress(_ ip: String) -> Bool {
        DeviceConnectionContext.isLocalDevVPNInterfaceAddress(ip)
    }

    private func ipv4String(from pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let pointer, pointer.pointee.sa_family == sa_family_t(AF_INET) else {
            return nil
        }
        var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: buffer)
        return ip == "0.0.0.0" ? nil : ip
    }

    private func probeDDI(force: Bool) async {
        if is_location_simulation_connected() {
            ddiStatus = .mounted
            return
        }

        guard pairingImported, vpnRequirementSatisfied else {
            if !is_location_simulation_connected() {
                ddiStatus = DeveloperDiskImageService.filesAreReady ? .unreachable : .filesMissing
            }
            return
        }

        if !DeveloperDiskImageService.filesAreReady {
            if !is_location_simulation_connected() {
                ddiStatus = .filesMissing
            }
            return
        }

        if is_location_simulation_connected(), !force {
            ddiStatus = .mounted
            return
        }

        if !is_location_simulation_connected(), !force, let lastDDIProbe, Date().timeIntervalSince(lastDDIProbe) < 3 {
            return
        }

        guard !ddiProbeInFlight else { return }
        ddiProbeInFlight = true
        defer { ddiProbeInFlight = false }
        lastDDIProbe = Date()

        if await Self.ensureLocationChannel() {
            ddiStatus = .mounted
            return
        }

        if isLikelyAirplaneMode {
            ddiStatus = .unreachable
            return
        }

        var status = await Self.queryMountStatus()
        if status == .notMounted {
            _ = await Self.mountIfNeeded()
            status = await Self.queryMountStatus()
        }

        if status == .notMounted {
            ddiStatus = .notMounted
            return
        }

        if await Self.ensureLocationChannel() {
            ddiStatus = .mounted
        } else if !is_location_simulation_connected() {
            ddiStatus = .unreachable
        }
    }

    private static func queryMountStatus() async -> MountCheckResult {
        await Task.detached(priority: .utility) {
            checkMountStatus()
        }.value
    }

    private static func mountIfNeeded() async -> String? {
        await Task.detached(priority: .utility) {
            mountDeveloperDiskImage(from: DeveloperDiskImageService.directoryURL.path)
        }.value
    }

    private static func ensureLocationChannel() async -> Bool {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                let pairingPath = PairingFileStore.prepareURL().path
                let code = ensure_location_simulation(
                    DeviceConnectionContext.targetIPAddress,
                    pairingPath
                )
                continuation.resume(returning: code == 0)
            }
        }
    }

    private func canReachLocalDevVPN() async -> Bool {
        let host = DeviceConnectionContext.targetIPAddress
        guard let port = NWEndpoint.Port(rawValue: 49152) else { return false }
        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: port),
            using: .tcp
        )

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let complete: (Bool) -> Void = { value in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(true)
                case .failed(let error):
                    if isHostPresent(error) {
                        complete(true)
                    } else {
                        complete(false)
                    }
                case .cancelled:
                    complete(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.4) {
                complete(false)
            }
        }
    }
}

enum DDIReadiness: Equatable {
    case unknown
    case filesMissing
    case mounted
    case notMounted
    case unreachable
}

private func isHostPresent(_ error: NWError) -> Bool {
    if case .posix(let code) = error {
        return code == .ECONNREFUSED || code == .ECONNRESET
    }
    return false
}
