'use strict';
'require baseclass';

return baseclass.extend({
	title: _('PON Status'),

	load: function () {
		if (document.hidden)
			return Promise.resolve(this.lastStatus || {});
		if (this.pendingStatus)
			return this.pendingStatus;

		var self = this;
		this.pendingStatus = L.Request.get(L.url('admin/8311/gpon_status')).then(function (res) {
			return res.json();
		}).then(function (data) {
			self.pendingStatus = null;
			self.lastStatus = data;
			return data;
		}, function (error) {
			self.pendingStatus = null;
			throw error;
		});
		return this.pendingStatus;
	},

	render: function (data) {
		var fields = [
			_('PON Mode'), data.pon_mode || '?',
			_('PON PLOAM Status'), data.status || '?',
			_('RX Power / TX Power / TX Bias'), data.power || '?',
			_('CPU0 / CPU1 / Optic Temperature'), data.temperature || '?',
			_('Module Voltage'), data.voltage || '?',
			_('Module Info'), data.module_info || '?',
			_('ETH Speed'), data.eth_speed || '?',
			_('Active Firmware'), data.active_bank || '?'
		];

		var table = E('div', { 'class': 'table' });

		for (var i = 0; i < fields.length; i += 2) {
			table.appendChild(E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td left', 'width': '33%' }, [fields[i]]),
				E('div', { 'class': 'td left' }, [fields[i + 1]])
			]));
		}

		return table;
	}
});
