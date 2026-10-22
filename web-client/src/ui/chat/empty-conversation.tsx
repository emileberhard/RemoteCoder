export function EmptyConversation({ hasHost, setUpHost }: { hasHost: boolean; setUpHost(): void }) {
  return (
    <div className="empty-conversation">
      {!hasHost && (
        <button type="button" className="primary" onClick={setUpHost}>
          Set up a host
        </button>
      )}
    </div>
  );
}
