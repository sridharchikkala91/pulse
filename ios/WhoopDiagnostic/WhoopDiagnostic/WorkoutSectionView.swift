import SwiftUI
import SwiftData

/// Phase 19: manual workout logging. See WhoopDatabase.swift's
/// WorkoutRecord doc comment for why automatic detection isn't
/// implemented (needs undecoded IMU data).
struct WorkoutSectionView: View {
    @ObservedObject var ble: WhoopBLEManager
    let age: Double?
    let latestRestingHeartRate: Double?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutRecord.startTimestamp, order: .reverse) private var workouts: [WorkoutRecord]
    @State private var activityType = "Run"

    private let activityOptions = ["Run", "Walk", "Cycle", "Strength Training", "HIIT", "Swim", "General Activity"]

    var body: some View {
        Section("Workout (Phase 19 — manual logging)") {
            if ble.isWorkoutActive {
                row("Tracking", activityType)
                row("HR samples collected", "\(ble.workoutSampleCount)")
                Button("End Workout") {
                    ble.endWorkout(activityType: activityType, restingHeartRate: latestRestingHeartRate, age: age)
                }
            } else {
                Picker("Activity", selection: $activityType) {
                    ForEach(activityOptions, id: \.self) { Text($0) }
                }
                Button("Start Workout") { ble.startWorkout() }
                    .disabled(ble.handshakeState != "SUCCESS" && ble.connectionState != "CONNECTED")
            }
        }

        if !workouts.isEmpty {
            Section("Recent workouts") {
                ForEach(workouts.prefix(10)) { workout in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.activityType).bold()
                        Text([
                            workout.averageHeartRate.map { "Avg HR \(Int($0))bpm" },
                            workout.maxHeartRate.map { "Max HR \(Int($0))bpm" },
                            workout.strainOurs.map { String(format: "Strain %.1f", $0) }
                        ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
