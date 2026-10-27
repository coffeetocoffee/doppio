import Foundation

public final class Doppio {
    private var flags: [String: FlagDefinition] = [:]
    private let lock = NSLock()

    public struct Options {
        public var flags: [FlagDefinition]?
        public var endpoint: String?
        public var clientKey: String?
        public var offline: Bool = true
        public init(flags: [FlagDefinition]? = nil, endpoint: String? = nil, clientKey: String? = nil, offline: Bool = true) {
            self.flags = flags; self.endpoint = endpoint; self.clientKey = clientKey; self.offline = offline
        }
    }

    public static func `init`(options: Options = Options()) -> Doppio { Doppio(options: options) }

    private init(options: Options) {
        _ = doppio_native_abi_version()
        if let f = options.flags { loadFlags(f) }
    }

    public func bucket(flagKey: String, unitId: String) -> UInt32 {
        flagKey.withCString { fk in unitId.withCString { ui in doppio_native_bucket(fk, UInt32(flagKey.utf8.count), ui, UInt32(unitId.utf8.count)) } }
    }

    public func isEnabled(flagKey: String, unitId: String) -> Bool {
        flagKey.withCString { fk in unitId.withCString { ui in doppio_native_enabled(fk, UInt32(flagKey.utf8.count), ui, UInt32(unitId.utf8.count), 100) != 0 } }
    }

    public func isEnabled(flagKey: String, context: EvaluationContext) -> Bool { get(flagKey, context: context).enabled }

    public func get(_ flagKey: String, context: EvaluationContext = EvaluationContext()) -> EvaluationResult {
        let unitId = context.unitId ?? context.userId ?? "anonymous"
        lock.lock(); let flag = flags[flagKey]; lock.unlock()
        guard let flag = flag else {
            return EvaluationResult(flagKey: flagKey, enabled: false, value: false, variation: nil, reason: .error, bucket: 0)
        }
        let evaluation = evaluate(flag, context: context, unitId: unitId, visited: [])
        return evaluation
    }

    public func loadFlags(_ newFlags: [FlagDefinition]) {
        lock.lock(); flags.removeAll(); newFlags.forEach { flags[$0.key] = $0 }; lock.unlock()
    }

    // --- eval engine (ported from packages/js/src/client.ts) ---
    private func evaluate(_ flag: FlagDefinition, context: EvaluationContext, unitId: String, visited: Set<String>) -> EvaluationResult {
        if !flag.enabled {
            let def = defaultVariation(flag)
            return result(flag, false, parse(def?.value ?? "false"), def?.key, .disabled, bucket(flag.key, unitId))
        }
        if let prereqs = flag.prerequisites, !prereqs.isEmpty {
            if visited.contains(flag.key) { return result(flag, false, false, nil, .error, 0) }
            var v = visited; v.insert(flag.key)
            for p in prereqs {
                lock.lock(); let parent = flags[p.flagKey]; lock.unlock()
                guard let parent = parent else { return result(flag, false, false, nil, .error, 0) }
                let pr = evaluate(parent, context: context, unitId: unitId, visited: v)
                if !(pr.enabled && pr.variation == p.variationKey) {
                    let def = defaultVariation(flag)
                    return result(flag, false, parse(def?.value ?? "false"), def?.key, .prerequisiteFailed, bucket(flag.key, unitId))
                }
            }
        }
        if let rules = flag.rules, !rules.isEmpty {
            for rule in rules {
                if rule.expression.isEmpty { continue }
                if !evalRule(rule.expression, unitId: unitId, context: context) { continue }
                if let idx = rule.variation, let vs = flag.variations, idx < vs.count {
                    let sel = vs[idx]
                    return result(flag, true, parse(sel.value), sel.key, .targetMatch, bucket(flag.key, unitId))
                }
                if let pct = rule.rolloutPercentage {
                    let inR = isEnabledNative(flag.key, unitId, pct)
                    let b = bucket(flag.key, unitId)
                    if inR {
                        let sel = defaultVariation(flag)
                        return result(flag, true, parse(sel?.value ?? "true"), sel?.key ?? "on", .targetMatch, b)
                    }
                    let def = defaultVariation(flag)
                    return result(flag, false, parse(def?.value ?? "false"), def?.key, .defaultReason, b)
                }
            }
        }
        let rollout = flag.rolloutPercentage ?? 100
        let b = bucket(flag.key, unitId)
        let enabled = isEnabledNative(flag.key, unitId, rollout)
        if enabled {
            let sel = defaultVariation(flag)
            return result(flag, true, parse(sel?.value ?? "true"), sel?.key ?? "on", .rollout, b)
        }
        let def = defaultVariation(flag)
        return result(flag, false, parse(def?.value ?? "false"), def?.key, .rolloutMiss, b)
    }

    private func evalRule(_ expr: String, unitId: String, context: EvaluationContext) -> Bool {
        if !expr.contains("user.") && !expr.contains("account.") && !expr.contains("custom.") {
            return evalCel(expr, unitId: unitId)
        }
        return evalContext(expr, unitId: unitId, context: context)
    }

    private func evalContext(_ expr: String, unitId: String, context: EvaluationContext) -> Bool {
        var flat: [String: Any?] = ["unit_id": unitId, "user.id": unitId, "user.country": context.country, "user.plan": context.plan, "account.plan": context.plan]
        context.custom?.forEach { flat["custom.\($0.key)"] = $0.value }
        context.extra?.forEach { flat[$0.key] = $0.value }
        // == string
        if let m = expr.range(of: #"^([\w.]+)\s*==\s*"([^"]+)"$"#, options: .regularExpression) {
            _ = m
        }
        // simple regex handling
        let eqPattern = try? NSRegularExpression(pattern: #"^([\w.]+)\s*==\s*"([^"]+)"$"#)
        if let mm = eqPattern?.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)) {
            let field = (expr as NSString).substring(with: mm.range(at: 1))
            let expected = (expr as NSString).substring(with: mm.range(at: 2))
            return String(describing: flat[field] ?? "") == expected
        }
        let inPattern = try? NSRegularExpression(pattern: #"^([\w.]+)\s+in\s+\[(.*)\]$"#)
        if let mm = inPattern?.firstMatch(in: expr, range: NSRange(expr.startIndex..., in: expr)) {
            let field = (expr as NSString).substring(with: mm.range(at: 1))
            let itemsRaw = (expr as NSString).substring(with: mm.range(at: 2))
            let items = itemsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            return items.contains(String(describing: flat[field] ?? ""))
        }
        return evalCel(expr, unitId: unitId)
    }

    private func evalCel(_ expr: String, unitId: String) -> Bool {
        expr.withCString { e in unitId.withCString { u in doppio_native_eval_cel(e, UInt32(expr.utf8.count), u, UInt32(unitId.utf8.count)) != 0 } }
    }

    private func isEnabledNative(_ flagKey: String, _ unitId: String, _ pct: Int) -> Bool {
        flagKey.withCString { fk in unitId.withCString { ui in doppio_native_enabled(fk, UInt32(flagKey.utf8.count), ui, UInt32(unitId.utf8.count), UInt32(pct)) != 0 } }
    }

    private func defaultVariation(_ flag: FlagDefinition) -> Variation? {
        guard let vs = flag.variations, !vs.isEmpty else { return nil }
        let idx = (flag.defaultVariation ?? 0)
        return (idx >= 0 && idx < vs.count) ? vs[idx] : vs[0]
    }

    private func parse(_ raw: String) -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if let n = Double(raw) { return n }
        return raw
    }

    private func result(_ flag: FlagDefinition, _ enabled: Bool, _ value: Any, _ variation: String?, _ reason: EvaluationReason, _ bucket: UInt32) -> EvaluationResult {
        EvaluationResult(flagKey: flag.key, enabled: enabled, value: value, variation: variation, reason: reason, bucket: bucket)
    }
}

// --- models ---
public struct EvaluationContext { public var userId: String?; public var unitId: String?; public var country: String?; public var plan: String?; public var custom: [String: Any?]?; public var extra: [String: Any?]?; public init() {} }

public struct Variation { public let key: String; public let value: String; public init(key: String, value: String) { self.key = key; self.value = value } }

public struct Rule { public var expression: String = ""; public var variation: Int?; public var rolloutPercentage: Int?; public init() {} }

public struct Prerequisite { public var flagKey: String; public var variationKey: String; public init(flagKey: String, variationKey: String) { self.flagKey = flagKey; self.variationKey = variationKey } }

public struct FlagDefinition { public var key: String; public var enabled: Bool = false; public var rolloutPercentage: Int?; public var variations: [Variation]?; public var defaultVariation: Int?; public var prerequisites: [Prerequisite]?; public var rules: [Rule]?; public init(key: String) { self.key = key } }

public enum EvaluationReason { case disabled, targetMatch, rollout, rolloutMiss, defaultReason, prerequisiteFailed, error }

public struct EvaluationResult { public var flagKey: String; public var enabled: Bool; public var value: Any?; public var variation: String?; public var reason: EvaluationReason; public var bucket: UInt32; public init(flagKey: String, enabled: Bool, value: Any?, variation: String?, reason: EvaluationReason, bucket: UInt32) { self.flagKey = flagKey; self.enabled = enabled; self.value = value; self.variation = variation; self.reason = reason; self.bucket = bucket } }

// --- C ABI ---
@_silgen_name("doppio_native_abi_version") func doppio_native_abi_version() -> UInt32
@_silgen_name("doppio_native_bucket") func doppio_native_bucket(_ fk: UnsafePointer<CChar>, _ fl: UInt32, _ ui: UnsafePointer<CChar>, _ ul: UInt32) -> UInt32
@_silgen_name("doppio_native_enabled") func doppio_native_enabled(_ fk: UnsafePointer<CChar>, _ fl: UInt32, _ ui: UnsafePointer<CChar>, _ ul: UInt32, _ pct: UInt32) -> UInt32
@_silgen_name("doppio_native_eval_cel") func doppio_native_eval_cel(_ ep: UnsafePointer<CChar>, _ el: UInt32, _ up: UnsafePointer<CChar>, _ ul: UInt32) -> UInt32
