using System.Runtime.InteropServices;

namespace Doppio;

/// <summary>
/// P/Invoke binding to the native libdoppio shared library. The library is a
/// thin C ABI over the Zig core (see libdoppio/src/native.zig): no shared
/// scratch buffer, just plain pointer+length calls.
/// </summary>
internal static unsafe class NativeCore
{
    private const string LibName = "doppio";

    static NativeCore()
    {
        NativeLibrary.SetDllImportResolver(typeof(NativeCore).Assembly, Resolve);
    }

    private static nint Resolve(string libraryName, System.Reflection.Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != LibName)
        {
            return nint.Zero;
        }

        string rid = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "win-x64",
            Architecture.Arm64 => "win-arm64",
            _ => "win-x64",
        };
        if (!OperatingSystem.IsWindows())
        {
            rid = OperatingSystem.IsMacOS()
                ? $"osx-{(RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64")}"
                : $"linux-{(RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64")}";
        }

        string libExt = OperatingSystem.IsWindows() ? "dll" : OperatingSystem.IsMacOS() ? "dylib" : "so";
        string libNameWithExt = OperatingSystem.IsWindows() ? $"{LibName}.dll" : $"lib{LibName}.{libExt}";

        string baseDir = AppContext.BaseDirectory;
        string[] candidates =
        {
            Path.Combine(baseDir, "native", rid, libNameWithExt),
            Path.Combine(baseDir, libNameWithExt),
        };

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return NativeLibrary.Load(candidate);
            }
        }
        return nint.Zero;
    }

    [DllImport(LibName, EntryPoint = "doppio_native_abi_version", CallingConvention = CallingConvention.Cdecl)]
    private static extern uint AbiVersion();

    [DllImport(LibName, EntryPoint = "doppio_native_bucket", CallingConvention = CallingConvention.Cdecl)]
    private static extern uint Bucket(byte* flagKey, uint flagLen, byte* unitId, uint unitLen);

    [DllImport(LibName, EntryPoint = "doppio_native_enabled", CallingConvention = CallingConvention.Cdecl)]
    private static extern uint Enabled(byte* flagKey, uint flagLen, byte* unitId, uint unitLen, uint rolloutPercentage);

    [DllImport(LibName, EntryPoint = "doppio_native_eval_cel", CallingConvention = CallingConvention.Cdecl)]
    private static extern uint EvalCel(byte* expr, uint exprLen, byte* unitId, uint unitLen);

    public static uint GetAbiVersion() => AbiVersion();

    public static uint Bucket(string flagKey, string unitId)
    {
        byte[] flagBytes = System.Text.Encoding.UTF8.GetBytes(flagKey);
        byte[] unitBytes = System.Text.Encoding.UTF8.GetBytes(unitId);
        fixed (byte* flagPtr = flagBytes)
        fixed (byte* unitPtr = unitBytes)
        {
            return Bucket(flagPtr, (uint)flagBytes.Length, unitPtr, (uint)unitBytes.Length);
        }
    }

    public static bool IsEnabled(string flagKey, string unitId, int rolloutPercentage)
    {
        byte[] flagBytes = System.Text.Encoding.UTF8.GetBytes(flagKey);
        byte[] unitBytes = System.Text.Encoding.UTF8.GetBytes(unitId);
        uint pct = (uint)Math.Clamp(rolloutPercentage, 0, 100);
        fixed (byte* flagPtr = flagBytes)
        fixed (byte* unitPtr = unitBytes)
        {
            return Enabled(flagPtr, (uint)flagBytes.Length, unitPtr, (uint)unitBytes.Length, pct) != 0;
        }
    }

    public static bool EvalCel(string expression, string unitId)
    {
        byte[] exprBytes = System.Text.Encoding.UTF8.GetBytes(expression);
        byte[] unitBytes = System.Text.Encoding.UTF8.GetBytes(unitId);
        fixed (byte* exprPtr = exprBytes)
        fixed (byte* unitPtr = unitBytes)
        {
            return EvalCel(exprPtr, (uint)exprBytes.Length, unitPtr, (uint)unitBytes.Length) != 0;
        }
    }
}
