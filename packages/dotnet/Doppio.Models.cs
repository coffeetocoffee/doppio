using System.Text.Json.Serialization;

namespace Doppio;

/// <summary>Per-evaluation context, mirroring the JS SDK's EvaluationContext.</summary>
public sealed class EvaluationContext
{
    [JsonPropertyName("userId")]
    public string? UserId { get; set; }

    [JsonPropertyName("unitId")]
    public string? UnitId { get; set; }

    [JsonPropertyName("country")]
    public string? Country { get; set; }

    [JsonPropertyName("plan")]
    public string? Plan { get; set; }

    [JsonPropertyName("custom")]
    public Dictionary<string, object>? Custom { get; set; }

    /// <summary>Extra top-level attributes, flattened like the JS SDK.</summary>
    [JsonExtensionData]
    public Dictionary<string, object>? Extra { get; set; }
}

public sealed class Variation
{
    [JsonPropertyName("key")]
    public string Key { get; set; } = "";

    [JsonPropertyName("value")]
    public string Value { get; set; } = "";
}

public sealed class Rule
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("priority")]
    public int? Priority { get; set; }

    [JsonPropertyName("expression")]
    public string Expression { get; set; } = "";

    [JsonPropertyName("variation")]
    public int? Variation { get; set; }

    [JsonPropertyName("rolloutPercentage")]
    public int? RolloutPercentage { get; set; }
}

public sealed class Prerequisite
{
    [JsonPropertyName("flagKey")]
    public string FlagKey { get; set; } = "";

    [JsonPropertyName("variationKey")]
    public string VariationKey { get; set; } = "";
}

public sealed class FlagDefinition
{
    [JsonPropertyName("key")]
    public string Key { get; set; } = "";

    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; }

    [JsonPropertyName("rolloutPercentage")]
    public int? RolloutPercentage { get; set; }

    [JsonPropertyName("variations")]
    public List<Variation>? Variations { get; set; }

    [JsonPropertyName("defaultVariation")]
    public int? DefaultVariation { get; set; }

    [JsonPropertyName("prerequisites")]
    public List<Prerequisite>? Prerequisites { get; set; }

    [JsonPropertyName("rules")]
    public List<Rule>? Rules { get; set; }
}

public enum EvaluationReason
{
    Disabled,
    TargetMatch,
    Rollout,
    RolloutMiss,
    Default,
    PrerequisiteFailed,
    Error,
}

public sealed class EvaluationResult
{
    public string FlagKey { get; init; } = "";
    public bool Enabled { get; init; }
    public object? Value { get; init; }
    public string? Variation { get; init; }
    public EvaluationReason Reason { get; init; }
    public uint Bucket { get; init; }
}

public sealed class ExposureEvent
{
    public string FlagKey { get; init; } = "";
    public string UnitId { get; init; } = "";
    public bool Enabled { get; init; }
    public string? Variation { get; init; }
    public uint Bucket { get; init; }
    public long Timestamp { get; init; }
    public EvaluationReason Reason { get; init; }
}

public sealed class MetricEvent
{
    public string EventName { get; init; } = "";
    public Dictionary<string, object>? Payload { get; init; }
    public long Timestamp { get; init; }
}

public sealed class DoppioOptions
{
    public string? ClientKey { get; set; }
    public string? Environment { get; set; }
    public bool Offline { get; set; } = true;
    public List<FlagDefinition>? Flags { get; set; }
    public string? Endpoint { get; set; }
    public int PollIntervalMs { get; set; } = 30_000;
    public int FlushIntervalMs { get; set; } = 0;
}
