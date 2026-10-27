/**
 * OpenFeature Provider for Doppio (JavaScript/TypeScript)
 * 
 * Implements the OpenFeature Provider interface to allow Doppio
 * to be used as a feature flag backend for OpenFeature-compatible applications.
 * 
 * Install: npm install @openfeature/server-sdk @doppio/js
 * Usage: 
 *   import { OpenFeature } from '@openfeature/server-sdk';
 *   import { DoppioProvider } from '@doppio/js/openfeature';
 *   import { Doppio } from '@doppio/js';
 * 
 *   const doppio = await Doppio.init({ flags: [...] });
 *   OpenFeature.setProvider(new DoppioProvider(doppio));
 *   const client = OpenFeature.getClient('my-app');
 *   const enabled = await client.getBooleanValue('flag-key', false, { targetingKey: 'user-123' });
 */

import { Provider, EvaluationContext, ResolutionDetails, FlagMetadata } from '@openfeature/server-sdk';
import { Doppio, EvaluationContext as DoppioContext, FlagDefinition, EvaluationReason } from './index.js';

export interface DoppioProviderOptions {
  /** The initialized Doppio client instance */
  doppio: Doppio;
  /** Optional: map Doppio variation values to OpenFeature types */
  valueMapper?: (value: any, type: 'boolean' | 'string' | 'number' | 'object') => any;
}

export class DoppioProvider {
  readonly metadata: FlagMetadata = {
    name: 'Doppio Feature Flag Provider',
  };

  private doppio: Doppio;
  private valueMapper: DoppioProviderOptions['valueMapper'];

  constructor(options: DoppioProviderOptions) {
    this.doppio = options.doppio;
    this.valueMapper = options.valueMapper ?? defaultValueMapper;
  }

  private convertContext(context?: EvaluationContext): DoppioContext {
    if (!context) return {};
    
    const doppioContext: DoppioContext = {
      unitId: context.targetingKey,
      userId: context.targetingKey,
    };

    // Map standard OpenFeature context fields
    if (typeof context.custom === 'object' && context.custom !== null) {
      for (const [key, value] of Object.entries(context.custom)) {
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          doppioContext[key] = value;
        }
      }
    }

    // Explicit mappings for common fields
    if (context.ip) doppioContext.custom = { ...doppioContext.custom, ip: String(context.ip) };
    if (context.userAgent) doppioContext.custom = { ...doppioContext.custom, userAgent: String(context.userAgent) };
    if (context.hostname) doppioContext.custom = { ...doppioContext.custom, hostname: String(context.hostname) };

    return doppioContext;
  }

  private mapReason(reason: EvaluationReason): ResolutionDetails<any>['reason'] {
    switch (reason) {
      case 'TARGET_MATCH':
        return 'TARGETING_MATCH';
      case 'ROLLOUT':
      case 'ROLLOUT_MISS':
        return 'SPLIT';
      case 'DISABLED':
        return 'DISABLED';
      case 'DEFAULT':
        return 'DEFAULT';
      case 'PREREQUISITE_FAILED':
        return 'ERROR';
      case 'ERROR':
      default:
        return 'ERROR';
    }
  }

  private getFlagMetadata(flagKey: string): FlagMetadata | undefined {
    const flag = (this.doppio as any).flags?.get?.(flagKey);
    if (!flag) return undefined;
    
    return {
      flagKey,
      description: flag.variations?.map((v: any) => `${v.key}: ${v.value}`).join(', '),
    };
  }

  async resolveBooleanEvaluation(
    flagKey: string,
    defaultValue: boolean,
    context?: EvaluationContext
  ): Promise<ResolutionDetails<boolean>> {
    const doppioCtx = this.convertContext(context);
    const result = this.doppio.get<boolean>(flagKey, doppioCtx);
    
    const value = result.enabled && result.value !== undefined
      ? Boolean(result.value)
      : defaultValue;

    return {
      value,
      variant: result.variation ?? undefined,
      reason: this.mapReason(result.reason),
      flagMetadata: this.getFlagMetadata(flagKey),
    };
  }

  async resolveStringEvaluation(
    flagKey: string,
    defaultValue: string,
    context?: EvaluationContext
  ): Promise<ResolutionDetails<string>> {
    const doppioCtx = this.convertContext(context);
    const result = this.doppio.get<string>(flagKey, doppioCtx);
    
    const value = result.enabled && result.value !== undefined
      ? String(result.value)
      : defaultValue;

    return {
      value,
      variant: result.variation ?? undefined,
      reason: this.mapReason(result.reason),
      flagMetadata: this.getFlagMetadata(flagKey),
    };
  }

  async resolveNumberEvaluation(
    flagKey: string,
    defaultValue: number,
    context?: EvaluationContext
  ): Promise<ResolutionDetails<number>> {
    const doppioCtx = this.convertContext(context);
    const result = this.doppio.get<number>(flagKey, doppioCtx);
    
    const value = result.enabled && typeof result.value === 'number'
      ? result.value
      : defaultValue;

    return {
      value,
      variant: result.variation ?? undefined,
      reason: this.mapReason(result.reason),
      flagMetadata: this.getFlagMetadata(flagKey),
    };
  }

  async resolveObjectEvaluation<U extends object>(
    flagKey: string,
    defaultValue: U,
    context?: EvaluationContext
  ): Promise<ResolutionDetails<U>> {
    const doppioCtx = this.convertContext(context);
    const result = this.doppio.get<U>(flagKey, doppioCtx);
    
    let value: U = defaultValue;
    if (result.enabled && result.value !== undefined) {
      try {
        value = result.value as U;
      } catch {
        value = defaultValue;
      }
    }

    return {
      value,
      variant: result.variation ?? undefined,
      reason: this.mapReason(result.reason),
      flagMetadata: this.getFlagMetadata(flagKey),
    };
  }

  // OpenFeature hook support (optional)
  async onContextChange(oldContext: EvaluationContext, newContext: EvaluationContext): Promise<void> {
    // Doppio handles context per-evaluation, no persistent state to update
    // Could emit events or invalidate caches here if needed
  }

  // Track exposures for analytics
  private trackExposure(flagKey: string, context?: EvaluationContext): void {
    // Exposure is already tracked by Doppio.get()
    // This is a no-op but available for custom tracking
  }
}

function defaultValueMapper(value: any, type: 'boolean' | 'string' | 'number' | 'object'): any {
  switch (type) {
    case 'boolean':
      return Boolean(value);
    case 'string':
      return String(value);
    case 'number':
      const num = Number(value);
      return isNaN(num) ? 0 : num;
    case 'object':
      if (typeof value === 'string') {
        try {
          return JSON.parse(value);
        } catch {
          return {};
        }
      }
      return value ?? {};
    default:
      return value;
  }
}

export function createDoppioProvider(options: DoppioProviderOptions): DoppioProvider {
  return new DoppioProvider(options);
}