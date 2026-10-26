import {
  DoppioOptions,
  ExposureEvent,
  FlagDefinition,
} from "./types.js";

/** Wire format of the delta-sync control-plane surface. */
export interface ServerFlag {
  key: string;
  enabled: boolean;
  rollout_percentage?: number;
  version?: number;
}

export interface SnapshotMessage {
  type: "snapshot";
  seq: number;
  flags: ServerFlag[];
}

export interface DeltaMessage {
  type: "delta";
  seq: number;
  changes: Array<{
    key: string;
    deleted: boolean;
    enabled: boolean;
    rollout_percentage: number;
    seq: number;
  }>;
}

export interface AckMessage {
  type: "ack";
  seq: number;
}

export type ServerMessage = SnapshotMessage | DeltaMessage | AckMessage | { type: string };

export type SyncTransportKind = "websocket" | "sse" | "delta-poll";
export type SyncStrategyKind = SyncTransportKind | "auto" | "manual";

export interface SyncStatus {
  kind: "idle" | "connecting" | "connected" | "degraded" | "stopped";
  transport: SyncTransportKind | null;
  attempts: number;
  lastSeq: number | null;
  lastError: string | null;
  lastAt: number | null;
}

export interface FlushOutcome {
  sent: number;
  kept: number;
  ok: boolean;
}

export interface SyncClientOptions {
  endpoint: string;
  clientKey?: string;
  strategy: SyncStrategyKind;
  pollInterval: number;
  flushInterval: number;
  backoffBaseMs: number;
  backoffCapMs: number;
  jitterRatio: number;
  fetchImpl?: typeof fetch;
}

export type FlagsListener = (flags: FlagDefinition[]) => void;
export type StatusListener = (status: SyncStatus) => void;
export type ErrorListener = (error: unknown) => void;

/**
 * Translate the server's snake_case flag payload into the SDK's
 * FlagDefinition. Returns null for anything unusable so callers can skip
 * instead of pushing a half-formed flag into the map.
 */
export function normalizeServerFlag(raw: unknown): FlagDefinition | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.key !== "string" || r.key.length === 0) return null;
  if (r.deleted === true) return null;

  const enabled = typeof r.enabled === "boolean" ? r.enabled : true;
  const out: FlagDefinition = { key: r.key, enabled };

  if (typeof r.rollout_percentage === "number") {
    out.rolloutPercentage = Math.min(100, Math.max(0, Math.trunc(r.rollout_percentage)));
  } else if (typeof r.rolloutPercentage === "number") {
    out.rolloutPercentage = Math.min(100, Math.max(0, Math.trunc(r.rolloutPercentage)));
  }
  if (Array.isArray(r.variations)) out.variations = r.variations as FlagDefinition["variations"];
  if (typeof r.default_variation === "number" || typeof r.defaultVariation === "number") {
    out.defaultVariation = Number(r.default_variation ?? r.defaultVariation);
  }

  return out;
}

/**
 * Delta-sync client for the Doppio control plane.
 *
 * Three transports ride the same snapshot/delta protocol:
 * - `websocket`: full-duplex frames on /sync/ws
 * - `sse`: server-sent events on /sync/stream
 * - `delta-poll`: long-poll on /sync/updates/{after_seq}, the lowest common
 *   denominator that works everywhere fetch does
 *
 * `auto` walks websocket, then sse, then delta-poll, so the client upgrades
 * when a transport is available without ever failing to receive flags.
 * Exposures are queued and flushed with idempotency keys so retries and
 * duplicate delivery both collapse to one recorded event.
 */
export class SyncClient {
  private readonly opts: SyncClientOptions;
  private readonly flagsById = new Map<string, FlagDefinition>();
  private readonly flagsListeners = new Set<FlagsListener>();
  private readonly statusListeners = new Set<StatusListener>();
  private readonly errorListeners = new Set<ErrorListener>();

  private pending: ExposureEvent[] = [];
  private lastSeq: number | null = null;
  private attempts = 0;
  private flushTimer: ReturnType<typeof setInterval> | null = null;
  private pollTimer: ReturnType<typeof setTimeout> | null = null;
  private socket: WebSocket | null = null;
  private abort: AbortController | null = null;
  private started = false;
  private stopping = false;
  private flushes = 0;
  private flushErrors = 0;

  private status: SyncStatus = {
    kind: "idle",
    transport: null,
    attempts: 0,
    lastSeq: null,
    lastError: null,
    lastAt: null,
  };

  /** Callback used by the host client to publish flag updates. */
  public onFlags: FlagsListener | null = null;

  constructor(opts: SyncClientOptions) {
    this.opts = opts;
  }

  /**
   * Translate the server's snake_case flag payload into the SDK's
   * FlagDefinition. Returns null for anything unusable so callers can skip
   * instead of pushing a half-formed flag into the map.
   */
  public normalizeServerFlag(raw: unknown): FlagDefinition | null {
    return normalizeServerFlag(raw);
  }

  /**
   * Exponential backoff with optional proportional jitter.
   * Capped so a long outage cannot back off past recovery.
   */
  public backoffDelay(attempt: number): number {
    if (attempt <= 0) return 0;
    const base = this.opts.backoffBaseMs * Math.pow(2, Math.min(attempt, 16) - 1);
    const capped = Math.min(this.opts.backoffCapMs, base);
    const jitter = capped * this.opts.jitterRatio * Math.random();
    return Math.round(capped + jitter);
  }

  /**
   * Stable idempotency key for an exposure. The server drops duplicates by
   * this key, so a retried flush cannot double-count an event.
   */
  public makeIdempotencyKey(exposure: ExposureEvent): string {
    const provided = (exposure as unknown as { idempotencyKey?: unknown }).idempotencyKey;
    if (typeof provided === "string" && provided.length > 0) return provided;
    const unit = exposure.unitId ?? "anonymous";
    const ts = typeof exposure.timestamp === "number" ? exposure.timestamp : Date.now();
    const variation = exposure.variation ?? "";
    return `${unit}:${exposure.flagKey}:${ts}:${exposure.variation === null || exposure.variation === undefined ? "" : variation}`;
  }

  /** Apply a full snapshot, replacing the local flag set wholesale. */
  public applySnapshot(msg: unknown): FlagDefinition[] {
    const snap = msg as SnapshotMessage;
    const raw = Array.isArray(snap.flags) ? snap.flags : [];

    this.flagsById.clear();
    for (const item of raw) {
      const normalized = normalizeServerFlag(item);
      if (normalized) this.flagsById.set(normalized.key, normalized);
    }

    if (typeof snap.seq === "number") {
      this.lastSeq = this.lastSeq === null ? snap.seq : Math.max(this.lastSeq, snap.seq);
      this.status.lastSeq = this.lastSeq;
    }

    this.notifyFlags();
    return this.currentFlags();
  }

  /** Apply a delta: deleted flags drop, others upsert. */
  public applyDelta(msg: unknown): FlagDefinition[] {
    const delta = msg as DeltaMessage;
    const changes = Array.isArray(delta.changes) ? delta.changes : [];

    for (const change of changes) {
      if (!change || typeof change.key !== "string") continue;
      if (change.deleted === true) {
        this.flagsById.delete(change.key);
        continue;
      }
      const normalized = normalizeServerFlag(change);
      if (normalized) this.flagsById.set(normalized.key, normalized);
    }

    if (typeof delta.seq === "number") {
      this.lastSeq = this.lastSeq === null ? delta.seq : Math.max(this.lastSeq, delta.seq);
      this.status.lastSeq = this.lastSeq;
    }

    this.notifyFlags();
    return this.currentFlags();
  }

  /** Dispatch any server message to the right handler. */
  public handleMessage(msg: unknown): FlagDefinition[] | null {
    if (!msg || typeof msg !== "object") return null;
    const kind = (msg as { type?: unknown }).type;
    if (kind === "snapshot") return this.applySnapshot(msg);
    if (kind === "delta") return this.applyDelta(msg);
    if (kind === "ack") {
      const seq = (msg as AckMessage).seq;
      if (typeof seq === "number" && (this.lastSeq === null || seq > this.lastSeq)) {
        this.lastSeq = seq;
        this.status.lastSeq = seq;
      }
      return null;
    }
    return null;
  }

  public getFlags(): FlagDefinition[] {
    return this.currentFlags();
  }

  public getSnapshot(): Record<string, unknown> {
    return {
      type: "snapshot",
      seq: this.lastSeq,
      flags: [...this.flagsById.values()],
    };
  }

  public getStatus(): SyncStatus {
    return { ...this.status };
  }

  public onFlagsChange(listener: FlagsListener): () => void {
    this.flagsListeners.add(listener);
    return () => this.flagsListeners.delete(listener);
  }

  public onStatusChange(listener: StatusListener): () => void {
    this.statusListeners.add(listener);
    return () => this.statusListeners.delete(listener);
  }

  public onError(listener: ErrorListener): () => void {
    this.errorListeners.add(listener);
    return () => this.errorListeners.delete(listener);
  }

  public queueExposure(exposure: ExposureEvent): void {
    this.pending.push(exposure);
  }

  public getPendingExposures(): ExposureEvent[] {
    return [...this.pending];
  }

  public get stats(): { flushes: number; flushErrors: number; pending: number } {
    return { flushes: this.flushes, flushErrors: this.flushErrors, pending: this.pending.length };
  }

  /** One-shot fetch of the current config, used by edge and cold starts. */
  public async fetchOnce(): Promise<FlagDefinition[]> {
    if (!this.opts.endpoint) return this.getFlags();
    const res = await this.request(`${this.url("updates", this.lastSeq ?? 0)}`);
    const data = (await res.json()) as ServerMessage;
    return this.handleMessage(data) ?? this.getFlags();
  }

  /** Start the configured strategy. `auto` walks ws -> sse -> delta-poll. */
  public async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    this.stopping = false;
    this.attempts = 0;

    if (!this.opts.endpoint || this.opts.strategy === "manual") {
      this.setStatus("idle", null);
      return;
    }

    this.setStatus("connecting", null);

    if (this.opts.flushInterval > 0) {
      this.flushTimer = setInterval(() => {
        void this.flush();
      }, this.opts.flushInterval);
    }

    const strategy = this.opts.strategy;
    if (strategy === "websocket" || strategy === "auto") {
      try {
        await this.connectWebsocket();
        return;
      } catch (err) {
        this.reportError(err);
        if (strategy === "websocket") return this.failStopped();
      }
    }
    if (strategy === "sse" || strategy === "auto") {
      try {
        await this.connectSse();
        return;
      } catch (err) {
        this.reportError(err);
        if (strategy === "sse") return this.failStopped();
      }
    }
    await this.startDeltaPoll();
  }

  public stop(): void {
    this.stopping = true;
    this.started = false;
    if (this.flushTimer) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }
    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
    if (this.socket) {
      try {
        this.socket.close();
      } catch {
        // Ignore double close
      }
      this.socket = null;
    }
    if (this.abort) {
      this.abort.abort();
      this.abort = null;
    }
    this.setStatus("stopped", this.status.transport);
  }

  /**
   * POST the queued exposures to /collect. Failures keep the queue intact so
   * the next attempt covers the same events, and the idempotency key makes a
   * partial success safe to retry.
   */
  public async flush(): Promise<FlushOutcome> {
    if (this.pending.length === 0 || !this.opts.endpoint) {
      return { sent: 0, kept: this.pending.length, ok: true };
    }

    const events = this.pending.map((exposure) => ({
      flag_key: exposure.flagKey,
      user_id: exposure.unitId,
      enabled: exposure.enabled,
      variation: exposure.variation,
      bucket: exposure.bucket,
      timestamp: exposure.timestamp,
      reason: exposure.reason,
      idempotency_key: this.makeIdempotencyKey(exposure),
    }));

    try {
      const res = await this.request(this.url("collect"), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ events }),
      });
      if (!res.ok) {
        this.flushErrors += 1;
        return { sent: 0, kept: this.pending.length, ok: false };
      }
      this.pending = [];
      this.flushes += 1;
      return { sent: events.length, kept: 0, ok: true };
    } catch {
      this.flushErrors += 1;
      return { sent: 0, kept: this.pending.length, ok: false };
    }
  }

  // Transport: WebSocket ---------------------------------------------------

  private async connectWebsocket(): Promise<void> {
    if (typeof WebSocket === "undefined") throw new Error("WebSocket is not available");
    const endpoint = this.opts.endpoint!;
    const url = endpoint.replace(/^http/, "ws").replace(/\/+$/, "") + "/sync/ws";

    await new Promise<void>((resolve, reject) => {
      let settled = false;
      let failed = false;
      const socket = new WebSocket(url);
      this.socket = socket;
      this.setStatus("connecting", "websocket");

      socket.onopen = () => {
        settled = true;
        this.setStatus("connected", "websocket");
        this.attempts = 0;
        socket.send(JSON.stringify({ type: "hello", last_seq: this.lastSeq ?? 0 }));
        resolve();
      };

      socket.onmessage = (event: MessageEvent) => {
        try {
          this.handleMessage(JSON.parse(String(event.data)));
        } catch (err) {
          this.reportError(err);
        }
      };

      socket.onerror = () => {
        if (settled) return;
        settled = true;
        failed = true;
        this.socket = null;
        reject(new Error(`websocket connection to ${url} failed`));
      };

      socket.onclose = () => {
        if (this.socket === socket) this.socket = null;
        // Only a previously connected socket should schedule a fallback;
        // an error during handshake already failed the attempt.
        if (failed) return;
        if (settled) this.scheduleTransportReconnect("websocket");
      };
    });
  }

  // Transport: SSE ---------------------------------------------------------

  private async connectSse(): Promise<void> {
    const endpoint = this.opts.endpoint!;
    const controller = new AbortController();
    this.abort = controller;
    this.setStatus("connecting", "sse");

    const res = await this.request(this.url("stream"), { signal: controller.signal });
    if (!res.ok || !res.body) {
      throw new Error(`sse stream returned ${res.status}`);
    }
    this.setStatus("connected", "sse");
    this.attempts = 0;

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    while (!this.stopping) {
      const chunk = await reader.read();
      if (chunk.done) break;
      buffer += decoder.decode(chunk.value, { stream: true });

      let boundary = buffer.indexOf("\n\n");
      while (boundary !== -1) {
        const rawEvent = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        this.consumeSseEvent(rawEvent);
        boundary = buffer.indexOf("\n\n");
      }
    }
  }

  private consumeSseEvent(rawEvent: string): void {
    const lines = rawEvent.split("\n");
    let data = "";
    for (const line of lines) {
      if (line.startsWith(":")) continue;
      if (line.startsWith("data:")) data += line.slice(5).trim();
    }
    if (data.length === 0 || data === "heartbeat") return;
    try {
      this.handleMessage(JSON.parse(data));
    } catch (err) {
      this.reportError(err);
    }
  }

  // Transport: delta-poll --------------------------------------------------

  private async startDeltaPoll(): Promise<void> {
    this.setStatus("connected", "delta-poll");
    await this.pollOnce();
  }

  private async pollOnce(): Promise<void> {
    if (this.stopping) return;

    try {
      if (this.opts.endpoint) {
        const res = await this.request(this.url("updates", this.lastSeq ?? 0));
        const data = (await res.json()) as ServerMessage;
        this.handleMessage(data);
      }
      this.setStatus("connected", "delta-poll");
      this.attempts = 0;
    } catch (err) {
      this.reportError(err);
      this.setStatus("degraded", "delta-poll");
      this.attempts += 1;
    }

    const delay = this.opts.pollInterval > 0 ? this.opts.pollInterval : this.backoffDelay(this.attempts);
    this.pollTimer = setTimeout(() => void this.pollOnce(), Math.max(250, delay));
  }

  // Fallback plumbing ------------------------------------------------------

  private scheduleTransportReconnect(failed: SyncTransportKind): void {
    if (this.stopping) return;
    const order: SyncTransportKind[] = ["websocket", "sse", "delta-poll"];
    const index = order.indexOf(failed);
    const next = index + 1 < order.length ? order[index + 1] : "delta-poll";
    void this.startTransport(next);
  }

  private async startTransport(kind: SyncTransportKind): Promise<void> {
    if (this.stopping) return;
    try {
      if (kind === "websocket") {
        await this.connectWebsocket();
      } else if (kind === "sse") {
        await this.connectSse();
      } else {
        await this.startDeltaPoll();
      }
    } catch (err) {
      this.reportError(err);
      this.setStatus("degraded", kind);
      const delay = this.backoffDelay(++this.attempts);
      this.pollTimer = setTimeout(() => {
        const order: SyncTransportKind[] = ["websocket", "sse", "delta-poll"];
        const index = order.indexOf(kind);
        const next = index + 1 < order.length ? order[index + 1] : "delta-poll";
        void this.startTransport(next);
      }, delay);
    }
  }

  private async failStopped(): Promise<void> {
    this.setStatus("stopped", this.status.transport);
  }

  // Helpers ----------------------------------------------------------------

  private url(kind: "snapshot" | "updates" | "stream" | "ws" | "collect", seq = 0): string {
    const base = (this.opts.endpoint ?? "").replace(/\/+$/, "");
    switch (kind) {
      case "snapshot":
        return `${base}/sync/snapshot`;
      case "updates":
        return `${base}/sync/updates/${seq}`;
      case "stream":
        return `${base}/sync/stream`;
      case "ws":
        return `${base}/sync/ws`;
      case "collect":
        return `${base}/collect`;
    }
  }

  private async request(
    url: string,
    init: RequestInit = {},
  ): Promise<Response> {
    const fetchImpl = this.opts.fetchImpl ?? fetch;
    const headers = new Headers(init.headers ?? {});
    if (this.opts.clientKey) headers.set("authorization", `Bearer ${this.opts.clientKey}`);
    return fetchImpl(url, { ...init, headers });
  }

  private currentFlags(): FlagDefinition[] {
    return [...this.flagsById.values()];
  }

  private notifyFlags(): void {
    const flags = this.currentFlags();
    for (const listener of this.flagsListeners) {
      try {
        listener(flags);
      } catch (err) {
        this.reportError(err);
      }
    }
    if (this.onFlags) {
      try {
        this.onFlags(flags);
      } catch (err) {
        this.reportError(err);
      }
    }
  }

  private setStatus(kind: SyncStatus["kind"], transport: SyncTransportKind | null): void {
    this.status = {
      ...this.status,
      kind,
      transport,
      attempts: this.attempts,
      lastSeq: this.lastSeq,
      lastAt: Date.now(),
    };
    for (const listener of this.statusListeners) {
      try {
        listener(this.getStatus());
      } catch {
        // Listener failures must not break sync
      }
    }
  }

  private reportError(error: unknown): void {
    this.status = { ...this.status, lastError: error instanceof Error ? error.message : String(error) };
    for (const listener of this.errorListeners) {
      try {
        listener(error);
      } catch {
        // Listener failures must not break sync
      }
    }
  }
}

/** Build a SyncClient from the host client's options. */
export function createSyncClient(options: DoppioOptions): SyncClient | null {
  if (!options.endpoint) return null;
  const strategy: SyncStrategyKind = options.syncStrategy ?? "auto";
  return new SyncClient({
    endpoint: options.endpoint.replace(/\/+$/, ""),
    clientKey: options.clientKey,
    strategy,
    pollInterval: options.pollInterval ?? 5000,
    flushInterval: options.flushInterval ?? 15000,
    backoffBaseMs: 500,
    backoffCapMs: 30000,
    jitterRatio: 0.1,
  });
}