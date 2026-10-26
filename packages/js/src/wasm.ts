import { getEmbeddedWasmBuffer } from "./wasm_binary.js";

export interface DoppioWasmExports {
  memory: WebAssembly.Memory;
  doppio_abi_version(): number;
  doppio_buffer_ptr(): number;
  doppio_buffer_size(): number;
  doppio_bucket(flagKeyPtr: number, flagKeyLen: number, unitIdPtr: number, unitIdLen: number): number;
  doppio_enabled(flagKeyPtr: number, flagKeyLen: number, unitIdPtr: number, unitIdLen: number, rolloutPercentage: number): number;
  doppio_eval_cel(exprPtr: number, exprLen: number, unitPtr: number, unitLen: number): number;
}

export class WasmCore {
  private instance: WebAssembly.Instance;
  private exports: DoppioWasmExports;

  private constructor(instance: WebAssembly.Instance) {
    this.instance = instance;
    this.exports = instance.exports as unknown as DoppioWasmExports;
  }

  public static async init(customSource?: WebAssembly.Module | ArrayBuffer | Uint8Array): Promise<WasmCore> {
    let instance: WebAssembly.Instance;

    if (customSource instanceof WebAssembly.Module) {
      instance = await WebAssembly.instantiate(customSource);
    } else {
      const buffer = customSource || getEmbeddedWasmBuffer();
      const res = await WebAssembly.instantiate(buffer);
      instance = (res as any).instance || (res as any);
    }

    return new WasmCore(instance);
  }

  public getAbiVersion(): number {
    return this.exports.doppio_abi_version();
  }

  public computeBucket(flagKey: string, unitId: string): number {
    const mem = new Uint8Array(this.exports.memory.buffer);
    const baseOffset = this.exports.doppio_buffer_ptr();

    const flagBytes = new TextEncoder().encode(flagKey);
    const unitBytes = new TextEncoder().encode(unitId);

    const flagOffset = baseOffset;
    mem.set(flagBytes, flagOffset);

    const unitOffset = flagOffset + flagBytes.length;
    mem.set(unitBytes, unitOffset);

    return this.exports.doppio_bucket(flagOffset, flagBytes.length, unitOffset, unitBytes.length);
  }

  public isEnabled(flagKey: string, unitId: string, rolloutPercentage: number): boolean {
    const mem = new Uint8Array(this.exports.memory.buffer);
    const baseOffset = this.exports.doppio_buffer_ptr();

    const flagBytes = new TextEncoder().encode(flagKey);
    const unitBytes = new TextEncoder().encode(unitId);

    const flagOffset = baseOffset;
    mem.set(flagBytes, flagOffset);

    const unitOffset = flagOffset + flagBytes.length;
    mem.set(unitBytes, unitOffset);

    const res = this.exports.doppio_enabled(
      flagOffset,
      flagBytes.length,
      unitOffset,
      unitBytes.length,
      Math.min(100, Math.max(0, rolloutPercentage))
    );
    return res === 1;
  }

  public evaluateCel(expression: string, unitId: string): boolean {
    const mem = new Uint8Array(this.exports.memory.buffer);
    const baseOffset = this.exports.doppio_buffer_ptr();

    const exprBytes = new TextEncoder().encode(expression);
    const unitBytes = new TextEncoder().encode(unitId);

    const exprOffset = baseOffset;
    mem.set(exprBytes, exprOffset);

    const unitOffset = exprOffset + exprBytes.length;
    mem.set(unitBytes, unitOffset);

    const res = this.exports.doppio_eval_cel(exprOffset, exprBytes.length, unitOffset, unitBytes.length);
    return res === 1;
  }
}
