package com.doppio

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class DoppioTest {

    @Test
    fun bucketMatchesZigCore() {
        val d = Doppio.init()
        assertEquals(24261L, d.bucket("flag-a", "user-1"))
        assertEquals(42637L, d.bucket("flag-b", "user-1"))
        assertEquals(58649L, d.bucket("flag-a", "user-2"))
    }

    @Test
    fun disabledFlagReturnsDisabled() {
        val d = Doppio.init()
        d.loadFlags(listOf(FlagDefinition(key = "off", enabled = false)))
        val res = d.get("off", EvaluationContext(unitId = "u1"))
        assertEquals(false, res.enabled)
        assertEquals(EvaluationReason.DISABLED, res.reason)
    }

    @Test
    fun targetingRulePlanMatch() {
        val d = Doppio.init()
        d.loadFlags(listOf(
            FlagDefinition(
                key = "targeted",
                enabled = true,
                rolloutPercentage = 100,
                rules = listOf(Rule(id = "premium", expression = "user.plan == \"premium\"", variation = 1)),
                variations = listOf(Variation("standard", "false"), Variation("premium", "true")),
                defaultVariation = 0,
            )
        ))
        val premium = d.get("targeted", EvaluationContext(unitId = "u1", plan = "premium"))
        assertEquals(true, premium.enabled)
        assertEquals("premium", premium.variation)
        assertEquals(EvaluationReason.TARGET_MATCH, premium.reason)
    }

    @Test
    fun exposuresTracked() {
        val d = Doppio.init()
        d.loadFlags(listOf(FlagDefinition(key = "f", enabled = true, rolloutPercentage = 100)))
        d.get("f", EvaluationContext(unitId = "u1"))
        assertEquals(1, d.flushExposures().size)
    }
}
