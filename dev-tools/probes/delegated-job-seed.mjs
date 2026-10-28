import assert from "node:assert/strict";
import { mkdir, readFile, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { createHash } from "node:crypto";

const hash = value => createHash("sha256").update(value).digest("hex");
const maxRecord = 1024 * 1024;

async function contained(root, name) {
    assert(typeof name === "string" && !isAbsolute(name), "Seed paths must be relative snapshot paths");
    const path = await realpath(resolve(root, name));
    assert(!relative(root, path).startsWith(`..${sep}`) && relative(root, path) !== "..", "Seed path escapes its snapshot");
    return path;
}

async function bounded(path, limit) {
    assert((await stat(path)).size <= limit, "Private seed input exceeds its bound");
    return await readFile(path, "utf8");
}

export async function installSeed(lab, manifestPath) {
    const root = await realpath(dirname(manifestPath));
    const manifest = JSON.parse(await bounded(await realpath(manifestPath), maxRecord));
    assert.equal(manifest.version, 1);
    assert.equal(manifest.snapshot, true, "Use an explicitly captured private snapshot");
    assert(Array.isArray(manifest.queries) && manifest.queries.length > 0 && manifest.queries.length <= 8);
    assert(Array.isArray(manifest.transcripts) && manifest.transcripts.length <= 32);
    await contained(root, manifest.jobStore);
    const destination = lab.path(".remote-coder/agent-jobs/v1");
    const snapshots = [];
    const altered = [];
    const homes = new Map();
    const directories = new Map();
    const directory = value => {
        if (!directories.has(value)) directories.set(value, lab.path(`work/seed/${hash(value).slice(0, 16)}`));
        return directories.get(value);
    };
    function remap(value, key) {
        if (Array.isArray(value)) return value.map(entry => remap(entry));
        if (!value || typeof value !== "object") {
            if (typeof value === "string" && isAbsolute(value) && ["cwd", "root", "path", "outputFile", "transcriptPath", "transcript_path"].includes(key)) return directory(value);
            return value;
        }
        const result = {};
        for (const [name, entry] of Object.entries(value)) {
            if (name === "providerHome" && entry?.kind === "known") {
                const provider = value.provider;
                assert(["codex", "claude"].includes(provider), "Seed provider home lacks its exact provider");
                const home = lab.path(provider === "claude" ? ".claude" : ".codex");
                homes.set(entry.path, home);
                result[name] = { ...entry, path: home };
            } else if (["providerHome", "parentHome"].includes(name) && typeof entry === "string") {
                assert(homes.has(entry), "Uncertainty home must match a selected exact provider home");
                result[name] = homes.get(entry);
            } else result[name] = remap(entry, name);
        }
        return result;
    }
    let count = 0;
    for (const kind of ["jobs", "agents", "uncertainties"]) {
        const source = await contained(root, join(manifest.jobStore, kind));
        const names = (await readdir(source)).filter(name => name.endsWith(".json"));
        assert(count + names.length <= 128, "Select at most 128 seed records, including their parents");
        await mkdir(join(destination, kind), { recursive: true });
        for (const name of names) {
            const original = JSON.parse(await bounded(await contained(root, join(manifest.jobStore, kind, name)), maxRecord));
            const record = remap(original);
            if (kind === "jobs") {
                if (record.source !== "imported" || record.stop?.kind !== "notRequested") {
                    altered.push({ jobId: record.jobId, source: record.source, stop: record.stop?.kind });
                }
                record.source = "imported";
                record.stop = { kind: "notRequested" };
            }
            const path = join(destination, kind, name);
            const bytes = JSON.stringify(record);
            await writeFile(path, bytes, { mode: 0o600, flag: "wx" });
            snapshots.push({ path, digest: hash(bytes) });
            count++;
        }
    }
    for (const transcript of manifest.transcripts) {
        assert(/^claude_[a-f0-9-]{36}$/.test(transcript.threadId), "Seed transcript needs an exact Claude thread ID");
        const session = transcript.threadId.slice(7);
        const text = await bounded(await contained(root, transcript.path), 16 * maxRecord);
        const rows = text.split("\n").filter(Boolean).map(line => remap(JSON.parse(line)));
        const cwd = rows.find(row => row.cwd)?.cwd;
        assert(cwd && isAbsolute(cwd), "Seed transcript has no recorded directory");
        const slug = cwd.replace(/[^a-zA-Z0-9]/g, "-");
        const target = lab.path(`.claude/projects/${slug}/${session}.jsonl`);
        await mkdir(dirname(target), { recursive: true });
        await writeFile(target, rows.map(row => JSON.stringify(row)).join("\n") + "\n", { mode: 0o600, flag: "wx" });
    }
    for (const path of directories.values()) await mkdir(path, { recursive: true });
    return { queries: manifest.queries, snapshots, summary: { records: count, transcripts: manifest.transcripts.length,
        projectionOnly: true, transcriptScope: manifest.transcriptScope ?? "selectedTranscripts", importedSnapshots: altered } };
}

export async function inspectSeed(lab, seed) {
    const client = await lab.connect();
    const projections = [];
    for (const query of seed.queries) {
        assert(typeof query.threadId === "string" && Array.isArray(query.expectedAgentIds) && query.expectedAgentIds.length > 0);
        const response = await client.rpc("conversation/agents/list", { threadId: query.threadId });
        assert(!response.error, `Copied conversation agent projection failed: ${JSON.stringify(response.error)}`);
        const agents = response.result.agents;
        assert(Array.isArray(agents));
        for (const id of query.expectedAgentIds) assert(agents.some(agent => agent.id === id), `Expected copied agent ${id} was missing`);
        for (const id of query.unknownAgentIds ?? []) {
            const agent = agents.find(agent => agent.id === id);
            assert(agent, `Ambiguous copied agent ${id} disappeared`);
            assert.equal(agent.state, "unknown");
            assert.equal(agent.executionId, null);
            for (const capability of ["inspect", "message", "continueWork", "stop"]) assert.equal(agent.capabilities[capability], false);
            assert.equal(agent.capabilities.openConversation, true);
        }
        for (const [id, parentId] of Object.entries(query.expectedParentIds ?? {})) {
            assert.equal(agents.find(agent => agent.id === id)?.parentId, parentId, `Copied agent ${id} lost its exact parent`);
        }
        for (const text of query.warningContains ?? []) assert((response.result.warnings ?? []).some(warning => warning.includes(text)),
            `Copied projection omitted expected warning: ${text}`);
        projections.push({ threadId: query.threadId, agentIds: agents.map(agent => agent.id), warnings: response.result.warnings });
    }
    for (const snapshot of seed.snapshots) assert.equal(hash(await readFile(snapshot.path)), snapshot.digest,
        "A read-only copied-state projection mutated its source job snapshot");
    return { ...seed.summary, projections, unchangedSnapshots: true };
}
