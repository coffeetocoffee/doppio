// Auto-generated WebAssembly binary loader
import { WASM_BASE64 } from "./wasm_data.js";

export function getEmbeddedWasmBuffer(): Uint8Array {
  if (typeof globalThis !== "undefined" && (globalThis as any).Buffer) {
    return (globalThis as any).Buffer.from(WASM_BASE64, "base64");
  }
  const binaryString = atob(WASM_BASE64);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}
