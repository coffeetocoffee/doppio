import { Doppio, EvaluationContext, EvaluationResult } from "@doppio/js";

export interface ReadableStore<T> {
  subscribe(run: (value: T) => void): () => void;
}

export interface FlagStoreValue<T> {
  enabled: boolean;
  value: T;
  variation: string | null;
  reason: string;
}

export interface DoppioStore {
  client: Doppio;
  flag<T = boolean>(flagKey: string, defaultValue?: T, context?: EvaluationContext): ReadableStore<FlagStoreValue<T>>;
  variant<T = any>(flagKey: string, context?: EvaluationContext): ReadableStore<EvaluationResult<T>>;
}

export function createDoppioStore(client: Doppio): DoppioStore {
  return {
    client,
    flag<T = boolean>(flagKey: string, defaultValue?: T, context?: EvaluationContext): ReadableStore<FlagStoreValue<T>> {
      return {
        subscribe(run: (value: FlagStoreValue<T>) => void): () => void {
          const compute = (): FlagStoreValue<T> => {
            const res = client.get<T>(flagKey, context);
            return {
              enabled: res.enabled,
              value: (res.value !== undefined ? res.value : defaultValue) as T,
              variation: res.variation,
              reason: res.reason,
            };
          };

          // Initial emission
          run(compute());

          // Subscribe to changes
          const unsubscribe = client.on("change", (changedKeys?: string[]) => {
            if (!changedKeys || changedKeys.includes(flagKey)) {
              run(compute());
            }
          });

          return unsubscribe;
        },
      };
    },

    variant<T = any>(flagKey: string, context?: EvaluationContext): ReadableStore<EvaluationResult<T>> {
      return {
        subscribe(run: (value: EvaluationResult<T>) => void): () => void {
          run(client.get<T>(flagKey, context));

          const unsubscribe = client.on("change", (changedKeys?: string[]) => {
            if (!changedKeys || changedKeys.includes(flagKey)) {
              run(client.get<T>(flagKey, context));
            }
          });

          return unsubscribe;
        },
      };
    },
  };
}
