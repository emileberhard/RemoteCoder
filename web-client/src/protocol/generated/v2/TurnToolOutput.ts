
import type { FunctionCallOutputBody } from "../FunctionCallOutputBody";

export type TurnToolOutput = { name: string, namespace: string | null, output: FunctionCallOutputBody,

retain?: boolean, };
