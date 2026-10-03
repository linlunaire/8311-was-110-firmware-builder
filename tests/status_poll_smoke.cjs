// Run the actual LuCI status include with controlled visibility and transport.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function main() {
  const document = { hidden: true };
  const pending = [];
  const L = { url: value => value, Request: { get: () => new Promise((resolve, reject) => pending.push({ resolve, reject })) } };
  const source = fs.readFileSync(path.join(__dirname, '../files/basic/www/luci-static/resources/view/status/include/15_pon.js'), 'utf8');
  const panel = new Function('baseclass', 'document', 'L', '_', source)({ extend: value => value }, document, L, value => value);
  assert.deepEqual(await panel.load(), {});
  assert.equal(pending.length, 0);

  document.hidden = false;
  const first = panel.load();
  assert.equal(panel.load(), first);
  assert.equal(pending.length, 1);
  pending[0].resolve({ json: () => ({ temperature: '42 C' }) });
  assert.deepEqual(await first, { temperature: '42 C' });

  document.hidden = true;
  assert.deepEqual(await panel.load(), { temperature: '42 C' });
  assert.equal(pending.length, 1);
  document.hidden = false;
  const failed = panel.load();
  const rejection = assert.rejects(failed, /unavailable/);
  pending[1].reject(new Error('unavailable'));
  await rejection;
  const retry = panel.load();
  assert.equal(pending.length, 3);
  pending[2].resolve({ json: () => ({ temperature: '43 C' }) });
  assert.deepEqual(await retry, { temperature: '43 C' });
  console.log('ok - hidden status requests stop, active requests coalesce, and failures can retry');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
