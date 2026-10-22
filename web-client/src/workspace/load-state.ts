export type Load<T> =
  | { status: "unread" | "loading" | "failed"; error?: string }
  | { status: "ready"; value: T };

export const failure = (error: unknown) => (error instanceof Error ? error.message : "The operation failed");
