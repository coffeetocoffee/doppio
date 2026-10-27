package com.doppio

class Doppio(private val options: Map<String, Any> = emptyMap()) {
    companion object {
        fun init(options: Map<String, Any> = emptyMap()) = Doppio(options)
    }
    fun isEnabled(flagKey: String, unitId: String): Boolean = false
    fun get(flagKey: String, context: Map<String, Any> = emptyMap()): Any? = null
}