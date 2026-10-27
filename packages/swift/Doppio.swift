public class Doppio {
    public static func init(options: [String: Any]) -> Doppio { Doppio() }
    public func isEnabled(flagKey: String, unitId: String) -> Bool { false }
    public func get(flagKey: String, context: [String: Any]) -> Any? { nil }
}