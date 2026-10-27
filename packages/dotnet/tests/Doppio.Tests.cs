using Doppio;
using Xunit;

namespace Doppio.Tests;

public class NativeCoreTests
{
    [Theory]
    [InlineData("flag-a", "user-1", 24261u)]
    [InlineData("flag-b", "user-1", 42637u)]
    [InlineData("flag-a", "user-2", 58649u)]
    public void Bucket_MatchesZigCore(string flag, string unit, uint expected)
    {
        using var d = Doppio.Init(new DoppioOptions());
        Assert.Equal(expected, d.Bucket(flag, unit));
    }

    [Theory]
    [InlineData("demo", "user-1", 0, false)]
    [InlineData("demo", "user-1", 100, true)]
    public void IsEnabled_Boundaries(string flag, string unit, int pct, bool expected)
    {
        using var d = Doppio.Init(new DoppioOptions());
        var flagDef = new FlagDefinition { Key = flag, Enabled = true, RolloutPercentage = pct };
        d.LoadFlags(new[] { flagDef });
        Assert.Equal(expected, d.IsEnabled(flag, unit));
    }
}

public class EvaluationTests
{
    [Fact]
    public void DisabledFlag_ReturnsDisabled()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[] { new FlagDefinition { Key = "off", Enabled = false } });

        var res = d.Get("off", new EvaluationContext { UnitId = "u1" });
        Assert.False(res.Enabled);
        Assert.Equal(EvaluationReason.Disabled, res.Reason);
    }

    [Fact]
    public void EnabledFlag_FullRollout_ReturnsRollout()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[] { new FlagDefinition { Key = "on", Enabled = true, RolloutPercentage = 100 } });

        var res = d.Get("on", new EvaluationContext { UnitId = "u1" });
        Assert.True(res.Enabled);
        Assert.Equal(EvaluationReason.Rollout, res.Reason);
    }

    [Fact]
    public void MissingFlag_ReturnsError()
    {
        using var d = Doppio.Init(new DoppioOptions());
        var res = d.Get("missing", new EvaluationContext { UnitId = "u1" });
        Assert.False(res.Enabled);
        Assert.Equal(EvaluationReason.Error, res.Reason);
    }

    [Fact]
    public void TargetingRule_PlanMatch()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[]
        {
            new FlagDefinition
            {
                Key = "targeted",
                Enabled = true,
                RolloutPercentage = 100,
                Rules = new List<Rule>
                {
                    new() { Id = "premium", Expression = "user.plan == \"premium\"", Variation = 1 },
                },
                Variations = new List<Variation>
                {
                    new() { Key = "standard", Value = "false" },
                    new() { Key = "premium", Value = "true" },
                },
                DefaultVariation = 0,
            },
        });

        var premium = d.Get("targeted", new EvaluationContext { UnitId = "u1", Plan = "premium" });
        Assert.True(premium.Enabled);
        Assert.Equal("premium", premium.Variation);
        Assert.Equal(EvaluationReason.TargetMatch, premium.Reason);

        var free = d.Get("targeted", new EvaluationContext { UnitId = "u2", Plan = "free" });
        Assert.Equal(false, free.Value);
        Assert.Equal("standard", free.Variation);
    }

    [Fact]
    public void Deterministic_SameContextSameResult()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[] { new FlagDefinition { Key = "det", Enabled = true, RolloutPercentage = 50 } });

        var a = d.Get("det", new EvaluationContext { UnitId = "user-123" });
        var b = d.Get("det", new EvaluationContext { UnitId = "user-123" });
        Assert.Equal(a.Enabled, b.Enabled);
        Assert.Equal(a.Reason, b.Reason);
    }

    [Fact]
    public void StringVariation_ValueParsed()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[]
        {
            new FlagDefinition
            {
                Key = "str",
                Enabled = true,
                RolloutPercentage = 100,
                Variations = new List<Variation> { new() { Key = "on", Value = "hello world" } },
                DefaultVariation = 0,
            },
        });

        var res = d.Get("str", new EvaluationContext { UnitId = "u1" });
        Assert.Equal("hello world", res.Value);
    }

    [Fact]
    public void NumberVariation_ValueParsed()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[]
        {
            new FlagDefinition
            {
                Key = "num",
                Enabled = true,
                RolloutPercentage = 100,
                Variations = new List<Variation> { new() { Key = "on", Value = "42" } },
                DefaultVariation = 0,
            },
        });

        var res = d.Get("num", new EvaluationContext { UnitId = "u1" });
        Assert.Equal(42.0, res.Value);
    }

    [Fact]
    public void Prerequisite_Gating()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[]
        {
            new FlagDefinition { Key = "root", Enabled = true, RolloutPercentage = 100, Variations = new List<Variation> { new() { Key = "on", Value = "true" } }, DefaultVariation = 0 },
            new FlagDefinition
            {
                Key = "child",
                Enabled = true,
                RolloutPercentage = 100,
                Prerequisites = new List<Prerequisite> { new() { FlagKey = "root", VariationKey = "on" } },
                Variations = new List<Variation> { new() { Key = "on", Value = "true" } },
                DefaultVariation = 0,
            },
        });

        var res = d.Get("child", new EvaluationContext { UnitId = "u1" });
        Assert.True(res.Enabled);
    }

    [Fact]
    public void TrackAndFlushExposures()
    {
        using var d = Doppio.Init(new DoppioOptions());
        d.LoadFlags(new[] { new FlagDefinition { Key = "f", Enabled = true, RolloutPercentage = 100 } });
        d.Get("f", new EvaluationContext { UnitId = "u1" });
        var flushed = d.FlushExposures();
        Assert.Single(flushed);
        Assert.Equal("f", flushed[0].FlagKey);
    }
}
