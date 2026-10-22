export type DrawerUndo = Readonly<{ count: number; expiresAt: number; undo(): void }>;

export function drawerUndo(count: number, restore: () => void): DrawerUndo {
  const expiresAt = Date.now() + 5000;
  let available = true;
  return {
    count,
    expiresAt,
    undo() {
      if (!available) return;
      if (Date.now() >= expiresAt) throw new Error("Undo has expired");
      restore();
      available = false;
    },
  };
}
