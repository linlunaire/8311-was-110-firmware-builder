/* Browser-only appearance and navigation; menus still use the native LuCI loader. */
(function () {
	'use strict';
	var root = document.documentElement;
	var modes = ['system', 'light', 'dark'];
	var mode = 'system';
	var preference = window.matchMedia('(prefers-color-scheme: dark)');
	try {
		var saved = localStorage.getItem('8311-theme');
		if (modes.indexOf(saved) !== -1) mode = saved;
	} catch (e) { /* Appearance remains usable when storage is blocked. */ }
	function applyAppearance() {
		root.dataset.theme = mode;
		root.dataset.color = mode === 'dark' || (mode === 'system' && preference.matches) ? 'dark' : 'light';
	}
	applyAppearance();
	if (preference.addEventListener) preference.addEventListener('change', applyAppearance);
	else preference.addListener(applyAppearance);

	document.addEventListener('DOMContentLoaded', function () {
		var theme = document.getElementById('8311-theme-toggle');
		function labelAppearance() {
			var label = theme.getAttribute('data-' + mode);
			theme.querySelector('span').textContent = label;
			theme.setAttribute('aria-label', theme.getAttribute('data-label') + ': ' + label);
		}
		if (theme) {
			labelAppearance();
			theme.addEventListener('click', function () {
				mode = modes[(modes.indexOf(mode) + 1) % modes.length];
				applyAppearance();
				labelAppearance();
				try { localStorage.setItem('8311-theme', mode); } catch (e) {}
			});
		}

		var menu = document.getElementById('topmenu');
		var toggle = document.getElementById('8311-menu-toggle');
		if (!menu || !toggle) return;
		var navigation = document.getElementById('8311-navigation');
		var backdrop = document.getElementById('8311-menu-backdrop');
		var content = document.getElementById('maincontent');
		var narrow = window.matchMedia('(max-width: 760px)');
		function setOpen(open, restoreFocus) {
			document.body.classList.toggle('navigation-open', open);
			toggle.setAttribute('aria-expanded', String(open));
			backdrop.hidden = !open;
			content.inert = open;
			if (open) {
				var first = menu.querySelector('a');
				if (first) first.focus();
			} else if (restoreFocus) toggle.focus();
		}
		toggle.addEventListener('click', function () { setOpen(toggle.getAttribute('aria-expanded') !== 'true', true); });
		backdrop.addEventListener('click', function () { setOpen(false, true); });
		function resizeNavigation() { if (!narrow.matches) setOpen(false, false); }
		if (narrow.addEventListener) narrow.addEventListener('change', resizeNavigation);
		else narrow.addListener(resizeNavigation);
		document.addEventListener('keydown', function (event) {
			if (toggle.getAttribute('aria-expanded') !== 'true') return;
			if (event.key === 'Escape') { setOpen(false, true); return; }
			if (event.key !== 'Tab') return;
			var links = Array.prototype.filter.call(menu.querySelectorAll('a'), function (link) { return link.getClientRects().length; });
			var last = links[links.length - 1] || toggle;
			if (event.shiftKey && document.activeElement === toggle) { event.preventDefault(); last.focus(); }
			else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); toggle.focus(); }
		});
		menu.addEventListener('click', function (event) {
			var link = event.target.closest('a');
			if (!link) return;
			if (link.getAttribute('href') === '#' && link.nextElementSibling) {
				event.preventDefault();
				var collapsed = link.parentElement.classList.toggle('is-collapsed');
				link.setAttribute('aria-expanded', String(!collapsed));
			} else if (narrow.matches) setOpen(false, false);
		});
		menu.addEventListener('keydown', function (event) {
			if (event.key === ' ' && event.target.getAttribute('role') === 'button') { event.preventDefault(); event.target.click(); }
		});
		function markNavigation() {
			if (!menu.children.length) return false;
			var current = location.pathname.replace(/\/$/, '');
			if (window.L && L.env && L.env.dispatchpath) current = L.url.apply(L, L.env.dispatchpath);
			var active = null;
			Array.prototype.forEach.call(menu.querySelectorAll('a[href]'), function (link) {
				var target = link.getAttribute('href');
				if (target !== '#' && (current === target || current.indexOf(target + '/') === 0) && (!active || target.length > active.getAttribute('href').length)) active = link;
			});
			if (active) { active.classList.add('active'); active.setAttribute('aria-current', 'page'); }
			Array.prototype.forEach.call(menu.children, function (item) {
				var link = item.firstElementChild;
				if (!link || link.getAttribute('href') !== '#') return;
				var expanded = !!(active && item.contains(active));
				item.classList.toggle('is-collapsed', !expanded);
				link.setAttribute('role', 'button');
				link.setAttribute('aria-expanded', String(expanded));
			});
			return true;
		}
		if (!markNavigation()) {
			var observer = new MutationObserver(function () { if (markNavigation()) observer.disconnect(); });
			observer.observe(menu, { childList: true });
		}
	});
})();
