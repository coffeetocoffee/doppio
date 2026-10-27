// Auto-generated WebAssembly binary loader
import { WASM_BASE64 } from "./wasm_data.js";

export function getEmbeddedWasmBuffer(): Uint8Array {
  const binaryString = atob(WASM_BASE64);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}
