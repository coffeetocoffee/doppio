using System.Text.Json;
using System.Text.RegularExpressions;

namespace Doppio;

/// <summary>
/// Doppio feature flag and experimentation client. Evaluation semantics mirror
/// the JS SDK (packages/js/src/client.ts); the bucketing and CEL primitives run
/// in the native libdoppio core via P/Invoke.
/// </summary>
public sealed class Doppio : IDisposable
{
    private readonly Dictionary<string, FlagDefinition> _flags = new();
    private readonly List<ExposureEvent> _exposureQueue = new();
    private readonly List<MetricEvent> _metricQueue = new();
    private readonly DoppioOptions _options;
    private readonly object _lock = new();
    private readonly HttpClient? _http;
    private readonly CancellationTokenSource _cts = new();
    private Task? _pollTask;
    private volatile bool _disposed;

    private Doppio(DoppioOptions options)
    {
        _options = options;
        NativeCore.GetAbiVersion(); // verify native core is loadable

        if (options.Flags is { Count: > 0 })
        {
            LoadFlags(options.Flags);
        }

        if (!options.Offline && !string.IsNullOrEmpty(options.Endpoint))
        {
            _http = new HttpClient { BaseAddress = new Uri(options.Endpoint.TrimEnd('/') + "/") };
            if (!string.IsNullOrEmpty(options.ClientKey))
            {
                _http.DefaultRequestHeaders.Authorization =
                    new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", options.ClientKey);
            }
            _pollTask = PollLoop();
        }
    }

    public static Doppio Init(DoppioOptions options) => new(options);

    public IReadOnlyDictionary<string, FlagDefinition> Flags => _flags;

    public uint Bucket(string flagKey, string unitId) => NativeCore.Bucket(flagKey, unitId);

    public bool IsEnabled(string flagKey, string unitId) =>
        Get(flagKey, new EvaluationContext { UnitId = unitId }).Enabled;

    public bool IsEnabled(string flagKey, EvaluationContext context) => Get(flagKey, context).Enabled;

    /// <summary>Evaluate a flag, mirroring the JS SDK's rules/prerequisites/rollout chain.</summary>
    public EvaluationResult Get(string flagKey, EvaluationContext? context = null)
    {
        context ??= new EvaluationContext();
        string unitId = context.UnitId ?? context.UserId ?? "anonymous";

        FlagDefinition? flag;
        lock (_lock)
        {
            _flags.TryGetValue(flagKey, out flag);
        }

        if (flag is null)
        {
            return new EvaluationResult
            {
                FlagKey = flagKey,
                Enabled = false,
                Value = false,
                Variation = null,
                Reason = EvaluationReason.Error,
                Bucket = 0,
            };
        }

        EvaluationResult evaluation = EvaluateInternal(flag, context, unitId, new HashSet<string>());
        RecordExposure(flagKey, unitId, evaluation);
        return evaluation;
    }

    public void LoadFlags(IEnumerable<FlagDefinition> flags)
    {
        lock (_lock)
        {
            _flags.Clear();
            foreach (FlagDefinition flag in flags)
            {
                _flags[flag.Key] = flag;
            }
        }
    }

    public void SetFlags(IEnumerable<FlagDefinition> flags)
    {
        List<string> changed = new();
        List<FlagDefinition> list = flags.ToList();
        lock (_lock)
        {
            foreach (FlagDefinition flag in list)
            {
                if (!_flags.TryGetValue(flag.Key, out FlagDefinition? existing) ||
                    !JsonSerializer.Serialize(existing).Equals(JsonSerializer.Serialize(flag)))
                {
                    changed.Add(flag.Key);
                }
            }
            _flags.Clear();
            foreach (FlagDefinition flag in list)
            {
                _flags[flag.Key] = flag;
            }
        }
    }

    public void Track(string eventName, Dictionary<string, object>? payload = null)
    {
        lock (_lock)
        {
            _metricQueue.Add(new MetricEvent
            {
                EventName = eventName,
                Payload = payload,
                Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            });
        }
    }

    public IReadOnlyList<ExposureEvent> GetExposures()
    {
        lock (_lock) { return _exposureQueue.ToList(); }
    }

    public IReadOnlyList<ExposureEvent> FlushExposures()
    {
        lock (_lock)
        {
            var snapshot = _exposureQueue.ToList();
            _exposureQueue.Clear();
            return snapshot;
        }
    }

    public IReadOnlyList<MetricEvent> GetMetrics()
    {
        lock (_lock) { return _metricQueue.ToList(); }
    }

    public IReadOnlyList<MetricEvent> FlushMetrics()
    {
        lock (_lock)
        {
            var snapshot = _metricQueue.ToList();
            _metricQueue.Clear();
            return snapshot;
        }
    }

    /// <summary>Fetch the current flag set once from the control plane.</summary>
    public async Task<List<FlagDefinition>> SyncOnceAsync(CancellationToken ct = default)
    {
        if (_http is null)
        {
            return _flags.Values.ToList();
        }
        int seq = 0;
        using HttpResponseMessage resp = await _http.GetAsync($"/sync/updates/{seq}", ct);
        resp.EnsureSuccessStatusCode();
        string body = await resp.Content.ReadAsStringAsync(ct);
        using JsonDocument doc = JsonDocument.Parse(body);
        if (doc.RootElement.TryGetProperty("type", out JsonElement type) &&
            type.GetString() == "snapshot" &&
            doc.RootElement.TryGetProperty("flags", out JsonElement flags))
        {
            var parsed = flags.Deserialize<List<FlagDefinition>>(JsonOpts) ?? new();
            LoadFlags(parsed);
            return parsed;
        }
        return _flags.Values.ToList();
    }

    /// <summary>POST queued exposures to /collect.</summary>
    public async Task<int> FlushExposuresRemoteAsync(CancellationToken ct = default)
    {
        if (_http is null) return 0;
        IReadOnlyList<ExposureEvent> events = FlushExposures();
        if (events.Count == 0) return 0;
        using StringContent content = new(JsonSerializer.Serialize(new { events }, JsonOpts));
        using HttpResponseMessage resp = await _http.PostAsync("/collect", content, ct);
        resp.EnsureSuccessStatusCode();
        return events.Count;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _cts.Cancel();
        _http?.Dispose();
    }

    // --- evaluation engine (ported from packages/js/src/client.ts) ---

    private EvaluationResult EvaluateInternal(
        FlagDefinition flag,
        EvaluationContext context,
        string unitId,
        HashSet<string> visited)
    {
        if (!flag.Enabled)
        {
            Variation? def = GetDefaultVariation(flag);
            return Result(flag, false, ParseVariationValue(def?.Value ?? "false"), def?.Key,
                EvaluationReason.Disabled, NativeCore.Bucket(flag.Key, unitId));
        }

        if (flag.Prerequisites is { Count: > 0 })
        {
            if (!visited.Add(flag.Key))
            {
                return Result(flag, false, false, null, EvaluationReason.Error, 0);
            }
            foreach (Prerequisite prereq in flag.Prerequisites)
            {
                FlagDefinition? parent;
                lock (_lock) { _flags.TryGetValue(prereq.FlagKey, out parent); }
                if (parent is null)
                {
                    return Result(flag, false, false, null, EvaluationReason.Error, 0);
                }
                EvaluationResult parentResult = EvaluateInternal(parent, context, unitId, new HashSet<string>(visited));
                bool matched = parentResult.Enabled && parentResult.Variation == prereq.VariationKey;
                if (!matched)
                {
                    Variation? def = GetDefaultVariation(flag);
                    return Result(flag, false, ParseVariationValue(def?.Value ?? "false"), def?.Key,
                        EvaluationReason.PrerequisiteFailed, NativeCore.Bucket(flag.Key, unitId));
                }
            }
        }

        if (flag.Rules is { Count: > 0 })
        {
            foreach (Rule rule in flag.Rules)
            {
                if (string.IsNullOrEmpty(rule.Expression)) continue;
                if (!EvaluateRuleExpression(rule.Expression, unitId, context)) continue;

                if (rule.Variation is int ruleVariation &&
                    flag.Variations is { Count: > 0 } &&
                    ruleVariation < flag.Variations.Count)
                {
                    Variation selected = flag.Variations[ruleVariation];
                    return Result(flag, true, ParseVariationValue(selected.Value), selected.Key,
                        EvaluationReason.TargetMatch, NativeCore.Bucket(flag.Key, unitId));
                }

                if (rule.RolloutPercentage is int rolloutPct)
                {
                    bool inRollout = NativeCore.IsEnabled(flag.Key, unitId, rolloutPct);
                    uint b = NativeCore.Bucket(flag.Key, unitId);
                    if (inRollout)
                    {
                        Variation? selected = GetDefaultVariation(flag);
                        return Result(flag, true, ParseVariationValue(selected?.Value ?? "true"), selected?.Key ?? "on",
                            EvaluationReason.TargetMatch, b);
                    }
                    Variation? def = GetDefaultVariation(flag);
                    return Result(flag, false, ParseVariationValue(def?.Value ?? "false"), def?.Key,
                        EvaluationReason.Default, b);
                }
            }
        }

        int rollout = flag.RolloutPercentage ?? 100;
        uint bucket = NativeCore.Bucket(flag.Key, unitId);
        bool enabled = NativeCore.IsEnabled(flag.Key, unitId, rollout);
        if (enabled)
        {
            Variation? selected = GetDefaultVariation(flag);
            return Result(flag, true, ParseVariationValue(selected?.Value ?? "true"), selected?.Key ?? "on",
                EvaluationReason.Rollout, bucket);
        }
        Variation? defaultVar = GetDefaultVariation(flag);
        return Result(flag, false, ParseVariationValue(defaultVar?.Value ?? "false"), defaultVar?.Key,
            EvaluationReason.RolloutMiss, bucket);
    }

    private bool EvaluateRuleExpression(string expr, string unitId, EvaluationContext context)
    {
        if (!expr.Contains("user.") && !expr.Contains("account.") && !expr.Contains("custom."))
        {
            return NativeCore.EvalCel(expr, unitId);
        }
        return EvaluateContextExpression(expr, unitId, context);
    }

    private bool EvaluateContextExpression(string expr, string unitId, EvaluationContext context)
    {
        Dictionary<string, object> flat = new()
        {
            ["unit_id"] = unitId,
            ["user.id"] = unitId,
            ["user.country"] = context.Country ?? (object?)null,
            ["user.plan"] = context.Plan ?? (object?)null,
            ["account.plan"] = context.Plan ?? (object?)null,
        };
        if (context.Custom is { })
        {
            foreach ((string k, object v) in context.Custom)
            {
                flat[$"custom.{k}"] = v;
            }
        }
        if (context.Extra is { })
        {
            foreach ((string k, object v) in context.Extra)
            {
                flat[k] = v;
            }
        }

        Match eq = Regex.Match(expr, @"^([\w.]+)\s*==\s*[""']([^""']+)[""']$");
        if (eq.Success)
        {
            string field = eq.Groups[1].Value;
            string expected = eq.Groups[2].Value;
            return string.Equals(Convert.ToString(flat.GetValueOrDefault(field)), expected);
        }

        Match inMatch = Regex.Match(expr, @"^([\w.]+)\s+in\s+\[(.*)\]$");
        if (inMatch.Success)
        {
            string field = inMatch.Groups[1].Value;
            string[] items = inMatch.Groups[2].Value
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(s => s.Trim().Trim('"', '\''))
                .ToArray();
            return items.Contains(Convert.ToString(flat.GetValueOrDefault(field)));
        }

        return NativeCore.EvalCel(expr, unitId);
    }

    private static Variation? GetDefaultVariation(FlagDefinition flag)
    {
        if (flag.Variations is not { Count: > 0 }) return null;
        int idx = flag.DefaultVariation is int dv && dv >= 0 && dv < flag.Variations.Count ? dv : 0;
        return flag.Variations[idx];
    }

    private static object? ParseVariationValue(string raw)
    {
        if (raw == "true") return true;
        if (raw == "false") return false;
        if (double.TryParse(raw, out double num) && !string.IsNullOrWhiteSpace(raw)) return num;
        try { return JsonSerializer.Deserialize<object>(raw, JsonOpts) ?? raw; }
        catch (JsonException) { return raw; }
    }

    private static EvaluationResult Result(
        FlagDefinition flag, bool enabled, object? value, string? variation,
        EvaluationReason reason, uint bucket) => new()
    {
        FlagKey = flag.Key,
        Enabled = enabled,
        Value = value,
        Variation = variation,
        Reason = reason,
        Bucket = bucket,
    };

    private void RecordExposure(string flagKey, string unitId, EvaluationResult evaluation)
    {
        var exposure = new ExposureEvent
        {
            FlagKey = flagKey,
            UnitId = unitId,
            Enabled = evaluation.Enabled,
            Variation = evaluation.Variation,
            Bucket = evaluation.Bucket,
            Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            Reason = evaluation.Reason,
        };
        lock (_lock)
        {
            _exposureQueue.Add(exposure);
        }
    }

    private async Task PollLoop()
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(Math.Max(1000, _options.PollIntervalMs)));
            while (!_cts.IsCancellationRequested)
            {
                await timer.WaitForNextTickAsync(_cts.Token);
                await SyncOnceAsync(_cts.Token);
                if (_options.FlushIntervalMs > 0)
                {
                    await FlushExposuresRemoteAsync(_cts.Token);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // disposed
        }
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };
}
