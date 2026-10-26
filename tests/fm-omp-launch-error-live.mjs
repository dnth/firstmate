// Real installed OMP against a disposable local HTTP 429 provider; no vendor credentials.
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
const home = resolve(process.env.FM_OMP_PROBE_HOME);
let requests = 0;
const message = 'Go usage limit exceeded retry-after-ms=363080000';
const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch() {
  requests++;
  return Response.json({ error: { message, type: 'GoUsageLimitError', code: 'rate_limit_exceeded' } }, { status: 429 });
}});
const extension = `${home}/quota-provider.ts`;
writeFileSync(extension, `export default function(pi) { pi.registerProvider('quota-probe', {baseUrl: 'http://127.0.0.1:${server.port}/v1', apiKey: 'disposable', api: 'openai-completions', models: [{id:'probe', name:'probe', reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:128000,maxTokens:100}]}); }\n`);
const journal = `${home}/native-error.json`;
const child = Bun.spawn([process.env.FM_OMP_PROBE_BIN, '--print', '--no-extensions', '--no-tools', '--no-lsp', '-e', `${home}/.omp/extensions/fm-primary-omp.ts`, '-e', extension, '--model', 'quota-probe/probe', 'Reply OK'], {
  cwd: home,
  env: {...process.env, FM_TASK_ID:'', FM_HOME:home, FM_ROOT_OVERRIDE:home, FM_STATE_OVERRIDE:`${home}/state`, FM_DATA_OVERRIDE:`${home}/data`, FM_CONFIG_OVERRIDE:`${home}/config`, PI_CODING_AGENT_DIR:`${home}/agent`, FM_OMP_LAUNCH_ERROR:journal, OMP_SKIP_SETUP:'1'},
  stdout:'pipe', stderr:'pipe',
});
const timer = setTimeout(() => child.kill(), 120000);
try {
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  console.log(`real OMP CLI exit=${code}, local provider requests=${requests}`);
  console.log(stdout.slice(-3000)); console.log(stderr.slice(-3000));
  if (!existsSync(journal)) throw new Error('real OMP did not publish a native launch-error journal');
  const value = JSON.parse(readFileSync(journal, 'utf8'));
  if (!value.errorMessage.includes(message) || value.pid !== child.pid) throw new Error('native error text/PID mismatch');
  console.log(JSON.stringify(value));
  console.log('ok - real OMP published exact native 429 provider error/retry window under its own PID');
} finally { clearTimeout(timer); server.stop(true); }
