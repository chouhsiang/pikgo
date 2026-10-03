import Foundation
import HealthKit

enum HealthKitError: LocalizedError {
    case notAvailable
    case authorizationDenied
    case invalidStepCount
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "這台裝置無法使用健康資料。"
        case .authorizationDenied:
            return "尚未允許寫入步數。請到「設定 → 健康 → 資料取用與裝置」開啟權限。"
        case .invalidStepCount:
            return "請輸入大於 0 的整數步數。"
        case .saveFailed(let message):
            return "儲存失敗：\(message)"
        }
    }
}

@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!

    @Published var isAuthorized = false
    @Published var statusMessage: String?
    @Published var isBusy = false

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async throws {
        guard isHealthDataAvailable else {
            throw HealthKitError.notAvailable
        }

        try await store.requestAuthorization(toShare: [stepType], read: [stepType])
        refreshAuthorizationStatus()
    }

    func requireWriteAuthorization() throws {
        refreshAuthorizationStatus()
        if !isAuthorized {
            throw HealthKitError.authorizationDenied
        }
    }

    func refreshAuthorizationStatus() {
        let status = store.authorizationStatus(for: stepType)
        isAuthorized = (status == .sharingAuthorized)
    }

    func addSteps(_ steps: Int, date: Date = .now) async throws {
        guard steps > 0 else {
            throw HealthKitError.invalidStepCount
        }

        guard isHealthDataAvailable else {
            throw HealthKitError.notAvailable
        }

        isBusy = true
        defer { isBusy = false }

        try await requestAuthorization()
        try requireWriteAuthorization()

        try await saveSteps(steps, start: date, end: date)
        statusMessage = "已新增 \(steps) 步到「健康」App"
    }

    func addStepsQuietly(_ steps: Int, start: Date, end: Date) async {
        guard steps > 0, isHealthDataAvailable else { return }
        refreshAuthorizationStatus()
        if !isAuthorized {
            do {
                try await requestAuthorization()
                try requireWriteAuthorization()
            } catch {
                return
            }
        }
        try? await saveSteps(steps, start: start, end: end)
    }

    private func saveSteps(_ steps: Int, start: Date, end: Date) async throws {
        let quantity = HKQuantity(unit: .count(), doubleValue: Double(steps))
        let sample = HKQuantitySample(
            type: stepType,
            quantity: quantity,
            start: start,
            end: max(end, start.addingTimeInterval(1))
        )
        do {
            try await store.save(sample)
        } catch {
            throw HealthKitError.saveFailed(error.localizedDescription)
        }
    }
}
