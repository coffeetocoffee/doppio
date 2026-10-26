export interface EvaluationContext {
  userId?: string;
  unitId?: string;
  country?: string;
  plan?: string;
  custom?: Record<string, string | number | boolean>;
  [key: string]: any;
}

export interface Variation {
  key: string;
  value: string;
}

export interface Rule {
  id?: string;
  priority?: number;
  expression: string;
  variation?: number;
  rolloutPercentage?: number;
}

export interface Prerequisite {
  flagKey: string;
  variationKey: string;
}

export interface FlagDefinition {
  key: string;
  enabled: boolean;
  rolloutPercentage?: number;
  variations?: Variation[];
  defaultVariation?: number;
  prerequisites?: Prerequisite[];
  rules?: Rule[];
}

export interface ConfigDefinition {
  environment?: string;
  version?: number;
  flags: FlagDefinition[];
}

export type EvaluationReason =
  | "DISABLED"
  | "TARGET_MATCH"
  | "ROLLOUT"
  | "ROLLOUT_MISS"
  | "DEFAULT"
  | "PREREQUISITE_FAILED"
  | "ERROR";

export interface EvaluationResult<T = any> {
  flagKey: string;
  enabled: boolean;
  value: T;
  variation: string | null;
  reason: EvaluationReason;
  bucket: number;
  version?: number;
}

export interface ExposureEvent {
  flagKey: string;
  unitId: string;
  enabled: boolean;
  variation: string | null;
  bucket: number;
  timestamp: number;
  reason: EvaluationReason;
}

export interface MetricEvent {
  eventName: string;
  payload?: Record<string, any>;
  timestamp: number;
}

export interface DoppioOptions {
  clientKey?: string;
  environment?: string;
  offline?: boolean;
  flags?: FlagDefinition[];
  endpoint?: string;
  /**
   * How to receive flag updates from the control plane.
   * `websocket` full-duplex, `sse` server-sent events, `delta-poll` HTTP
   * long-poll, `auto` walks websocket, sse, then delta-poll, `manual`
   * disables background sync entirely.
   */
  syncStrategy?: "websocket" | "sse" | "delta-poll" | "auto" | "manual";
  pollInterval?: number;
  /** How often queued exposures are POSTed to /collect, in milliseconds. 0 disables the timer. */
  flushInterval?: number;
  wasmModule?: WebAssembly.Module;
  wasmBuffer?: ArrayBuffer | Uint8Array;
}
