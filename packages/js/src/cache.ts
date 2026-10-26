import { FlagDefinition } from "./types.js";

export interface StorageAdapter {
  loadFlags(): Promise<FlagDefinition[] | null>;
  saveFlags(flags: FlagDefinition[]): Promise<void>;
}

export class MemoryStorage implements StorageAdapter {
  private flags: FlagDefinition[] | null = null;

  async loadFlags(): Promise<FlagDefinition[] | null> {
    return this.flags;
  }

  async saveFlags(flags: FlagDefinition[]): Promise<void> {
    this.flags = [...flags];
  }
}

export class IndexedDbStorage implements StorageAdapter {
  private dbName: string;
  private storeName = "flags";

  constructor(dbName = "doppio_cache") {
    this.dbName = dbName;
  }

  private openDb(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
      if (typeof indexedDB === "undefined") {
        return reject(new Error("IndexedDB is not available in this environment"));
      }

      const request = indexedDB.open(this.dbName, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(this.storeName)) {
          db.createObjectStore(this.storeName);
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  async loadFlags(): Promise<FlagDefinition[] | null> {
    try {
      const db = await this.openDb();
      return new Promise((resolve, reject) => {
        const tx = db.transaction(this.storeName, "readonly");
        const store = tx.objectStore(this.storeName);
        const req = store.get("current_flags");
        req.onsuccess = () => resolve(req.result || null);
        req.onerror = () => reject(req.error);
      });
    } catch {
      return null;
    }
  }

  async saveFlags(flags: FlagDefinition[]): Promise<void> {
    try {
      const db = await this.openDb();
      return new Promise((resolve, reject) => {
        const tx = db.transaction(this.storeName, "readwrite");
        const store = tx.objectStore(this.storeName);
        const req = store.put(flags, "current_flags");
        req.onsuccess = () => resolve();
        req.onerror = () => reject(req.error);
      });
    } catch {
      // Fallback silently if storage unavailable
    }
  }
}

export function createStorage(preferIndexedDb = true): StorageAdapter {
  if (preferIndexedDb && typeof indexedDB !== "undefined") {
    return new IndexedDbStorage();
  }
  return new MemoryStorage();
}
