package com.doppio;

import java.util.List;
import java.util.Map;

public class Doppio {
    private final Map<String, Object> flags;

    public Doppio(Map<String, Object> options) {
        this.flags = (Map<String, Object>) options.getOrDefault("flags", Map.of());
    }

    public static Doppio init(Map<String, Object> options) {
        return new Doppio(options);
    }

    public boolean isEnabled(String flagKey, String unitId) {
        Object f = flags.get(flagKey);
        if (f == null) return false;
        return true;
    }

    public Object get(String flagKey, Map<String, Object> context) {
        return flags.get(flagKey);
    }
}