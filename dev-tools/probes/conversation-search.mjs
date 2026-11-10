import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {IsolatedGateway} from './isolated-gateway.mjs';

const [binary] = process.argv.slice(2);
const lab = await IsolatedGateway.create(binary);
let failure;
try {
  const home = lab.path('.claude');
  const project = join(home,'projects','fixture');
  await mkdir(project,{recursive:true});
  const root='11111111-2222-4333-8444-555555555555';
  const records=[
    {type:'user',sessionId:root,uuid:'prompt',cwd:lab.root,timestamp:'2026-11-01T10:00:00Z',message:{role:'user',content:'Drawer jitters'}},
    {type:'assistant',sessionId:root,uuid:'answer',timestamp:'2026-11-01T10:00:01Z',message:{id:'answer',role:'assistant',content:[{type:'text',text:'Fix the flicker in Malmö'}]}},
  ];
  await writeFile(join(project,`${root}.jsonl`),records.map(v=>JSON.stringify(v)+'\n').join(''));
  const provider = lab.path('meaning.sh');
  await writeFile(provider,`cat >/dev/null\nprintf '%s' '${JSON.stringify({conversations:[{sessionId:'unknown',provider:'claude',summary:'omit',score:2},{sessionId:root,provider:'claude',summary:'Drawer reveal stutter',score:1}]})}'\n`);
  const config=lab.path('meaning.json');
  await writeFile(config,JSON.stringify({command:'/bin/sh',args:[provider]}));
  await lab.writeGatewayEnv(['RC_CLAUDE_ENABLED=false',`RC_CLAUDE_HOME=${home}`,`RC_CODEX_GATEWAY_CONVERSATION_SEARCH_PROVIDER_FILE=${config}`]);
  await lab.start();
  const {ws,rpc}=await lab.connect();
  const info=await rpc('host/info',{});
  assert.equal(info.result.conversationSearch,true);
  assert.equal(info.result.conversationSearchByMeaning,true);
  let result;
  await lab.waitFor(async()=>{
    result=await rpc('sessions/conversations/search',{query:'drawer flick',limit:30});
    return result.result?.conversations?.length===1;
  },30);
  assert.equal(result.result.conversations[0].threadId,`claude_${root}`);
  const hit=result.result.conversations[0].hits.find(v=>v.kind==='assistant');
  assert.ok(hit?.excerpt.includes('flicker'));
  const located=await rpc('sessions/locate',{itemKey:hit.itemKey});
  assert.equal(located.result.threadId,`claude_${root}`);
  assert.equal(located.result.itemId,'answer#0');
  assert.ok(located.result.turnId && located.result.turnsCursor && located.result.itemsCursor);
  const items=await rpc('thread/items/list',{threadId:located.result.threadId,cursor:located.result.itemsCursor,sortDirection:'asc',limit:1});
  assert.equal(items.result.data[0].item.id,located.result.itemId);
  const page=await rpc('thread/turns/list',{threadId:located.result.threadId,cursor:located.result.turnsCursor,sortDirection:'asc',itemsView:'full',limit:1});
  assert.equal(page.result.data[0].id,located.result.turnId);
  assert.ok(JSON.stringify(page.result).includes(located.result.itemId));
  const folded=await rpc('sessions/conversations/search',{query:'malmo',limit:30});
  assert.equal(folded.result.conversations.length,1);
  const meaning=await rpc('sessions/conversations/searchByMeaning',{query:'the sidebar has a stutter when it is being revealed',limit:20});
  assert.equal(meaning.result.conversations.length,1);
  assert.equal(meaning.result.conversations[0].threadId,`claude_${root}`);
  assert.equal(meaning.result.conversations[0].summary,'Drawer reveal stutter');
  for(const params of [{query:'',limit:30},{query:'drawer',limit:0},{query:'drawer',limit:30,extra:true}]) {
    assert.equal((await rpc('sessions/conversations/search',params)).error.code,-32602);
  }
  const pidFile=lab.path('meaning.pid');
  await writeFile(provider,`cat >/dev/null\necho $$ > '${pidFile}'\nsleep 30\n`);
  let resolveCancelled;
  const cancelled=new Promise(resolve=>{resolveCancelled=resolve;});
  const listener=event=>{const message=JSON.parse(String(event.data));if(message.id==='meaning-cancel')resolveCancelled(message);};
  ws.addEventListener('message',listener);
  ws.send(JSON.stringify({id:'meaning-cancel',method:'sessions/conversations/searchByMeaning',params:{query:'cancel this provider',limit:20}}));
  let pid;
  await lab.waitFor(async()=>{try{pid=Number((await readFile(pidFile,'utf8')).trim());return pid>0;}catch{return false;}},10);
  ws.send(JSON.stringify({method:'$/cancelRequest',params:{id:'meaning-cancel'}}));
  assert.equal((await lab.within(cancelled,3000,'Meaning cancellation did not answer')).error.data.kind,'requestCancelled');
  await lab.waitFor(async()=>{try{process.kill(pid,0);return false;}catch{return true;}},3);
  ws.removeEventListener('message',listener);
  console.log(JSON.stringify({ok:true,search:true,diacritics:true,locate:located.result,meaning:true}));
} catch(error) {failure=error;}
finally {
  try {await lab.stop();} catch(error) {failure??=error;await lab.forceStop();}
  await lab.stopNativeDaemon(lab.nativeDefault);
  await lab.router?.stop(true);
  if(!failure)await lab.removeRoot();
  else console.error(`Retained isolated evidence: ${lab.root}`);
}
if(failure)throw failure;
