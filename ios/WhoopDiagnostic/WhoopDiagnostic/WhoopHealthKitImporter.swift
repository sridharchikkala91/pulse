import Foundation
import HealthKit
import SwiftData

/// Phase 37: HealthKit as an OPTIONAL SECONDARY source (section 37 of the
/// master prompt). WHOOP stays primary — this never overwrites WHOOP-
/// sourced data automatically, it only adds HEALTHKIT-sourced
/// HealthSampleRecord rows alongside whatever WHOOP already reported.
///
/// UNCERTAIN, not yet verified: whether the HealthKit entitlement actually
/// provisions on this project's free personal Apple Developer team. Some
/// capabilities require a paid Program membership; this has not been
/// confirmed either way for HealthKit specifically. The real device build
/// will reveal this — do not treat this class as "working" until that
/// build (and an actual authorization prompt on a real device) succeeds.
final class WhoopHealthKitImporter: ObservableObject {
    @Published var authorizationStatus: String = "NOT REQUESTED"
    @Published var lastImportStatus: String = ""

    private let store = HKHealthStore()

    static var isAvailableOnThisDevice: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .heartRate, .heartRateVariabilitySDNN, .restingHeartRate,
            .respiratoryRate, .bodyTemperature, .vo2Max, .activeEnergyBurned, .bodyMass
        ]
        for id in quantityIdentifiers {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let workout = HKObjectType.workoutType() as HKObjectType? { types.insert(workout) }
        return types
    }

    func requestAuthorization() async {
        guard Self.isAvailableOnThisDevice else {
            await MainActor.run { authorizationStatus = "NOT AVAILABLE ON THIS DEVICE" }
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            await MainActor.run { authorizationStatus = "REQUESTED (per-type grant is not readable back from HealthKit by design)" }
        } catch {
            await MainActor.run { authorizationStatus = "FAILED: \(error.localizedDescription)" }
        }
    }

    /// Imports heart rate + resting HR + HRV samples from the last N days
    /// into HealthSampleRecord rows, source="HEALTHKIT". Does not touch
    /// any WHOOP-sourced record.
    @MainActor
    func importRecentSamples(days: Int, context: ModelContext) async {
        guard Self.isAvailableOnThisDevice else {
            lastImportStatus = "HealthKit not available on this device"
            return
        }
        let types: [(HKQuantityTypeIdentifier, String, HKUnit)] = [
            (.heartRate, "heart_rate", HKUnit.count().unitDivided(by: .minute())),
            (.heartRateVariabilitySDNN, "hrv_sdnn", HKUnit.secondUnit(with: .milli)),
            (.restingHeartRate, "resting_heart_rate", HKUnit.count().unitDivided(by: .minute())),
            (.respiratoryRate, "respiratory_rate", HKUnit.count().unitDivided(by: .minute())),
            (.bodyTemperature, "body_temperature", HKUnit.degreeCelsius())
        ]

        var totalImported = 0
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        for (identifier, metricType, unit) in types {
            guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
            let samples = await fetchSamples(type: quantityType, predicate: predicate)
            for sample in samples {
                let value = sample.quantity.doubleValue(for: unit)
                let record = HealthSampleRecord(
                    timestamp: sample.startDate, metricType: metricType, value: value,
                    unit: unit.unitString, source: "HEALTHKIT"
                )
                context.insert(record)
                totalImported += 1
            }
        }
        try? context.save()
        lastImportStatus = "Imported \(totalImported) HealthKit sample(s) from the last \(days) day(s)"
    }

    private func fetchSamples(type: HKQuantityType, predicate: NSPredicate) async -> [HKQuantitySample] {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }
}
