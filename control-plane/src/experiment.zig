const std = @import("std");

/// Experiment definitions and the deterministic sample-size calculation behind
/// the experiment wizard. Analysis of results belongs to the analytics phase;
/// this is the definition, power, and review surface the Admin UI v1 needs.
pub const ExperimentStatus = enum {
    draft,
    running,
    concluded,

    pub fn label(self: ExperimentStatus) []const u8 {
        return @tagName(self);
    }
};

pub const Guardrail = struct {
    metric: []const u8,
    /// Minimum acceptable value of the guardrail metric. Below it the
    /// experiment is considered harmful.
    threshold: f64,
};

pub const Experiment = struct {
    id: []const u8,
    hypothesis: []const u8,
    flag_key: []const u8,
    primary_metric: []const u8,
    owner: []const u8,
    status: ExperimentStatus = .draft,
    baseline_rate: f64 = 0,
    /// Minimum detectable effect as an absolute difference in the metric.
    mde: f64 = 0,
    power: f64 = 0.8,
    /// Two-sided significance level.
    alpha: f64 = 0.05,
    guardrails: std.ArrayList(Guardrail),
    required_sample: usize = 0,
    created_at: i64 = 0,
};

pub const PowerInput = struct {
    baseline_rate: f64,
    mde: f64,
    power: f64 = 0.8,
    alpha: f64 = 0.05,
};

pub const ExperimentRegistry = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Experiment),
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) ExperimentRegistry {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *ExperimentRegistry) void {
        for (self.items.items) |*exp| self.freeFields(exp);
        self.items.deinit(self.allocator);
    }

    fn freeFields(self: *ExperimentRegistry, exp: *Experiment) void {
        self.allocator.free(exp.id);
        self.allocator.free(exp.hypothesis);
        self.allocator.free(exp.flag_key);
        self.allocator.free(exp.primary_metric);
        self.allocator.free(exp.owner);
        for (exp.guardrails.items) |guardrail| self.allocator.free(guardrail.metric);
        exp.guardrails.deinit(self.allocator);
    }

    pub const Spec = struct {
        hypothesis: []const u8,
        flag_key: []const u8,
        primary_metric: []const u8,
        owner: []const u8,
        baseline_rate: f64 = 0,
        mde: f64 = 0,
        power: f64 = 0.8,
        alpha: f64 = 0.05,
        guardrails: []const Guardrail = &.{},
        now_ms: i64 = 0,
    };

    pub fn submit(self: *ExperimentRegistry, spec: Spec) !Experiment {
        const id = try std.fmt.allocPrint(self.allocator, "exp-{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        const owned_hypothesis = try self.allocator.dupe(u8, spec.hypothesis);
        errdefer self.allocator.free(owned_hypothesis);
        const owned_flag = try self.allocator.dupe(u8, spec.flag_key);
        errdefer self.allocator.free(owned_flag);
        const owned_metric = try self.allocator.dupe(u8, spec.primary_metric);
        errdefer self.allocator.free(owned_metric);
        const owned_owner = try self.allocator.dupe(u8, spec.owner);
        errdefer self.allocator.free(owned_owner);

        var guardrails: std.ArrayList(Guardrail) = .empty;
        errdefer guardrails.deinit(self.allocator);
        for (spec.guardrails) |guardrail| {
            try guardrails.append(self.allocator, .{
                .metric = try self.allocator.dupe(u8, guardrail.metric),
                .threshold = guardrail.threshold,
            });
        }

        const required = requiredSampleSize(.{
            .baseline_rate = spec.baseline_rate,
            .mde = spec.mde,
            .power = spec.power,
            .alpha = spec.alpha,
        });

        try self.items.append(self.allocator, .{
            .id = id,
            .hypothesis = owned_hypothesis,
            .flag_key = owned_flag,
            .primary_metric = owned_metric,
            .owner = owned_owner,
            .guardrails = guardrails,
            .required_sample = required,
            .baseline_rate = spec.baseline_rate,
            .mde = spec.mde,
            .power = spec.power,
            .alpha = spec.alpha,
            .created_at = spec.now_ms,
        });
        self.next_id += 1;
        return self.items.items[self.items.items.len - 1];
    }

    pub fn find(self: *ExperimentRegistry, id: []const u8) ?*Experiment {
        for (self.items.items) |*exp| {
            if (std.mem.eql(u8, exp.id, id)) return exp;
        }
        return null;
    }

    /// Advance the lifecycle: draft to running, running to concluded.
    pub fn advance(self: *ExperimentRegistry, id: []const u8) bool {
        const exp = self.find(id) orelse return false;
        switch (exp.status) {
            .draft => exp.status = .running,
            .running => exp.status = .concluded,
            .concluded => return false,
        }
        return true;
    }
};

/// Sample size per arm for a two-proportion comparison.
///
/// n = 2 * (z_{1-alpha/2} + z_{1-beta})^2 * p(1-p) / mde^2
///
/// The normal quantiles are approximated with Acklam's rational
/// approximation so the result is deterministic and dependency-free.
pub fn requiredSampleSize(input: PowerInput) usize {
    if (input.mde <= 0 or input.baseline_rate <= 0 or input.baseline_rate >= 1) return 0;
    if (input.power <= 0 or input.power >= 1) return 0;
    if (input.alpha <= 0 or input.alpha >= 1) return 0;

    const z_alpha = quantile(1.0 - input.alpha / 2.0);
    const z_beta = quantile(input.power);
    const variance = input.baseline_rate * (1.0 - input.baseline_rate);

    const per_arm = 2.0 * std.math.pow(f64, z_alpha + z_beta, 2.0) * variance / (input.mde * input.mde);
    if (per_arm <= 0 or !std.math.isFinite(per_arm)) return 0;
    return @intFromFloat(@ceil(per_arm));
}

/// Standard normal quantile via Acklam's inverse normal CDF approximation.
/// Accurate to roughly 1.15e-9 relative error, which is far beyond the
/// precision a sample-size estimate needs.
fn quantile(p: f64) f64 {
    if (p <= 0 or p >= 1) return 0;

    const a = [_]f64{ -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00 };
    const b = [_]f64{ -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01 };
    const c = [_]f64{ -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00 };
    const d = [_]f64{ 7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.444408054165638e+01 };

    const p_low = 0.02425;
    const p_high = 1.0 - p_low;

    if (p < p_low) {
        const q = @sqrt(-2.0 * @log(p));
        return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
            ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0);
    } else if (p > p_high) {
        const q = @sqrt(-2.0 * @log(1.0 - p));
        return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
            ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0);
    }

    const q = p - 0.5;
    const r = q * q;
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
        (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1.0);
}

test "quantile reproduces the standard normal quantiles" {
    try std.testing.expect(@abs(quantile(0.975) - 1.959963985) < 1e-6);
    try std.testing.expect(@abs(quantile(0.8) - 0.841621234) < 1e-6);
    try std.testing.expect(@abs(quantile(0.5)) < 1e-9);
}

test "required sample size matches the analytic formula" {
    // baseline 0.10, mde 0.02, power 0.80, alpha 0.05 -> 3602 per arm.
    const n = requiredSampleSize(.{ .baseline_rate = 0.10, .mde = 0.02 });
    try std.testing.expect(n > 3500 and n < 3700);

    // A larger effect needs fewer units.
    const wider_mde = requiredSampleSize(.{ .baseline_rate = 0.10, .mde = 0.05 });
    try std.testing.expect(wider_mde < n);

    // More power costs more units.
    const stronger = requiredSampleSize(.{ .baseline_rate = 0.10, .mde = 0.02, .power = 0.95 });
    try std.testing.expect(stronger > n);

    // Degenerate inputs return 0 rather than a nonsense number.
    try std.testing.expectEqual(@as(usize, 0), requiredSampleSize(.{ .baseline_rate = 0.1, .mde = 0 }));
    try std.testing.expectEqual(@as(usize, 0), requiredSampleSize(.{ .baseline_rate = 1.0, .mde = 0.02 }));
    try std.testing.expectEqual(@as(usize, 0), requiredSampleSize(.{ .baseline_rate = 0.1, .mde = 0.02, .power = 1.0 }));
}

test "experiment registry stores the wizard definition and advances status" {
    var registry = ExperimentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const guardrails = [_]Guardrail{
        .{ .metric = "latency_p95_ms", .threshold = 400 },
        .{ .metric = "error_rate", .threshold = 0.01 },
    };

    const exp = try registry.submit(.{
        .hypothesis = "A shorter checkout increases completion rate",
        .flag_key = "checkout-short",
        .primary_metric = "completion_rate",
        .owner = "growth-team",
        .baseline_rate = 0.32,
        .mde = 0.03,
        .guardrails = &guardrails,
        .now_ms = 1,
    });
    try std.testing.expectEqualStrings("exp-1", exp.id);
    try std.testing.expect(exp.required_sample > 1000);
    try std.testing.expectEqualStrings("draft", exp.status.label());
    try std.testing.expectEqual(@as(usize, 2), exp.guardrails.items.len);

    try std.testing.expect(registry.advance("exp-1"));
    try std.testing.expectEqual(ExperimentStatus.running, registry.find("exp-1").?.status);
    try std.testing.expect(registry.advance("exp-1"));
    try std.testing.expectEqual(ExperimentStatus.concluded, registry.find("exp-1").?.status);
    // A concluded experiment cannot advance further.
    try std.testing.expect(!registry.advance("exp-1"));
    try std.testing.expect(!registry.advance("exp-missing"));
}
