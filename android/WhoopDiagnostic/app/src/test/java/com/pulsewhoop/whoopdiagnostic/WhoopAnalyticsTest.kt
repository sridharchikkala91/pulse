package com.pulsewhoop.whoopdiagnostic

import org.junit.Assert.*
import org.junit.Test

class WhoopAnalyticsTest {

    @Test fun `rmssd returns null for fewer than three intervals`() {
        assertNull(WhoopAnalytics.rmssd(listOf(800.0, 850.0)))
    }

    @Test fun `rmssd is zero for constant intervals`() {
        assertEquals(0.0, WhoopAnalytics.rmssd(listOf(1000.0, 1000.0, 1000.0))!!, 0.0001)
    }

    @Test fun `rmssd matches hand-computed value`() {
        val result = WhoopAnalytics.rmssd(listOf(800.0, 850.0, 780.0, 820.0))
        assertEquals(54.772255750516614, result!!, 0.0000001)
    }

    @Test fun `rollingBaseline nil for empty input`() {
        assertNull(WhoopAnalytics.rollingBaseline(emptyList()))
    }

    @Test fun `rollingBaseline median and MAD`() {
        val baseline = WhoopAnalytics.rollingBaseline(listOf(1.0, 2.0, 3.0, 4.0, 5.0))!!
        assertEquals(3.0, baseline.median, 0.0001)
        assertEquals(1 * 1.4826, baseline.robustStdDev, 0.0001)
        assertEquals(5, baseline.sampleCount)
    }

    @Test fun `recoveryScore is fifty when today exactly matches baseline with neutral sleep`() {
        val baseline = WhoopAnalytics.rollingBaseline(listOf(55.0, 60.0, 60.0, 65.0))!!
        val score = WhoopAnalytics.recoveryScore(
            hrvToday = baseline.median, rhrToday = baseline.median,
            hrvBaseline = baseline, rhrBaseline = baseline, sleepHours = 7.0
        )
        assertEquals(50, score)
    }

    @Test fun `recoveryScore nil when baseline has zero spread`() {
        val baseline = WhoopAnalytics.rollingBaseline(listOf(60.0, 60.0, 60.0, 60.0))!!
        assertEquals(0.0, baseline.robustStdDev, 0.0)
        assertNull(WhoopAnalytics.recoveryScore(60.0, 60.0, baseline, baseline, 7.0))
    }

    @Test fun `recoveryScore clamps to one and hundred`() {
        val baseline = WhoopAnalytics.rollingBaseline(listOf(10.0, 20.0, 30.0, 40.0))!!
        val score = WhoopAnalytics.recoveryScore(1000.0, null, baseline, null, 9.0)
        assertEquals(100, score)
    }

    @Test fun `strainScore zero for empty samples`() {
        assertEquals(0.0, WhoopAnalytics.strainScore(emptyList(), 60.0, 190.0), 0.0)
    }

    @Test fun `strainScore zero when max not above resting`() {
        assertEquals(0.0, WhoopAnalytics.strainScore(listOf(100.0, 110.0), 190.0, 190.0), 0.0)
    }

    @Test fun `strainScore stays within documented range`() {
        val samples = List(1000) { 150.0 }
        val strain = WhoopAnalytics.strainScore(samples, 55.0, 190.0)
        assertTrue(strain > 0)
        assertTrue(strain <= 21)
    }

    @Test fun `estimateVo2Max matches hand-computed value`() {
        val maxHr = WhoopAnalytics.estimateMaxHeartRate(27.0)
        assertEquals(189.1, maxHr, 0.001)
        val vo2 = WhoopAnalytics.estimateVo2Max(58.0, maxHr)
        assertEquals(49.88327586206896, vo2!!, 0.0001)
    }

    /** Same real inputs (age 27, RHR 58, HRV 65) already validated on real
     *  hardware in the web app after an earlier RHR-only formula swung 8
     *  years in the wrong direction. */
    @Test fun `estimateFitnessAge matches hand-computed value`() {
        val maxHr = WhoopAnalytics.estimateMaxHeartRate(27.0)
        val vo2 = WhoopAnalytics.estimateVo2Max(58.0, maxHr)
        val fitnessAge = WhoopAnalytics.estimateFitnessAge(27.0, vo2, 65.0)
        assertEquals(25, fitnessAge)
        assertTrue(fitnessAge!! < 27)
    }

    @Test fun `estimateFitnessAge nil without required inputs`() {
        assertNull(WhoopAnalytics.estimateFitnessAge(null, 50.0, 60.0))
        assertNull(WhoopAnalytics.estimateFitnessAge(30.0, null, 60.0))
    }

    @Test fun `sleepDurationScore nil without baseline`() {
        assertNull(WhoopAnalytics.sleepDurationScore(7.0, emptyList()))
    }

    @Test fun `sleepDurationScore hundred when matching baseline`() {
        val score = WhoopAnalytics.sleepDurationScore(7.0, listOf(7.0, 7.0, 7.0, 7.0))
        assertEquals(100, score)
    }
}
