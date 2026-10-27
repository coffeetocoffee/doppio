package com.doppio

import com.fasterxml.jackson.databind.ObjectMapper

/**
 * Doppio flag model, mirroring packages/js/src/types.ts. Field names line up
 * with the control-plane JSON so `flags` can be deserialized directly.
 */
data class DoppioOptions(
    val clientKey: String? = null,
    val environment: String? = null,
    val offline: Boolean = true,
    val flags: List<FlagDefinition>? = null,
    val endpoint: String? = null,
    val pollIntervalMs: Int = 30_000,
    val flushIntervalMs: Int = 0,
)

data class EvaluationContext(
    val userId: String? = null,
    val unitId: String? = null,
    val country: String? = null,
    val plan: String? = null,
    val custom: Map<String, Any?>? = null,
    val extra: Map<String, Any?>? = null,
)

data class Variation(val key: String, val value: String)

data class Rule(
    val id: String? = null,
    val priority: Int? = null,
    val expression: String = "",
    val variation: Int? = null,
    val rolloutPercentage: Int? = null,
)

data class Prerequisite(val flagKey: String, val variationKey: String)

data class FlagDefinition(
    val key: String,
    val enabled: Boolean = false,
    val rolloutPercentage: Int? = null,
    val variations: List<Variation>? = null,
    val defaultVariation: Int? = null,
    val prerequisites: List<Prerequisite>? = null,
    val rules: List<Rule>? = null,
)

enum class EvaluationReason { DISABLED, TARGET_MATCH, ROLLOUT, ROLLOUT_MISS, DEFAULT, PREREQUISITE_FAILED, ERROR }

data class EvaluationResult(
    val flagKey: String,
    val enabled: Boolean,
    val value: Any?,
    val variation: String?,
    val reason: EvaluationReason,
    val bucket: Long,
)

data class ExposureEvent(
    val flagKey: String,
    val unitId: String,
    val enabled: Boolean,
    val variation: String?,
    val bucket: Long,
    val timestamp: Long,
    val reason: EvaluationReason,
)

data class MetricEvent(
    val eventName: String,
    val payload: Map<String, Any?>?,
    val timestamp: Long,
)

internal object Json {
    private val mapper = ObjectMapper()

    fun parse(raw: String): Any? = mapper.readTree(raw)
}
