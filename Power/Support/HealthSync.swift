import Foundation
import HealthKit
import SwiftData

/// Optional Apple Health integration: finished workouts are saved as strength-training
/// workouts, bodyweight entries are written to Health, and bodyweight logged elsewhere
/// (a smart scale, the Health app) is imported into Body measurements.
final class HealthSync {
    static let shared = HealthSync()
    static let enabledKey = "healthSyncEnabled"

    private let store = HKHealthStore()
    private let bodyMass = HKQuantityType(.bodyMass)
    private let kilograms = HKUnit.gramUnit(with: .kilo)

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Shows the Health permission sheet the first time; later calls return immediately.
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), bodyMass], read: [bodyMass])
            return true
        } catch {
            print("Health authorization failed: \(error)")
            return false
        }
    }

    func saveWorkout(start: Date, end: Date) {
        guard isAvailable, end > start else { return }
        Task {
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .traditionalStrengthTraining
            configuration.locationType = .indoor
            let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
            do {
                try await builder.beginCollection(at: start)
                try await builder.endCollection(at: end)
                _ = try await builder.finishWorkout()
            } catch {
                print("Couldn't save workout to Health: \(error)")
            }
        }
    }

    func saveBodyweight(kilograms value: Double, date: Date) {
        guard isAvailable else { return }
        let sample = HKQuantitySample(type: bodyMass, quantity: HKQuantity(unit: kilograms, doubleValue: value),
                                      start: date, end: date)
        Task {
            do {
                try await store.save(sample)
            } catch {
                print("Couldn't save bodyweight to Health: \(error)")
            }
        }
    }

    /// Copies bodyweight from other Health sources into the app, skipping ones already here.
    @MainActor
    func importBodyweight(into context: ModelContext) async {
        guard isAvailable else { return }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: bodyMass)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 365)
        guard let samples = try? await descriptor.result(for: store) else { return }

        let ownBundle = Bundle.main.bundleIdentifier
        let bodyweightRaw = BodyMeasurementKind.bodyweight.rawValue
        let existing = (try? context.fetch(FetchDescriptor<BodyMeasurement>(
            predicate: #Predicate { $0.kindRaw == bodyweightRaw }))) ?? []

        for sample in samples where sample.sourceRevision.source.bundleIdentifier != ownBundle {
            let value = sample.quantity.doubleValue(for: kilograms)
            let isDuplicate = existing.contains {
                abs($0.date.timeIntervalSince(sample.endDate)) < 60 && abs($0.value - value) < 0.05
            }
            if !isDuplicate {
                context.insert(BodyMeasurement(date: sample.endDate, kind: .bodyweight, value: value))
            }
        }
    }
}
