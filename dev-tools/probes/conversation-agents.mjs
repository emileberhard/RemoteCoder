import assert from "node:assert/strict";
import { mkdir, symlink } from "node:fs/promises";
import { hostname } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { IsolatedGateway } from "./isolated-gateway.mjs";

const binary = process.argv[2];
const launcherSource = process.argv[3];
assert(launcherSource, "Pass the matching configs checkout");
assert(binary, "Pass the built gateway executable");
assert(!hostname().includes("mac-mini"), "Run native acceptance on the MacBook, not the services Mini");
const lab = await IsolatedGateway.create(binary);
const { root, nativeDefault, realHome } = lab;
lab.safeEnv.RC_AGENT_WORK_CLI = lab.path("agent-work");
const results = [];
function pass(test, extra = {}) { results.push({ test, passed: true, ...extra }); console.log(JSON.stringify({ test, passed: true, ...extra })); }
const write = lab.write.bind(lab);
const request = lab.request.bind(lab);
const start = lab.start.bind(lab);
const stop = lab.stop.bind(lab);
const connect = lab.connect.bind(lab);

const parent="11111111-2222-4333-8444-555555555555";
const external="22222222-2222-4222-8222-222222222222";
const rootThread=`claude_${parent}`;
const nativeAgent="a123456789";
let failure;
try {
    await mkdir(join(nativeDefault,"packages/standalone"),{recursive:true,mode:0o700});
    await symlink(join(realHome,".codex/packages/standalone/current"),join(nativeDefault,"packages/standalone/current"));
    await write(join(nativeDefault,"config.toml"),'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n');
    const claudeHome=join(root,".claude"), project=join(claudeHome,"projects","-fixture");
    await mkdir(project,{recursive:true,mode:0o700});
    await write(join(claudeHome,"settings.json"),'{"disableAllHooks":true}');
    const user=(id,text)=>({type:"user",uuid:randomUUID(),sessionId:id,cwd:root,timestamp:"2026-09-26T10:00:00Z",message:{role:"user",content:text}});
    const assistant=(text)=>({type:"assistant",message:{role:"assistant",content:[{type:"text",text}]}});
    const records=[user(parent,"Review this project"),
        {type:"assistant",message:{content:[{type:"tool_use",name:"Agent",id:"tool-native",input:{description:"Native review",model:"opus"}}]}},
        {type:"user",toolUseResult:{agentId:nativeAgent,resolvedModel:"claude-opus-5-5",status:"completed"},message:{content:[{type:"tool_result",tool_use_id:"tool-native",content:"Native summary"}]}}];
    await write(join(project,`${parent}.jsonl`),records.map(JSON.stringify).join("\n")+"\n");
    await write(join(project,`${external}.jsonl`),JSON.stringify(user(external,"<agent_message>not ancestry</agent_message>"))+"\n");
    await mkdir(join(project,parent,"subagents"),{recursive:true});
    await write(join(project,parent,"subagents",`agent-${nativeAgent}.jsonl`),JSON.stringify(assistant("Native checked output"))+"\n");
    const runs=join(root,".local/state/emils-subagents/runs");
    async function run(id,metadata,result) {
        const path=join(runs,id); await mkdir(path,{recursive:true});
        await write(join(path,"metadata.json"),JSON.stringify(metadata));
        await write(join(path,"done"),"exit_code=0\n");
        await write(join(path,"result.txt"),result);
    }
    const metadata={agent:"claude",provider_session_id:external,provider_home:claudeHome,
        parent_kind:"claude",parent_provider_session_id:parent,parent_home:claudeHome,
        spawned_at_epoch_ms:1,title:"External review",model:"opus"};
    await run("agent-claude-1",metadata,"First output");
    await run("agent-claude-2",{...metadata,parent_kind:null,parent_provider_session_id:null,parent_home:null,
        spawned_at_epoch_ms:2,resumed_from_run:"agent-claude-1"},"Continued exact session");
    await write(join(root,"agent-work"),`#!/bin/sh\nexec '${realHome}/.local/bin/python3' '${launcherSource}/skills/agents/scripts/agent_work.py' "$@"\n`);
    await Bun.$`chmod 700 ${join(root,"agent-work")}`.quiet();
    const reindex=await Bun.$`echo ${JSON.stringify({schemaVersion:2,operation:"reindex"})} | ${join(root,"agent-work")}`.env(lab.safeEnv).json();
    assert.equal(reindex.coverage.status,"complete");
    await lab.writeGatewayEnv([
        `RC_CLAUDE_HOME=${claudeHome}`,
        `RC_CLAUDE_PATH=${realHome}/.local/bin/claude`,
        `RC_CLAUDE_KEYCHAIN_SHIM_DIR=${realHome}/configs/claude/keychain-shim`,
    ]);
    await start();
    const client=await connect();
    async function rpc(method,params) {
        const reply=await client.rpc(method,params);
        assert(!reply.error,`${method}: ${reply.error?.message}`);
        return reply.result;
    }
    const classified=await rpc("conversation/agents/classify",{threadIds:[rootThread,`claude_${external}`]});
    assert(!classified.relations[rootThread]);
    assert.equal(classified.relations[`claude_${external}`].parentThreadId,rootThread);
    pass("classification uses exact original delegation and does not promote XML text to ancestry");
    const list=await rpc("conversation/agents/list",{threadId:rootThread});
    assert.equal(list.agents.length,2);
    const native=list.agents.find(a=>a.source==="native");
    assert.equal(native.state,"completed");assert(!native.capabilities.stop);
    const launcher=list.agents.find(a=>a.id==="launcher:agent-claude-1");
    assert.equal(launcher.executionId,"agent-claude-2");assert(launcher.capabilities.continueWork);
    pass("native and launcher children share one stable graph across continuation");
    const nativeOutput=await rpc("conversation/agents/read",{threadId:rootThread,agentId:native.id});
    assert(nativeOutput.messages.some(m=>m.text==="Native checked output"));
    const externalOutput=await rpc("conversation/agents/read",{threadId:rootThread,agentId:launcher.id});
    assert(externalOutput.messages.some(m=>m.text==="Continued exact session"));
    pass("output is routed to the exact native agent and latest external execution");
    const stale=await client.rpc("conversation/agents/action",{threadId:rootThread,agentId:launcher.id,
        executionId:"agent-claude-1",action:"continue",mutationId:"stale",text:"must not start"});
    assert(stale.error && stale.error.message.includes("execution"));
    const escaped=await client.rpc("conversation/agents/read",{threadId:`claude_${external}`,agentId:native.id});
    assert(escaped.error);
    pass("stale controls and unrelated parent reads are rejected without model execution");
} catch(error) {
    failure=error;console.error(JSON.stringify({passed:false,error:String(error.message),evidenceRoot:root}));
} finally {
    try { await stop(); } catch(error) { failure??=error; await lab.forceStop(); }
    if(lab.child) {
        try {
            if(await lab.stopNativeDaemon(nativeDefault)!==0)failure??=new Error("Owned native daemon cleanup failed");
        } catch(error) { failure??=error; }
    }
    if(!failure)await lab.removeRoot();
    console.log(JSON.stringify({summary:{passed:!failure,tests:results.length,temporaryHomesRemoved:!failure,evidenceRoot:failure?root:undefined}}));
}
if(failure)process.exitCode=1;
