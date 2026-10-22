
import type { JsonValue } from "../serde_json/JsonValue";

export type DynamicToolFunctionSpec = { name: string, description: string, inputSchema: JsonValue, deferLoading?: boolean, };
