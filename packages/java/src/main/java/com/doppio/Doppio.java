package com.doppio;

import com.dylibso.chicory.runtime.Instance;
import com.dylibso.chicory.runtime.Module;
import com.dylibso.chicory.wasm.Parser;
import com.dylibso.chicory.runtime.Memory;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

public class Doppio {
    private final Instance wasm;
    private final Memory memory;

    public Doppio(Map<String, Object> options) {
        InputStream in = getClass().getResourceAsStream("/doppio.wasm");
        if (in == null) {
            throw new IllegalStateException("doppio.wasm not found on classpath");
        }
        Module module = Parser.parse(in);
        this.wasm = module.instantiate();
        this.memory = wasm.memory();
    }

    public static Doppio init(Map<String, Object> options) {
        return new Doppio(options);
    }

    public boolean isEnabled(String flagKey, String unitId) {
        int offFlag = 0;
        int offUnit = flagKey.length() + 1;
        writeStr(offFlag, flagKey);
        writeStr(offUnit, unitId);
        long enabled = wasm.export("doppio_enabled")
                .apply(offFlag, flagKey.length(), offUnit, unitId.length(), 100)[0];
        return enabled != 0;
    }

    public int bucket(String flagKey, String unitId) {
        int offFlag = 0;
        int offUnit = flagKey.length() + 1;
        writeStr(offFlag, flagKey);
        writeStr(offUnit, unitId);
        return (int) wasm.export("doppio_bucket")
                .apply(offFlag, flagKey.length(), offUnit, unitId.length())[0];
    }

    public boolean evalCel(String expr, String unitId) {
        int offExpr = 0;
        int offUnit = expr.length() + 1;
        writeStr(offExpr, expr);
        writeStr(offUnit, unitId);
        return wasm.export("doppio_eval_cel")
                .apply(offExpr, expr.length(), offUnit, unitId.length())[0] != 0;
    }

    private void writeStr(int offset, String s) {
        byte[] bytes = s.getBytes(StandardCharsets.UTF_8);
        memory.write(offset, bytes);
    }

    public Object get(String flagKey, Map<String, Object> context) {
        return null;
    }
}