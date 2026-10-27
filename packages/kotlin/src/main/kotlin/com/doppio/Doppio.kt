package com.doppio

import com.dylibso.chicory.runtime.Instance
import com.dylibso.chicory.runtime.Module
import com.dylibso.chicory.wasm.Parser
import com.dylibso.chicory.runtime.Memory
import java.io.InputStream
import java.nio.charset.StandardCharsets

/**
 * Doppio core binding for Kotlin/JVM. Loads the embedded `doppio.wasm` module
 * with Chicory, a pure-JVM WASM runtime, so there is no native binary. The
 * evaluation engine below mirrors packages/js/src/client.ts so Kotlin flags
 * bucket identically to every other SDK.
 */
class Doppio(private val options: DoppioOptions = DoppioOptions()) {

    private val wasm: Instance
    private val memory: Memory
    private val flags: MutableMap<String, FlagDefinition> = LinkedHashMap()
    private val exposureQueue: MutableList<ExposureEvent> = mutableListOf()
    private val metricQueue: MutableList<MetricEvent> = mutableListOf()
    private val lock = Any()

    init {
        val input: InputStream = checkNotNull(
            javaClass.getResourceAsStream("/doppio.wasm")
        ) { "doppio.wasm not found on classpath" }
        val module = Parser.parse(input)
        this.wasm = module.instantiate()
        this.memory = wasm.memory()
        check(abiVersion() == 1u) { "doppio.wasm ABI mismatch" }
        options.flags?.let { loadFlags(it) }
    }

    companion object {
        @JvmStatic
        fun init(options: DoppioOptions = DoppioOptions()): Doppio = Doppio(options)
    }

    fun abiVersion(): Long = wasm.export("doppio_abi_version").apply()[0]

    fun bucket(flagKey: String, unitId: String): Long {
        val offUnit = flagKey.encodeToByteArray().size + 1
        writeString(0, flagKey)
        writeString(offUnit, unitId)
        return wasm.export("doppio_bucket").apply(0L, flagKey.length.toLong(), offUnit.toLong(), unitId.length.toLong())[0]
    }

    fun isEnabled(flagKey: String, unitId: String): Boolean {
        val offUnit = flagKey.encodeToByteArray().size + 1
        writeString(0, flagKey)
        writeString(offUnit, unitId)
        return wasm.export("doppio_enabled")
            .apply(0L, flagKey.length.toLong(), offUnit.toLong(), unitId.length.toLong(), 100L)[0] != 0L
    }

    fun evalCel(expression: String, unitId: String): Boolean {
        val offUnit = expression.encodeToByteArray().size + 1
        writeString(0, expression)
        writeString(offUnit, unitId)
        return wasm.export("doppio_eval_cel")
            .apply(0L, expression.length.toLong(), offUnit.toLong(), unitId.length.toLong())[0] != 0L
    }

    val flagList: List<FlagDefinition> get() = synchronized(lock) { flags.values.toList() }

    fun loadFlags(newFlags: List<FlagDefinition>) {
        synchronized(lock) {
            flags.clear()
            newFlags.forEach { flags[it.key] = it }
        }
    }

    /** Evaluate a flag and record an exposure. Mirrors JS client.get(). */
    fun get(flagKey: String, context: EvaluationContext = EvaluationContext()): EvaluationResult {
        val unitId = context.unitId ?: context.userId ?: "anonymous"
        val flag = synchronized(lock) { flags[flagKey] }
        if (flag == null) {
            return EvaluationResult(flagKey, false, false, null, EvaluationReason.ERROR, 0)
        }
        val evaluation = evaluateInternal(flag, context, unitId, mutableSetOf())
        val exposure = ExposureEvent(
            flagKey = flagKey,
            unitId = unitId,
            enabled = evaluation.enabled,
            variation = evaluation.variation,
            bucket = evaluation.bucket,
            timestamp = System.currentTimeMillis(),
            reason = evaluation.reason,
        )
        synchronized(lock) { exposureQueue.add(exposure) }
        return evaluation
    }

    fun isEnabled(flagKey: String, context: EvaluationContext): Boolean = get(flagKey, context).enabled

    fun track(eventName: String, payload: Map<String, Any?>? = null) {
        synchronized(lock) {
            metricQueue.add(MetricEvent(eventName, payload, System.currentTimeMillis()))
        }
    }

    fun getExposures(): List<ExposureEvent> = synchronized(lock) { exposureQueue.toList() }

    fun flushExposures(): List<ExposureEvent> = synchronized(lock) {
        val snapshot = exposureQueue.toList()
        exposureQueue.clear()
        snapshot
    }

    fun getMetrics(): List<MetricEvent> = synchronized(lock) { metricQueue.toList() }

    fun flushMetrics(): List<MetricEvent> = synchronized(lock) {
        val snapshot = metricQueue.toList()
        metricQueue.clear()
        snapshot
    }

    // --- evaluation engine (ported from packages/js/src/client.ts) ---

    private fun evaluateInternal(
        flag: FlagDefinition,
        context: EvaluationContext,
        unitId: String,
        visited: MutableSet<String>,
    ): EvaluationResult {
        // 1. Disabled
        if (!flag.enabled) {
            val def = getDefaultVariation(flag)
            return EvaluationResult(
                flag.key, false,
                parseVariationValue(def?.value ?: "false"),
                def?.key, EvaluationReason.DISABLED, bucket(flag.key, unitId),
            )
        }

        // 2. Prerequisites
        if (!flag.prerequisites.isNullOrEmpty()) {
            if (!visited.add(flag.key)) {
                return EvaluationResult(flag.key, false, false, null, EvaluationReason.ERROR, 0)
            }
            for (prereq in flag.prerequisites) {
                val parent = synchronized(lock) { flags[prereq.flagKey] }
                    ?: return EvaluationResult(flag.key, false, false, null, EvaluationReason.ERROR, 0)
                val parentResult = evaluateInternal(parent, context, unitId, visited.toMutableSet())
                val matched = parentResult.enabled && parentResult.variation == prereq.variationKey
                if (!matched) {
                    val def = getDefaultVariation(flag)
                    return EvaluationResult(
                        flag.key, false,
                        parseVariationValue(def?.value ?: "false"),
                        def?.key, EvaluationReason.PREREQUISITE_FAILED, bucket(flag.key, unitId),
                    )
                }
            }
        }

        // 3. Targeting rules
        if (!flag.rules.isNullOrEmpty()) {
            for (rule in flag.rules) {
                if (rule.expression.isBlank()) continue
                if (!evaluateRuleExpression(rule.expression, unitId, context)) continue

                val selectedVar = rule.variation?.let { idx ->
                    flag.variations?.getOrNull(idx)
                }
                if (selectedVar != null) {
                    return EvaluationResult(
                        flag.key, true, parseVariationValue(selectedVar.value),
                        selectedVar.key, EvaluationReason.TARGET_MATCH, bucket(flag.key, unitId),
                    )
                }

                val rollout = rule.rolloutPercentage
                if (rollout != null) {
                    val inRollout = inRollout(flag.key, unitId, rollout)
                    val b = bucket(flag.key, unitId)
                    if (inRollout) {
                        val selected = getDefaultVariation(flag)
                        return EvaluationResult(
                            flag.key, true,
                            parseVariationValue(selected?.value ?: "true"),
                            selected?.key ?: "on", EvaluationReason.TARGET_MATCH, b,
                        )
                    }
                    val def = getDefaultVariation(flag)
                    return EvaluationResult(
                        flag.key, false,
                        parseVariationValue(def?.value ?: "false"),
                        def?.key, EvaluationReason.DEFAULT, b,
                    )
                }
            }
        }

        // 4. Default rollout
        val rollout = flag.rolloutPercentage ?: 100
        val b = bucket(flag.key, unitId)
        val enabled = inRollout(flag.key, unitId, rollout)
        return if (enabled) {
            val selected = getDefaultVariation(flag)
            EvaluationResult(
                flag.key, true,
                parseVariationValue(selected?.value ?: "true"),
                selected?.key ?: "on", EvaluationReason.ROLLOUT, b,
            )
        } else {
            val def = getDefaultVariation(flag)
            EvaluationResult(
                flag.key, false,
                parseVariationValue(def?.value ?: "false"),
                def?.key, EvaluationReason.ROLLOUT_MISS, b,
            )
        }
    }

    private fun evaluateRuleExpression(expr: String, unitId: String, context: EvaluationContext): Boolean {
        return if (!expr.contains("user.") && !expr.contains("account.") && !expr.contains("custom.")) {
            evalCel(expr, unitId)
        } else {
            evaluateContextExpression(expr, unitId, context)
        }
    }

    private fun evaluateContextExpression(expr: String, unitId: String, context: EvaluationContext): Boolean {
        val flat = mutableMapOf<String, Any?>(
            "unit_id" to unitId,
            "user.id" to unitId,
            "user.country" to context.country,
            "user.plan" to context.plan,
            "account.plan" to context.plan,
        )
        context.custom?.forEach { (k, v) -> flat["custom.$k"] = v }
        context.extra?.forEach { (k, v) -> flat[k] = v }

        Regex("^([\\w.]+)\\s*==\\s*[\"']([^\"']+)[\"']$").matchEntire(expr)?.let { m ->
            val field = m.groupValues[1]
            val expected = m.groupValues[2]
            return flat[field]?.toString() == expected
        }

        Regex("^([\\w.]+)\\s+in\\s+\\[(.*)\\]$").matchEntire(expr)?.let { m ->
            val field = m.groupValues[1]
            val items = m.groupValues[2].split(",").map { it.trim().trim('"', '\'') }
            return items.contains(flat[field]?.toString())
        }

        return evalCel(expr, unitId)
    }

    private fun inRollout(flagKey: String, unitId: String, percentage: Int): Boolean {
        val pct = percentage.coerceIn(0, 100)
        val offUnit = flagKey.encodeToByteArray().size + 1
        writeString(0, flagKey)
        writeString(offUnit, unitId)
        return wasm.export("doppio_enabled")
            .apply(0L, flagKey.length.toLong(), offUnit.toLong(), unitId.length.toLong(), pct.toLong())[0] != 0L
    }

    private fun getDefaultVariation(flag: FlagDefinition): Variation? {
        val variations = flag.variations ?: return null
        if (variations.isEmpty()) return null
        val idx = flag.defaultVariation ?: 0
        return if (idx in variations.indices) variations[idx] else variations[0]
    }

    private fun parseVariationValue(raw: String): Any? {
        return when (raw) {
            "true" -> true
            "false" -> false
            else -> raw.toDoubleOrNull()
                ?: runCatching { Json.parse(raw) }.getOrNull()
                ?: raw
        }
    }

    private fun writeString(offset: Int, s: String) {
        memory.write(offset, s.toByteArray(StandardCharsets.UTF_8))
    }
}

