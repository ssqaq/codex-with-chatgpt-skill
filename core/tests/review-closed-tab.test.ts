import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {it,expect} from 'vitest';
import {makeTmpDir,cleanup} from './helpers.js';
const repo=fileURLToPath(new URL('../../',import.meta.url));
const bundle=path.join(repo,'bundled-skills/deepseek-consensus-review');
it('restores a proven closed tab without resetting runtime budget, rejecting unsafe or repeated evidence',()=>{
 const dir=makeTmpDir('closed-tab');
 const ps=(file:string,args:string[])=>spawnSync('pwsh',['-NoProfile','-NonInteractive','-File',file,...args],{encoding:'utf8',windowsHide:true,timeout:20000});
 try {
  const setup=ps(path.join(repo,'core/tests/fixtures/review-native-smoke.ps1'),['-SkillRoot',bundle,'-StateDir',dir]);
  expect(setup.status,setup.stderr).toBe(0);
  const file=path.join(dir,'thread-bindings.json'), evidenceFile=path.join(dir,'closed.json');
  const original=JSON.parse(fs.readFileSync(file,'utf8'));
  Object.assign(original.bindings[0],{browserRecoveryCount:1,browserRecoveryStatus:'recovered'});
  const url='https://chat.deepseek.com/a/chat/s/synthetic-session-123';
  const evidence={source:'cua.getState',taskId:'native-smoke',threadId:'native-test-thread',browserSurface:'codex-in-app-sidebar',capturedAt:new Date().toISOString(),oldTabId:'synthetic-tab',tabs:[{id:'restored',url}]};
  const args=['-Action','RecoverRuntimeTab','-TaskId','native-smoke','-CodexThreadId','native-test-thread','-StateDir',dir,
   '-EvidenceSource','dom','-BrowserSurface','codex-in-app-sidebar','-BrowserTabId','restored','-BrowserRuntimeId','synthetic-runtime',
   '-RuntimeEpoch','2','-TabMatchCount','1','-DomTargetUrl',url,'-DomSessionTitle','Synthetic test',
   '-DomMessageMarker','CODEX-BINDING-native-test-thread','-DomModel','网页当前模型（合并升级版）','-DomReasoning','深度思考','-DomSearch','智能搜索','-ClosedTabEvidenceFile',evidenceFile];
  const run=(binding={},e={})=>{const state=structuredClone(original);Object.assign(state.bindings[0],binding);fs.writeFileSync(file,JSON.stringify(state));fs.writeFileSync(evidenceFile,JSON.stringify({...evidence,...e}));return ps(path.join(bundle,'scripts/session_binding.ps1'),args);};
  for(const b of [{pendingReceipt:true},{auditRisk:true},{lastReceiptStatus:'unknown'},{status:'frozen'},{status:'recovery-pending'}])expect(run(b).status).not.toBe(0);
  for(const e of [{taskId:'wrong'},{source:'external-browser'},{capturedAt:new Date(Date.now()-61000).toISOString()},{capturedAt:new Date(Date.now()+60000).toISOString()},{tabs:[{id:'synthetic-tab',url},{id:'restored',url}]},{tabs:[{id:'duplicate',url},{id:'restored',url}]},{tabs:[]}])expect(run({},e).status).not.toBe(0);
  const result=run();expect(result.status,result.stderr).toBe(0);
  const binding=JSON.parse(fs.readFileSync(file,'utf8')).bindings[0];
  expect(binding.browserTabId).toBe('restored');expect(binding.runtimeEpoch).toBe(2);expect(binding.browserRecoveryCount).toBe(1);
  expect(binding.lastMessageFingerprint).toBe(original.bindings[0].lastMessageFingerprint);expect(binding.closedTabRestoreCount).toBe(1);
  expect(JSON.parse(fs.readFileSync(path.join(dir,'native-smoke.json'),'utf8')).executionStatus).toBe('禁止修改');
  expect(ps(path.join(bundle,'scripts/session_binding.ps1'),args).status).not.toBe(0);
  fs.writeFileSync(evidenceFile,JSON.stringify({...evidence,capturedAt:new Date().toISOString(),oldTabId:'restored',tabs:[{id:'restored-again',url}]}));
  const second=args.map((v,i)=>args[i-1]==='-BrowserTabId'?'restored-again':args[i-1]==='-RuntimeEpoch'?'3':v);
  const again=ps(path.join(bundle,'scripts/session_binding.ps1'),second);expect(again.status,again.stderr).toBe(0);
  expect(JSON.parse(fs.readFileSync(file,'utf8')).bindings[0].closedTabRestoreCount).toBe(2);
 } finally {cleanup(dir);}
},30000);
