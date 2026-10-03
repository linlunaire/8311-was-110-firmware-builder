function switchTab(tab) {
	var selectTab = $('li[data-tab]').filter(function () { return this.dataset.tab === tab; });
	if (!selectTab.length) return;
	var activeTab = $('li.cbi-tab');
	activeTab.addClass('cbi-tab-disabled');
	activeTab.removeClass('cbi-tab');

	selectTab.addClass('cbi-tab');
	selectTab.removeClass('cbi-tab-disabled');

	$('div[data-tab-active=true]').removeAttr('data-tab-active');
	$('div[data-tab]').filter(function () { return this.dataset.tab === tab; }).attr('data-tab-active', 'true');
}

function saveConfig(form) {
	const field = Array.from(form.elements);
	var saveb = $('#save-btn');
	var valid = true;

	var activeTab = $('li.cbi-tab[data-tab]').attr('data-tab');
	if (activeTab) {
		try { localStorage.setItem('activeConfigTab', activeTab); } catch (_) { /* Saving does not require browser storage. */ }
	}

	field.forEach(i => {
		var element = $(i);
		var element_id = element.attr('id');
		var error_label = $('label.error[for="' + element_id + '"]');

		if (!i.checkValidity()) {
			valid = false;
			error_label.text(i.validationMessage);
			error_label.show();

			element.addClass("error");

			switchTab(element.data("cat-id"));
			element.focus();
		}
		else {
			element.removeClass("error");
			error_label.text("");
			error_label.hide();
		}
	});

	if (valid) {
		saveb.attr('disabled', 'disabled');
		saveb.addClass('spinning');
		var message = $('#config-save-message');
		message.hide();
		$.ajax({
			url: form.action,
			method: 'POST',
			data: $(form).serialize(),
			dataType: 'json',
			timeout: 30000
		}).done(function (response) {
			message.text(response.message).show();
			if (response.success === true) {
				try { sessionStorage.setItem('8311-config-result', response.message); } catch (_) { /* Reload still verifies saved values. */ }
				window.location.reload();
			}
		}).fail(function (xhr, status) {
			var response = xhr.responseJSON || {};
			message.text(status === 'timeout' ? form.dataset.timeout :
				(response.message || 'Unable to save configuration. Reload the page and retry.')).show();
			Object.keys(response.errors || {}).forEach(function (name) {
				var input = document.getElementById('widget.cbid.system.poncfg.' + name);
				if (input) {
					$(input).addClass('error');
					$('label.error[for="' + input.id + '"]').text(response.errors[name]).show();
					switchTab($(input).data('cat-id'));
				}
			});
		}).always(function () {
			saveb.removeAttr('disabled').removeClass('spinning');
		});
	}

	return false;
}

function readDiagnosticText(url, output, done) {
	var previous = output.data('request');
	if (previous) previous.abort();
	output.text(output.attr('data-loading') || 'Loading...').show();
	var request = $.ajax({ url: url, dataType: 'text', timeout: 15000, cache: false });
	output.data('request', request);
	request.done(function (data) {
		if (output.data('request') !== request) return;
		output.text(data);
		if (done) done();
	}).fail(function (_, status) {
		if (status !== 'abort' && output.data('request') === request)
			output.text(output.attr('data-failure') || 'Unable to load diagnostics. Retry shortly.');
	}).always(function () {
		if (output.data('request') === request) output.removeData('request');
	});
}

function vlanTables() {
	readDiagnosticText('vlans/extvlans', $('#syslog'));
}

function switchTabPonStatus(tab) {
	switchTab(tab);

	readDiagnosticText('pontop/' + tab, $('#syslog'));
}

function showPonMe(meId, instanceId) {
	var meLabel = $('#me_label');
	meLabel.hide();
	readDiagnosticText('pon_dump/' + meId + '/' + instanceId, $('#me_dump'), function () {
		meLabel.text("ME " + meId + " Instance " + instanceId);
		meLabel.show();
		meLabel.get(0).scrollIntoView({behavior: 'smooth'});
	});
}

function submitSupportForm(input, action) {
	$('button.support-button').attr('disabled', 'disabled');
	$('#support-action').attr('value', action);
	var btn = $(input);
	if (btn)
		btn.addClass('spinning');

	$('#support-form').submit();
}

function submitFirmwareForm(input) {
	var form = document.getElementById('firmware-form');
	if (form.dataset.submitting === 'true')
		return false;
	form.dataset.submitting = 'true';
	var btn = $(input);
	$('.firmware-button, .recovery-button').attr('disabled', 'disabled');
	$('#firmware-file').attr('onclick', 'return false');
	if (btn)
		btn.addClass('spinning');

	HTMLFormElement.prototype.submit.call(form);
	return false;
}

function uploadFirmware(input) {
	var file = document.getElementById('firmware-file');
	file.setCustomValidity('');
	if (!$('#firmware-form').valid())
		return false;
	if (file.files.length && file.files[0].size > 128 * 1024 * 1024) {
		file.setCustomValidity('Firmware exceeds the 128 MiB limit.');
		file.reportValidity();
		return false;
	}
	file.setCustomValidity('');
	$('#switch-reboot-section').hide();
	return submitFirmwareForm(input);
}

function cancelFirmware(input) {
	$('#firmware-action').attr('value', 'cancel');
	return submitFirmwareForm(input);
}

function rebootFirmware(input) {
	$('#firmware-file').prop('disabled', true);
	$('#firmware-action').attr('value', 'reboot');
	return submitFirmwareForm(input);
}

function confirmCurrentFirmware(input) {
	$('#firmware-file').prop('disabled', true);
	$('#firmware-action').val('commit');
	return submitFirmwareForm(input);
}

function startConnectionDiagnostics(panel) {
	var pending = false;
	var message = document.getElementById('diagnostic-message');
	var details = document.getElementById('diagnostic-rule-details');
	function value(input) { return input == null ? panel.dataset.unavailable : String(input); }
	function row(parent, values) {
		var tr = document.createElement('tr');
		values.forEach(function (text) {
			var td = document.createElement('td');
			td.textContent = value(text);
			tr.appendChild(td);
		});
		parent.appendChild(tr);
	}
	function refresh() {
		if (pending || document.hidden) return;
		pending = true;
		var includeRules = !details || details.open;
		$.ajax({ url: panel.dataset.url, data: { rules: includeRules ? 1 : 0 }, dataType: 'json', timeout: 10000, cache: false }).done(function (data) {
			panel.querySelectorAll('[data-diagnostic]').forEach(function (node) {
				node.textContent = value(data[node.dataset.diagnostic]);
			});
			var links = document.getElementById('diagnostic-links');
			var rules = document.getElementById('diagnostic-rules');
			links.replaceChildren();
			if (includeRules) rules.replaceChildren();
			(data.links || []).forEach(function (link) {
				var counters = link.counters || {};
				row(links, [link.device, counters.rx_packets, counters.tx_packets,
					value(counters.rx_dropped) + ' / ' + value(counters.tx_dropped),
					value(counters.rx_errors) + ' / ' + value(counters.tx_errors)]);
				if (includeRules) {
					(link.filters || []).forEach(function (filter) {
						var label = filter.protocol + ' · ' + filter.pref + ' · ' + value(filter.action);
						if (filter.vlan_id) label += ' · VLAN ' + filter.vlan_id;
						row(rules, [link.device, filter.direction === 'ingress' ? panel.dataset.ingress : panel.dataset.egress,
							label, filter.packets, filter.dropped]);
					});
					if (!link.available || !link.rules_available) row(rules, [link.device, panel.dataset.rulesUnavailable, '', '', '']);
				}
			});
			if (includeRules && !rules.children.length) row(rules, [panel.dataset.noRules, '', '', '', '']);
			message.textContent = panel.dataset.sampled + ' ' + new Date().toLocaleTimeString();
		}).fail(function () {
			message.textContent = panel.dataset.failure;
		}).always(function () {
			pending = false;
			// Opening the details during a summary request needs one full sample.
			if (details && details.open && !includeRules) refresh();
		});
	}
	refresh();
	if (details) details.addEventListener('toggle', function () { if (details.open) refresh(); });
	document.addEventListener('visibilitychange', refresh);
	return window.setInterval(refresh, 10000);
}

function installFirmware(input, reboot) {
	var action = 'install';
	if (reboot)
		action = 'install_reboot';

	$('#firmware-action').attr('value', action);
	return submitFirmwareForm(input);
}

function showSwitchRebootConfirmation() {
	$('#switch-reboot-original').hide();
	$('#switch-reboot-confirmation').show();
}

function confirmSwitchReboot(confirm, input) {
	if (confirm) {
		$('#firmware-file').removeAttr('required');
		$('#firmware-file').prop('disabled', true);
		$('#firmware-action').val('switch_reboot');
		return submitFirmwareForm(input);
	}
	else {
		$('#switch-reboot-confirmation').hide();
		$('#switch-reboot-original').show();
	}
}

var recoveryPreview = null;
var recoveryBusy = false;

function cancelRecoveryPreview() {
	recoveryPreview = null;
	$('#recovery-preview').prop('hidden', true);
	$('#recovery-fields').empty();
}

function recoveryMessage(message) {
	$('#recovery-message').text(message).prop('hidden', false);
}

async function runRecovery(input, operation) {
	if (recoveryBusy) return false;
	recoveryBusy = true;
	const form = document.getElementById('recovery-form');
	const controls = Array.from(document.querySelectorAll('[id="8311-recovery-page"] button, #recovery-file, #recovery-form select'));
	const disabled = controls.map(control => control.disabled);
	controls.forEach(control => { control.disabled = true; });
	$(input).addClass('spinning');
	try {
		await operation(form);
	} catch (error) {
		const timedOut = error.name === 'AbortError' || error.statusText === 'timeout';
		recoveryMessage(timedOut ? form.dataset.timeout : ((error.responseJSON || {}).message || form.dataset.failure));
	} finally {
		controls.forEach((control, index) => { control.disabled = disabled[index]; });
		$(input).removeClass('spinning');
		recoveryBusy = false;
	}
	return false;
}

function requestRecovery(form, action, content, preserve) {
	return $.ajax({
		url: form.action, method: 'POST', dataType: 'json', timeout: 30000,
		data: { action: action, token: form.querySelector('[name="token"]').value,
			content: content || '', preserve_pon: preserve ? '1' : '0', confirm: action === 'preview' ? '' : '1' }
	});
}

function backupSettings(input) {
	return runRecovery(input, async function(form) {
		const controller = new AbortController();
		const timer = setTimeout(() => controller.abort(), 30000);
		try {
			const response = await fetch(form.action, {
				method: 'POST', credentials: 'same-origin', cache: 'no-store',
				signal: controller.signal,
				body: new URLSearchParams({ action: 'backup', token: form.querySelector('[name="token"]').value })
			});
			if (!response.ok) {
				let error = {};
				try { error = await response.json(); } catch (_) { /* Use the translated connection message. */ }
				throw { responseJSON: error };
			}
			if (!(response.headers.get('Content-Type') || '').startsWith('text/plain')) throw new Error('Invalid backup response');
			const blob = await response.blob();
			if (!blob.size || blob.size > 131072) throw new Error('Invalid backup size');
			const url = URL.createObjectURL(blob);
			const link = document.createElement('a');
			link.href = url;
			link.download = '8311-settings-' + new Date().toISOString().slice(0, 19).replace(/:/g, '-') + '.env';
			document.body.appendChild(link);
			link.click();
			link.remove();
			setTimeout(() => URL.revokeObjectURL(url), 1000);
			recoveryMessage(form.dataset.backupSuccess);
		} finally {
			clearTimeout(timer);
		}
	});
}

function previewRecovery(input) {
	return runRecovery(input, async function(form) {
		cancelRecoveryPreview();
		const file = document.getElementById('recovery-file').files[0];
		if (!file || !file.size || file.size > 131072) {
			recoveryMessage(form.dataset.fileError);
			return;
		}
		const content = await file.text();
		const preserve = document.getElementById('recovery-preserve').value !== '0';
		const response = await requestRecovery(form, 'preview', content, preserve);
		if (!response.success) { recoveryMessage(response.message); return; }
		(response.names || []).forEach(name => $('<li>').text(name).appendTo('#recovery-fields'));
		$('#recovery-skipped').text(response.skipped || 0);
		recoveryMessage(response.message);
		if (response.count > 0) {
			recoveryPreview = { content: content, preserve: preserve, hook: response.hook_script };
			$('#recovery-preview').prop('hidden', false);
		}
	});
}

function applyRecovery(input) {
	if (!recoveryPreview) return false;
	const form = document.getElementById('recovery-form');
	if (!recoveryPreview.preserve && !window.confirm(form.dataset.ponConfirm)) return false;
	if (recoveryPreview.hook && !window.confirm(form.dataset.hookConfirm)) return false;
	return runRecovery(input, async function() {
		const preview = recoveryPreview;
		cancelRecoveryPreview();
		$('#recovery-reboot').prop('hidden', true);
		const response = await requestRecovery(form, 'restore', preview.content, preview.preserve);
		recoveryMessage(response.message);
		$('#recovery-reboot').prop('hidden', !response.success || !response.reboot_required);
	});
}

function resetSettings(input) {
	const form = document.getElementById('recovery-form');
	const preserve = document.getElementById('reset-preserve').value !== '0';
	if (recoveryBusy || !window.confirm(form.dataset.resetConfirm)) return false;
	if (!preserve && !window.confirm(form.dataset.ponConfirm)) return false;
	return runRecovery(input, async function() {
		cancelRecoveryPreview();
		$('#recovery-reboot').prop('hidden', true);
		const response = await requestRecovery(form, 'reset', '', preserve);
		recoveryMessage(response.message);
		$('#recovery-reboot').prop('hidden', !response.success || !response.reboot_required);
	});
}

$(document).ready(function () {
	var diagnostics = document.getElementById('connection-diagnostics');
	if (diagnostics) startConnectionDiagnostics(diagnostics);
	var configForm = document.getElementById('8311-config');
	if (configForm) {
		$(configForm).on('input change', function () {
			$('#config-save-message').text(configForm.dataset.unsaved).show();
		});
		function resetConfigFields() {
			configForm.reset();
			$('#save-btn').prop('disabled', false).removeClass('spinning');
			if (fixVlansSelect && fixVlansSelect.length) toggleVlanFields();
		}
		// Ready may run after pageshow; restored controls need a subsequent task.
		setTimeout(resetConfigFields, 0);
		window.addEventListener('pageshow', function (event) {
			if (event.persisted) { window.location.reload(); return; }
			setTimeout(resetConfigFields, 0);
		});
		try {
			var result = sessionStorage.getItem('8311-config-result');
			sessionStorage.removeItem('8311-config-result');
			if (result) $('#config-save-message').text(result).show();
		} catch (_) { /* Browser storage can be unavailable. */ }
	}
	var vlanStatus = document.getElementById('vlan-apply-status');
	if (vlanStatus) {
		var vlanStatusTimer;
		function readVlanStatus() {
			if (document.hidden) { vlanStatusTimer = setTimeout(readVlanStatus, 5000); return; }
			$.ajax({ url: vlanStatus.dataset.url, dataType: 'json', timeout: 5000, cache: false }).done(function (status) {
				var text = status.message;
				if (status.last_applied_at > 0) text += ' ' + vlanStatus.dataset.lastApplied + ' ' + new Date(status.last_applied_at * 1000).toLocaleString();
				$(vlanStatus).text(text);
			}).fail(function () { $(vlanStatus).text(vlanStatus.dataset.failure); }).always(function () {
				vlanStatusTimer = setTimeout(readVlanStatus, 5000);
			});
		}
		readVlanStatus();
		window.addEventListener('pagehide', function () { clearTimeout(vlanStatusTimer); });
	}
	if (configForm) {
		try {
			var savedTab = localStorage.getItem('activeConfigTab');
			if (savedTab) switchTab(savedTab);
			localStorage.removeItem('activeConfigTab');
		} catch (_) { /* Browser storage can be unavailable. */ }
	}

	var fixVlansSelect = $('#widget\\.cbid\\.system\\.poncfg\\.fix_vlans');
	if (fixVlansSelect.length === 0) {
		return;
	}

	var editHookScriptBtn = $('#edit-hook-script-btn');
	var hookScriptModal = $('#hook-script-modal');
	var hookScriptMessage = $('#hook-script-message');
	var hookScriptTextarea = $('#hook-script-textarea');
	var vlanFields = $('.vlan-field');

	function toggleVlanFields() {
		var fixVlansValue = fixVlansSelect.val();
		if (fixVlansValue == '1') {
			vlanFields.show();
		} else {
			vlanFields.hide();
		}
	}

	fixVlansSelect.change(toggleVlanFields);
	toggleVlanFields();
	editHookScriptBtn.click(function (e) {
		e.preventDefault();
		if (editHookScriptBtn.prop('disabled')) return;
		editHookScriptBtn.prop('disabled', true);
		$('#hook-script-save-btn').prop('disabled', true);
		hookScriptTextarea.val('');

		hookScriptMessage.hide();
		hookScriptMessage.text('');

		$.ajax({ url: 'get_hook_script', dataType: 'text', timeout: 30000 }).done(function (data) {
			hookScriptTextarea.val(data);
			$('#hook-script-save-btn').prop('disabled', false);
			hookScriptModal.show();
			adjustTextareaHeight();
		}).fail(function () {
			hookScriptMessage.text(translations.hookScriptLoadFailed).css('color', 'red').show();
			hookScriptModal.show();
		}).always(function () {
			editHookScriptBtn.prop('disabled', false);
		});
	});

	$('#hook-script-save-btn').click(function () {
		var saveButton = $(this);
		if (saveButton.prop('disabled')) return;
		saveButton.prop('disabled', true).addClass('spinning');
		var content = hookScriptTextarea.val();
		$.ajax({ url: 'save_hook_script', method: 'POST', dataType: 'json', timeout: 30000,
			data: { content: content, token: $('#8311-config input[name="token"]').val() }
		}).done(function (response) {
			if (!response.success) {
				hookScriptMessage.text(translations.hookScriptSaveFailed).css('color', 'red').show();
				return;
			}
			hookScriptMessage.text(translations.hookScriptSaved);
			hookScriptMessage.css('color', 'green');
			hookScriptMessage.show();
			setTimeout(function () {
				hookScriptMessage.hide();
				hookScriptModal.hide();
			}, 1000); // hide window in 1s
		}).fail(function (_, status) {
			hookScriptMessage.text(status === 'timeout' ? configForm.dataset.timeout : translations.hookScriptSaveFailed);
			hookScriptMessage.css('color', 'red');
			hookScriptMessage.show();
		}).always(function () {
			saveButton.prop('disabled', false).removeClass('spinning');
		});
	});
	$('#hook-script-cancel-btn').click(function () {
		hookScriptModal.hide();
	});
	function adjustTextareaHeight() {
		hookScriptTextarea.height(0);
		var height = hookScriptTextarea[0].scrollHeight;
		hookScriptTextarea.height(height);
	}
	hookScriptTextarea.on('input', adjustTextareaHeight);
});
