export function Diff({ text }: { text: string }) {
  return (
    <pre className="diff">
      {text
        ? text.split("\n").map((line, index) => (
            <span
              key={`part:${index}`}
              className={
                line.startsWith("+")
                  ? "added"
                  : line.startsWith("-")
                    ? "removed"
                    : line.startsWith("@@")
                      ? "hunk"
                      : ""
              }
            >
              {line || " "}
              {"\n"}
            </span>
          ))
        : "Diff unavailable"}
    </pre>
  );
}
