local require = require
local string = string
local setmetatable = setmetatable
local tonumber = tonumber
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local type = type

module "8311.tools"

local util = require "luci.util"
local sys = require "luci.sys"
local math = require "math"
local fs = require "nixio.fs"
local nixio = require "nixio"
local bit = require "nixio.bit"
local table = require "table"

function html_escape(text)
	if text == nil then text = "" end
	text = "" .. text

	return (text:gsub("[&<>\"']", {
		["&"] = "&amp;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		['"'] = "&quot;",
		["'"] = "&#039;"
	}))
end

function nl2br(text)
	if text == nil then text = "" end
	return string.gsub("" .. text, "\n", "<br />\n")
end

function fw_getenv(t)
	setmetatable(t, {__index={key=nil, default=nil, base64=false}})

	return fwenv_get(
		t[1] or t.key,
		t[2] or t.default,
		false,
		t[3] or t.base64
	)
end

function fw_getenv_8311(t)
	setmetatable(t, {__index={key=nil, default=nil, base64=false}})

	return fwenv_get(
		t[1] or t.key,
		t[2] or t.default,
		true,
		t[3] or t.base64
	)
end

function fwenv_get(key, default, _8311, base64)
	if not key then return false end

	local _8311_arg, base64_arg, default_arg = "", "", ""
	if _8311 then _8311_arg = "--8311 " end
	if base64 then base64_arg = "--base64 " end
	if default then default_arg = " " .. util.shellquote(default) end

	return string.gsub(util.exec("fwenv_get " .. _8311_arg .. base64_arg .. util.shellquote(key) .. default_arg), '[\r\n]+$', "")
end

function fw_getenvs_8311()
	local fwenvs = {}
	for k, v in string.gmatch(util.exec('echo ; fw_printenv | grep "^8311_"'), '\n8311_([^\n=]+)=([^\r\n]+)') do
		fwenvs[k] = v
	end

	return fwenvs
end

function fw_setenv(t)
	setmetatable(t, {__index={key=nil, value=nil, base64=false}})

	return fwenv_set(
		t[1] or t.key,
		t[2] or t.value,
		false,
		t[3] or t.base64
	)
end

function fw_setenv_8311(t)
	setmetatable(t, {__index={key=nil, value=nil, base64=false}})

	return fwenv_set(
		t[1] or t.key,
		t[2] or t.value,
		true,
		t[3] or t.base64
	)
end

function fwenv_set(key, value, _8311, base64)
	if not key then return false end

	local _8311_arg, base64_arg = "", ""
	if _8311 then _8311_arg = "--8311 " end
	if base64 then base64_arg = "--base64 " end

	if sys.call("fwenv_set " .. _8311_arg .. base64_arg .. "-- " .. util.shellquote(key) .. " " .. util.shellquote(value or "")) ~= 0 then
		return false
	end
	return fwenv_get(key, nil, _8311, base64) == (value or "")
end

function request_vlan_reload()
	return fs.writefile("/tmp/8311-vlans.reload", "\n") == 1
end

-- The same field definitions supply the HTML constraints and server checks.
-- PCRE patterns remain PCRE; Lua patterns have different syntax.
function validate_config_value(item, value)
	if type(value) ~= "string" or value:find("[%z\1-\31\127]") then
		return false, "Enter a single-line value."
	end
	if value == "" then
		return not item.required, "This field is required."
	end
	if item.maxlength and #value > tonumber(item.maxlength) then
		return false, "Value exceeds the maximum length."
	end
	if item.type == "checkbox" or item.type == "checkbox_onoff" then
		return value == "0" or value == "1", "Invalid checkbox value."
	elseif item.type == "number" then
		local n = tonumber(value)
		if not value:match("^%d+$") or not n or
			(item.min and n < item.min) or (item.max and n > item.max) then
			return false, "Enter an integer within the allowed range."
		end
	elseif item.type == "select" or item.type == "select_named" then
		for _, option in ipairs(item.options) do
			if value == (type(option) == "table" and option.value or option) then
				return true
			end
		end
		return false, "Select one of the available options."
	end
	if item.pattern and sys.call("printf '%s\\n' " .. util.shellquote(value) ..
		" | /usr/bin/pcre2grep -q -x -- " .. util.shellquote(item.pattern)) ~= 0 then
		return false, "Value does not match the required format."
	end
	return true
end

function number_format(number, decimals)
	return string.format("%." .. decimals .."f", number)
end

metric_names = {
	"cpu1_tempC", "cpu2_tempC", "module_voltage", "optic_tempC",
	"ploam_state", "rx_power_dBm", "tx_bias_mA", "tx_power_dBm"
}

function is_finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function read_eeprom_metrics()
	local path = "/sys/class/pon_mbox/pon_mbox0/device/eeprom51"
	local fd = nixio.open(path, "r")
	if not fd then return nil end
	local positioned = fd:seek(96, "set") == 96
	local data = positioned and fd:read(10) or nil
	fd:close()
	-- Older drivers may not support seeking a sysfs binary attribute.
	if not positioned then
		local prefix = fs.readfile(path, 106)
		data = prefix and #prefix == 106 and prefix:sub(97) or nil
	end
	return data and #data == 10 and data or nil
end

function active_bank()
	return (" " .. (fs.readfile("/proc/cmdline") or "") .. " "):match("%srootfsname=rootfs([AB])%s")
end

function module_type()
	local cached = util.trim(fs.readfile("/tmp/8311-module-type", 32) or "")
	if cached:match("^[%w_-]+$") then return cached end
	local detected = util.trim(util.exec("timeout -k 1 2 /bin/sh -c '. /lib/8311.sh && get_8311_module_type'"))
	return detected:match("^[%w_-]+$") and detected or nil
end

function metrics()
	local ploam_status = util.exec("timeout -k 1 2 pon psg"):match("current=(%d+)")
	local cpu1_temp = tonumber(fs.readfile("/sys/class/thermal/thermal_zone0/temp") or "")
	local cpu2_temp = tonumber(fs.readfile("/sys/class/thermal/thermal_zone1/temp") or "")
	local result = {
		ploam_state = tonumber(ploam_status),
		cpu1_tempC = cpu1_temp and cpu1_temp / 1000,
		cpu2_tempC = cpu2_temp and cpu2_temp / 1000,
	}
	local eep51 = read_eeprom_metrics()
	if eep51 then
		local function word(offset)
			return bit.lshift(eep51:byte(offset), 8) + eep51:byte(offset + 1)
		end
		-- SFF-8472 temperature is a signed, two's-complement Q8.8 value.
		local temp = word(1)
		if temp >= 32768 then temp = temp - 65536 end
		result.optic_tempC = temp / 256
		result.module_voltage = word(3) / 10000
		result.tx_bias_mA = word(5) / 500
		local tx_mw, rx_mw = word(7) / 10000, word(9) / 10000
		-- Zero optical power has no finite dBm representation.
		if tx_mw > 0 then result.tx_power_dBm = 10 * math.log10(tx_mw) end
		if rx_mw > 0 then result.rx_power_dBm = 10 * math.log10(rx_mw) end
	end
	result.sample_valid = true
	for _, name in ipairs(metric_names) do
		if not is_finite(result[name]) then
			result[name] = nil
			result.sample_valid = false
		end
	end
	return result
end

function sorted_keys(t)
	local tkeys = {}
	-- populate the table that holds the keys
	for k in pairs(t) do table.insert(tkeys, k) end
	-- sort the keys
	table.sort(tkeys)

	return tkeys
end

function iterator2array(...)
	local arr = {}
	for v in ... do
		table.insert(arr, v)
	end
	return arr
end
