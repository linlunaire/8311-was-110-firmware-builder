-- Run with Lua 5.1. Hardware, LuCI and environment writes are isolated stubs.
local root = REPO_ROOT or "."
package.path = root .. "/files/basic/usr/lib/lua/?.lua;" .. package.path
string.trim = function(s) return s:match("^%s*(.-)%s*$") end
local saved_arg = arg
arg = nil
local native_base64 = require "base64"
local real_base64 = { enc = native_base64.enc, dec = native_base64.dec }
arg = saved_arg

local passed = 0
local function check(name, fn)
	if RUN_LOCK_WORKER then return end
	fn()
	passed = passed + 1
	print("ok - " .. name)
end

check("Base64 handles all bytes without global functions or mistaking caller arguments for CLI input", function()
	local bytes = {}
	for value = 0, 255 do bytes[#bytes + 1] = string.char(value) end
	local raw = table.concat(bytes)
	assert(real_base64.dec(real_base64.enc(raw)) == raw)
	for _, sample in ipairs({ "", "f", "fo", "foo", "line\nnext", string.rep("x", 65536) }) do
		assert(real_base64.dec(real_base64.enc(sample)) == sample)
	end
	assert(rawget(_G, "enc") == nil and rawget(_G, "dec") == nil)
	package.loaded["nixio"] = { bin = { b64encode = real_base64.enc, b64decode = real_base64.dec } }
	package.loaded["base64"] = nil
	arg = { [0] = "caller.lua", "ignored argument" }
	local codec = require "base64"
	assert(codec.enc == real_base64.enc and codec.dec == real_base64.dec)
	package.loaded["nixio"] = nil
	arg = saved_arg
end)

local function native_permissions(value)
	if value == nil then return end
	local mode = tostring(value)
	-- Legacy nixio parses octal digits or chmod-style strings, not decimal bits.
	assert(mode:match("^[0-7][0-7][0-7]$") or mode:match("^[0-7][0-7][0-7][0-7]$") or
		mode:match("^[r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]$"), "invalid native nixio permission mode")
end

local function setup()
	local s = { files = {}, directories = {}, reads = {}, closed = 0, calls = {}, processes = {}, writes = {}, text = "", status = 200, pon = "current=50", readback = "", rebooted = false }
	local util = {
		trim = string.trim,
		shellquote = function(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end,
		exec = function(command)
			table.insert(s.calls, command)
			if command == "pon psg" or command == "timeout -k 1 2 pon psg" then return s.pon end
			if command:match("^fwenv_get ") then return s.readback end
			return ""
		end
	}
	local fs = {
		readfile = function(path, length)
			table.insert(s.reads, { path = path, offset = 0, length = length })
			local data = s.files[path]
			return data and (length and data:sub(1, length) or data)
		end,
		writefile = function(path, content)
			if s.fail_write then return nil end
			table.insert(s.writes, { path = path, content = content })
			s.files[path] = content
			return #content - (s.short_write and 1 or 0)
		end,
		mkdirr = function(path, mode) native_permissions(mode); s.directories[path] = true; return true end,
		mkdir = function(path, mode) native_permissions(mode); s.directories[path] = true; return true end,
		lstat = function(path, field)
			if s.fail_lstat then return nil, 5 end
			if not s.files[path] and not s.directories[path] then return nil, 2 end
			local info = { type = s.directories[path] and "dir" or "reg", uid = 0 }
			return field and info[field] or info
		end,
		chmod = function(_, mode) native_permissions(mode); return not s.fail_chmod end,
		rename = function(src, dest)
			if s.fail_rename then return nil end
			s.files[dest], s.files[src] = s.files[src], nil
			return true
		end,
		remove = function(path)
			if s.files[path] == nil then return nil, 2 end
			s.files[path] = nil
			return true
		end,
		glob = function() return ipairs({}) end,
	}
	local http = {
		HTTP_MAX_CONTENT = 102400,
		formvalue = function(key)
			if key then return (s.form or {})[key] end
			return s.form or {}
		end,
		getenv = function(key)
			if key == "CONTENT_LENGTH" then return s.content_length or "1024" end
			return s.method or "POST"
		end,
		setfilehandler = function(callback)
			s.upload_handled = true
			if s.upload then s.upload(callback) end
		end,
		-- Legacy LuCI keeps the first prepared Content-Type until explicitly replaced.
		prepare_content = function(value) if not s.content_type then s.content_type = value end end,
		header = function(key, value)
			s.headers = s.headers or {}; s.headers[key] = value
			if key:lower() == "content-type" then s.content_type = value end
		end,
		status = function(code) s.status = code end,
		write = function(data) s.text = s.text .. data end,
		write_json = function(data) s.json = data end,
		redirect = function() error("save must report its result") end,
	}
	local sys = {
		call = function(command)
			table.insert(s.calls, command)
			if command:match("^printf ") then
				return (HOST_CALL or os.execute)(command)
			end
			return s.call_code or 0
		end,
		process = { exec = function(command, output)
			if command[1] == "/usr/sbin/8311-temp-space.sh" then
				s.space_checks = (s.space_checks or 0) + 1
				return { code = s.space_code or 0 }
			end
			if command[5] == "/usr/sbin/8311-bank-check.sh" then
				s.bank_checks = (s.bank_checks or 0) + 1
				return { code = s.bank_invalid and 1 or 0 }
			end
			if command[5] == "/sbin/tc" then
				s.tc_reads = (s.tc_reads or 0) + 1
				if output then output(s.tc_text or "") end
				return { code = s.tc_failure and 1 or 0 }
			end
			table.insert(s.processes, command)
			if command[1] == "/usr/sbin/fw_printenv" or command[5] == "/usr/sbin/fw_printenv" then
				table.remove(s.processes)
				s.environment_reads = (s.environment_reads or 0) + 1
				if output then output(s.environment or "") end
				return { code = s.env_read_code or 0 }
			end
			if output then output(s.process_output or "") end
			return { code = s.process_code or 0 }
		end },
		reboot = function() s.rebooted = true end,
	}
	local nixio = {
		getpid = function() return 123 end,
		open_flags = function(...) return table.concat({...}, ",") end,
		open = function(path, mode, permissions)
			native_permissions(permissions)
			if mode == "w" or mode:find("creat", 1, true) then
				if s.fail_open then return nil end
				if mode:find("excl", 1, true) and s.files[path] then return nil end
				if path:find(".incoming.", 1, true) then assert(permissions == "rw-------" or tostring(permissions) == "600") end
				s.files[path] = ""
			end
			if not s.files[path] then return nil end
			local offset = 0
			return {
				seek = function(_, value)
					if s.fail_seek then return nil end
					offset = value
					return value
				end,
				read = function(_, length)
					table.insert(s.reads, { path = path, offset = offset, length = length })
					return not s.fail_read and s.files[path]:sub(offset + 1, offset + length) or nil
				end,
				write = function(_, data, offset)
					if s.fail_write then return nil end
					local part = data:sub((offset or 0) + 1)
					if s.discard_writes then return #part end
					if s.short_write or s.short_stream_write then part = part:sub(1, 1) end
					s.files[path] = s.files[path] .. part
					return #part
				end,
				close = function() s.closed = s.closed + 1; return true end,
				lock = function() return not s.busy_lock end,
			}
		end,
	}
	local modules = {
		["luci.util"] = util, ["luci.sys"] = sys, ["luci.http"] = http,
		["nixio.fs"] = fs, ["nixio"] = nixio,
		["nixio.bit"] = { lshift = function(a, b) return a * 2^b end },
		["luci.i18n"] = { translate = function(text) return text end },
		["luci.template"] = { render = function(_, values) s.render = values end },
		["luci.dispatcher"] = {
			context = { authsession = string.rep("a", 32) },
			test_post_security = function()
				s.security_checked = true
				s.parse_limit = http.HTTP_MAX_CONTENT
				if (s.form or {}).token ~= "fixture-token" then s.status = 403; return false end
				return true
			end,
		}, ["luci.ltn12"] = {},
		["8311.version"] = { version = "test", revision = "test", variant = "basic" },
		["luci.model.uci"] = { get = function() return nil end,
			get_all = function() return s.languages end },
		["luci.jsonc"] = {},
		["base64"] = real_base64,
	}
	for name, instance in pairs(modules) do package.loaded[name] = instance end
	luci = { http = http, sys = sys }
	package.loaded["8311.tools"] = nil
	package.loaded["8311.recovery"] = nil
	package.loaded["luci.controller.8311"] = nil
	local tools = require "8311.tools"
	local controller = require "luci.controller.8311"
	return s, tools, controller
end

if RUN_LOCK_WORKER then RUN_LOCK_WORKER(setup); return end

check("HTML escaping handles adjacent special characters and nil", function()
	local _, tools = setup()
	assert(tools.html_escape([[A&B<demo>"']]) == "A&amp;B&lt;demo&gt;&quot;&#039;")
	assert(tools.html_escape(nil) == "")
	assert(tools.html_escape(0) == "0")
	assert(select("#", tools.html_escape("&")) == 1)
end)

check("failed environment reads never render defaults or write configuration", function()
	for _, action in ipairs({ "action_config", "action_save" }) do
		local s, tools, controller = setup()
		s.env_read_code = 1
		tools.fwenv_set = function() error("failed read reached configuration writer") end
		controller[action]()
		assert(s.status == 503 and not s.render and #s.writes == 0, action)
	end
end)

check("one bounded environment snapshot preserves empty and literal values", function()
	local s, tools, controller = setup()
	s.environment = "8311_hostname=\n8311_loid=a=b&c\\n\nbootdelay=5\nuart_select=disable\nimg_versionA=one\nimg_versionB=two\n"
	local values = controller.populate_8311_fwenvs()
	local fields = {}
	for _, category in ipairs(values) do
		for _, field in ipairs(category.items) do fields[field.id] = field end
	end
	assert(fields.hostname.value == "" and fields.loid.value == "a=b&c\\n")
	assert(fields.bootdelay.value == "5" and fields.uart_select.value == "disable")
	assert(fields.sw_verA.default == "one" and fields.sw_verB.default == "two")
	assert(s.environment_reads == 1 and #s.calls == 4, "configuration spawned redundant environment queries")
	s.environment = string.rep("x", 131073)
	assert(tools.read_fwenvs() == nil, "oversized environment accepted")
end)

check("field validation reads choices directly without resolving display defaults", function()
	local s, tools, controller = setup()
	s.languages = { [".type"] = "internal", en = "English", zh_cn = "Chinese", list = {} }
	s.files["/usr/share/zoneinfo/zone.tab"] = "# comment\nCN\t+3114+12128\tAsia/Shanghai\nUS +404251-0740023 America/New_York\nCN +0 Asia/Shanghai\n"
	local fields = {}
	for _, category in ipairs(controller.fwenvs_8311(false)) do
		for _, item in ipairs(category.items) do fields[item.id] = item end
	end
	assert(#s.calls == 0, "validation spawned processes for unused display defaults or option parsing")
	assert(fields.sw_verA.default == nil and fields.gateway.default == nil)
	assert(fields.hostname.default == "prx126-sfp-pon")
	assert(table.concat(fields.timezone.options, ",") == "America/New_York,Asia/Shanghai,UTC")
	assert(#fields.lang.options == 3 and fields.lang.options[1].value == "auto")
	assert(fields.lang.options[2].value == "en" and fields.lang.options[2].name == "English")
	assert(tools.validate_config_value(fields.lang, "zh_cn"))
	assert(not tools.validate_config_value(fields.lang, ".type"))
	assert(not tools.validate_config_value(fields.timezone, "Unknown/Zone"))
	controller.fwenvs_8311()
	assert(#s.calls == 4 and s.environment_reads == 2, "display defaults should retain bounded environment lookups")
end)

check("link diagnostics preserve counter precision and parse only bounded service rule counters", function()
	local s, tools = setup()
	s.files["/sys/class/net/eth0_0/ifindex"] = "10\n"
	s.files["/sys/class/net/eth0_0/statistics/rx_packets"] = "18446744073709551615\n"
	s.files["/sys/class/net/eth0_0/statistics/tx_packets"] = "0\n"
	s.files["/sys/class/net/eth0_0/statistics/rx_errors"] = "nan\n"
	s.tc_text = [[filter protocol 802.1Q pref 1 flower
filter protocol 802.1Q pref 1 flower handle 0x1
  vlan_id 41
  action order 1: vlan pop pass
  Sent 100 bytes 5 pkt (dropped 2, overlimits 0 requeues 0)
  action order 2: gact action pass
  Sent 100 bytes 99 pkt (dropped 10, overlimits 0 requeues 0)
filter protocol 802.1ad pref 251 flower handle 0x6f
  action order 1: gact action pass
  Sent 100 bytes 12 pkt (dropped 0, overlimits 0 requeues 0)
]]
	local links = tools.link_diagnostics()
	assert(#links == 2 and links[1].available and not links[2].available and s.tc_reads == 2)
	assert(links[1].counters.rx_packets == "18446744073709551615" and links[1].counters.tx_packets == "0")
	assert(links[1].counters.rx_errors == nil)
	assert(#links[1].filters == 2 and links[1].filters[1].vlan_id == "41")
	assert(links[1].filters[1].packets == "5" and links[1].filters[1].dropped == "2")
	assert(links[1].filters[1].direction == "ingress" and links[1].filters[2].direction == "egress")
	s.tc_failure = true
	assert(tools.link_diagnostics()[1].rules_available == false)
	s.tc_failure, s.tc_text = false, string.rep("x", 65537)
	assert(tools.link_diagnostics()[1].rules_available == false)
end)

check("collapsed rule diagnostics skip TC while interface counters remain current", function()
	local s, _, controller = setup()
	s.files["/sys/class/net/eth0_0/ifindex"] = "10\n"
	s.files["/sys/class/net/eth0_0/statistics/rx_packets"] = "18446744073709551615\n"
	s.form = { rules = "0" }
	controller.action_diagnostics()
	assert((s.tc_reads or 0) == 0, "collapsed rule details still query TC")
	assert(s.json.links[1].counters.rx_packets == "18446744073709551615")
	assert(#s.json.links[1].filters == 0 and s.json.links[1].rules_available == nil)
	s.form.rules = "1"
	controller.action_diagnostics()
	assert(s.tc_reads == 2 and s.json.links[1].rules_available)
end)

check("connection diagnostics are read-only and missing readings stay unavailable", function()
	local s, _, controller = setup()
	controller.action_diagnostics()
	assert(s.json.links and s.json.vlan and s.json.sample_valid == false)
	assert(s.headers["Cache-Control"] == "no-store" and #s.writes == 0 and not s.rebooted)
	assert(s.json.links[1].counters.rx_packets == nil)
end)

check("missing and short EEPROMs produce unavailable readings without exceptions", function()
	for _, data in ipairs({ false, "", string.rep("\0", 105) }) do
		local s, tools, controller = setup()
		s.files["/sys/class/pon_mbox/pon_mbox0/device/eeprom51"] = data or nil
		local values = tools.metrics()
		assert(values.ploam_state == 50 and values.optic_tempC == nil)
		assert(values.sample_valid == false and values.cpu1_tempC == nil)
		controller.action_metrics()
		assert(s.text:find('"optic_tempC": null', 1, true))
		assert(s.text:find('"sample_valid": false', 1, true))
		controller.action_gpon_status()
		assert(s.json.power == "N/A / N/A / N/A")
		assert(s.json.module_info:find("N/A", 1, true))
	end
end)

local function eeprom(temp, tx, rx)
	local function word(n) return string.char(math.floor(n / 256), n % 256) end
	return string.rep("\0", 96) .. word(temp) .. word(33000) .. word(5000) .. word(tx) .. word(rx)
end

check("metrics read only the ten dynamic EEPROM bytes and close the descriptor", function()
	local s, tools = setup()
	s.files["/sys/class/pon_mbox/pon_mbox0/device/eeprom51"] = eeprom(2560, 10000, 1000)
	assert(tools.metrics().optic_tempC == 10)
	local reads = 0
	for _, read in ipairs(s.reads) do
		if read.path:match("eeprom51$") then
			assert(read.offset == 96 and read.length == 10, "unnecessary EEPROM bytes were read")
			reads = reads + 1
		end
	end
	assert(reads == 1 and s.closed == 1)
end)

check("EEPROM seek fallback stays bounded and failed reads close the descriptor", function()
	local s, tools = setup()
	s.files["/sys/class/pon_mbox/pon_mbox0/device/eeprom51"] = eeprom(2560, 10000, 1000)
	s.fail_seek = true
	assert(tools.metrics().optic_tempC == 10 and s.closed == 1)
	assert(s.reads[#s.reads].length == 106)
	s.fail_seek, s.fail_read = false, true
	assert(tools.metrics().optic_tempC == nil and s.closed == 2)
end)

check("status reuses the module cache and parses only a complete boot-bank argument", function()
	local s, _, controller = setup()
	s.files["/tmp/8311-module-type"] = "bfw\n"
	s.files["/proc/cmdline"] = "console=ttyS0 rootfsname=rootfsB quiet\n"
	s.files["/sys/class/pon_mbox/pon_mbox0/device/eeprom50"] = string.rep("x", 256)
	controller.action_gpon_status()
	assert(s.json.active_bank == "B" and s.json.module_info:match("%(bfw%)$"))
	assert(#s.calls == 1, "status spawned a shell to read static information")
	for _, read in ipairs(s.reads) do
		if read.path:match("eeprom50$") then assert(read.length == 60) end
	end
	s.files["/proc/cmdline"] = "rootfsname=rootfsBAD"
	controller.action_gpon_status()
	assert(s.json.active_bank == "N/A")
end)

check("signed optical temperature, real zero CPU temperature and finite power", function()
	local s, tools = setup()
	-- -1.5 C as Q8.8, 1 mW TX and 0.1 mW RX.
	s.files["/sys/class/pon_mbox/pon_mbox0/device/eeprom51"] = eeprom(65152, 10000, 1000)
	s.files["/sys/class/thermal/thermal_zone0/temp"] = "0\n"
	s.files["/sys/class/thermal/thermal_zone1/temp"] = "45000\n"
	local values = tools.metrics()
	assert(values.optic_tempC == -1.5 and values.cpu1_tempC == 0 and values.cpu2_tempC == 45)
	assert(math.abs(values.rx_power_dBm + 10) < 1e-9 and values.tx_power_dBm == 0)
	assert(values.module_voltage == 3.3 and values.tx_bias_mA == 10 and values.sample_valid)
end)

check("zero optical power and failed PON reads are not invented numeric readings", function()
	local s, tools, controller = setup()
	s.pon = ""
	s.files["/sys/class/pon_mbox/pon_mbox0/device/eeprom51"] = eeprom(0, 0, 0)
	local values = tools.metrics()
	assert(values.ploam_state == nil and values.rx_power_dBm == nil and values.tx_power_dBm == nil)
	assert(values.optic_tempC == 0 and not values.sample_valid)
	controller.action_metrics()
	assert(not s.text:find("inf") and not s.text:find("nan"))
	assert(s.text:find('"ploam_state": null', 1, true))
end)

check("shared field rules validate ranges, enums, lengths and request types", function()
	local _, tools = setup()
	assert(tools.validate_config_value({ type = "number", min = 0, max = 4095 }, "4095"))
	for _, value in ipairs({ "4096", "-1", "1.5", "1e2", "nan", "1;reboot" }) do
		assert(not tools.validate_config_value({ type = "number", min = 0, max = 4095 }, value))
	end
	assert(not tools.validate_config_value({ required = true }, ""))
	assert(not tools.validate_config_value({ maxlength = 3 }, "abcd"))
	assert(not tools.validate_config_value({}, { "a", "b" }))
	assert(not tools.validate_config_value({}, "a\nb"))
	assert(not tools.validate_config_value({}, "a\0b"))
	assert(tools.validate_config_value({ type = "checkbox" }, "0"))
	assert(not tools.validate_config_value({ type = "checkbox" }, "yes"))
	assert(tools.validate_config_value({ type = "select", options = { "A", "B" } }, "A"))
	assert(not tools.validate_config_value({ type = "select", options = { "A", "B" } }, "C"))
end)

check("server checks actual PCRE constraints without interpreting shell input", function()
	local _, tools = setup()
	local field = { pattern = "^([A-Fa-f0-9]{2})*$", maxlength = 72 }
	assert(tools.validate_config_value(field, "0011aAbB"))
	assert(not tools.validate_config_value(field, "ABC"))
	assert(not tools.validate_config_value(field, "G0"))
	assert(not tools.validate_config_value(field, "'$(echo injected)'"))
	assert(tools.validate_config_value({ pattern = "^\\d{6}.{0,2}$" }, "260102AA"))
end)

check("environment writes report failure and verify readback", function()
	local s, tools = setup()
	s.call_code = 1
	assert(not tools.fwenv_set("fix_vlans", "1", true, false))
	s.call_code = 0
	s.environment = "8311_fix_vlans=0\n"
	assert(not tools.fwenv_set("fix_vlans", "1", true, false))
	s.environment = "8311_fix_vlans=1\n"
	assert(tools.fwenv_set("fix_vlans", "1", true, false))
end)

check("clearing an environment field requires a successful complete readback", function()
	for _, code in ipairs({ 7, 124, 137 }) do
		for _, output in ipairs({ "", "8311_fix_vlans=\n" }) do
			local s, tools = setup()
			s.env_read_code, s.environment = code, output
			assert(not tools.fwenv_set("fix_vlans", "", true, false), "failed read reported a confirmed clear")
		end
	end
	local s, tools = setup()
	s.environment = "bootdelay=5\n"
	assert(tools.fwenv_set("fix_vlans", "", true, false), "successful snapshot without key must confirm a clear")
	s.environment = "8311_fix_vlans=\n"
	assert(tools.fwenv_set("fix_vlans", "", true, false))
end)

check("environment read states and verification stages preserve exact stored values", function()
	local s, tools = setup()
	s.environment = "8311_text_b64=" .. real_base64.enc("a\n=b") .. "\ncommit_bank=A\n"
	assert(tools.fwenv_get("missing", "fallback", true) == "fallback")
	assert(tools.fwenv_get("text", nil, true, true) == "a\n=b")
	assert(tools.fwenv_set("text", "a\n=b", true, true))
	s.environment = "8311_text_b64=other\n"
	local ok, stage, reason = tools.fwenv_set("text", "a\n=b", true, true)
	assert(not ok and stage == "verify" and reason == "mismatch")
	s.env_read_code = 124
	ok, stage, reason = tools.fwenv_set("text", "", true, true)
	assert(not ok and stage == "verify" and reason == "timeout")
	assert(tools.fwenv_get("missing", "fallback") == nil)
	s.env_read_code = 0
	for _, raw in ipairs({ "warning\n8311_text_b64=\n", "8311_text_b64=\n8311_text_b64=duplicate\n" }) do
		s.environment = raw
		assert(tools.read_fwenvs() == nil)
	end
	s.call_code = 7
	ok, stage = tools.fwenv_set("text", "", true, true)
	assert(not ok and stage == "write")
end)

check("VLAN status reports only bounded states, pending reloads and a live monitor", function()
	local s, tools, controller = setup()
	assert(tools.vlan_status().state == "unknown")
	s.files["/tmp/8311-vlans.status"] = "123\t100\t99\t2\tapplied\tnone\t0\n"
	s.files["/proc/123/cmdline"] = "/bin/sh\0/usr/sbin/8311-vlansd.sh\0"
	local status = tools.vlan_status()
	assert(status.state == "applied" and status.running and status.last_applied_at == 99)
	controller.action_vlan_status()
	assert(s.json.message == "VLAN script completed successfully." and s.headers["Cache-Control"] == "no-store")
	s.files["/tmp/8311-vlans.reload"] = "\n"
	assert(tools.vlan_status().state == "scheduled")
	s.files["/tmp/8311-vlans.reload"] = nil
	s.files["/proc/123/cmdline"] = nil
	controller.action_vlan_status()
	assert(s.json.message == "VLAN monitor is not running.")
	for _, raw in ipairs({ "secret-hook-output", string.rep("x", 257), "123\t100\t0\t2\terror\tapply\t999\n",
		"123\t" .. string.rep("9", 100) .. "\t0\t2\tapplied\tnone\t0\n" }) do
		s.files["/tmp/8311-vlans.status"] = raw
		assert(tools.vlan_status().state == "unknown")
	end
	s.files["/tmp/8311-vlans.status"] = "123\t100\t0\t2\terror\tapply\t10\n"
	s.files["/proc/123/cmdline"] = "/usr/sbin/8311-vlansd.sh\0"
	controller.action_vlan_status()
	assert(s.json.message:find("application failed", 1, true) and s.json.retry_in == 10)
	assert(not s.json.output and not s.json.hook)
	s.files["/tmp/8311-vlans.status"] = "123\t100\t0\tunknown\terror\tconfiguration\t0\n"
	controller.action_vlan_status()
	assert(s.json.message == "The VLAN mode is invalid.")
end)

check("management masks require contiguous bits in saves and recovery", function()
	local s, tools, controller = setup()
	local categories = controller.fwenvs_8311()
	local field
	for _, category in ipairs(categories) do
		for _, item in ipairs(category.items) do if item.id == "netmask" then field = item end end
	end
	assert(field)
	for prefix = 0, 32 do
		local octets = {}
		for index = 0, 3 do
			local bits = math.min(8, math.max(0, prefix - index * 8))
			octets[#octets + 1] = tostring(256 - 2 ^ (8 - bits))
		end
		local mask = table.concat(octets, ".")
		assert(tools.validate_config_value(field, mask), mask)
	end
	local recovery = require "8311.recovery"
	for _, mask in ipairs({ "255.0.255.0", "255.255.253.0", "128.128.0.0", "0.0.0.1", "255.255.255.256" }) do
		assert(not tools.validate_config_value(field, mask), mask)
		assert(not recovery.plan("8311_netmask=" .. mask .. "\n", categories, {}, false, false, ""), mask)
	end
	assert(recovery.plan("8311_netmask=255.255.254.0\n", categories, {}, false, false, ""))
	controller.populate_8311_fwenvs = function() return {{ items = { field } }} end
	tools.fwenv_set = function() error("Invalid mask reached the writer") end
	s.form = { netmask = "255.0.255.0" }
	controller.action_save()
	assert(s.status == 400 and s.json.errors.netmask)
end)

check("all fields are validated before the first configuration write", function()
	local s, tools, controller = setup()
	controller.populate_8311_fwenvs = function() return {{ items = {
		{ id = "loid", type = "text", value = "old" },
		{ id = "internet_vlan", type = "number", min = 0, max = 4095, value = "0" },
	} }} end
	local writes = 0
	tools.fwenv_set = function() writes = writes + 1; return true end
	s.form = { loid = "new", internet_vlan = "4096" }
	controller.action_save()
	assert(s.status == 400 and writes == 0 and s.json.errors.internet_vlan)
end)

check("configuration errors stop later writes and cannot report success", function()
	local s, tools, controller = setup()
	controller.populate_8311_fwenvs = function() return {{ items = {
		{ id = "loid", type = "text", value = "old" },
		{ id = "lpwd", type = "text", value = "old" },
	} }} end
	local writes = 0
	tools.fwenv_set = function() writes = writes + 1; return false end
	s.form = { loid = "new", lpwd = "new" }
	controller.action_save()
	assert(s.status == 500 and not s.json.success and writes == 1)
end)

check("configuration saves serialize and report confirmed fields on partial failure", function()
	local s, tools, controller = setup()
	controller.populate_8311_fwenvs = function() return {{ items = {
		{ id = "loid", name = "LOID", type = "text", value = "old" },
		{ id = "lpwd", type = "text", value = "old" },
		{ id = "internet_vlan", type = "number", value = "0", min = 0, max = 4095 },
	} }} end
	local writes = 0
	tools.fwenv_set = function() writes = writes + 1; return writes == 1 end
	s.form = { loid = "new", lpwd = "new", internet_vlan = "100" }
	s.busy_lock = true
	controller.action_save()
	assert(s.status == 409 and writes == 0 and s.closed == 1)
	s.busy_lock = false
	controller.action_save()
	assert(s.status == 500 and writes == 2 and s.closed == 2)
	assert(s.json.saved[1] == "loid" and #s.json.saved == 1)
	assert(s.json.pending[1] == "internet_vlan" and s.json.field == "lpwd")
	assert(s.json.failed_stage == "write" and s.json.message:find("LOID", 1, true))
	assert(not s.files["/tmp/8311-vlans.reload"])
	tools.fwenv_set = function() error("injected write failure") end
	controller.action_save()
	assert(s.status == 500 and s.closed == 3 and not s.json.success)
end)

check("unchanged defaults avoid flash writes and changed VLANs notify the daemon", function()
	local s, tools, controller = setup()
	controller.populate_8311_fwenvs = function() return {{ items = {
		{ id = "pingd", type = "checkbox", default = true, value = "" },
		{ id = "internet_vlan", type = "number", min = 0, max = 4095, default = "0", value = "" },
	} }} end
	local writes = {}
	tools.fwenv_set = function(key, value) table.insert(writes, {key, value}); return true end
	s.form = { pingd = "1", internet_vlan = "0" }
	controller.action_save()
	assert(s.json.success and #writes == 0 and #s.writes == 0)
	s.form.internet_vlan = "100"
	controller.action_save()
	assert(s.json.success and #writes == 1 and writes[1][1] == "internet_vlan" and writes[1][2] == "100")
	assert(s.files["/tmp/8311-vlans.reload"])
end)

check("configuration exposes unconfirmed and untouched fields after a readback failure", function()
	local s, tools, controller = setup()
	controller.populate_8311_fwenvs = function() return {{items={
		{id="hostname", value="old", type="text"}, {id="lpwd", value="old", type="text"}
	}}} end
	s.form = {hostname="new", lpwd="new"}
	local writes=0
	tools.fwenv_set=function() writes=writes+1; return false, "verify", "timeout" end
	controller.action_save()
	assert(writes==1 and s.status==500 and s.json.failed_stage=="verify" and s.json.verify_reason=="timeout")
	assert(#s.json.saved==0 and s.json.unconfirmed[1]=="hostname" and s.json.pending[1]=="lpwd")
end)

check("configuration and hook mutations reject GET and missing hook content", function()
	local s, _, controller = setup()
	s.method = "GET"
	controller.action_save()
	assert(s.status == 405)
	controller.action_save_hook_script()
	assert(s.status == 405 and #s.writes == 0)
	s.method = "POST"
	controller.action_save_hook_script()
	assert(s.status == 400 and #s.writes == 0)
end)

check("hook writes are atomic and failed writes, syntax checks or renames preserve the old script", function()
	for _, failure in ipairs({ "fail_write", "fail_chmod", "fail_rename", "call_code" }) do
		local s, _, controller = setup()
		local path = "/ptconf/8311/vlan_fixes_hook.sh"
		s.files[path] = "old hook"
		s[failure] = failure == "call_code" and 1 or true
		s.form = { content = "echo new\n" }
		controller.action_save_hook_script()
		assert(s.status == 500 and not s.json.success and s.files[path] == "old hook")
		assert(not s.files["/tmp/8311-vlans.reload"])
	end
	local s, _, controller = setup()
	s.short_stream_write = true
	s.form = { content = "echo new\n" }
	controller.action_save_hook_script()
	assert(s.json.success and s.files["/ptconf/8311/vlan_fixes_hook.sh"] == "echo new\n")
	assert(s.files["/tmp/8311-vlans.reload"])
end)

check("VLAN display runs only the two required decoders", function()
	local s, _, controller = setup()
	controller.action_vlan_extvlans()
	assert(#s.processes == 2 and #s.calls == 0)
end)

check("diagnostic failures discard partial data and reject invalid identifiers", function()
	for _, action in ipairs({ "action_pontop", "action_vlan_extvlans", "action_pon_explorer", "action_pon_dump" }) do
		local s, _, controller = setup()
		s.process_code, s.process_output = 124, "incomplete diagnostic data"
		if action == "action_pon_dump" then controller[action]("256", "0") else controller[action]() end
		assert(s.status == 503 and s.text == "" and not s.render, action)
		assert(s.processes[1][1] == "/usr/bin/timeout")
	end
	local s, _, controller = setup()
	controller.action_pon_dump("65536", "0")
	controller.action_pon_dump("256", "-1")
	controller.action_pon_dump("256", nil)
	assert(s.status == 400 and #s.processes == 0)
	s.process_output = string.rep("x", 131073)
	controller.action_pon_dump("256", "0")
	assert(s.status == 503 and s.text == "")
end)

check("hook reads stay bounded and unreadable files cannot appear empty", function()
	local s, _, controller = setup()
	s.files["/ptconf/8311/vlan_fixes_hook.sh"] = string.rep("x", 65537)
	controller.action_get_hook_script()
	assert(s.status == 503 and s.text == "" and s.headers["Cache-Control"] == "no-store")
	s.files["/ptconf/8311/vlan_fixes_hook.sh"] = nil
	s.fail_lstat = true
	controller.action_get_hook_script()
	assert(s.status == 503 and s.text == "")
end)

local staged_firmware = "/tmp/8311-web-upgrade/" .. string.rep("a", 32) .. ".tar"

check("firmware GET cannot install, cancel, switch banks or reboot", function()
	for _, action in ipairs({ "install", "install_reboot", "switch_reboot", "cancel", "reboot", "commit" }) do
		local s, _, controller = setup()
		s.method, s.form = "GET", { action = action, firmware_file = "ignored" }
		s.files[staged_firmware] = "existing firmware"
		controller.action_firmware()
		assert(#s.processes == 0 and not s.rebooted and not s.upload_handled)
		assert(s.files[staged_firmware] == "existing firmware" and s.closed == 0)
	end
end)

check("firmware checks the body limit, token, action and session before mutations", function()
	local s, _, controller = setup()
	s.form = { action = "switch_reboot" }
	controller.action_firmware()
	assert(s.status == 403 and #s.processes == 0 and not s.rebooted and s.closed == 0)
	s.security_checked = false
	s.content_length = tostring(128 * 1024 * 1024 + 65537)
	controller.action_firmware()
	assert(s.status == 413 and not s.security_checked and not s.upload_handled)
	s.content_length = ""
	controller.action_firmware()
	assert(s.status == 411)
	s.content_length = "1024"
	s.form = { token = "fixture-token", action = { "install", "cancel" } }
	controller.action_firmware()
	assert(s.status == 400 and #s.processes == 0)
	s.form.action = "install"
	package.loaded["luci.dispatcher"].context.authsession = "../../outside"
	controller.action_firmware()
	assert(s.status == 403 and #s.processes == 0 and s.closed == 0)
end)

check("firmware uploads handle unrelated fields, short writes and atomic promotion", function()
	local s, _, controller = setup()
	s.form = { action = "validate", token = "fixture-token", firmware_file = "upload.tar" }
	s.short_write = true
	s.upload = function(callback)
		callback({ name = "other" }, "ignored", true)
		local meta = { name = "firmware_file" }
		callback(meta, "firm", false)
		callback(meta, "ware", true)
	end
	controller.action_firmware()
	assert(s.status == 200 and s.files[staged_firmware] == "firmware")
	assert(not s.files[staged_firmware .. ".incoming.123"] and s.closed == 2)
	assert(#s.processes == 1 and s.processes[1][2] == "--validate")
	assert(s.processes[1][3] == staged_firmware and s.render.firmware_file_exists)
end)

check("upload resource prechecks precede multipart parsing and copying", function()
	local s, _, controller = setup()
	s.space_code=1
	s.content_length="1048576"
	s.form={action="validate", token="fixture-token", firmware_file="upload.tar"}
	controller.action_firmware()
	assert(s.status==503 and not s.security_checked and not s.upload_handled and #s.writes==0)
	s.content_length="1024"
	controller.action_firmware()
	assert(s.status==500 and s.security_checked and not s.upload_handled and not s.files[staged_firmware])
end)

check("failed or incomplete uploads preserve the existing file and never validate partial bytes", function()
	for _, failure in ipairs({ "fail_write", "fail_rename", "incomplete", "duplicate", "exception", "fail_chmod" }) do
		local s, _, controller = setup()
		s.files[staged_firmware] = "old firmware"
		s.form = { action = "validate", token = "fixture-token", firmware_file = "new.tar" }
		s[failure] = true
		s.upload = function(callback)
			if failure == "exception" then error("injected multipart failure") end
			local meta = { name = "firmware_file" }
			callback(meta, "new", failure ~= "incomplete")
			if failure == "duplicate" then callback({ name = "firmware_file" }, "other", true) end
		end
		controller.action_firmware()
		assert(s.status == 500 and #s.processes == 0 and s.files[staged_firmware] == "old firmware", failure)
		assert(not s.files[staged_firmware .. ".incoming.123"], failure)
	end
end)

check("firmware rejects oversized streamed bytes even with a smaller declared request", function()
	local s, _, controller = setup()
	s.form = { action = "validate", token = "fixture-token", firmware_file = "large.tar" }
	s.discard_writes = true
	s.upload = function(callback)
		local meta, block = { name = "firmware_file" }, string.rep("x", 1024 * 1024)
		for i = 1, 129 do callback(meta, block, i == 129) end
	end
	controller.action_firmware()
	assert(s.status == 500 and #s.processes == 0 and not s.files[staged_firmware])
	assert(not s.files[staged_firmware .. ".incoming.123"] and s.closed == 2)
end)

check("firmware operations serialize and cancellation is scoped to the login session", function()
	local s, _, controller = setup()
	local other = "/tmp/8311-web-upgrade/" .. string.rep("b", 32) .. ".tar"
	s.files[staged_firmware], s.files[other] = "first", "other"
	s.form = { action = "cancel", token = "fixture-token" }
	s.busy_lock = true
	controller.action_firmware()
	assert(s.status == 409 and s.files[staged_firmware] == "first")
	s.busy_lock = false
	controller.action_firmware()
	assert(not s.files[staged_firmware] and s.files[other] == "other" and #s.processes == 0)
end)

check("failed installation preserves evidence and only successful installation clears cached metadata", function()
	local s, _, controller = setup()
	s.files[staged_firmware], s.files["/tmp/8311-alt-firmware"] = "firmware", "old metadata"
	s.files["/proc/cmdline"] = "rootfsname=rootfsA"
	s.form = { action = "install", token = "fixture-token" }
	s.process_code = 1
	controller.action_firmware()
	assert(s.status == 500 and not s.render.firmware_installed)
	assert(s.files[staged_firmware] and s.files["/tmp/8311-alt-firmware"])
	s.process_code = 0
	controller.action_firmware()
	assert(s.render.firmware_installed and not s.files[staged_firmware] and not s.files["/tmp/8311-alt-firmware"])
	assert(s.processes[2][2] == "--yes" and s.processes[2][3] == "--install" and not s.rebooted)
end)

check("bank switching delegates a guarded trial instead of changing the default in LuCI", function()
	local s, tools, controller = setup()
	s.form = { action = "switch_reboot", token = "fixture-token" }
	local writes = 0
	tools.fw_setenv = function() writes = writes + 1; return true end
	controller.action_firmware()
	assert(not s.rebooted and writes == 0 and #s.processes == 0)
	s.files["/proc/cmdline"] = "rootfsname=rootfsA"
	s.process_code = 1
	controller.action_firmware()
	assert(s.status == 500 and writes == 0 and #s.processes == 1)
	s.process_code = 0
	controller.action_firmware()
	assert(s.render.firmware_exec.code == 0 and writes == 0)
	assert(s.processes[2][1] == "/usr/sbin/8311-bankctl.sh" and s.processes[2][2] == "trial" and s.processes[2][3] == "B")
end)

check("an empty inactive bank cannot be selected even when its environment flag says valid", function()
	local s, tools, controller = setup()
	s.files["/proc/cmdline"] = "rootfsname=rootfsA"
	s.form = { action = "switch_reboot", token = "fixture-token" }
	local writes = 0
	tools.bank_available = function() return false end
	tools.fw_setenv = function() writes = writes + 1; return true end
	controller.action_firmware()
	assert(writes == 0 and not s.rebooted and s.status == 500, "empty bank was selected")
end)

check("web installation keeps the default bank and explicit trial requests carry the trial option", function()
	for _, action in ipairs({ "install", "install_reboot" }) do
		local s, _, controller = setup()
		s.files[staged_firmware] = "firmware"
		s.files["/proc/cmdline"] = "rootfsname=rootfsA"
		s.form = { action = action, token = "fixture-token" }
		controller.action_firmware()
		local command = table.concat(s.processes[1], " ")
		assert(command:find("--no-commit", 1, true))
		assert((command:find("--trial", 1, true) ~= nil) == (action == "install_reboot"))
	end
end)

check("support generation and deletion cannot bypass POST and token checks", function()
	local s, _, controller = setup()
	controller.file_exists = function(path) return s.files[path] ~= nil end
	s.files["/tmp/support.tar.gz"] = "existing"
	s.method, s.form = "GET", { action = "delete" }
	controller.action_support()
	assert(s.files["/tmp/support.tar.gz"] == "existing")
	s.method = "POST"
	s.form.action = "generate"
	controller.action_support()
	assert(s.status == 403 and #s.processes == 0)
	s.form.token = "fixture-token"
	controller.action_support()
	assert(#s.processes == 1 and #s.processes[1] == 1)
	s.form.action = "delete"
	controller.action_support()
	assert(s.processes[2][1] == "/usr/sbin/8311-support.sh" and s.processes[2][2] == "--delete")
end)

local function recovery_fixture()
	local s, tools, controller = setup()
	controller.fwenvs_8311 = function() return {
		{ id = "pon", items = {
			{ id = "gpon_sn", name = "PON serial", type = "text", pattern = "^[A-Z]{4}[A-F0-9]{8}$", required = true },
			{ id = "loid", name = "LOID", type = "text", maxlength = 24 },
			{ id = "fw_match_b64", type = "text", base64 = true, maxlength = 30 },
		} },
		{ id = "device", items = {
			{ id = "hostname", name = "Hostname", type = "text", maxlength = 100 },
			{ id = "persist_root", type = "checkbox" },
			{ id = "bootdelay", type = "number", base = true },
		} },
		{ id = "isp", items = { { id = "internet_vlan", name = "Internet VLAN", type = "number", min = 0, max = 4095 } } },
		{ id = "manage", items = { { id = "pingd", type = "checkbox" } } },
	} end
	s.environment = "bootcmd=never change\n8311_hostname=old\n8311_loid=secret-identity\n8311_internet_vlan=41\n"
	s.form = { token = "fixture-token", action = "preview", preserve_pon = "1",
		content = "8311_hostname=new\n8311_loid=other-identity\n" }
	s.env_writes = {}
	tools.fwenv_set = function(id, value, prefixed)
		assert(prefixed)
		if id == s.fail_env then return false end
		table.insert(s.env_writes, { id = id, value = value })
		return true
	end
	return s, tools, controller
end

check("recovery requires POST, bounded body, token, allowlisted action and confirmation", function()
	local s, _, controller = recovery_fixture()
	s.method = "GET"
	controller.action_recovery()
	assert(s.status == 405 and #s.env_writes == 0 and #s.processes == 0)
	s.method, s.content_length, s.security_checked = "POST", "999999", false
	controller.action_recovery()
	assert(s.status == 413 and not s.security_checked)
	s.content_length, s.form.token = "1024", nil
	controller.action_recovery()
	assert(s.status == 403)
	s.form.token, s.form.action = "fixture-token", "reset"
	controller.action_recovery()
	assert(s.status == 400 and #s.env_writes == 0 and #s.processes == 0)
	s.form.confirm, s.form.preserve_pon = "1", { "0", "1" }
	controller.action_recovery()
	assert(s.status == 400 and #s.env_writes == 0)
end)

check("recovery preview lists changes without values or writes and keeps PON by default", function()
	local s, _, controller = recovery_fixture()
	s.form.preserve_pon = nil
	controller.action_recovery()
	assert(s.status == 200 and s.json.success and s.json.count == 1 and s.json.skipped == 1)
	assert(s.json.names[1] == "Hostname" and not s.json.content and #s.env_writes == 0)
	assert(s.closed == 2 and not s.rebooted)
	s.form.action, s.form.confirm = "restore", "1"
	controller.action_recovery()
	assert(s.json.success and #s.env_writes == 1 and s.env_writes[1].id == "hostname")
	assert(s.env_writes[1].value == "new" and not s.rebooted and s.json.reboot_required)
end)

check("invalid recovery files fail in full before the first write", function()
	for _, invalid in ipairs({
		"8311_hostname=new\nbootcmd=bad\n", "8311_bootdelay=0\n", "8311_uvlan=41\n",
		"8311_hostname=one\n8311_hostname=two\n", "8311_internet_vlan=4096\n",
		"8311_pingd=on\n", "8311_hostname=bad\0data\n", "#!/bin/sh\necho bad\n",
		"8311_hostname=" .. string.rep("x", 101), "8311_persist_root=1\n",
		"8311_fw_match_b64=invalid\n", string.rep("x", 131073), "# empty\n",
	}) do
		local s, _, controller = recovery_fixture()
		s.form.action, s.form.confirm, s.form.content = "restore", "1", invalid
		controller.action_recovery()
		assert(s.status == 400 and not s.json.success and #s.env_writes == 0 and not s.rebooted, invalid:sub(1, 50))
	end
end)

check("recovery accepts CRLF, canonical encoded values and empty overrides with explicit PON replacement", function()
	local s, _, controller = recovery_fixture()
	s.form.action, s.form.confirm, s.form.preserve_pon = "restore", "1", "0"
	s.form.content = "# 8311 backup\r\n8311_gpon_sn=TEST1234ABCD\r\n8311_fw_match_b64=Zml4dHVyZQ==\r\n8311_hostname=\r\n"
	controller.action_recovery()
	assert(s.json.success and #s.env_writes == 3)
	assert(s.env_writes[1].id == "gpon_sn" and s.env_writes[2].value == "Zml4dHVyZQ==" and s.env_writes[3].value == "")
end)

check("reset preserves PON and bootloader, clears only known overrides and removes the VLAN hook", function()
	local s, _, controller = recovery_fixture()
	s.form.action, s.form.confirm = "reset", "1"
	s.files["/ptconf/8311/vlan_fixes_hook.sh"] = "fixture hook"
	s.files["/ptconf/factory-calibration"] = "calibration fixture"
	controller.action_recovery()
	assert(s.json.success and #s.env_writes == 2 and s.json.reboot_required)
	assert(s.env_writes[1].id == "hostname" and s.env_writes[2].id == "internet_vlan")
	assert(s.env_writes[1].value == "" and not s.files["/ptconf/8311/vlan_fixes_hook.sh"])
	assert(s.files["/ptconf/factory-calibration"] == "calibration fixture" and not s.rebooted)
end)

check("recovery read failures, persistent RootFS and busy locks make no configuration writes", function()
	for _, failure in ipairs({ "read", "persistent", "busy" }) do
		local s, _, controller = recovery_fixture()
		s.form.action, s.form.confirm = "reset", "1"
		if failure == "read" then s.env_read_code = 1
		elseif failure == "persistent" then s.environment = s.environment .. "8311_persist_root=1\n"
		else s.busy_lock = true end
		controller.action_recovery()
		assert(s.status >= 400 and #s.env_writes == 0 and not s.rebooted, failure)
	end
end)

check("the full reset mode also clears PON overrides but never touches firmware selection", function()
	local s, _, controller = recovery_fixture()
	s.form.action, s.form.confirm, s.form.preserve_pon = "reset", "1", "0"
	s.environment = s.environment .. "commit_bank=A\n8311_gpon_sn=TEST1234ABCD\n"
	controller.action_recovery()
	assert(s.json.success and #s.env_writes == 4 and not s.rebooted)
	for _, write in ipairs(s.env_writes) do
		assert(write.value == "" and write.id ~= "commit_bank" and write.id ~= "bootcmd")
	end
	assert(s.env_writes[1].id == "gpon_sn" and s.env_writes[2].id == "loid")
end)

check("partial recovery failure reports confirmed writes and leaves the hook and reboot alone", function()
	local s, _, controller = recovery_fixture()
	s.form.action, s.form.confirm = "reset", "1"
	s.fail_env = "internet_vlan"
	s.files["/ptconf/8311/vlan_fixes_hook.sh"] = "keep on failure"
	controller.action_recovery()
	assert(s.status == 500 and not s.json.success and s.json.field == "internet_vlan")
	assert(#s.json.saved == 1 and s.json.saved[1] == "hostname" and s.closed == 2)
	assert(s.files["/ptconf/8311/vlan_fixes_hook.sh"] == "keep on failure" and not s.rebooted)
end)

check("hook edits respect the configuration lock held by recovery", function()
	local s, _, controller = setup()
	s.files["/ptconf/8311/vlan_fixes_hook.sh"] = "old script"
	s.form, s.busy_lock = { content = "echo new\n" }, true
	controller.action_save_hook_script()
	assert(s.status == 409 and s.files["/ptconf/8311/vlan_fixes_hook.sh"] == "old script")
	assert(not s.files["/tmp/8311-vlans.reload"] and s.closed == 1)
end)

check("backup is a private authenticated download and never includes bootloader variables", function()
	local s, _, controller = recovery_fixture()
	s.form = { action = "backup", token = "fixture-token" }
	s.method = "GET"
	controller.action_recovery()
	assert(s.status == 405 and s.text == "")
	s.method, s.form.token = "POST", nil
	controller.action_recovery()
	assert(s.status == 403 and s.text == "")
	s.form.token = "fixture-token"
	controller.action_recovery()
	assert(s.status == 200 and s.content_type == "text/plain; charset=utf-8")
	assert(s.parse_limit == 3 * 131072 + 8192 and require("luci.http").HTTP_MAX_CONTENT == 102400)
	assert(s.headers["Cache-Control"] == "no-store" and s.headers["Content-Disposition"]:find("attachment", 1, true))
	assert(s.text:find("8311_loid=secret-identity\n", 1, true) and s.text:find("8311_pingd=\n", 1, true))
	assert(not s.text:find("bootcmd", 1, true) and not s.text:find("bootdelay", 1, true))
	assert(#s.env_writes == 0 and not s.rebooted)
end)

check("a generated backup restores credentials, defaults and the exact multiline VLAN hook", function()
	local s, _, controller = recovery_fixture()
	local path = "/ptconf/8311/vlan_fixes_hook.sh"
	local hook = "#!/bin/sh\nprintf '%s\\n' 'fixture hook'\n"
	s.files[path] = hook
	s.form = { action = "backup", token = "fixture-token" }
	controller.action_recovery()
	assert(s.status == 200 and s.files[path] == hook and not s.files[path .. ".restore.123"])
	for name in pairs(s.directories) do assert(not name:match("^/ptconf/"), "backup touched persistent storage") end
	for _, call in ipairs(s.calls) do assert(not call:find("/ptconf/", 1, true), "backup staged its hook in flash") end
	local backup = s.text
	local recovery = require "8311.recovery"
	local current = { hostname = "old", loid = "secret-identity", internet_vlan = "41" }
	local unchanged = assert(recovery.plan(backup, controller.fwenvs_8311(), current, false, false, hook))
	assert(#unchanged.changes == 0 and not unchanged.hook_changed)
	s.environment = "bootcmd=never change\n8311_hostname=changed\n8311_loid=changed\n8311_pingd=1\n"
	s.files[path] = "# newer hook\n"
	s.form = { action = "preview", token = "fixture-token", preserve_pon = "0", content = backup }
	controller.action_recovery()
	assert(s.json.success and s.json.count == 5 and s.json.hook_script and #s.env_writes == 0)
	for name in pairs(s.directories) do assert(not name:match("^/ptconf/"), "preview touched persistent storage") end
	assert(s.files[path] == "# newer hook\n" and not s.files[path .. ".restore.123"])
	s.form.action, s.form.confirm = "restore", "1"
	controller.action_recovery()
	assert(s.json.success and #s.env_writes == 4 and s.files[path] == hook and not s.rebooted)
	assert(s.env_writes[1].id == "loid" and s.env_writes[1].value == "secret-identity")
	assert(s.env_writes[4].id == "pingd" and s.env_writes[4].value == "")
	assert(not s.files[path .. ".restore.123"])
end)

check("hook validation fails before settings writes and staged files are removed after partial failure", function()
	for _, failure in ipairs({ "encoding", "syntax", "write", "environment" }) do
		local s, _, controller = recovery_fixture()
		local path = "/ptconf/8311/vlan_fixes_hook.sh"
		s.files[path] = "# original\n"
		s.form.action, s.form.confirm = "restore", "1"
		s.form.content = "8311_hostname=new\n8311_backup_hook_b64=" .. real_base64.enc("# replacement\n") .. "\n"
		if failure == "encoding" then s.form.content = "8311_backup_hook_b64=invalid!\n"
		elseif failure == "syntax" then s.call_code = 1
		elseif failure == "write" then s.fail_write = true
		else s.fail_env = "hostname" end
		controller.action_recovery()
		assert(s.status >= 400 and #s.env_writes == 0 and not s.rebooted, failure)
		assert(s.files[path] == "# original\n" and not s.files[path .. ".restore.123"], failure)
	end
end)

check("backup read failures return no partial file and omitted legacy hooks remain unchanged", function()
	local s, _, controller = recovery_fixture()
	s.form = { action = "backup", token = "fixture-token" }
	s.env_read_code = 1
	controller.action_recovery()
	assert(s.status == 503 and s.text == "" and not s.headers["Content-Disposition"])
	s.env_read_code = 0
	s.environment = s.environment .. "8311_pingd=invalid\n"
	controller.action_recovery()
	assert(s.status == 400 and s.text == "")
	s.environment = "8311_hostname=old\n"
	s.files["/ptconf/8311/vlan_fixes_hook.sh"] = "# retain\n"
	s.form = { action = "restore", token = "fixture-token", confirm = "1", content = "8311_hostname=new\n" }
	controller.action_recovery()
	assert(s.json.success and s.files["/ptconf/8311/vlan_fixes_hook.sh"] == "# retain\n")
end)

print(string.format("%d Lua regression groups passed", passed))
