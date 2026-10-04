// Execute the bundled LuCI renderers with synthetic input, without polling a device.
async function renderNativeStatus(name) {
  const base = await L.require('baseclass');
  const rpc = await L.require('rpc');
  const validation = await L.require('validation');
  async function stock(module) {
    const response = await fetch('/luci-static/resources/view/status/' + module + '.js');
    if (!response.ok) throw new Error('Missing stock status module: ' + module);
    // Use the base class to invoke render() directly; view.__init__ would load live data.
    const Widget = new Function('baseclass', 'view', 'rpc', 'validation', 'fs', 'network', await response.text())(base, base, rpc, validation, {}, {});
    return new Widget();
  }
  const target = document.getElementById('theme-native-view');
  if (name === 'overview') {
    const system = await stock('include/10_system');
    const memory = await stock('include/20_memory');
    const network = await stock('include/30_network');
    const dev = { getType: () => 'ethernet', getI18n: () => 'Ethernet eth0', getMAC: () => '02:00:00:00:00:01' };
    const iface = { getL3Device: () => dev, getProtocol: () => 'static', getIPAddrs: () => ['192.0.2.1/24'], getIP6Addrs: () => [],
      getDNSAddrs: () => ['192.0.2.53'], getDNS6Addrs: () => [], getExpiry: () => null, getUptime: () => 12000,
      getI18n: () => 'Static address', getIP6Prefix: () => null, getGatewayAddr: () => '192.0.2.254', getGateway6Addr: () => null };
    target.append(
      E('div', { class: 'cbi-section', id: 'stock-system' }, [E('h3', system.title), system.render([
        { hostname: 'WAS-110', model: 'WAS-110', system: 'MIPS', kernel: '4.4', release: { description: 'Fixture firmware' } },
        { localtime: 1791100800, uptime: 12000, load: [1200, 1000, 800] }, ['luciname = "LuCI"', 'luciversion = "fixture"']])]),
      E('div', { class: 'cbi-section', id: 'stock-memory' }, [E('h3', memory.title), memory.render({
        memory: { total: 268435456, free: 104857600, available: 115343360, buffered: 5242880, cached: 20971520 }, swap: {} })]),
      E('div', { class: 'cbi-section', id: 'stock-network' }, [E('h3', network.title), network.render([9, 16384, [iface], []])])
    );
  } else {
    const routes = await stock('routes');
    target.append(routes.render([[{ interface: 'management', l3_device: 'eth0', 'ipv4-address': [{ address: '192.0.2.1', mask: 24 }] }],
      { stdout: '192.0.2.10 dev eth0 lladdr 02:00:00:00:00:02 REACHABLE' },
      { stdout: 'default via 192.0.2.254 dev eth0 proto static\n192.0.2.0/24 dev eth0 proto kernel scope link src 192.0.2.1' },
      { stdout: '' }, { stdout: '' }]));
  }
  target.dataset.ready = 'true';
}

module.exports = renderNativeStatus;
