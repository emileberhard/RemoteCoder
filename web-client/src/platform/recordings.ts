export type SavedRecording = {
  id: string;
  hostId: string;
  createdAt: number;
  blob: Blob;
};

export interface RecordingStore {
  save(recording: SavedRecording): Promise<void>;
  list(hostId: string): Promise<SavedRecording[]>;
  remove(id: string): Promise<void>;
}

export class BrowserRecordingStore implements RecordingStore {
  private database?: Promise<IDBDatabase>;

  private open(): Promise<IDBDatabase> {
    if (this.database) return this.database;
    this.database = new Promise((resolve, reject) => {
      const request = indexedDB.open("remotecoder-dictation", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("recordings", { keyPath: "id" });
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error("Could not open saved dictation recordings"));
      request.onblocked = () =>
        reject(new Error("Close another RemoteCoder tab before opening dictation storage"));
    });
    return this.database;
  }

  async save(recording: SavedRecording): Promise<void> {
    const database = await this.open();
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction("recordings", "readwrite");
      const store = transaction.objectStore("recordings");
      const existing = store.getAll();
      existing.onsuccess = () => {
        const records = existing.result as SavedRecording[];
        const bytes = records.reduce((total, item) => total + item.blob.size, 0);
        if (records.length >= 20 || bytes + recording.blob.size > 100 * 1024 * 1024) {
          transaction.abort();
          reject(new Error("Saved dictation storage is full. Retry or discard an earlier recording."));
          return;
        }
        store.put(recording);
      };
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(new Error("Could not save the dictation recording"));
      transaction.onabort = () => reject(new Error("The dictation recording could not be saved"));
    });
  }

  async list(hostId: string): Promise<SavedRecording[]> {
    const database = await this.open();
    return new Promise((resolve, reject) => {
      const request = database.transaction("recordings", "readonly").objectStore("recordings").getAll();
      request.onsuccess = () =>
        resolve(
          (request.result as SavedRecording[])
            .filter((item) => item.hostId === hostId)
            .sort((left, right) => right.createdAt - left.createdAt),
        );
      request.onerror = () => reject(new Error("Could not read saved dictation recordings"));
    });
  }

  async remove(id: string): Promise<void> {
    const database = await this.open();
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction("recordings", "readwrite");
      transaction.objectStore("recordings").delete(id);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(new Error("Could not remove the saved dictation recording"));
    });
  }

  dispose(): void {
    void this.database?.then(
      (database) => database.close(),
      () => undefined,
    );
  }
}
