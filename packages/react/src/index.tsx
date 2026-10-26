import React, { createContext, useContext, useState, useEffect, ReactNode, useMemo } from "react";
import { Doppio, EvaluationContext, EvaluationResult } from "@doppio/js";

const DoppioContext = createContext<Doppio | null>(null);

export interface DoppioProviderProps {
  client: Doppio;
  children: ReactNode;
}

export function DoppioProvider({ client, children }: DoppioProviderProps): React.JSX.Element {
  return React.createElement(DoppioContext.Provider, { value: client }, children);
}

export function useDoppio(): Doppio {
  const client = useContext(DoppioContext);
  if (!client) {
    throw new Error("useDoppio must be used within a DoppioProvider");
  }
  return client;
}

export function useFlag<T = boolean>(
  flagKey: string,
  defaultValue?: T,
  context?: EvaluationContext
): {
  enabled: boolean;
  value: T;
  variation: string | null;
  reason: string;
} {
  const client = useDoppio();
  const [evalResult, setEvalResult] = useState(() => client.get<T>(flagKey, context));

  useEffect(() => {
    // Re-evaluate on mount or context change
    setEvalResult(client.get<T>(flagKey, context));

    const unsubscribe = client.on("change", (changedKeys?: string[]) => {
      if (!changedKeys || changedKeys.includes(flagKey)) {
        setEvalResult(client.get<T>(flagKey, context));
      }
    });

    return unsubscribe;
  }, [client, flagKey, JSON.stringify(context)]);

  return {
    enabled: evalResult.enabled,
    value: (evalResult.value !== undefined ? evalResult.value : defaultValue) as T,
    variation: evalResult.variation,
    reason: evalResult.reason,
  };
}

export function useVariant<T = any>(
  flagKey: string,
  context?: EvaluationContext
): EvaluationResult<T> {
  const client = useDoppio();
  const [result, setResult] = useState(() => client.get<T>(flagKey, context));

  useEffect(() => {
    setResult(client.get<T>(flagKey, context));

    const unsubscribe = client.on("change", (changedKeys?: string[]) => {
      if (!changedKeys || changedKeys.includes(flagKey)) {
        setResult(client.get<T>(flagKey, context));
      }
    });

    return unsubscribe;
  }, [client, flagKey, JSON.stringify(context)]);

  return result;
}
