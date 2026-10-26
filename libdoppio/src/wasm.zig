const doppio = @import("doppio");

var wasm_buffer: [65536]u8 = undefined;

export fn doppio_abi_version() u32 {
    return 1;
}

export fn doppio_buffer_ptr() [*]u8 {
    return &wasm_buffer;
}

export fn doppio_buffer_size() u32 {
    return wasm_buffer.len;
}

export fn doppio_bucket(
    flag_key: [*]const u8,
    flag_len: u32,
    unit_id: [*]const u8,
    unit_len: u32,
) u32 {
    return doppio.hash.bucketUnit(flag_key[0..flag_len], unit_id[0..unit_len]);
}

export fn doppio_enabled(
    flag_key: [*]const u8,
    flag_len: u32,
    unit_id: [*]const u8,
    unit_len: u32,
    rollout_percentage: u32,
) u32 {
    const percentage: u8 = @intCast(@min(rollout_percentage, 100));
    return @intFromBool(doppio.hash.inRollout(
        flag_key[0..flag_len],
        unit_id[0..unit_len],
        percentage,
    ));
}

export fn doppio_eval_cel(
    expr_ptr: [*]const u8,
    expr_len: u32,
    unit_ptr: [*]const u8,
    unit_len: u32,
) u32 {
    const expr = expr_ptr[0..expr_len];
    const unit_id = unit_ptr[0..unit_len];
    const res = doppio.cel.evaluate(expr, .{ .unit_id = unit_id }) catch false;
    return @intFromBool(res);
}
