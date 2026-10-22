
import type { JsonValue } from "./serde_json/JsonValue";
import type { WebSearchAction } from "./v2/WebSearchAction";

export type WebSearchItem = { id: string, query: string, action: WebSearchAction | null,

results: Array<JsonValue> | null, };
