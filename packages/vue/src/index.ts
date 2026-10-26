import { App, inject, InjectionKey, ref, onUnmounted, readonly, Ref } from "vue";
import { Doppio, EvaluationContext, EvaluationResult } from "@doppio/js";

export const DOPPIO_KEY: InjectionKey<Doppio> = Symbol("doppio");

export interface DoppioPluginOptions {
  client: Doppio;
}

export function createDoppio(client: Doppio) {
  return {
    install(app: App) {
      app.provide(DOPPIO_KEY, client);
      app.config.globalProperties.$doppio = client;
    },
  };
}

export function useDoppio(): Doppio {
  const client = inject(DOPPIO_KEY);
  if (!client) {
    throw new Error("useDoppio requires Doppio plugin installed via app.use(createDoppio(client))");
  }
  return client;
}

export interface UseFlagReturn<T> {
  enabled: boolean;
  value: T;
  variation: string | null;
  reason: string;
}

export function useFlag<T = boolean>(
  flagKey: string,
  defaultValue?: T,
  context?: EvaluationContext
): Ref<UseFlagReturn<T>> {
  const client = useDoppio();
  const compute = () => {
    const res = client.get<T>(flagKey, context);
    return {
      enabled: res.enabled,
      value: (res.value !== undefined ? res.value : defaultValue) as T,
      variation: res.variation,
      reason: res.reason,
    };
  };

  const state = ref(compute()) as Ref<UseFlagReturn<T>>;

  const unsubscribe = client.on("change", (changedKeys?: string[]) => {
    if (!changedKeys || changedKeys.includes(flagKey)) {
      state.value = compute();
    }
  });

  try {
    onUnmounted(() => {
      unsubscribe();
    });
  } catch {
    // Outside component lifecycle, keep subscription
  }

  return readonly(state) as Ref<UseFlagReturn<T>>;
}

export function useVariant<T = any>(
  flagKey: string,
  context?: EvaluationContext
): Ref<EvaluationResult<T>> {
  const client = useDoppio();
  const compute = () => client.get<T>(flagKey, context);
  const state = ref(compute()) as Ref<EvaluationResult<T>>;

  const unsubscribe = client.on("change", (changedKeys?: string[]) => {
    if (!changedKeys || changedKeys.includes(flagKey)) {
      state.value = compute();
    }
  });

  try {
    onUnmounted(() => {
      unsubscribe();
    });
  } catch {
    // Outside component lifecycle
  }

  return readonly(state) as Ref<EvaluationResult<T>>;
}
