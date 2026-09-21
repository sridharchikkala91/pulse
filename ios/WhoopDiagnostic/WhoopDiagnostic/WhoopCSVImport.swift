import Foundation
import SwiftData

/// Phase 6: WHOOP data export import (physiological_cycles.csv).
///
/// Column names below are ported directly from the web app's
/// importPhysiologicalCsv, which was verified against a real 317-day
/// WHOOP export (see CONTEXT.md history) — not guessed here.
///
/// HARD RULE (master prompt sections 16/25): a WHOOP_EXPORT-sourced
/// record's real recoveryScoreWhoop must NEVER be overwritten by anything
/// else, including a re-import. Our own algorithm writes to a completely
/// separate field (recoveryScoreOurs) so the two can never collide.
enum WhoopCSVImport {

    struct ImportResult {
        let rowsImported: Int
        let rowsSkipped: Int
    }

    static func parseCSV(_ text: String) -> [[String: String]] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let headers = splitCSVLine(headerLine)
        var rows: [[String: String]] = []
        for line in lines.dropFirst() {
            let cells = splitCSVLine(line)
            guard cells.count >= 2 else { continue }
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() {
                row[header.trimmingCharacters(in: .whitespaces)] = i < cells.count ? cells[i].trimmingCharacters(in: .whitespaces) : ""
            }
            rows.append(row)
        }
        return rows
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                out.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        out.append(current)
        return out
    }

    private static func num(_ row: [String: String], _ key: String) -> Double? {
        guard let raw = row[key], !raw.isEmpty else { return nil }
        return Double(raw)
    }

    /// Tries a couple of plausible WHOOP export timestamp formats. This
    /// exact format has NOT been re-verified against a real export in
    /// Swift (only the web app's JS `new Date(string)` lenient parsing was
    /// verified against a real 317-day export) — treat as
    /// PARTIALLY_CONFIRMED until checked against a real file here.
    private static func dateKey(fromTimestamp raw: String) -> String? {
        let formatters: [DateFormatter] = {
            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd HH:mm:ss"; f1.timeZone = TimeZone.current
            let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            return [f1, f2]
        }()
        var date: Date?
        for f in formatters {
            if let d = f.date(from: raw) { date = d; break }
        }
        if date == nil {
            date = ISO8601DateFormatter().date(from: raw)
        }
        guard let resolved = date else { return nil }
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"
        keyFormatter.timeZone = TimeZone.current
        return keyFormatter.string(from: resolved)
    }

    /// Imports physiological_cycles.csv rows into DailyMetricsRecord,
    /// keyed by the morning the cycle was scored (Wake onset, falling back
    /// to Cycle start time — same convention as the web app).
    @MainActor
    static func importPhysiologicalCycles(csvText: String, context: ModelContext) -> ImportResult {
        let rows = parseCSV(csvText)
        var imported = 0
        var skipped = 0

        for row in rows {
            let anchor = row["Wake onset"].flatMap { $0.isEmpty ? nil : $0 } ?? row["Cycle start time"]
            guard let anchor, let dateKey = dateKey(fromTimestamp: anchor) else {
                skipped += 1
                continue
            }

            let descriptor = FetchDescriptor<DailyMetricsRecord>(
                predicate: #Predicate { $0.dateKey == dateKey }
            )
            let existing = try? context.fetch(descriptor).first

            // HARD RULE: never overwrite an existing WHOOP_EXPORT record's
            // real recovery score with a re-import (idempotent re-imports
            // are fine; silently clobbering with possibly-different data
            // from a second export is not).
            if let existing, existing.source == "WHOOP_EXPORT", existing.recoveryScoreWhoop != nil {
                skipped += 1
                continue
            }

            let record = existing ?? DailyMetricsRecord(dateKey: dateKey)
            record.recoveryScoreWhoop = num(row, "Recovery score %")
            record.restingHeartRate = num(row, "Resting heart rate (bpm)")
            record.hrv = num(row, "Heart rate variability (ms)")
            record.strain = num(row, "Day Strain")
            if let asleepMinutes = num(row, "Asleep duration (min)") {
                record.sleepHours = asleepMinutes / 60
            }
            record.skinTempC = num(row, "Skin temp (celsius)")
            record.spo2Percent = num(row, "Blood oxygen %")
            record.respiratoryRate = num(row, "Respiratory rate (rpm)")
            record.averageHeartRate = num(row, "Average HR (bpm)")
            record.maxHeartRate = num(row, "Max HR (bpm)")
            record.source = "WHOOP_EXPORT"

            if existing == nil { context.insert(record) }
            imported += 1
        }

        try? context.save()
        return ImportResult(rowsImported: imported, rowsSkipped: skipped)
    }
}
