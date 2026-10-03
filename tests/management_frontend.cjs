// Exercise the actual management JS against local, credential-free endpoints.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium, firefox, webkit } = require('playwright');

const assets = path.resolve(__dirname, '../files/basic/www/luci-static/resources');
const scripts = '<script src="/resources/jquery-3.7.1.min.js"></script><script src="/resources/view/8311.js"></script>';
const diagnosticsHtml = process.env.DIAGNOSTICS_FIXTURE_FILE
  ? fs.readFileSync(process.env.DIAGNOSTICS_FIXTURE_FILE, 'utf8')
  : `<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/resources/view/8311.css">
<section id="connection-diagnostics" data-url="/admin/8311/diagnostics" data-unavailable="N/A"
data-failure="Sample may be outdated" data-sampled="Last sample:" data-ingress="Ingress" data-egress="Egress"
data-no-rules="No service rules" data-rules-unavailable="Rule counters unavailable">
<span data-diagnostic="status"></span><span data-diagnostic="power"></span>
<p id="diagnostic-message" role="status"></p>
<div class="diagnostic-scroll"><table><tbody id="diagnostic-links"></tbody></table></div>
<details id="diagnostic-rule-details"><summary>Rule counters</summary>
<div class="diagnostic-scroll"><table><tbody id="diagnostic-rules"></tbody></table></div></details></section>${scripts}`;

function bankHtml(name) {
  if (process.env.FIRMWARE_FIXTURE_DIR)
    return fs.readFileSync(path.join(process.env.FIRMWARE_FIXTURE_DIR, name + '.html'), 'utf8');
  return `<!doctype html><meta charset="utf-8"><div id="8311-recovery-page">
<form id="recovery-form" action="/recovery" data-failure="Backup failed" data-timeout="Timed out">
<input name="token" value="fixture-token"><button type="button" onclick="return backupSettings(this)">Backup</button>
<p id="recovery-message" hidden></p></form>
<form id="firmware-form" action="/flash" method="post"><input name="token" value="fixture-token">
<input id="firmware-action" name="action" value="validate" type="hidden">
${name === 'empty' ? '<button class="firmware-button" type="button" disabled onclick="showSwitchRebootConfirmation();">Trial</button>' :
  '<button class="firmware-button" type="button" onclick="return confirmCurrentFirmware(this);">Confirm</button>'}
</form></div>${scripts}`;
}

let diagnosticRequests = 0, failDiagnostics = false, holdDiagnostics = false;
const heldDiagnostics = [];
const submissions = [];
const diagnosticOptions = [];
const data = {
  status:'Fixture PON', power:'-19 dBm', temperature:'42 C', eth_speed:'10000 Mbps', vlan_message:'Rules checked',
  links:[{ device:'eth0_0', available:true, rules_available:true,
    counters:{rx_packets:'18446744073709551615',tx_packets:'0',rx_dropped:'0',tx_dropped:'0',rx_errors:'0',tx_errors:'0'},
    filters:[{direction:'ingress',protocol:'all',pref:2,action:'<img src=x onerror="window.injected=true">',packets:'0',dropped:'0'}] },
  {device:'eth0_0_2',available:false,rules_available:false,counters:{},filters:[]}]
};
const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];
  if (url.startsWith('/resources/')) {
    const file = path.resolve(assets, url.slice('/resources/'.length));
    if (!file.startsWith(assets + path.sep) || !fs.existsSync(file)) { res.writeHead(404).end(); return; }
    res.setHeader('Content-Type', file.endsWith('.css') ? 'text/css' : 'application/javascript');
    res.end(fs.readFileSync(file));
  } else if (url === '/admin/8311/diagnostics') {
    diagnosticRequests++;
    const rules = new URL(req.url, 'http://127.0.0.1').searchParams.get('rules');
    diagnosticOptions.push(rules);
    const respond = () => {
      res.writeHead(failDiagnostics ? 503 : 200, {'Content-Type':'application/json'});
      res.end(JSON.stringify(rules === '0' ? {...data, links:data.links.map(link=>({...link,filters:[],rules_available:undefined}))} : data));
    };
    if (holdDiagnostics) { heldDiagnostics.push(respond); return; }
    respond();
  } else if (req.method === 'POST') {
    let body = '';
    for await (const chunk of req) body += chunk;
    submissions.push(body);
    if (url.endsWith('/recovery')) {
      res.writeHead(500, {'Content-Type':'application/json'});
      res.end(JSON.stringify({success:false,message:'Fixture backup failed'}));
    } else { res.end('Submitted'); }
  } else {
    res.setHeader('Content-Type','text/html');
    res.end(url === '/diagnostics-page' ? diagnosticsHtml : url === '/empty' ? bankHtml('empty') : url === '/trial' ? bankHtml('trial') : '');
  }
});

(async () => {
  let browser;
  try {
    await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
    const base = 'http://127.0.0.1:' + server.address().port;
    const engine = { chromium, firefox, webkit }[process.env.BROWSER_ENGINE || 'chromium'];
    assert(engine, 'Unsupported BROWSER_ENGINE');
    browser = await engine.launch({headless:true,...(process.env.BROWSER_CHANNEL ? {channel:process.env.BROWSER_CHANNEL} : {})});
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(() => {
      window.fixtureHidden = false;
      Object.defineProperty(document,'hidden',{configurable:true,get:()=>window.fixtureHidden});
      const interval = window.setInterval;
      window.setInterval = (fn, ms) => { if (ms === 10000) { window.diagnosticTick = fn; return 1; } return interval(fn, ms); };
    });
    await page.goto(base + '/diagnostics-page');
    await page.waitForLoadState('networkidle');
    await page.locator('#diagnostic-links').filter({hasText:'18446744073709551615'}).waitFor();
    assert.equal(diagnosticOptions.at(-1),'0','collapsed rule details requested TC counters');
    assert.equal(await page.locator('#diagnostic-rules tr').count(),0);
    await page.locator('#diagnostic-rule-details summary').click();
    await page.locator('#diagnostic-rules').filter({hasText:'<img src=x'}).waitFor();
    assert.equal(diagnosticOptions.at(-1),'1');
    console.log('ok - collapsed rule details skip TC sampling and opening them fetches fresh counters');
    assert.equal(await page.locator('#diagnostic-links tr').first().locator('td').nth(2).innerText(),'0');
    assert.equal(await page.locator('#diagnostic-rules img').count(),0);
    assert.equal(await page.evaluate(()=>window.injected),undefined);
    assert.equal(await page.locator('#diagnostic-links tr').nth(1).locator('td').nth(1).innerText(),
      await page.locator('#connection-diagnostics').getAttribute('data-unavailable'));
    console.log('ok - diagnostics preserve 64-bit counters, real zeroes, unavailable readings and text-only rule descriptions');

    await page.locator('#diagnostic-rule-details summary').click();
    holdDiagnostics = true;
    const beforeOpening = diagnosticRequests;
    await page.evaluate(()=>window.diagnosticTick());
    await page.waitForTimeout(100);
    assert.equal(diagnosticOptions.at(-1),'0');
    await page.locator('#diagnostic-rule-details summary').click();
    assert.equal(diagnosticRequests,beforeOpening+1);
    const fullSample = page.waitForResponse(response => response.url().includes('/admin/8311/diagnostics') &&
      new URL(response.url()).searchParams.get('rules') === '1');
    holdDiagnostics = false;
    heldDiagnostics.shift()();
    await fullSample;
    await page.waitForLoadState('networkidle');
    assert.equal(diagnosticRequests,beforeOpening+2);
    assert.equal(diagnosticOptions.at(-1),'1');
    console.log('ok - opening rules during an active summary request queues one full sample');

    const beforeHidden = diagnosticRequests;
    await page.evaluate(() => { window.fixtureHidden=true; window.diagnosticTick(); document.dispatchEvent(new Event('visibilitychange')); });
    await page.waitForTimeout(100);
    assert.equal(diagnosticRequests,beforeHidden);
    failDiagnostics = true;
    await page.evaluate(() => { window.fixtureHidden=false; document.dispatchEvent(new Event('visibilitychange')); });
    const failure = await page.locator('#connection-diagnostics').getAttribute('data-failure');
    await page.locator('#diagnostic-message').filter({hasText:failure}).waitFor();
    assert.match(await page.locator('#diagnostic-links').innerText(),/18446744073709551615/);
    failDiagnostics = false;
    await page.evaluate(()=>window.diagnosticTick());
    await page.locator('#diagnostic-message').filter({hasText:await page.locator('#connection-diagnostics').getAttribute('data-sampled')}).waitFor();
    console.log('ok - hidden diagnostics stop polling and failed samples are marked stale until a successful retry');

    holdDiagnostics = true;
    const beforeHeld = diagnosticRequests;
    await page.evaluate(() => { window.diagnosticTick(); window.diagnosticTick(); window.diagnosticTick(); });
    await page.waitForTimeout(100);
    assert.equal(diagnosticRequests,beforeHeld+1);
    await page.goto(base + '/empty');
    holdDiagnostics = false;
    await page.waitForLoadState('networkidle');
    const switchButton = page.locator('button[onclick*="showSwitchRebootConfirmation"]');
    assert(await switchButton.isDisabled());
    await page.locator('button[onclick*="backupSettings"]').click();
    await page.locator('#recovery-message').filter({hasText:'Fixture backup failed'}).waitFor();
    await page.waitForFunction(()=>!document.querySelector('button[onclick*="backupSettings"]').disabled);
    assert(await switchButton.isDisabled());
    console.log('ok - overlapping diagnostic requests coalesce and recovery never enables an unavailable bank');

    await page.goto(base + '/trial');
    await page.waitForLoadState('networkidle');
    const beforeConfirm = submissions.length;
    await Promise.all([page.waitForRequest(request=>request.method()==='POST'),
      page.locator('button[onclick*="confirmCurrentFirmware"]').click()]);
    await page.waitForLoadState('networkidle');
    assert.equal(submissions.length,beforeConfirm+1);
    assert.match(submissions.at(-1),/(?:action=commit|name="action"\r\n\r\ncommit)/);
    assert.match(submissions.at(-1),/fixture-token/);
    console.log('ok - confirming a running trial submits one authenticated commit action');

    await page.setViewportSize({width:360,height:800});
    await page.goto(base + '/diagnostics-page');
    await page.waitForLoadState('networkidle');
    await page.locator('#diagnostic-links tr').first().waitFor();
    await page.locator('details').evaluateAll(nodes=>nodes.forEach(node=>node.open=true));
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
    const output = path.resolve(__dirname,'../.test-tmp/diagnostics-mobile.png');
    fs.mkdirSync(path.dirname(output),{recursive:true});
    await page.screenshot({path:output,fullPage:true});
    assert.deepEqual(errors,[]);
    console.log('ok - diagnostics stay within a narrow viewport with horizontally scrollable tables');
  } finally {
    if (browser) await browser.close();
    server.closeAllConnections();
    await new Promise(resolve=>server.close(resolve));
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
