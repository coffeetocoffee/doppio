import {
  DoppioOptions,
  EvaluationContext,
  EvaluationResult,
  FlagDefinition,
  ExposureEvent,
  MetricEvent,
  EvaluationReason,
} from "./types.js";
import { WasmCore } from "./wasm.js";
import { createStorage, StorageAdapter } from "./cache.js";
import { SyncClient, createSyncClient, SyncStatus } from "./sync.js";

type EventCallback = (...args: any[]) => void;

export class Doppio {
  private wasm: WasmCore;
  private flags: Map<string, FlagDefinition> = new Map();
  private storage: StorageAdapter;
  private listeners: Map<string, Set<EventCallback>> = new Map();
  private exposureQueue: ExposureEvent[] = [];
  private metricQueue: MetricEvent[] = [];
  private options: DoppioOptions;
  private isReady = false;
  private syncClient: SyncClient | null = null;
  private syncUnsubscribes: Array<() => void> = [];

  private constructor(wasm: WasmCore, storage: StorageAdapter, options: DoppioOptions) {
    this.wasm = wasm;
    this.storage = storage;
    this.options = options;
    this.syncClient = createSyncClient(options);
  }

  public static async init(options: DoppioOptions = {}): Promise<Doppio> {
    const wasm = await WasmCore.init(options.wasmModule || options.wasmBuffer);
    const storage = createStorage(options.offline !== false);
    const client = new Doppio(wasm, storage, options);

    // Initial flags from options
    if (options.flags) {
      client.loadFlagDefinitions(options.flags);
    }

    // Try restoring flags from cache if offline caching enabled
    if (options.offline !== false) {
      const cached = await storage.loadFlags();
      if (cached && cached.length > 0) {
        client.loadFlagDefinitions(cached);
      }
    }

    client.isReady = true;
    client.emit("ready");

    // Background delta sync only runs when an endpoint is configured and the
    // strategy is not manual. Default init keeps the current behavior of no
    // timers and no sockets.
    if (client.syncClient && options.syncStrategy !== "manual") {
      client.wireSync();
    }

    return client;
  }

  private wireSync(): void {
    const syncClient = this.syncClient;
    if (!syncClient) return;

    this.syncUnsubscribes.push(
      syncClient.onFlagsChange((flags) => {
        void this.setFlags(flags);
      }),
    );
    this.syncUnsubscribes.push(
      syncClient.onStatusChange((status) => {
        if (status.kind === "degraded") this.emit("sync:degraded", status);
        if (status.kind === "connected") this.emit("sync:connected", status);
      }),
    );
    this.syncUnsubscribes.push(
      syncClient.onError((err) => {
        this.emit("error", err);
      }),
    );

    void syncClient.start();
  }

  public get sync(): SyncClient | null {
    return this.syncClient;
  }

  public getSyncStatus(): SyncStatus {
    return this.syncClient?.getStatus() ?? {
      kind: "idle",
      transport: null,
      attempts: 0,
      lastSeq: null,
      lastError: null,
      lastAt: Date.now(),
    };
  }

  /** Fetch the current flag set once, useful for edge and cold starts. */
  public async syncOnce(): Promise<FlagDefinition[]> {
    if (!this.syncClient) return this.getFlagList();
    return this.syncClient.fetchOnce();
  }

  /** Flush queued exposures (and any client-side sync queue) to /collect. */
  public async flushExposuresRemote(): Promise<void> {
    if (!this.syncClient) return;
    await this.syncClient.flush();
  }

  public stopSync(): void {
    for (const unsubscribe of this.syncUnsubscribes) unsubscribe();
    this.syncUnsubscribes = [];
    this.syncClient?.stop();
  }

  private getFlagList(): FlagDefinition[] {
    return [...this.flags.values()];
  }

  public on(
    event: "ready" | "change" | "error" | "sync:degraded" | "sync:connected",
    callback: EventCallback,
  ): () => void {
    if (!this.listeners.has(event)) {
      this.listeners.set(event, new Set());
    }
    this.listeners.get(event)!.add(callback);

    if (event === "ready" && this.isReady) {
      setTimeout(() => callback(), 0);
    }

    return () => {
      this.listeners.get(event)?.delete(callback);
    };
  }

  private emit(event: string, ...args: any[]): void {
    const callbacks = this.listeners.get(event);
    if (callbacks) {
      for (const cb of callbacks) {
        try {
          cb(...args);
        } catch {
          // Prevent listener error from breaking evaluation
        }
      }
    }
  }

  public async setFlags(flags: FlagDefinition[]): Promise<void> {
    const changed: string[] = [];
    for (const flag of flags) {
      const existing = this.flags.get(flag.key);
      if (!existing || JSON.stringify(existing) !== JSON.stringify(flag)) {
        changed.push(flag.key);
      }
    }

    this.loadFlagDefinitions(flags);
    await this.storage.saveFlags(flags);

    if (changed.length > 0) {
      this.emit("change", changed);
    }
  }

  private loadFlagDefinitions(flags: FlagDefinition[]): void {
    this.flags.clear();
    for (const flag of flags) {
      this.flags.set(flag.key, flag);
    }
  }

  public get<T = any>(flagKey: string, context: EvaluationContext = {}): EvaluationResult<T> {
    const unitId = context.unitId || context.userId || "anonymous";
    const flag = this.flags.get(flagKey);

    if (!flag) {
      return {
        flagKey,
        enabled: false,
        value: false as unknown as T,
        variation: null,
        reason: "ERROR",
        bucket: 0,
      };
    }

    const evaluation = this.evaluateInternal(flag, context, unitId, new Set());
    
    // Record exposure
    const exposure: ExposureEvent = {
      flagKey,
      unitId,
      enabled: evaluation.enabled,
      variation: evaluation.variation,
      bucket: evaluation.bucket,
      timestamp: Date.now(),
      reason: evaluation.reason,
    };
    this.exposureQueue.push(exposure);
    this.syncClient?.queueExposure(exposure);

    return evaluation;
  }

  public isEnabled(flagKey: string, context: EvaluationContext = {}): boolean {
    return this.get(flagKey, context).enabled;
  }

  private evaluateInternal(
    flag: FlagDefinition,
    context: EvaluationContext,
    unitId: string,
    visited: Set<string>
  ): EvaluationResult {
    // 1. Check if disabled
    if (!flag.enabled) {
      const defaultVar = this.getDefaultVariation(flag);
      return {
        flagKey: flag.key,
        enabled: false,
        value: this.parseVariationValue(defaultVar?.value ?? "false"),
        variation: defaultVar?.key ?? null,
        reason: "DISABLED",
        bucket: this.wasm.computeBucket(flag.key, unitId),
      };
    }

    // 2. Check prerequisites
    if (flag.prerequisites && flag.prerequisites.length > 0) {
      if (visited.has(flag.key)) {
        return {
          flagKey: flag.key,
          enabled: false,
          value: false,
          variation: null,
          reason: "ERROR",
          bucket: 0,
        };
      }
      visited.add(flag.key);

      for (const prereq of flag.prerequisites) {
        const parentFlag = this.flags.get(prereq.flagKey);
        if (!parentFlag) {
          return {
            flagKey: flag.key,
            enabled: false,
            value: false,
            variation: null,
            reason: "ERROR",
            bucket: 0,
          };
        }

        const parentResult = this.evaluateInternal(parentFlag, context, unitId, new Set(visited));
        const matched = parentResult.enabled && parentResult.variation === prereq.variationKey;
        if (!matched) {
          const defaultVar = this.getDefaultVariation(flag);
          return {
            flagKey: flag.key,
            enabled: false,
            value: this.parseVariationValue(defaultVar?.value ?? "false"),
            variation: defaultVar?.key ?? null,
            reason: "PREREQUISITE_FAILED",
            bucket: this.wasm.computeBucket(flag.key, unitId),
          };
        }
      }
    }

    // 3. Evaluate targeting rules
    if (flag.rules && flag.rules.length > 0) {
      for (const rule of flag.rules) {
        if (rule.expression) {
          const matched = this.evaluateRuleExpression(rule.expression, unitId, context);
          if (matched) {
            if (rule.variation !== undefined && flag.variations && rule.variation < flag.variations.length) {
              const selectedVar = flag.variations[rule.variation];
              return {
                flagKey: flag.key,
                enabled: true,
                value: this.parseVariationValue(selectedVar.value),
                variation: selectedVar.key,
                reason: "TARGET_MATCH",
                bucket: this.wasm.computeBucket(flag.key, unitId),
              };
            }

            if (rule.rolloutPercentage !== undefined) {
              const inRollout = this.wasm.isEnabled(flag.key, unitId, rule.rolloutPercentage);
              const b = this.wasm.computeBucket(flag.key, unitId);
              if (inRollout) {
                const selectedVar = this.getDefaultVariation(flag);
                return {
                  flagKey: flag.key,
                  enabled: true,
                  value: this.parseVariationValue(selectedVar?.value ?? "true"),
                  variation: selectedVar?.key ?? "on",
                  reason: "TARGET_MATCH",
                  bucket: b,
                };
              } else {
                const defaultVar = this.getDefaultVariation(flag);
                return {
                  flagKey: flag.key,
                  enabled: false,
                  value: this.parseVariationValue(defaultVar?.value ?? "false"),
                  variation: defaultVar?.key ?? null,
                  reason: "DEFAULT",
                  bucket: b,
                };
              }
            }
          }
        }
      }
    }

    // 4. Default rollout percentage
    const rollout = flag.rolloutPercentage !== undefined ? flag.rolloutPercentage : 100;
    const bucket = this.wasm.computeBucket(flag.key, unitId);
    const enabled = this.wasm.isEnabled(flag.key, unitId, rollout);

    if (enabled) {
      const selectedVar = this.getDefaultVariation(flag);
      return {
        flagKey: flag.key,
        enabled: true,
        value: this.parseVariationValue(selectedVar?.value ?? "true"),
        variation: selectedVar?.key ?? "on",
        reason: "ROLLOUT",
        bucket,
      };
    } else {
      const defaultVar = this.getDefaultVariation(flag);
      return {
        flagKey: flag.key,
        enabled: false,
        value: this.parseVariationValue(defaultVar?.value ?? "false"),
        variation: defaultVar?.key ?? null,
        reason: "ROLLOUT_MISS",
        bucket,
      };
    }
  }

  private evaluateRuleExpression(expr: string, unitId: string, context: EvaluationContext): boolean {
    // If expression uses unit_id directly, evaluate via WASM core
    if (!expr.includes("user.") && !expr.includes("account.") && !expr.includes("custom.")) {
      return this.wasm.evaluateCel(expr, unitId);
    }

    // Context-aware evaluation
    return this.evaluateContextExpression(expr, unitId, context);
  }

  private evaluateContextExpression(expr: string, unitId: string, context: EvaluationContext): boolean {
    const flatContext: Record<string, any> = {
      unit_id: unitId,
      "user.id": unitId,
      "user.country": context.country,
      "account.plan": context.plan,
    };

    if (context.custom) {
      for (const [k, v] of Object.entries(context.custom)) {
        flatContext[`custom.${k}`] = v;
      }
    }

    // For any direct attributes in context
    for (const [k, v] of Object.entries(context)) {
      if (k !== "custom") {
        flatContext[k] = v;
      }
    }

    // Check simple comparison: e.g. key == "val"
    const eqMatch = expr.match(/^([\w.]+)\s*==\s*["']([^"']+)["']$/);
    if (eqMatch) {
      const field = eqMatch[1];
      const expected = eqMatch[2];
      return String(flatContext[field]) === expected;
    }

    const inMatch = expr.match(/^([\w.]+)\s+in\s+\[(.*)\]$/);
    if (inMatch) {
      const field = inMatch[1];
      const items = inMatch[2].split(",").map(s => s.trim().replace(/^["']|["']$/g, ""));
      return items.includes(String(flatContext[field]));
    }

    // Fallback to WASM evaluator
    return this.wasm.evaluateCel(expr, unitId);
  }

  private getDefaultVariation(flag: FlagDefinition) {
    if (!flag.variations || flag.variations.length === 0) return null;
    const idx = flag.defaultVariation !== undefined && flag.defaultVariation < flag.variations.length
      ? flag.defaultVariation
      : 0;
    return flag.variations[idx];
  }

  private parseVariationValue(raw: string): any {
    if (raw === "true") return true;
    if (raw === "false") return false;
    const num = Number(raw);
    if (!isNaN(num) && raw.trim() !== "") return num;
    try {
      return JSON.parse(raw);
    } catch {
      return raw;
    }
  }

  public track(eventName: string, payload?: Record<string, any>): void {
    this.metricQueue.push({
      eventName,
      payload,
      timestamp: Date.now(),
    });
  }

  public getExposures(): ExposureEvent[] {
    return [...this.exposureQueue];
  }

  public flushExposures(): ExposureEvent[] {
    const exposures = [...this.exposureQueue];
    this.exposureQueue = [];
    return exposures;
  }

  public getMetrics(): MetricEvent[] {
    return [...this.metricQueue];
  }

  public flushMetrics(): MetricEvent[] {
    const metrics = [...this.metricQueue];
    this.metricQueue = [];
    return metrics;
  }
}
