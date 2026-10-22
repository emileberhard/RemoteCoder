// Isolated gateway/native-runtime acceptance. No production credentials or model prompts.
import assert from "node:assert/strict";
import { mkdir, symlink } from "node:fs/promises";
import { hostname } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const binary = process.argv[2];
assert(binary, "Pass the built gateway executable");
assert(!hostname().includes("mac-mini"), "Run native acceptance on the MacBook, not the services Mini");
const lab = await IsolatedGateway.create(binary);
const { root, nativeDefault, realHome } = lab;
const retiredId = "11111111-1111-1111-1111-111111111111";
const profile = join(root, ".rca", retiredId.replaceAll("-", ""));
const source = join(profile, "c");
let migratedMarks;
const results = [];
function pass(test, extra = {}) { results.push({ test, passed: true, ...extra }); console.log(JSON.stringify({ test, passed: true, ...extra })); }
const write = lab.write.bind(lab);
const request = lab.request.bind(lab);
const start = lab.start.bind(lab);
const stop = lab.stop.bind(lab);
const connect = lab.connect.bind(lab);

async function command(argv) {
    const child = Bun.spawn(argv, { stdout: "ignore", stderr: "pipe" });
    const [status, error] = await Promise.all([child.exited, new Response(child.stderr).text()]);
    assert.equal(status, 0, `${argv[0]} failed: ${error}`);
}

async function rpc(client, method, params = {}) {
    const response = await client.rpc(method, params);
    assert(!response.error, `${method}: ${JSON.stringify(response.error)}`);
    return response.result;
}

async function execHome(client) {
    const result=await client.rpc("command/exec",{command:["/usr/bin/printenv","CODEX_HOME"],cwd:root,
        timeoutMs:10000,sandboxPolicy:{type:"dangerFullAccess"}});
    assert(!result.error,"Native read-only command failed");
    assert.equal(result.result.exitCode,0);
    return result.result.stdout.trim();
}
let failure;
try {
    await mkdir(join(nativeDefault,"packages/standalone"),{recursive:true,mode:0o700});
    await mkdir(join(root,".claude"),{mode:0o700});
    await symlink(join(realHome,".codex/packages/standalone/current"),join(nativeDefault,"packages/standalone/current"));
    await write(join(nativeDefault,"config.toml"),'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n');
    await write(join(root,".claude/settings.json"),'{"disableAllHooks":true}');
    const fixture = resolve(import.meta.dir, "../../host-daemon-rs/test-fixtures/codex-adoption");
    const manifest = await Bun.file(join(fixture,"manifest.json")).json();
    await mkdir(profile,{recursive:true,mode:0o700});
    await command(["tar","-xzf",join(fixture,"native-home.tar.gz"),"-C",profile]);
    await command(["python3",resolve(import.meta.dir,"codex-adoption-rebase.py"),manifest.originalHome,source]);
    await write(join(source,"config.toml"),'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n');
    for(const [directory,baseline,id] of [[join(root,".remote-coder"),300,"host-only"],[join(profile,"state"),100,"source-only"]]) {
        await mkdir(directory,{recursive:true,mode:0o700});
        await write(join(directory,"conversation-marks.v3.json"),JSON.stringify({schemaVersion:3,revision:1,readBaseline:baseline,threads:{[id]:{revision:1,markedUnread:true}}}));
    }
    await lab.writeGatewayEnv([
        `RC_CLAUDE_PATH=${realHome}/.local/bin/claude`,
        `RC_CLAUDE_KEYCHAIN_SHIM_DIR=${realHome}/configs/claude/keychain-shim`,
    ]);
    await start();
    const defaults=await request("/accounts");assert.equal(defaults.accounts.length,2);
    const defaultClient=await connect();assert.equal(await execHome(defaultClient),nativeDefault);
    pass("isolated default gateway uses only the temporary native home");
    const full = await rpc(defaultClient,"conversation/marks/read");
    assert.equal(full.supportsRetiredScopeRead,true);
    assert.equal(full.readBaseline,100);
    const {thread} = await rpc(defaultClient,"thread/start",{cwd:root,model:"gpt-5.4",approvalPolicy:"never",sandbox:"read-only"});
    await rpc(defaultClient,"conversation/marks/update",{changes:[{op:"setPurpose",threadId:thread.id,purpose:"probe"},{op:"markUnread",threadId:thread.id}]});
    const before = await rpc(defaultClient,"conversation/marks/read");
    const sourceRead = {op:"markRetiredScopeRead",scopeId:retiredId,through:200};
    const {delta} = await rpc(defaultClient,"conversation/marks/update",{changes:[sourceRead]});
    assert.equal(delta.readBaseline,100);
    assert(!("supportsRetiredScopeRead" in delta));
    const after = await rpc(defaultClient,"conversation/marks/read");
    for(const id of [...manifest.threads.map(thread=>thread.id),"source-only"]) {
        assert.equal(after.threads[id].seenThrough,200,`uncached scope ID ${id}`);
        assert(!after.threads[id].markedUnread);
    }
    for(const id of ["host-only",thread.id])assert.deepEqual(after.threads[id],before.threads[id]);
    const duplicate = await rpc(defaultClient,"conversation/marks/update",{changes:[sourceRead]});
    assert.equal(duplicate.delta,null);
    pass("full-read capability and scoped reads cover uncached native fixture threads only");
    const failed = await defaultClient.rpc("conversation/marks/update",{changes:[
        {op:"pin",threadId:"host-only",name:"Must not commit"},
        {op:"markUnread",threadId:manifest.threads[0].id},
        {op:"markRetiredScopeRead",scopeId:"22222222-2222-2222-2222-222222222222",through:200},
    ]});
    assert(failed.error,"Unknown scope must fail visibly");
    assert.deepEqual(await rpc(defaultClient,"conversation/marks/read"),after);
    pass("unknown scoped reads reject a mixed batch without any partial marks mutation");
    await rpc(defaultClient,"conversation/marks/update",{changes:[{op:"markRetiredScopeRead",scopeId:"default",through:200}]});
    migratedMarks = await rpc(defaultClient,"conversation/marks/read");
    assert.equal(migratedMarks.threads["host-only"].seenThrough,300);
    assert(!migratedMarks.threads["host-only"].markedUnread);
    assert.deepEqual(migratedMarks.threads[thread.id],after.threads[thread.id]);
    for(const {id} of manifest.threads)assert.deepEqual(migratedMarks.threads[id],after.threads[id]);
    assert.equal(migratedMarks.readBaseline,100);
    pass("the original default scope excludes adopted source threads and newer drafts");
    for(const [method,params] of [["account/login/start",{type:"chatgpt"}],["account/logout",{}]]) {
        const refused=await defaultClient.rpc(method,params);
        assert(refused.error?.message?.includes("llm-router"),`${method} reached the default runtime`);
    }
    pass("the default runtime refuses native sign-in and sign-out");
    assert.equal(defaults.schemaVersion,2);
    assert(!("handoffs" in defaults) && !("handoffSnapshots" in defaults));
    const id=randomUUID();
    for(const [path,method,body] of [
        ["/accounts/enroll","POST",{id,provider:"codex",label:"native"}],
        ["/accounts/handoff","POST",{}],
        [`/accounts/${id}/login`,"POST",{generation:1}],
        [`/accounts/${id}/login`,"DELETE"],
        [`/accounts/${id}/logout`,"POST",{generation:1}],
        [`/accounts/${id}`,"PUT",{generation:1,label:"retired",enabled:false}],
        [`/accounts/${id}/remove`,"POST",{generation:1}],
    ]) {
        await request(path,method,body,[404,405]);
    }
    assert.equal((await request("/accounts")).accounts.length,2);
    pass("Codex enrollment mutations, sign-in and handoff routes are gone");
    defaultClient.ws.close();
    await stop();await start();
    const restored=await connect();assert.equal(await execHome(restored),nativeDefault);
    assert.deepEqual(await rpc(restored,"conversation/marks/read"),migratedMarks);
    pass("gateway restart preserves the isolated default home and scoped marks");
    pass("no model prompts or production account grants were used");
} catch(error) {
    failure=error;console.error(JSON.stringify({passed:false,error:String(error.message),evidenceRoot:root}));
} finally {
    try { await stop(); } catch(error) { failure??=error; await lab.forceStop(); }
    for(const home of [source,nativeDefault]) {
        if(!await lab.hasNativeDaemon(home))continue;
        try {
            if(await lab.stopNativeDaemon(home)!==0)failure??=new Error("Owned native daemon cleanup failed");
        } catch(error) { failure??=error; }
    }
    if(!failure)await lab.removeRoot();
    console.log(JSON.stringify({summary:{passed:!failure,tests:results.length,temporaryHomesRemoved:!failure,
        evidenceRoot:failure?root:undefined}}));
}
if(failure)process.exitCode=1;
