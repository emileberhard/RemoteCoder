import { expect, test } from "bun:test";
import { FixtureConnection } from "../server/fixture";
import { type Frame, object } from "../src/protocol/boundary";

test("fixture preference replicas preserve opaque native keys, tombstones and version ordering", () => {
  const host = `preferences-${crypto.randomUUID()}`;
  const frames: Frame[] = [];
  const first = new FixtureConnection(host, (frame) => frames.push(frame as Frame));
  const second = new FixtureConnection(host, (frame) => frames.push(frame as Frame));
  let sequence = 0;
  const call = (connection: FixtureConnection, method: string, entries = {}) => {
    const id = ++sequence;
    connection.receive(JSON.stringify({ id, method, params: { entries } }));
    const reply = frames.find((frame) => frame.id === id);
    expect(reply?.error).toBeUndefined();
    return object(object(reply?.result).entries);
  };
  try {
    const opaque = { value: { future: [null, { flag: true }] }, updatedAt: 100, device: "native" };
    const key = "future.native.preference";
    expect(call(first, "preferences/update", { [key]: opaque })[key]).toEqual(opaque);
    const reset = { value: null, updatedAt: 101, device: "native" };
    call(second, "preferences/update", { [key]: reset });
    call(first, "preferences/update", { [key]: opaque });
    expect(call(first, "preferences/read")[key]).toEqual(reset);
    expect(frames.filter((frame) => frame.method === "preferences/changed")).toHaveLength(4);
  } finally {
    first.close();
    second.close();
  }
});
