'use strict';
// Thin stdio transport for the official installed Playwright MCP API.
// Wampum owns the isolated context, avoiding the CLI's detached browser daemon.
const path = require('node:path');
const readline = require('node:readline');
const http = require('node:http');
const cli = process.argv[2];
const outputDir = process.argv[3];
const headed = process.argv[4] === 'headed';
const packageRoot = path.dirname(cli);
const { createConnection } = require(packageRoot);
const { chromium } = require(path.resolve(packageRoot, '../../playwright'));
let browser;
let server;
let closing = false;
let fixture;
async function fixtureURL() {
  if (!fixture) {
    fixture = http.createServer((request, response) => {
      response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'});
      response.end(`<!doctype html><html><head><title>Wampum browser check</title></head><body style="margin:0;background:#17191d;color:#f5f0e7;font:22px -apple-system,sans-serif;padding:48px"><p style="color:#baca94;font:14px monospace">WAMPUM / LOCAL BROWSER CHECK</p><h1>The page and the model share a tab.</h1><p>This page is served only on this Mac.</p><p id="result">Evidence pending</p><button style="font:20px sans-serif;padding:14px 22px;background:#becf99;border:0;border-radius:8px" onclick="document.getElementById('result').textContent='Evidence recorded 742'">Record evidence</button><p style="font-size:15px;color:#aaa">Ask Qwen to click Record evidence once. Review its arguments, allow the action, then watch this capture update.</p><script>console.info('WAMPUM_BROWSER_CHECK_READY')</script></body></html>`);
    });
    await new Promise((resolve, reject) => {fixture.once('error', reject);fixture.listen(0, '127.0.0.1', resolve);});
  }
  return 'http://127.0.0.1:' + fixture.address().port;
}
async function shutdown() {
  if (closing) return;
  closing = true;
  const timer = setTimeout(() => process.exit(1), 2500).unref();
  try { fixture?.close(); } catch {}
  try { if (server) await server.close(); } catch {}
  try { if (browser) await browser.close(); } catch {}
  clearTimeout(timer);
  process.exit(0);
}
(async () => {
  const transport = {
    async start() {
      const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
      input.on('line', line => {
        try {
          const message = JSON.parse(line);
          if (message.method === 'wampum/self-check') {
            void fixtureURL().then(url => this.send({jsonrpc:'2.0',id:message.id,result:{url}})).catch(error => this.send({jsonrpc:'2.0',id:message.id,error:{code:-32603,message:error.message}}));
          } else if (message.method === 'wampum/diagnostics') {
            void this.send({jsonrpc:'2.0',id:message.id,result:{node:process.version,playwrightMCP:require(path.join(packageRoot,'package.json')).version,chrome:browser?.version() || 'not started',mode:headed ? 'window':'headless viewer'}});
          } else { this.onmessage?.(message); }
        }
        catch (error) { this.onerror?.(error); }
      });
      input.on('close', () => { this.onclose?.(); void shutdown(); });
      this.input = input;
    },
    async send(message) {
      await new Promise((resolve, reject) => process.stdout.write(JSON.stringify(message) + '\n', error => error ? reject(error) : resolve()));
    },
    async close() { this.input?.close(); }
  };
  server = await createConnection({
    browser: { isolated: false }, // contextGetter supplies a fresh nonpersistent context.
    webmcp: false,
    outputDir,
    outputMaxSize: 64 * 1024 * 1024,
    timeouts: { action: 5000, navigation: 15000 },
    console: { level: 'info' }
  }, async () => {
    browser = await chromium.launch({ channel: 'chrome', headless: !headed });
    return await browser.newContext({ viewport: { width: 1200, height: 800 }, serviceWorkers: 'block', acceptDownloads: false });
  });
  await server.connect(transport);
})().catch(error => { console.error(error.stack || String(error)); void shutdown(); });
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
