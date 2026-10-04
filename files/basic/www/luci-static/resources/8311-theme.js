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
		function markAppearance() {
			Array.prototype.forEach.call(theme.querySelectorAll('button[data-theme-mode]'), function (button) {
				button.setAttribute('aria-pressed', String(button.getAttribute('data-theme-mode') === mode));
			});
		}
		if (theme) {
			markAppearance();
			theme.addEventListener('click', function (event) {
				var button = event.target.closest('button[data-theme-mode]');
				if (!button || !theme.contains(button)) return;
				mode = button.getAttribute('data-theme-mode');
				applyAppearance();
				markAppearance();
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
				if (!link) return;
				var route = item.querySelector('a[href]:not([href="#"])');
				var group = route && route.getAttribute('href').split('/admin/')[1];
				group = group ? group.split('/')[0] : 'other';
				var paths = {
					status: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z',
					system: 'M12 3v3m0 12v3M3 12h3m12 0h3M6 6l2 2m8 8 2 2M6 18l2-2M16 8l2-2M17 12a5 5 0 1 1-10 0 5 5 0 0 1 10 0',
					network: 'M9 3h6v6H9zM3 15h6v6H3zM15 15h6v6h-6zM12 9v3M6 15v-3h12v3',
					'8311': 'M5 7h14v10H5zM8 3v4m8-4v4M8 17v4m8-4v4M2 10h3m-3 4h3m14-4h3m-3 4h3M9 10h6v4H9z',
					logout: 'M10 3H4v18h6M9 12h12m-4-4 4 4-4 4'
				};
				var icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
				icon.setAttribute('viewBox', '0 0 24 24');
				icon.setAttribute('aria-hidden', 'true');
				icon.classList.add('menu-icon');
				var path = document.createElementNS(icon.namespaceURI, 'path');
				path.setAttribute('d', paths[group] || paths.network);
				icon.appendChild(path);
				link.insertBefore(icon, link.firstChild);
				item.setAttribute('data-menu-group', group);
				var expanded = !!(active && item.contains(active));
				item.classList.toggle('active-section', expanded);
				if (link.getAttribute('href') !== '#') return;
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
