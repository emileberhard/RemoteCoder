import { Code2 } from "lucide-react";
import { useState } from "react";

export function UnlockScreen({
  loading,
  error,
  unlock,
}: {
  loading: boolean;
  error: string;
  unlock(key: string): Promise<void>;
}) {
  const [key, setKey] = useState("");
  return (
    <main className="unlock">
      <div className="brand-mark">
        <Code2 size={32} />
      </div>
      <h1>RemoteCoder</h1>
      {loading ? (
        <p>Connecting to your workspace…</p>
      ) : (
        <form
          onSubmit={(event) => {
            event.preventDefault();
            void unlock(key).then(() => setKey(""));
          }}
        >
          <label>
            Browser access key
            <input
              autoComplete="current-password"
              type="password"
              value={key}
              onChange={(event) => setKey(event.target.value)}
            />
          </label>
          {error && <p className="error">{error}</p>}
          <button className="primary" type="submit">
            Unlock workspace
          </button>
        </form>
      )}
    </main>
  );
}
