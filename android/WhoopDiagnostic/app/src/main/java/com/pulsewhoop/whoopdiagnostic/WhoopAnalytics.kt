package com.pulsewhoop.whoopdiagnostic

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * Direct Kotlin port of WhoopAnalytics.swift (iOS) — same formulas, same
 * real validated inputs, same provenance. See that file's doc comments
 * for the full rationale; not repeated here to avoid drift between the
 * two copies of the same comment.
 *
 * EVERYTHING here is OUR OWN algorithm (RMSSD, Karvonen %HRR, Tanaka
 * max-HR, Uth-Sørensen-Overgaard-Pedersen VO2max) — never WHOOP's real
 * proprietary score. See docs/WHOOP5_LIMITATIONS.md in the repo root.
 */
object WhoopAnalytics {

    // ---- Phase 36: Personal baseline engine (robust median/MAD) ----

    data class RobustBaseline(val median: Double, val robustStdDev: Double, val sampleCount: Int)

    fun rollingBaseline(values: List<Double>): RobustBaseline? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val median = median(sorted)
        val deviations = values.map { abs(it - median) }.sorted()
        val mad = median(deviations)
        return RobustBaseline(median, mad * 1.4826, values.size)
    }

    private fun median(sorted: List<Double>): Double {
        val n = sorted.size
        if (n == 0) return 0.0
        return if (n % 2 == 1) sorted[n / 2] else (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // ---- Phase 11: HRV ----

    fun rmssd(rrIntervalsMs: List<Double>): Double? {
        if (rrIntervalsMs.size < 3) return null
        var sumSquares = 0.0
        for (i in 1 until rrIntervalsMs.size) {
            val diff = rrIntervalsMs[i] - rrIntervalsMs[i - 1]
            sumSquares += diff * diff
        }
        return sqrt(sumSquares / (rrIntervalsMs.size - 1))
    }

    /** Tanaka et al. (2001): 208 - 0.7 * age. */
    fun estimateMaxHeartRate(age: Double?): Double = if (age == null) 190.0 else 208 - 0.7 * age

    // ---- Phase 12: Recovery (OUR_ALGORITHM only) ----

    fun recoveryScore(
        hrvToday: Double?, rhrToday: Double?,
        hrvBaseline: RobustBaseline?, rhrBaseline: RobustBaseline?, sleepHours: Double?
    ): Int? {
        if (hrvToday == null || hrvBaseline == null || hrvBaseline.robustStdDev <= 0) return null
        val hrvZ = (hrvToday - hrvBaseline.median) / hrvBaseline.robustStdDev
        var rhrZ = 0.0
        if (rhrToday != null && rhrBaseline != null && rhrBaseline.robustStdDev > 0) {
            rhrZ = (rhrToday - rhrBaseline.median) / rhrBaseline.robustStdDev
        }
        var score = 50 + 22 * hrvZ - 13 * rhrZ
        if (sleepHours != null) {
            score += ((sleepHours - 7) * 3).coerceIn(-10.0, 10.0)
        }
        return score.let { Math.round(it).toInt() }.coerceIn(1, 100)
    }

    // ---- Phase 13: Strain (OUR_ALGORITHM only) ----

    fun strainScore(heartRateSamples: List<Double>, restingHeartRate: Double?, maxHeartRate: Double): Double {
        if (heartRateSamples.isEmpty() || restingHeartRate == null || maxHeartRate <= restingHeartRate) return 0.0
        var accumulatedHRR = 0.0
        for (hr in heartRateSamples) {
            val hrr = ((hr - restingHeartRate) / (maxHeartRate - restingHeartRate)).coerceAtLeast(0.0)
            accumulatedHRR += hrr
        }
        val normalized = accumulatedHRR / heartRateSamples.size
        val scaled = ln(1 + normalized * heartRateSamples.size / 100) * 8
        return scaled.coerceIn(0.0, 21.0)
    }

    // ---- Phase 30: Fitness / Biological Age (explicitly an estimate) ----

    fun estimateVo2Max(restingHeartRate: Double?, maxHeartRate: Double): Double? {
        if (restingHeartRate == null || restingHeartRate <= 0) return null
        return 15.3 * (maxHeartRate / restingHeartRate)
    }

    fun estimateFitnessAge(chronologicalAge: Double?, vo2Max: Double?, hrv: Double?): Int? {
        if (chronologicalAge == null || vo2Max == null) return null
        val avgVo2MaxForAge = 55 - 0.35 * (chronologicalAge - 20)
        val ageAdjustFromVo2Max = (avgVo2MaxForAge - vo2Max) / 0.35

        var adjust = ageAdjustFromVo2Max
        if (hrv != null) {
            val hrvZ = (hrv - 42) / 14
            val ageAdjustFromHrv = -4 * hrvZ
            adjust = 0.35 * ageAdjustFromVo2Max + 0.65 * ageAdjustFromHrv
        }
        val age = chronologicalAge + adjust
        return Math.round(age).toInt().coerceIn(10, 90)
    }

    // ---- Phase 27: Sleep Score (duration component only, for now) ----

    fun sleepDurationScore(lastNightHours: Double, recentNightsHours: List<Double>): Int? {
        val baseline = rollingBaseline(recentNightsHours) ?: return null
        if (baseline.median <= 0) return null
        val ratio = lastNightHours / baseline.median
        val score = (ratio * 100).coerceIn(0.0, 100.0)
        return Math.round(score).toInt()
    }
}
