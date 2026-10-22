
import type { DynamicToolFunctionSpec } from "./DynamicToolFunctionSpec";
import type { DynamicToolNamespaceSpec } from "./DynamicToolNamespaceSpec";

export type DynamicToolSpec = { "type": "function" } & DynamicToolFunctionSpec | { "type": "namespace" } & DynamicToolNamespaceSpec;
