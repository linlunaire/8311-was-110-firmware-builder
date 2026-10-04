// Native Bootstrap menu loader and actual theme assets, with local fixture endpoints.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { chromium, firefox, webkit } = require('playwright');
const renderNativeStatus = require('./theme_native_fixtures.cjs');

const root = path.resolve(__dirname, '..');
const resources = path.join(root, 'files/basic/www/luci-static/resources');
const native = path.join(root, '.test-tmp/theme-browser-native-' + (process.env.BROWSER_ENGINE || 'chromium'));
// Read the already bundled packages; do not download or install dependencies on a device.
execFileSync(process.platform === 'win32' ? 'python' : 'python3', ['-c', `
import io,re,tarfile
from pathlib import Path
root=Path(${JSON.stringify(root)})
destination=Path(${JSON.stringify(native)}).resolve()
for package in ('luci-base_git-22.045.73925-36e5c1c-1_mips_24kc.ipk','luci-theme-bootstrap_git-22.045.73925-36e5c1c-1_all.ipk','luci-mod-status_git-22.045.73925-36e5c1c-1_mips_24kc.ipk'):
 with tarfile.open(root/'packages/basic'/package) as outer:
  with tarfile.open(fileobj=io.BytesIO(outer.extractfile(next(n for n in outer.getnames() if 'data.tar' in n)).read())) as archive:
   for member in archive.getmembers():
    if member.isfile() and '/www/luci-static/' in member.name:
     target=(destination/member.name.split('/www/luci-static/',1)[1]).resolve()
     assert target.is_relative_to(destination)
     target.parent.mkdir(parents=True,exist_ok=True)
     target.write_bytes(archive.extractfile(member).read())
    if member.isfile() and member.name.endswith('/view/admin_status/index.htm'):
     source=archive.extractfile(member).read().decode()
     helper=re.search(r'<script type="text/javascript">([\\s\\S]*?)</script>',source).group(1)
     (destination/'resources/theme-status-helper.js').write_text(helper,encoding='utf-8')
`]);
const routes = {
  config: '/cgi-bin/luci/admin/8311/config', pon: '/cgi-bin/luci/admin/8311/pon_status',
  firmware: '/cgi-bin/luci/admin/system/flash', login: '/login',
  overview: '/cgi-bin/luci/admin/status/overview', routes: '/cgi-bin/luci/admin/status/routes'
};
const menu = { children: { admin: { title: 'Administration', order: 1, children: {
  status: { title: 'Status', order: 1, children: { overview: { title: 'Overview', order: 1 }, routes: { title: 'Routes', order: 2 } } },
  system: { title: 'System', order: 2, children: { flash: { title: 'Backup / Flash Firmware', order: 1 } } },
  '8311': { title: '8311', order: 3, children: {
    config: { title: 'Configuration', order: 1 }, pon_status: { title: 'PON Status', order: 2 },
    pon_explorer: { title: 'PON ME Explorer', order: 3 }, vlans: { title: 'VLAN Tables', order: 4 }
  } }
} } } };
function satisfy(node) {
  node.satisfied = true;
  node.children ||= {};
  Object.values(node.children).forEach(satisfy);
}
satisfy(menu);

function footer() {
  return fs.readFileSync(path.join(root, 'files/basic/usr/lib/lua/luci/view/themes/bootstrap/footer.htm'), 'utf8')
    .match(/<footer[\s\S]*?<\/footer>/)[0]
    .replace(/<%:([^%]+)%>/g, '$1')
    .replace(/<%=\s*ver8311\.variant\s*%>/g, 'basic')
    .replace(/<%=\s*ver8311\.version\s*%>/g, 'v2.8.3-opt1')
    .replace(/<%=\s*ver8311\.revision\s*%>/g, '0000000')
    .replace(/<%=resource%>/g, '/luci-static/resources');
}

function appearance() {
  return fs.readFileSync(path.join(root, 'files/basic/usr/lib/lua/luci/view/themes/bootstrap/header.htm'), 'utf8')
    .match(/<div id="8311-theme-toggle"[\s\S]*?<\/div>/)[0].replace(/<%:([^%]+)%>/g, '$1');
}

function backup() {
  return '<link rel="stylesheet" href="/luci-static/resources/view/8311.css">' +
    fs.readFileSync(path.join(root, 'files/basic/usr/lib/lua/luci/view/8311/firmware.htm'), 'utf8')
      .split('<div id="8311-recovery-page">')[1].split('<div class="cbi-section">\n\t<h3><%:Flash new firmware image%>')[0]
      .replace(/<%:([^%]+)%>/g, '$1').replace(/<%=esc\(translate\('([^']+)'\)\)%>/g, '$1')
      .replace(/<%=url\([^%]+%>/g, routes.firmware+'/recovery').replace(/<%=token%>/g, 'fixture-token')
      .replace(/^/, '<div id="8311-recovery-page">') + '</div>';
}

function fixture(name) {
  if (process.env.THEME_FIXTURE_DIR && !['overview','routes'].includes(name))
    return fs.readFileSync(path.join(process.env.THEME_FIXTURE_DIR, name + '.html'), 'utf8');
  const anonymous = name === 'login';
  const dispatchpath = (anonymous ? routes.config : routes[name]).replace('/cgi-bin/luci/', '').split('/');
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="/luci-static/bootstrap/cascade.css"><link rel="stylesheet" href="/luci-static/resources/8311-theme.css">
<script src="/luci-static/resources/8311-theme.js"></script><script src="/luci-static/resources/cbi.js"></script></head>
<body class="luci-8311 ${anonymous ? 'luci-login' : 'luci-authenticated'}" data-page="${dispatchpath.join('-')}"><header><div class="fill"><div class="container">
${anonymous ? '' : '<button id="8311-menu-toggle" type="button" aria-expanded="false" aria-controls="8311-navigation">Menu</button>'}
<a class="brand" href="/cgi-bin/luci/admin">WAS-110<span>linlunaire</span></a><div class="theme-controls"><div id="indicators"></div>
${appearance()}</div>
${anonymous ? '' : '<nav id="8311-navigation"><a class="brand sidebar-brand" href="/cgi-bin/luci/admin">WAS-110<span>linlunaire</span></a><ul id="topmenu" class="nav" style="display:none"></ul></nav><button id="8311-menu-backdrop" type="button" hidden>Close</button>'}
</div></div></header><div id="maincontent" class="container"><div id="tabmenu" style="display:none"></div>
<script src="/luci-static/resources/luci.js"></script><script>L=new LuCI(${JSON.stringify({
  token: 'fixture-token', media: '/luci-static/bootstrap', resource: '/luci-static/resources', scriptname: '/cgi-bin/luci',
  pathinfo: '/'+dispatchpath.join('/'), documentroot: '/www', requestpath: dispatchpath, dispatchpath,
  pollinterval: 5, ubuspath: '/ubus/', sessionid: anonymous ? null : '00000000000000000000000000000000',
  apply_rollback: 90, apply_holdoff: 4, apply_timeout: 5, apply_display: 1.5
})});</script>
${name==='routes' ? '' : '<h2>'+(anonymous ? 'Authorization Required' : name)+'</h2>'}
${['overview','routes'].includes(name) ? '<div id="theme-native-view"></div><script src="/luci-static/resources/theme-status-helper.js"></script><script>('+renderNativeStatus.toString()+')('+JSON.stringify(name)+')</script>' : name==='firmware' ? backup() : `<form method="post"><div class="cbi-map"><div class="cbi-section">
<div class="cbi-value"><label class="cbi-value-title" for="fixture-value">${anonymous ? 'Username' : 'PON Serial Number'}</label><div class="cbi-value-field"><input type="text" id="fixture-value" name="gpon_sn" value="TEST12345678"></div></div>
<div class="cbi-value-description">Device settings and connection diagnostics.</div></div></div></form>`}
${footer()}</div>${anonymous ? '' : "<script>L.require('menu-bootstrap')</script>"}</body></html>`;
}

const requests = [];
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  requests.push({ method: req.method, path: url.pathname });
  if (url.pathname.startsWith('/luci-static/')) {
    const relative = url.pathname.slice('/luci-static/'.length);
    const override = relative.startsWith('resources/') ? path.resolve(resources, relative.slice(10)) : null;
    const fallback = path.resolve(native, relative);
    const file = override && override.startsWith(resources + path.sep) && fs.existsSync(override) ? override : fallback;
    if (!file.startsWith(resources + path.sep) && !file.startsWith(native + path.sep) || !fs.existsSync(file)) { if(process.env.THEME_DEBUG) console.error('Missing fixture resource:',url.pathname); res.writeHead(404).end(); return; }
    res.setHeader('Content-Type', file.endsWith('.css') ? 'text/css' : file.endsWith('.html') ? 'text/html; charset=utf-8' : file.endsWith('.png') ? 'image/png' : 'application/javascript');
    res.end(fs.readFileSync(file));
  } else if (url.pathname.endsWith('/admin/menu')) {
    res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(menu));
  } else if (url.pathname === '/ubus/' || url.pathname.endsWith('/admin/ubus')) {
    if (req.method !== 'POST') { res.writeHead(400, {'Content-Type':'application/json'}).end('{}'); return; }
    let body = ''; for await (const chunk of req) body += chunk;
    const respond = request => ({ jsonrpc: '2.0', id: request.id, result: request.method === 'list' ? {} : [0, { changes: {}, result: {}, features: {} }] });
    const data = JSON.parse(body);
    res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(Array.isArray(data) ? data.map(respond) : respond(data)));
  } else if (url.pathname.includes('/admin/translations/')) {
    res.setHeader('Content-Type', 'application/javascript'); res.end('');
  } else if (url.pathname.endsWith('/get_hook_script')) { res.end('# fixture hook\n');
  } else if (url.pathname.endsWith('/vlan_status')) {
    res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({state:'applied',message:'Fixture rules applied'}));
  } else if (url.pathname.endsWith('/diagnostics')) {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ status: 'O5', power: '-19.2 dBm / 2.1 dBm / 12 mA', temperature: '42 / 43 / 40 °C',
      eth_speed: '10000 Mbps', vlan_message: 'Fixture rules applied', links: [{device:'eth0_0',available:true,
        counters:{rx_packets:'18446744073709551615',tx_packets:'18023',rx_dropped:'0',tx_dropped:'0',rx_errors:'0',tx_errors:'0'}, filters:[]}] }));
  } else if (url.pathname.includes('/pontop/')) { res.end('Fixture PON state: O5\nNo live device reads.');
  } else {
    const name = Object.keys(routes).find(name => routes[name] === url.pathname);
    if (!name) { if(process.env.THEME_DEBUG) console.error('Missing fixture endpoint:',url.pathname); res.writeHead(404).end(); return; }
    res.setHeader('Content-Type', 'text/html'); res.end(fixture(name));
  }
});

function contrast(foreground, background) {
  function luminance(color) {
    const channels = color.match(/[\d.]+/g).slice(0,3).map(Number).map(value => {
      value /= 255; return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
    });
    return channels[0]*.2126 + channels[1]*.7152 + channels[2]*.0722;
  }
  const a=luminance(foreground),b=luminance(background);
  return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
}

(async () => {
  let browser;
  try {
    await new Promise(resolve => server.listen(process.env.THEME_PREVIEW ? 56410 : 0, '127.0.0.1', resolve));
    const base='http://127.0.0.1:'+server.address().port;
    if (process.env.THEME_PREVIEW) { console.log('Preview: '+base+routes.config); return; }
    const engine = { chromium, firefox, webkit }[process.env.BROWSER_ENGINE || 'chromium'];
    assert(engine, 'Unsupported BROWSER_ENGINE');
    browser=await engine.launch({ headless:true, ...(process.env.BROWSER_CHANNEL ? {channel:process.env.BROWSER_CHANNEL} : {}) });
    const page=await browser.newPage({viewport:{width:1280,height:900},colorScheme:'light'});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    if (process.env.THEME_DEBUG) page.on('console',message=>{if(message.type()==='error') console.error(message.text());});
    await page.goto(base+routes.config);await page.waitForLoadState('networkidle');
    await page.locator('#topmenu a[aria-current="page"]').waitFor();
    assert.equal(await page.locator('#topmenu a[aria-current="page"]').getAttribute('href'),routes.config);
    // Menu rendering can finish before the luci-loaded UCI changes request.
    await page.waitForFunction(()=>window.L && L.ui && L.ui.changes.changes != null);
    await page.waitForLoadState('networkidle');
    const before=requests.length;
    const appearance=page.locator('[id="8311-theme-toggle"]');
    assert.equal(await appearance.getAttribute('role'),'group');
    assert.equal(await appearance.locator('button').count(),3);
    await appearance.locator('[data-theme-mode="light"]').click();assert.equal(await page.locator('html').getAttribute('data-color'),'light');
    await appearance.locator('[data-theme-mode="dark"]').click();assert.equal(await page.locator('html').getAttribute('data-color'),'dark');
    assert.equal(await appearance.locator('[aria-pressed="true"]').getAttribute('data-theme-mode'),'dark');
    assert.equal(requests.length,before,'appearance change made a network request: '+JSON.stringify(requests.slice(before)));
    await page.reload();await page.waitForLoadState('networkidle');
    assert.equal(await page.locator('html').getAttribute('data-theme'),'dark');
    await appearance.locator('[data-theme-mode="system"]').focus();await page.keyboard.press('Enter');
    assert.equal(await page.locator('html').getAttribute('data-theme'),'system');
    assert.equal(await appearance.locator('[aria-pressed="true"]').getAttribute('data-theme-mode'),'system');
    await page.emulateMedia({colorScheme:'dark'});
    await page.waitForFunction(()=>document.documentElement.dataset.color==='dark');
    await page.emulateMedia({colorScheme:'light'});
    await page.waitForFunction(()=>document.documentElement.dataset.color==='light');
    console.log('ok - appearance persists, follows system changes and makes zero requests');

    const system=page.locator('#topmenu > li > a').filter({hasText:'System'});
    await system.focus();await page.keyboard.press('Space');
    assert.equal(await system.getAttribute('aria-expanded'),'true');
    await page.locator('#topmenu a[href="'+routes.firmware+'"]').click();await page.waitForLoadState('networkidle');
    assert.equal(new URL(page.url()).pathname,routes.firmware);
    console.log('ok - native menu routes and keyboard group toggles remain usable');

    for(const color of ['light','dark']) {
      await page.evaluate(color=>localStorage.setItem('8311-theme',color),color);
      await page.goto(base+routes.config);await page.waitForLoadState('networkidle');
      const palette=await page.evaluate(()=>{
        const widgets=document.createElement('div');widgets.id='theme-widget-fixture';
        widgets.innerHTML='<div class="table"><div class="tr cbi-section-table-titles"><div class="th">Settings</div></div></div>'+
          '<div class="cbi-dropdown" open><ul class="dropdown"><li display>Option</li><li display selected>Selected</li></ul></div>'+
          '<div class="cbi-progressbar" title="42%"><div style="width:42%"></div></div>';
        document.getElementById('maincontent').appendChild(widgets);
        L.ui.showModal('Fixture dialog',[E('p','Readable dialog content')]);
        function pair(element,pseudo,background) {
          let surface=background || element;
          while(surface.parentElement && getComputedStyle(surface).backgroundColor==='rgba(0, 0, 0, 0)') surface=surface.parentElement;
          return {text:getComputedStyle(element,pseudo).color,background:getComputedStyle(surface).backgroundColor};
        }
        return [pair(widgets.querySelector('.th')),pair(widgets.querySelector('li')),
          pair(widgets.querySelector('li[selected]')),pair(document.querySelector('.modal p')),
          pair(widgets.querySelector('.cbi-progressbar'),'::after')];
      });
      for(const [index,pair] of palette.entries()) assert(contrast(pair.text,pair.background)>=4.5,`${color} native widget ${index} contrast: ${JSON.stringify(pair)}`);
      await page.evaluate(()=>{L.ui.hideModal();document.getElementById('theme-widget-fixture').remove();});
    }
    console.log('ok - native dropdowns, table titles, dialogs and progress labels stay readable');

    for(const color of ['light','dark']) {
      await page.evaluate(color=>localStorage.setItem('8311-theme',color),color);
      await page.goto(base+routes.overview);await page.waitForLoadState('networkidle');
      await page.locator('#theme-native-view[data-ready="true"]').waitFor();
      const overviewColors=await page.evaluate(()=>{
        function pair(element,pseudo) {
          let surface=element;
          while(surface.parentElement && getComputedStyle(surface).backgroundColor==='rgba(0, 0, 0, 0)') surface=surface.parentElement;
          return {text:getComputedStyle(element,pseudo).color,background:getComputedStyle(surface).backgroundColor};
        }
        const bar=document.querySelector('#stock-memory .cbi-progressbar');
        return {pairs:[pair(document.querySelector('.ifacebox-head strong')),pair(document.querySelector('.ifacebox-body > span')),
          pair(document.querySelector('.ifacebox-body .ifacebadge')),pair(bar,'::after')],
          gap:bar.getBoundingClientRect().height-parseFloat(getComputedStyle(bar,'::after').height)-bar.firstElementChild.getBoundingClientRect().height};
      });
      for(const pair of overviewColors.pairs) assert(contrast(pair.text,pair.background)>=4.5,`${color} stock overview contrast: ${JSON.stringify(pair)}`);
      assert(overviewColors.gap>=2,'native progress labels overlap the fill');
      await page.goto(base+routes.routes);await page.waitForLoadState('networkidle');
      await page.locator('#theme-native-view[data-ready="true"]').waitFor();
      const routeColors=await page.locator('.table-titles .th, .td > .ifacebadge').evaluateAll(elements=>elements.map(element=>{
        let surface=element;
        while(surface.parentElement && getComputedStyle(surface).backgroundColor==='rgba(0, 0, 0, 0)') surface=surface.parentElement;
        return {text:getComputedStyle(element).color,background:getComputedStyle(surface).backgroundColor};
      }));
      for(const pair of routeColors) assert(contrast(pair.text,pair.background)>=4.5,`${color} stock route contrast: ${JSON.stringify(pair)}`);
      await page.goto(base+routes.firmware);await page.waitForLoadState('networkidle');
      const controls=await page.locator('#reset-preserve').evaluate(select=>{
        const button=select.nextElementSibling,a=select.getBoundingClientRect(),b=button.getBoundingClientRect();
        return {topDifference:Math.abs(a.top-b.top),heightDifference:Math.abs(a.height-b.height),
          action:getComputedStyle(document.querySelector('.recovery-button')).backgroundColor,
          reset:getComputedStyle(button).backgroundColor,card:getComputedStyle(select.closest('.cbi-section')).backgroundColor};
      });
      assert(controls.topDifference<=1 && controls.heightDifference<=1,`${color} backup controls misalign: ${JSON.stringify(controls)}`);
      assert.notEqual(controls.action,controls.card,'backup action lost its primary color');
      assert.notEqual(controls.action,controls.reset,'reset and backup actions have identical colors');
    }
    console.log('ok - stock overview and route widgets stay readable; backup actions align and keep semantic colors');

    for (const color of ['light','dark']) {
      await page.evaluate(color=>{localStorage.setItem('8311-theme',color);},color);
      for (const name of Object.keys(routes)) {
        await page.goto(base+routes[name]);await page.waitForLoadState('networkidle');
        if(['overview','routes'].includes(name)) await page.locator('#theme-native-view[data-ready="true"]').waitFor();
        assert.match(await page.locator('footer').innerText(), /linlunaire/);
        assert(!await page.locator('footer a[href*="djGrrr"], footer a[href*="missing233"], footer img').count());
        assert.equal(await page.locator('footer a[href$="8311-notices.html"]').count(), 1);
        for (const width of [320,390,760,761,1280]) {
          await page.setViewportSize({width,height:900});
          const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1);
          assert(!overflow,`${name} overflows at ${width}px in ${color}`);
          if(name==='routes' && width<=760) {
            const table=await page.locator('.table').nth(1).evaluate(element=>({
              viewport:element.clientWidth,content:element.scrollWidth,
              wrap:getComputedStyle(element.querySelector('.th')).whiteSpace}));
            assert((table.viewport>=640 || table.content>table.viewport) && table.wrap==='nowrap','narrow routes must scroll locally without splitting column labels: '+JSON.stringify(table));
          }
        }
        const colors=await page.locator('.cbi-value-title, .diagnostic-summary strong, .table .th, .table .td').first().evaluate(label=>{
          let background=label;
          while(background.parentElement && getComputedStyle(background).backgroundColor==='rgba(0, 0, 0, 0)') background=background.parentElement;
          return {text:getComputedStyle(label).color,background:getComputedStyle(background).backgroundColor,
            muted:getComputedStyle(document.querySelector('.cbi-value-description') || label).color};
        });
        assert(contrast(colors.text,colors.background)>=4.5,`${name} ${color} label contrast`);
        assert(contrast(colors.muted,colors.background)>=4.5,`${name} ${color} description contrast`);
        if(process.env.THEME_SCREENSHOT_DIR) {
          fs.mkdirSync(process.env.THEME_SCREENSHOT_DIR,{recursive:true});
          await page.screenshot({path:path.join(process.env.THEME_SCREENSHOT_DIR,name+'-'+color+'.png'),fullPage:true});
        }
      }
    }
    console.log('ok - six pages fit 320–1280px and remain readable in both appearances');

    const notices = await page.request.get(base+'/luci-static/resources/8311-notices.html');
    assert(notices.ok());
    assert.match(notices.headers()['content-type'], /^text\/html/);
    const noticeText = await notices.text();
    for(const name of ['linlunaire','djGrrr','Missing','Apache License','Jerry']) assert(noticeText.includes(name), 'missing credit: '+name);
    console.log('ok - personal footer links retain upstream credits and the full license');

    await page.goto(base+routes.config);await page.waitForLoadState('networkidle');
    await page.setViewportSize({width:390,height:844});
    const toggle=page.locator('[id="8311-menu-toggle"]');
    await toggle.click();assert.equal(await toggle.getAttribute('aria-expanded'),'true');
    assert(await page.locator('[id="8311-navigation"]').isVisible());
    await page.keyboard.press('Escape');assert.equal(await toggle.getAttribute('aria-expanded'),'false');
    assert(await toggle.evaluate(button=>document.activeElement===button));
    assert(!await page.locator('[id="8311-navigation"]').isVisible());
    await toggle.click();await page.locator('[id="8311-menu-backdrop"]').click({position:{x:350,y:40}});
    assert.equal(await toggle.getAttribute('aria-expanded'),'false');
    await toggle.click();await page.setViewportSize({width:1280,height:900});
    await page.waitForFunction(()=>document.getElementById('8311-menu-toggle').getAttribute('aria-expanded')==='false');
    assert.equal(await toggle.getAttribute('aria-expanded'),'false');
    assert.equal(await page.locator('#maincontent').evaluate(content=>content.inert),false);
    console.log('ok - mobile navigation closes with Escape, backdrop and desktop resize');

    if(process.env.THEME_FIXTURE_DIR) {
      await page.setViewportSize({width:390,height:844});
      const category=await page.locator('[name="fix_vlans"]').getAttribute('data-cat-id');
      await page.locator('li[data-tab="'+category+'"] a').click();
      await page.locator('#edit-hook-script-btn').click();
      await page.waitForFunction(()=>document.getElementById('hook-script-textarea').value.includes('# fixture hook'));
      const box=await page.locator('#hook-script-box').boundingBox();
      assert(box.x>=0 && box.y>=0 && box.x+box.width<=390 && box.y+box.height<=844,'hook editor is outside the viewport');
      await page.locator('#hook-script-cancel-btn').click();
      assert(!await page.locator('#hook-script-modal').isVisible());
      console.log('ok - native hook editor fits mobile and still opens and cancels');
    }

    const restricted=await browser.newContext();
    await restricted.addInitScript(()=>{Object.defineProperty(window,'localStorage',{get(){throw new Error('Storage blocked')}})});
    const blocked=await restricted.newPage();blocked.on('pageerror',error=>errors.push(error.message));
    await blocked.goto(base+routes.login);await blocked.waitForLoadState('networkidle');
    await blocked.locator('[id="8311-theme-toggle"] [data-theme-mode="light"]').click();
    assert.equal(await blocked.locator('html').getAttribute('data-theme'),'light');
    await restricted.close();
    console.log('ok - appearance controls work when browser storage is blocked');
    assert.deepEqual(errors,[]);
    assert(!requests.some(request=>/\.(woff2?|ttf|mp4|webm)$/.test(request.path)),'theme loaded a font or video');
    console.log('ok - no browser errors, downloaded fonts or background video');
  } finally {
    if(browser) await browser.close();
    if(!process.env.THEME_PREVIEW) await new Promise(resolve=>server.close(resolve));
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
