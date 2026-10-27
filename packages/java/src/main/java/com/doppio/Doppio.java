package com.doppio;

import com.dylibso.chicory.runtime.Instance;
import com.dylibso.chicory.runtime.Module;
import com.dylibso.chicory.wasm.Parser;
import com.dylibso.chicory.runtime.Memory;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class Doppio {
    private final Instance wasm;
    private final Memory memory;
    private final Map<String, FlagDefinition> flags = new LinkedHashMap<>();
    private final List<ExposureEvent> exposureQueue = new ArrayList<>();
    private final List<MetricEvent> metricQueue = new ArrayList<>();
    private final Object lock = new Object();

    private final DoppioOptions options;

    public Doppio(Map<String, Object> options) {
        this.options = new DoppioOptions(options);
        InputStream in = getClass().getResourceAsStream("/doppio.wasm");
        if (in == null) throw new IllegalStateException("doppio.wasm not found on classpath");
        Module module = Parser.parse(in);
        this.wasm = module.instantiate();
        this.memory = wasm.memory();
        if (abiVersion() != 1) throw new IllegalStateException("doppio.wasm ABI mismatch");
        if (this.options.flags != null) loadFlags(this.options.flags);
    }

    public static Doppio init(Map<String, Object> options) { return new Doppio(options); }

    public long abiVersion() { return wasm.export("doppio_abi_version").apply()[0]; }

    private void writeStr(int offset, String s) {
        byte[] bytes = s.getBytes(StandardCharsets.UTF_8);
        memory.write(offset, bytes);
    }

    public long bucket(String flagKey, String unitId) {
        int offUnit = flagKey.getBytes(StandardCharsets.UTF_8).length + 1;
        writeStr(0, flagKey);
        writeStr(offUnit, unitId);
        return wasm.export("doppio_bucket").apply(0L, flagKey.length(), offUnit, unitId.length())[0];
    }

    public boolean isEnabled(String flagKey, String unitId) {
        int offUnit = flagKey.getBytes(StandardCharsets.UTF_8).length + 1;
        writeStr(0, flagKey);
        writeStr(offUnit, unitId);
        return wasm.export("doppio_enabled").apply(0L, flagKey.length(), offUnit, unitId.length(), 100L)[0] != 0;
    }

    public boolean evalCel(String expr, String unitId) {
        int offUnit = expr.getBytes(StandardCharsets.UTF_8).length + 1;
        writeStr(0, expr);
        writeStr(offUnit, unitId);
        return wasm.export("doppio_eval_cel").apply(0L, expr.length(), offUnit, unitId.length())[0] != 0;
    }

    public List<FlagDefinition> flagList() { synchronized (lock) { return new ArrayList<>(flags.values()); } }

    public void loadFlags(List<FlagDefinition> newFlags) {
        synchronized (lock) { flags.clear(); for (FlagDefinition f : newFlags) flags.put(f.key, f); }
    }

    public EvaluationResult get(String flagKey, EvaluationContext context) {
        if (context == null) context = new EvaluationContext();
        String unitId = context.unitId != null ? context.unitId : (context.userId != null ? context.userId : "anonymous");
        FlagDefinition flag;
        synchronized (lock) { flag = flags.get(flagKey); }
        if (flag == null) return new EvaluationResult(flagKey, false, false, null, EvaluationReason.ERROR, 0);
        EvaluationResult evaluation = evaluateInternal(flag, context, unitId, new HashSet<>());
        ExposureEvent exposure = new ExposureEvent(flagKey, unitId, evaluation.enabled, evaluation.variation, evaluation.bucket, System.currentTimeMillis(), evaluation.reason);
        synchronized (lock) { exposureQueue.add(exposure); }
        return evaluation;
    }

    public boolean isEnabled(String flagKey, EvaluationContext context) { return get(flagKey, context).enabled; }

    public void track(String eventName, Map<String, Object> payload) {
        synchronized (lock) { metricQueue.add(new MetricEvent(eventName, payload, System.currentTimeMillis())); }
    }

    public List<ExposureEvent> getExposures() { synchronized (lock) { return new ArrayList<>(exposureQueue); } }
    public List<ExposureEvent> flushExposures() { synchronized (lock) { List<ExposureEvent> s = new ArrayList<>(exposureQueue); exposureQueue.clear(); return s; } }
    public List<MetricEvent> getMetrics() { synchronized (lock) { return new ArrayList<>(metricQueue); } }
    public List<MetricEvent> flushMetrics() { synchronized (lock) { List<MetricEvent> s = new ArrayList<>(metricQueue); metricQueue.clear(); return s; } }

    private EvaluationResult evaluateInternal(FlagDefinition flag, EvaluationContext context, String unitId, Set<String> visited) {
        if (!flag.enabled) {
            Variation def = defaultVariation(flag);
            return result(flag, false, parse(def != null ? def.value : "false"), def != null ? def.key : null, EvaluationReason.DISABLED, bucket(flag.key, unitId));
        }
        if (flag.prerequisites != null && !flag.prerequisites.isEmpty()) {
            if (visited.contains(flag.key)) return result(flag, false, false, null, EvaluationReason.ERROR, 0);
            Set<String> v = new HashSet<>(visited); v.add(flag.key);
            for (Prerequisite p : flag.prerequisites) {
                FlagDefinition parent;
                synchronized (lock) { parent = flags.get(p.flagKey); }
                if (parent == null) return result(flag, false, false, null, EvaluationReason.ERROR, 0);
                EvaluationResult pr = evaluateInternal(parent, context, unitId, new HashSet<>(v));
                boolean matched = pr.enabled && Objects.equals(pr.variation, p.variationKey);
                if (!matched) {
                    Variation def = defaultVariation(flag);
                    return result(flag, false, parse(def != null ? def.value : "false"), def != null ? def.key : null, EvaluationReason.PREREQUISITE_FAILED, bucket(flag.key, unitId));
                }
            }
        }
        if (flag.rules != null && !flag.rules.isEmpty()) {
            for (Rule rule : flag.rules) {
                if (rule.expression == null || rule.expression.trim().isEmpty()) continue;
                if (!evalRule(rule.expression, unitId, context)) continue;
                if (rule.variation != null && flag.variations != null && rule.variation < flag.variations.size()) {
                    Variation sel = flag.variations.get(rule.variation);
                    return result(flag, true, parse(sel.value), sel.key, EvaluationReason.TARGET_MATCH, bucket(flag.key, unitId));
                }
                if (rule.rolloutPercentage != null) {
                    int pct = rule.rolloutPercentage;
                    boolean inR = isEnabledNative(flag.key, unitId, pct);
                    long b = bucket(flag.key, unitId);
                    if (inR) {
                        Variation sel = defaultVariation(flag);
                        return result(flag, true, parse(sel != null ? sel.value : "true"), sel != null ? sel.key : "on", EvaluationReason.TARGET_MATCH, b);
                    }
                    Variation def = defaultVariation(flag);
                    return result(flag, false, parse(def != null ? def.value : "false"), def != null ? def.key : null, EvaluationReason.DEFAULT, b);
                }
            }
        }
        int rollout = flag.rolloutPercentage != null ? flag.rolloutPercentage : 100;
        long b = bucket(flag.key, unitId);
        boolean enabled = isEnabledNative(flag.key, unitId, rollout);
        if (enabled) {
            Variation sel = defaultVariation(flag);
            return result(flag, true, parse(sel != null ? sel.value : "true"), sel != null ? sel.key : "on", EvaluationReason.ROLLOUT, b);
        }
        Variation def = defaultVariation(flag);
        return result(flag, false, parse(def != null ? def.value : "false"), def != null ? def.key : null, EvaluationReason.ROLLOUT_MISS, b);
    }

    private boolean evalRule(String expr, String unitId, EvaluationContext context) {
        if (!expr.contains("user.") && !expr.contains("account.") && !expr.contains("custom.")) {
            return evalCel(expr, unitId);
        }
        return evalContext(expr, unitId, context);
    }

    private boolean evalContext(String expr, String unitId, EvaluationContext context) {
        Map<String, Object> flat = new HashMap<>();
        flat.put("unit_id", unitId);
        flat.put("user.id", unitId);
        flat.put("user.country", context.country);
        flat.put("user.plan", context.plan);
        flat.put("account.plan", context.plan);
        if (context.custom != null) for (Map.Entry<String,Object> e : context.custom.entrySet()) flat.put("custom." + e.getKey(), e.getValue());
        if (context.extra != null) for (Map.Entry<String,Object> e : context.extra.entrySet()) flat.put(e.getKey(), e.getValue());
        java.util.regex.Matcher eq = java.util.regex.Pattern.compile("^([\\w.]+)\\s*==\\s*\"([^\"]+)\"$").matcher(expr);
        if (eq.matches()) {
            String field = eq.group(1); String expected = eq.group(2);
            return String.valueOf(flat.getOrDefault(field, "")).equals(expected);
        }
        java.util.regex.Matcher inm = java.util.regex.Pattern.compile("^([\\w.]+)\\s+in\\s+\\[(.*)\\]$").matcher(expr);
        if (inm.matches()) {
            String field = inm.group(1);
            String[] items = inm.group(2).split(",");
            List<String> list = new ArrayList<>();
            for (String s : items) list.add(s.trim().replace("\"","").replace("'",""));
            return list.contains(String.valueOf(flat.getOrDefault(field, "")));
        }
        return evalCel(expr, unitId);
    }

    private boolean isEnabledNative(String flagKey, String unitId, int pct) {
        int offUnit = flagKey.getBytes(StandardCharsets.UTF_8).length + 1;
        writeStr(0, flagKey);
        writeStr(offUnit, unitId);
        return wasm.export("doppio_enabled").apply(0L, flagKey.length(), offUnit, unitId.length(), pct)[0] != 0;
    }

    private Variation defaultVariation(FlagDefinition flag) {
        List<Variation> vs = flag.variations;
        if (vs == null || vs.isEmpty()) return null;
        int idx = flag.defaultVariation != null ? flag.defaultVariation : 0;
        if (idx < 0 || idx >= vs.size()) idx = 0;
        return vs.get(idx);
    }

    private Object parse(String raw) {
        if ("true".equals(raw)) return Boolean.TRUE;
        if ("false".equals(raw)) return Boolean.FALSE;
        try { return Double.parseDouble(raw); } catch (NumberFormatException ignored) {}
        return raw;
    }

    private EvaluationResult result(FlagDefinition flag, boolean enabled, Object value, String variation, EvaluationReason reason, long bucket) {
        return new EvaluationResult(flag.key, enabled, value, variation, reason, bucket);
    }

    // --- nested model classes ---
    public static class DoppioOptions {
        public String clientKey, environment, endpoint;
        public boolean offline = true;
        public List<FlagDefinition> flags;
        public int pollIntervalMs = 30000, flushIntervalMs = 0;
        public DoppioOptions() {}
        public DoppioOptions(Map<String,Object> o) {
            if (o == null) return;
            clientKey = (String) o.get("clientKey");
            environment = (String) o.get("environment");
            endpoint = (String) o.get("endpoint");
            if (o.get("offline") instanceof Boolean) offline = (Boolean) o.get("offline");
            if (o.get("flags") instanceof List) flags = (List<FlagDefinition>) o.get("flags");
        }
    }
    public static class EvaluationContext { public String userId, unitId, country, plan; public Map<String,Object> custom, extra; }
    public static class Variation { public String key, value; }
    public static class Rule { public String expression = ""; public Integer variation; public Integer rolloutPercentage; }
    public static class Prerequisite { public String flagKey, variationKey; }
    public static class FlagDefinition { public String key; public boolean enabled = false; public Integer rolloutPercentage; public List<Variation> variations; public Integer defaultVariation; public List<Prerequisite> prerequisites; public List<Rule> rules; }
    public enum EvaluationReason { DISABLED, TARGET_MATCH, ROLLOUT, ROLLOUT_MISS, DEFAULT, PREREQUISITE_FAILED, ERROR }
    public static class EvaluationResult { public String flagKey; public boolean enabled; public Object value; public String variation; public EvaluationReason reason; public long bucket; public EvaluationResult(String fk, boolean en, Object v, String var, EvaluationReason r, long b){flagKey=fk;enabled=en;value=v;variation=var;reason=r;bucket=b;} }
    public static class ExposureEvent { public String flagKey, unitId, variation; public boolean enabled; public long bucket, timestamp; public EvaluationReason reason; public ExposureEvent(String fk,String ui,boolean en,String v,long b,long t,EvaluationReason r){flagKey=fk;unitId=ui;enabled=en;variation=v;bucket=b;timestamp=t;reason=r;} }
    public static class MetricEvent { public String eventName; public Map<String,Object> payload; public long timestamp; public MetricEvent(String e, Map<String,Object> p, long t){eventName=e;payload=p;timestamp=t;} }
}
