// Optional browser smoke test: local fixture endpoints only, no device access.
// Requires Playwright and Chromium/Firefox, or BROWSER_CHANNEL=msedge/chrome.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium, firefox, webkit } = require('playwright');

const assets = path.resolve(__dirname, '../files/basic/www/luci-static/resources');
const requests = [];
let status = 200;
let backupContentType = 'text/plain; charset=utf-8';
let configuredInternetVlan = '100';
let holdRequests = false;
let holdBackupBody = false;
const html = `<!doctype html><meta charset="utf-8">
<style>[data-tab]:not(li):not([data-tab-active]){display:none}</style>
<ul><li class="cbi-tab" data-tab="pon">PON</li><li class="cbi-tab-disabled" data-tab="vlans">VLAN</li></ul>
<form id="8311-config" action="save" onsubmit="return saveConfig(this)" novalidate
data-unsaved="Unsaved changes" data-timeout="Request timed out; reload to check saved settings">
<input type="hidden" name="token" value="fixture-token">
<p id="config-save-message" role="status" style="display:none"></p>
<div data-tab="pon" data-tab-active="true">
<input id="widget.cbid.system.poncfg.gpon_sn" name="gpon_sn" value="TEST12345678" required data-cat-id="pon">
<label class="error" for="widget.cbid.system.poncfg.gpon_sn"></label></div>
<div data-tab="vlans"><select id="widget.cbid.system.poncfg.fix_vlans" name="fix_vlans" data-cat-id="vlans">
<option value="0">Disabled</option><option value="1" selected>Enabled</option></select>
<div class="vlan-field"><input type="number" id="widget.cbid.system.poncfg.internet_vlan" name="internet_vlan" min="0" max="4095" value="100" data-cat-id="vlans">
<label class="error" for="widget.cbid.system.poncfg.internet_vlan"></label></div></div>
<button id="save-btn" type="submit">Save</button><button id="edit-hook-script-btn">Edit hook</button></form>
<div id="hook-script-modal" style="display:none"><p id="hook-script-message"></p>
<textarea id="hook-script-textarea"></textarea><button id="hook-script-save-btn">Save hook</button>
<button id="hook-script-cancel-btn">Cancel hook</button></div>
<script>var translations={hookScriptSaved:'Hook saved',hookScriptSaveFailed:'Hook failed',
unsavedChanges:'Unsaved changes',requestTimedOut:'Request timed out; reload to check saved settings'};</script>
<script src="/jquery.js"></script><script src="/8311.js"></script>`;

// A native LuCI render can be supplied to exercise the exact template DOM.
const recoveryHtml = `<form id="recovery-form" action="/admin/system/flash/recovery" method="post"
data-file-error="Choose a non-empty 8311 settings file no larger than 128 KiB."
data-backup-success="Configuration downloaded" data-hook-confirm="Restore the included script?"
data-timeout="Request timed out; reload to check saved settings"
data-failure="Recovery failed" data-reset-confirm="Reset settings?" data-pon-confirm="Also reset PON?">
<input type="hidden" name="token" value="fixture-token">
<button type="button" class="recovery-button" onclick="return backupSettings(this)">Backup</button>
<select id="recovery-preserve" onchange="cancelRecoveryPreview()"><option value="0">Include PON</option><option value="1">Keep PON</option></select>
<select id="reset-preserve"><option value="1">Keep PON</option><option value="0">Reset PON</option></select>
<button type="button" class="recovery-button" onclick="return resetSettings(this)">Reset</button>
<input id="recovery-file" type="file" onchange="cancelRecoveryPreview()">
<button type="button" class="recovery-button" onclick="return previewRecovery(this)">Check</button>
<div id="recovery-preview" hidden><ul id="recovery-fields"></ul><span id="recovery-skipped"></span>
<button id="recovery-apply" type="button" class="recovery-button" onclick="return applyRecovery(this)">Restore</button></div>
<p id="recovery-message" role="status" hidden></p><div id="recovery-reboot" hidden>Reboot to apply</div></form>`;
const firmwareHtml = process.env.FIRMWARE_FIXTURE_DIR
  ? fs.readFileSync(path.join(process.env.FIRMWARE_FIXTURE_DIR, 'upload.html'), 'utf8')
  : `<!doctype html><meta charset="utf-8"><div id="8311-recovery-page">${recoveryHtml}<form id="firmware-form" action="/admin/system/flash" method="post" enctype="multipart/form-data">
<input type="hidden" name="token" value="fixture-token"><input id="firmware-action" name="action" value="validate" type="hidden">
<input id="firmware-file" name="firmware_file" type="file" required>
<button class="firmware-button" type="button" title="Upload firmware" onclick="return uploadFirmware(this)">Upload</button></form>
<script src="/resources/jquery-3.7.1.min.js"></script><script src="/resources/jquery.validate.min.js"></script>
<script src="/resources/view/8311.js"></script></div>`;
const nativeConfigHtml = process.env.CONFIG_FIXTURE_FILE ? fs.readFileSync(process.env.CONFIG_FIXTURE_FILE, 'utf8') : null;
const assetRoutes = {
  '/jquery.js': 'jquery-3.7.1.min.js', '/8311.js': 'view/8311.js',
  '/resources/jquery-3.7.1.min.js': 'jquery-3.7.1.min.js',
  '/resources/jquery.validate.min.js': 'jquery.validate.min.js',
  '/resources/view/8311.js': 'view/8311.js', '/resources/view/8311.css': 'view/8311.css'
};
const backupContents = '# 8311 settings backup v1\n8311_hostname=fixture\n8311_loid=secret-fixture\n8311_backup_hook_b64=IyBmaXh0dXJlIGhvb2sK\n';

const server = http.createServer(async (req, res) => {
  if (assetRoutes[req.url]) {
    res.setHeader('Content-Type', req.url.endsWith('.css') ? 'text/css' : 'application/javascript');
    res.end(fs.readFileSync(path.join(assets, assetRoutes[req.url])));
  } else if (req.method === 'POST') {
    let data = '';
    for await (const chunk of req) data += chunk;
    requests.push({ url: req.url, values: new URLSearchParams(data), raw: data });
    if (holdRequests) return;
    if (status === 200 && new URLSearchParams(data).get('action') === 'backup') {
      res.writeHead(200, { 'Content-Type': backupContentType, 'Cache-Control': 'no-store' });
      if (holdBackupBody) { res.write(backupContents.slice(0, 20)); return; }
      res.end(backupContents);
      return;
    }
    res.writeHead(status, { 'Content-Type': 'application/json' });
    const recovery = req.url === '/admin/system/flash/recovery';
    if (status === 200 && req.url === '/save') configuredInternetVlan = new URLSearchParams(data).get('internet_vlan');
    const preview = new URLSearchParams(data).get('action') === 'preview';
    res.end(JSON.stringify(status === 200 ? (recovery ?
      { success: true, message: preview ? 'Checked fixture file' : 'Restored fixture settings',
        count: 1, names: ['Hostname'], skipped: 1, reboot_required: !preview,
        hook_script: (new URLSearchParams(data).get('content') || '').includes('backup_hook_b64=Iy') } :
      { success: true, message: 'Saved fixture settings' }) :
      { success: false, message: 'Invalid fixture settings', errors: { internet_vlan: 'Rejected VLAN' } }));
  } else if (req.url === '/get_hook_script') {
    res.end('# fixture hook');
  } else if (req.url.startsWith('/vlan_status')) {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ state:'applied', message:'VLAN fixture applied', last_applied_at:100 }));
  } else {
    res.setHeader('Content-Type', 'text/html');
    res.end(req.url === '/firmware' ? firmwareHtml : req.url === '/native-config' && nativeConfigHtml ? nativeConfigHtml :
      html.replace('value="100"', 'value="' + configuredInternetVlan + '"'));
  }
});

(async () => {
  let browser;
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const engine = { chromium, firefox, webkit }[process.env.BROWSER_ENGINE || 'chromium'];
    assert(engine, 'Unsupported BROWSER_ENGINE');
    browser = await engine.launch({ headless: true, ...(process.env.BROWSER_CHANNEL ? { channel: process.env.BROWSER_CHANNEL } : {}) });
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForLoadState('networkidle');
    assert.equal(await page.locator('#save-btn').count(), 1);

    // Replay form values restored by Firefox before the pageshow event.
    await page.evaluate(() => switchTab('vlans'));
    await page.locator('[name="internet_vlan"]').fill('201');
    await page.locator('[name="fix_vlans"]').selectOption('0');
    await page.evaluate(() => {
      document.getElementById('save-btn').disabled = true;
      window.dispatchEvent(new PageTransitionEvent('pageshow'));
    });
    await page.waitForFunction(() => document.querySelector('[name="internet_vlan"]').value === '100');
    assert.equal(await page.locator('[name="internet_vlan"]').inputValue(), '100');
    assert.equal(await page.locator('[name="fix_vlans"]').inputValue(), '1');
    assert(await page.locator('#save-btn').isEnabled());
    assert.equal(requests.length, 0);
    await page.locator('[name="internet_vlan"]').fill('202');
    await page.reload();
    await page.waitForLoadState('networkidle');
    assert.equal(await page.locator('[name="internet_vlan"]').inputValue(), '100');
    assert.equal(requests.length, 0);
    console.log('ok - restored and reloaded unsaved fields show server values without a write');

    await page.locator('#save-btn').click();
    await page.getByRole('status').filter({ hasText: 'Saved fixture settings' }).waitFor();
    await page.waitForFunction(() => !document.getElementById('save-btn').disabled);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].values.get('token'), 'fixture-token');
    assert.equal(requests[0].values.get('internet_vlan'), '100');
    await page.waitForLoadState('networkidle');
    console.log('ok - configuration success sends token and restores the save button');

    let navigationCount = 0;
    const onNavigate = frame => { if (frame === page.mainFrame()) navigationCount++; };
    page.on('framenavigated', onNavigate);
    await page.evaluate(() => switchTab('vlans'));
    await page.locator('[name="internet_vlan"]').fill('123');
    await page.locator('#save-btn').click();
    await page.waitForFunction(() => document.querySelector('[name="internet_vlan"]').defaultValue === '123');
    await page.waitForLoadState('networkidle');
    assert.equal(navigationCount, 1);
    assert.equal(await page.getByRole('status').textContent(), 'Saved fixture settings');
    page.off('framenavigated', onNavigate);
    console.log('ok - a successful save reloads confirmed server values and keeps its result message');

    status = 400;
    await page.locator('#save-btn').click();
    await page.getByText('Rejected VLAN', { exact: true }).waitFor();
    await page.waitForFunction(() => !document.getElementById('save-btn').disabled);
    assert.equal(await page.locator('li.cbi-tab').getAttribute('data-tab'), 'vlans');
    assert.equal(await page.getByRole('status').textContent(), 'Invalid fixture settings');
    console.log('ok - server validation failure displays field feedback and selects its tab');

    const vlan = page.locator('[name="internet_vlan"]');
    await vlan.fill('4096');
    await page.locator('#save-btn').click();
    assert.equal(requests.length, 3);
    assert.match(await vlan.getAttribute('class'), /error/);
    console.log('ok - browser validation rejects out-of-range VLAN without a request');

    // Accelerate the real 30-second transport timers, leaving other timers alone.
    const accelerateTimeouts = () => {
      const original = window.setTimeout;
      window.setTimeout = (callback, delay, ...args) => original(callback, delay === 30000 ? 100 : delay, ...args);
    };
    await page.evaluate(accelerateTimeouts);
    await vlan.fill('123');
    holdRequests = true;
    await page.locator('#save-btn').click();
    await page.getByText('Request timed out; reload to check saved settings', { exact: true }).waitFor();
    assert(await page.locator('#save-btn').isEnabled());
    holdRequests = false;
    console.log('ok - a stalled configuration request times out and permits checking the saved state');

    status = 500;
    await page.locator('#edit-hook-script-btn').click();
    await page.locator('#hook-script-modal').waitFor();
    await page.locator('#hook-script-textarea').fill('# updated fixture hook');
    await page.locator('#hook-script-save-btn').click();
    await page.getByText('Hook failed', { exact: true }).waitFor();
    assert.equal(requests.at(-1).values.get('token'), 'fixture-token');
    assert.equal(requests.at(-1).values.get('content'), '# updated fixture hook');
    const beforeHookTimeout = requests.length;
    holdRequests = true;
    await page.evaluate(() => {
      $('#hook-script-save-btn').trigger('click');
      $('#hook-script-save-btn').trigger('click');
    });
    await page.locator('#hook-script-message').filter({ hasText: 'Request timed out; reload to check saved settings' }).waitFor();
    await page.waitForFunction(() => !document.getElementById('hook-script-save-btn').disabled);
    assert.equal(requests.length, beforeHookTimeout + 1);
    assert(await page.locator('#hook-script-save-btn').isEnabled());
    holdRequests = false;
    console.log('ok - a stalled hook save is submitted once and releases its button after timeout');
    status = 200;
    await page.locator('#hook-script-save-btn').click();
    await page.getByText('Hook saved', { exact: true }).waitFor();
    assert.deepEqual(errors, []);
    console.log('ok - hook saves send the token and show both failure and success');

    status = 200;
    const firmwareUrl = `http://127.0.0.1:${server.address().port}/firmware`;
    await page.goto(firmwareUrl);
    await page.waitForLoadState('networkidle');
    const beforeUpload = requests.length;
    await page.evaluate(() => {
      const file = new File(['fixture'], 'large.tar');
      Object.defineProperty(file, 'size', { value: 128 * 1024 * 1024 + 1 });
      const transfer = new DataTransfer();
      transfer.items.add(file);
      document.getElementById('firmware-file').files = transfer.files;
    });
    await page.locator('button[title="Upload firmware"]').click();
    assert.equal(requests.length, beforeUpload);
    assert.match(await page.locator('#firmware-file').evaluate(input => input.validationMessage), /128 MiB/);
    await page.locator('#firmware-file').setInputFiles({ name: 'fixture.tar', mimeType: 'application/x-tar', buffer: Buffer.from('fixture archive') });
    await Promise.all([
      page.waitForResponse(response => response.request().method() === 'POST'),
      page.waitForURL('**/admin/system/flash', { waitUntil: 'networkidle' }),
      page.locator('button[title="Upload firmware"]').click()
    ]);
    await page.waitForLoadState('networkidle');
    assert.equal(requests.length, beforeUpload + 1);
    assert.match(requests.at(-1).raw, /name="token"\r\n\r\nfixture-token/);
    assert.match(requests.at(-1).raw, /fixture archive/);
    console.log('ok - firmware size rejection can recover and upload submits exactly once with its token');

    await page.goto(firmwareUrl);
    await page.waitForLoadState('networkidle');
    assert.equal(await page.evaluate(() => {
      let count = 0;
      HTMLFormElement.prototype.submit = () => { count++; };
      const button = document.querySelector('.firmware-button');
      submitFirmwareForm(button);
      submitFirmwareForm(button);
      return count;
    }), 1);
    console.log('ok - repeated firmware submission is coalesced');

    await page.goto(firmwareUrl);
    await page.waitForLoadState('networkidle');
    await page.locator('#firmware-file').setInputFiles({ name: 'unused.tar', mimeType: 'application/x-tar', buffer: Buffer.from('must not upload') });
    await Promise.all([
      page.waitForResponse(response => response.request().method() === 'POST'),
      page.waitForURL('**/admin/system/flash', { waitUntil: 'networkidle' }),
      page.evaluate(() => confirmSwitchReboot(true, document.querySelector('.firmware-button')))
    ]);
    assert.match(requests.at(-1).raw, /name="action"\r\n\r\nswitch_reboot/);
    assert(!requests.at(-1).raw.includes('name="firmware_file"'));
    assert.deepEqual(errors, []);
    console.log('ok - switching banks submits its action without an unrelated selected firmware file');

    await page.goto(firmwareUrl);
    await page.waitForLoadState('networkidle');
    const recoveryCheck = page.locator('button[onclick*="previewRecovery"]');
    const recoveryReset = page.locator('button[onclick*="resetSettings"]');
    assert.equal(await page.locator('#recovery-preserve').inputValue(), '0');
    assert.equal(await page.locator('#reset-preserve').inputValue(), '1');
    await page.locator('#recovery-preserve').selectOption('1');
    const beforeRecovery = requests.length;
    await recoveryCheck.click();
    await page.getByText('Choose a non-empty 8311 settings file no larger than 128 KiB.', { exact: true }).waitFor();
    assert.equal(requests.length, beforeRecovery);
    await page.locator('#recovery-file').setInputFiles({ name: 'settings.env', mimeType: 'text/plain',
      buffer: Buffer.from('8311_hostname=new\n8311_loid=secret-fixture\n') });
    await recoveryCheck.click();
    await page.locator('#recovery-preview').waitFor();
    assert.equal(requests.at(-1).values.get('action'), 'preview');
    assert.equal(requests.at(-1).values.get('preserve_pon'), '1');
    assert.equal(requests.at(-1).values.get('token'), 'fixture-token');
    assert(!await page.locator('body').innerText().then(text => text.includes('secret-fixture')));
    assert.equal(await page.locator('#recovery-fields').innerText(), 'Hostname');
    await page.locator('#recovery-preserve').selectOption('0');
    assert.equal(await page.locator('#recovery-preview').isVisible(), false);
    await page.locator('#recovery-preserve').selectOption('1');
    await recoveryCheck.click();
    await page.locator('#recovery-preview').waitFor();
    console.log('ok - recovery preview keeps credentials private, sends its token and invalidates when scope changes');

    const beforeApply = requests.length;
    await page.locator('#recovery-apply').click();
    await page.getByText('Restored fixture settings', { exact: true }).waitFor();
    assert.equal(requests.length, beforeApply + 1);
    assert.equal(requests.at(-1).values.get('action'), 'restore');
    assert.equal(requests.at(-1).values.get('confirm'), '1');
    assert.equal(await page.locator('#recovery-preview').isVisible(), false);
    assert.equal(await page.locator('#recovery-reboot').isVisible(), true);
    console.log('ok - restoring requires a validated preview and leaves reboot as a separate action');

    status = 500;
    await recoveryCheck.click();
    await page.getByText('Invalid fixture settings', { exact: true }).waitFor();
    await page.waitForFunction(() => !document.querySelector('button[onclick*="previewRecovery"]').disabled);
    assert.equal(await page.locator('#recovery-preview').isVisible(), false);
    console.log('ok - failed recovery requests display errors and release all controls');

    await page.evaluate(accelerateTimeouts);
    holdRequests = true;
    await recoveryCheck.click();
    await page.locator('#recovery-message').filter({ hasText: await page.locator('#recovery-form').getAttribute('data-timeout') }).waitFor();
    assert(await recoveryCheck.isEnabled());
    assert(await page.locator('#recovery-file').isEnabled());
    holdRequests = false;
    console.log('ok - a stalled recovery preview times out and releases every control');

    status = 200;
    let acceptDialog = false, dialogs = 0;
    page.on('dialog', async dialog => { dialogs++; await (acceptDialog ? dialog.accept() : dialog.dismiss()); });
    const beforeReset = requests.length;
    await recoveryReset.click();
    assert.equal(requests.length, beforeReset);
    acceptDialog = true;
    await page.locator('#reset-preserve').selectOption('0');
    await recoveryReset.click();
    await page.getByText('Restored fixture settings', { exact: true }).waitFor();
    assert.equal(requests.length, beforeReset + 1);
    assert.equal(dialogs, 3);
    assert.equal(requests.at(-1).values.get('action'), 'reset');
    assert.equal(requests.at(-1).values.get('preserve_pon'), '0');
    assert.deepEqual(errors, []);
    console.log('ok - reset cancellation makes no request and including PON requires the additional confirmation');

    await page.goto(firmwareUrl);
    await page.waitForLoadState('networkidle');
    const backupButton = page.locator('button[onclick*="backupSettings"]');
    backupContentType = 'application/json';
    const rejectedDownloads = [];
    const recordRejectedDownload = download => rejectedDownloads.push(download);
    page.on('download', recordRejectedDownload);
    await backupButton.click();
    const failureMessage = await page.locator('#recovery-form').getAttribute('data-failure');
    await page.getByText(failureMessage, { exact: true }).waitFor();
    await page.waitForFunction(() => !document.querySelector('button[onclick*="backupSettings"]').disabled);
    assert.equal(rejectedDownloads.length, 0);
    page.off('download', recordRejectedDownload);
    console.log('ok - a backup mislabeled as JSON is rejected and the download button is released');

    await page.evaluate(accelerateTimeouts);
    const timeoutMessage = await page.locator('#recovery-form').getAttribute('data-timeout');
    holdRequests = true;
    await backupButton.click();
    await page.getByText(timeoutMessage, { exact: true }).waitFor();
    assert(await backupButton.isEnabled());
    assert(await page.locator('.firmware-button').first().isEnabled());
    holdRequests = false;
    backupContentType = 'text/plain; charset=utf-8';
    holdBackupBody = true;
    await backupButton.click();
    await page.waitForFunction(() => !document.querySelector('button[onclick*="backupSettings"]').disabled);
    assert.equal(await page.locator('#recovery-message').textContent(), timeoutMessage);
    holdBackupBody = false;
    console.log('ok - backup connection and incomplete body timeouts release the form without a partial download');

    backupContentType = 'text/plain; charset=utf-8';
    const [download] = await Promise.all([page.waitForEvent('download'), backupButton.click()]);
    assert.match(download.suggestedFilename(), /^8311-settings-.*\.env$/);
    const downloaded = fs.readFileSync(await download.path());
    assert.equal(downloaded.toString(), backupContents);
    assert.equal(requests.at(-1).values.get('action'), 'backup');
    assert.equal(requests.at(-1).values.get('token'), 'fixture-token');
    assert(!await page.locator('body').innerText().then(text => text.includes('secret-fixture')));
    await page.waitForFunction(() => !document.querySelector('button[onclick*="backupSettings"]').disabled);
    console.log('ok - backup downloads a private settings file without rendering credentials or navigating away');

    await page.locator('#recovery-file').setInputFiles({ name: download.suggestedFilename(), mimeType: 'text/plain', buffer: downloaded });
    await recoveryCheck.click();
    await page.locator('#recovery-preview').waitFor();
    const beforeRoundTrip = requests.length;
    const beforeDialogs = dialogs;
    await page.locator('#recovery-apply').click();
    await page.getByText('Restored fixture settings', { exact: true }).waitFor();
    assert.equal(requests.length, beforeRoundTrip + 1);
    assert.equal(dialogs, beforeDialogs + 2);
    assert.equal(requests.at(-1).values.get('content'), backupContents);
    assert.equal(requests.at(-1).values.get('preserve_pon'), '0');
    console.log('ok - a downloaded backup can be restored including PON and the explicitly confirmed hook');

    status = 500;
    await backupButton.click();
    await page.getByText('Invalid fixture settings', { exact: true }).waitFor();
    await page.waitForFunction(() => !document.querySelector('button[onclick*="backupSettings"]').disabled);
    assert.deepEqual(errors, []);
    console.log('ok - backup failure shows feedback and re-enables download and firmware controls');

    if (nativeConfigHtml) {
      const beforeNative = requests.length;
      await page.goto(`http://127.0.0.1:${server.address().port}/native-config`);
      await page.locator('#vlan-apply-status').filter({ hasText:'VLAN fixture applied' }).waitFor();
      assert.match(await page.locator('#vlan-apply-status').textContent(), /Last successful application:/);
      const mask = page.locator('[name="netmask"]');
      const category = await mask.getAttribute('data-cat-id');
      await page.evaluate(category => switchTab(category), category);
      for (let prefix=0; prefix<=32; prefix++) {
        const value = Array.from({ length:4 }, (_, index) => 256 - 2 ** (8 - Math.max(0, Math.min(8, prefix - index*8)))).join('.');
        await mask.fill(value);
        assert(await mask.evaluate(input => input.checkValidity()), value);
      }
      for (const value of ['255.0.255.0','255.255.253.0','0.0.0.1']) {
        await mask.fill(value);
        assert(!await mask.evaluate(input => input.checkValidity()), value);
      }
      await page.reload();
      await page.waitForLoadState('networkidle');
      assert.equal(await mask.inputValue(), '255.255.255.0');
      assert.equal(requests.length, beforeNative);
      console.log('ok - native configuration DOM renders VLAN status, validates all mask prefixes and discards unsaved edits');
    }
  } finally {
    if (browser) await browser.close();
    server.closeAllConnections();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
