module("luci.controller.8311", package.seeall)

local tools = require "8311.tools"
local util = require "luci.util"
local ltemplate = require "luci.template"
local http = require "luci.http"
local formvalue = http.formvalue
local dispatcher = require "luci.dispatcher"
local sys = require "luci.sys"
local i18n = require "luci.i18n"
local translate = i18n.translate
local base64 = require "base64"
local ltn12 = require "luci.ltn12"
local fs = require "nixio.fs"
local nixio = require "nixio"
local bit = require "nixio.bit"
local uci = require "luci.model.uci"
local support_file = "/tmp/support.tar.gz"

local firmwareOutput = ''
local supportOutput = ''
local vlan_status_values

local function acquire_lock(path)
	local fd = nixio.open(path, "w", "rw-------")
	if not fd then return nil, 503 end
	if not fd:lock("tlock") then
		fd:close()
		return nil, 409
	end
	return fd
end

function index()
	entry({"admin", "8311"}, firstchild(), translate("8311"), 99).dependent=false
	entry({"admin", "8311", "config"}, call("action_config"), translate("Configuration"), 1)
	entry({"admin", "8311", "pon_status"}, call("action_pon_status"), translate("PON Status"), 2)
	entry({"admin", "8311", "pon_explorer"}, call("action_pon_explorer"), translate("PON ME Explorer"), 3)
	entry({"admin", "8311", "vlans"}, call("action_vlans"), translate("VLAN Tables"), 4)
	entry({"admin", "8311", "support"}, call("action_support"), translate("Support"), 5)

	entry({"admin", "8311", "save"}, post("action_save"))
	entry({"admin", "8311", "get_hook_script"}, call("action_get_hook_script")).leaf=true
	entry({"admin", "8311", "save_hook_script"}, post("action_save_hook_script")).leaf=true
	entry({"admin", "8311", "vlan_status"}, call("action_vlan_status")).leaf=true
	entry({"admin", "8311", "pontop"}, call("action_pontop")).leaf=true
	entry({"admin", "8311", "pon_dump"}, call("action_pon_dump")).leaf=true
	entry({"admin", "8311", "gpon_status"}, call("action_gpon_status")).leaf = true
	entry({"admin", "8311", "diagnostics"}, call("action_diagnostics")).leaf = true
	entry({"admin", "8311", "vlans", "extvlans"}, call("action_vlan_extvlans"))
	entry({"admin", "8311", "support", "support.tar.gz"}, call("action_support_download"))

	entry({"admin", "system", "flash"}, call("action_firmware"), translate("Backup / Flash Firmware"), 70).dependent=false
	entry({"admin", "system", "flash", "recovery"}, call("action_recovery")).leaf=true
	-- Preserve existing bookmarks while keeping one visible menu entry.
	entry({"admin", "8311", "firmware"}, call("action_firmware"))
	entry({"8311", "metrics"}, call("action_metrics"))
end

function pontop_page_details()
	return {{
			id="status",
			page="Status",
			label=translate("Status")
		},{
			id="cap",
			page="Capability and Configuration",
			label=translate("Capability")
		},{
			id="lan",
			page="LAN Interface Status & Counters",
			label=translate("LAN Info"),
			display=false
		},{
			id="alarms",
			page="Active alarms",
			label=translate("Alarms")
		},{
			id="gem",
			page="GEM/XGEM Port Status",
			label=translate("GEM Status")
		},{
			id="gem_stats",
			page="GEM/XGEM Port Counters",
			label=translate("GEM Stats")
		},{
			id="gem_ds",
			page="GEM/XGEM port DS Counters",
			label=translate("GEM DS"),
			display=false
		},{
			id="gem_us",
			page="GEM/XGEM port US Counters",
			label=translate("GEM US"),
			display=false
		},{
			id="eth_ds",
			page="GEM/XGEM port Eth DS Cnts",
			label=translate("ETH DS Stats"),
		},{
			id="eth_us",
			page="GEM/XGEM port Eth US Cnts",
			label=translate("ETH US Stats")
		},{
			id="fec",
			page="FEC Status & Counters",
			label=translate("FEC Info")
		},{
			id="gtc",
			page="GTC/XGTC Status & Counters",
			label=translate("GTC Info")
		},{
			id="power_save",
			page="Power Save Status",
			label=translate("PS Status")
		},{
			id="psm",
			page="PSM Configuration",
			label=translate("PSM")
		},{
			id="alloc_stats",
			page="Allocation Counters",
			label=translate("Alloc Stats")
		},{
			id="ploam_ds",
			page="PLOAM Downstream Counters",
			label=translate("PLOAM DS")
		},{
			id="ploam_us",
			page="PLOAM Upstream Counters",
			label=translate("PLOAM US")
		},{
			id="optical",
			page="Optical Interface Status",
			label=translate("Optical Status")
		},{
			id="optical_info",
			page="Optical Interface Info",
			label=translate("Optical Info")
		},{
			id="debug_burst",
			page="Debug Burst Profile",
			label=translate("Burst Profile")
		},{
			id="cqm",
			page="CQM ofsc",
			label=translate("CQM")
		},{
			id="cqm_map",
			page="CQM Queue Map",
			label=translate("CQM Q Map")
		},{
			id="datapath_ports",
			page="Datapath Ports",
			label=translate("DP Ports")
		},{
			id="datapath_qos",
			page="Datapath QOS",
			label=translate("DP QoS")
		},{
			id="pp4_buffers",
			page="PPv4 Buffer MGR HW Stats",
			label=translate("PPv4 Buffers")
		},{
			id="pp4_pps",
			page="PPv4 QoS Queue PPS",
			label=translate("PPv4 PPS")
		},{
			id="pp4_stats",
			page="PPv4 QoS Queues Stats",
			label=translate("PPv4 Stats")
		},{
			id="pp4_tree",
			page="PPv4 QoS Tree",
			label=translate("PPv4 Tree")
		},{
			id="pp4_qstats",
			page="PPv4 QoS QStats",
			label=translate("PPv4 QStats")
		}
	}
end


function pontop_pages()
	local details = pontop_page_details()
	local pages = {}
	for _, page in pairs(details) do
		pages[page.id] = page.page
	end

	return pages
end

function language_change(value)
	return sys.call("uci set luci.main.lang=" .. util.shellquote(value ~= "" and value or "auto") .. " && uci commit luci") == 0
end

function fwenvs_8311()
	local zones = util.trim(util.exec("grep -v '^#' /usr/share/zoneinfo/zone.tab  | awk '{print $3}' | sort -uV ; echo UTC"))
	local timezones = {}
	for zone in zones:gmatch("[^\r\n]+") do
		table.insert(timezones, zone)
	end

	local languages = {{
		name="auto",
		value="auto"
	}}
	local langs = util.trim(util.exec("uci show luci.languages | pcre2grep -o1 '^luci\.languages\.([^=]+)='"))
	for lang in langs:gmatch("[^\r\n]+") do
		table.insert(languages, {
			name=util.trim(util.exec("uci get luci.languages." .. util.shellquote(lang))),
			value=lang
		})
	end

	local ipv4_regex = "^((25[0-5]|(2[0-4]|1\\d|[1-9]|)\\d)\\.?\\b){4}$"
	local partial_mask = "(?:254|252|248|240|224|192|128|0)"
	local netmask_regex = "^(?:(?:255\\.){3}(?:255|" .. partial_mask .. ")|" ..
		"(?:255\\.){2}" .. partial_mask .. "\\.0|255\\." .. partial_mask ..
		"\\.0\\.0|" .. partial_mask .. "(?:\\.0){3})$"

	return {{
			id="pon",
			category=translate("PON"),
			items={	{
					id="gpon_sn",
					name=translate("PON Serial Number (ONT ID)"),
					description=translate("GPON Serial Number sent to the OLT in various MEs (4 alphanumeric characters, followed by 8 hex digits)."),
					maxlength=12,
					pattern='^[A-Za-z0-9]{4}[A-F0-9]{8}$',
					type="text",
					required=true
				},{
					id="vendor_id",
					name=translate("Vendor ID"),
					description=translate("PON Vendor ID sent in various MEs, automatically derived from the PON Serial Number if not set (4 alphanumeric characters)."),
					maxlength=4,
					pattern='^[A-Za-z0-9]{4}$',
					type="text"
				},{
					id="equipment_id",
					name=translate("Equipment ID"),
					description=translate("PON Equipment ID field in the ONU2-G ME [257] (up to 20 characters)."),
					maxlength=20,
					type="text"
				},{
					id="hw_ver",
					name=translate("Hardware Version"),
					description=translate("Hardware version string sent in various MEs (up to 14 characters)."),
					maxlength=14,
					type="text"
				},{
					id="cp_hw_ver_sync",
					name=translate("Sync Circuit Pack Version"),
					description=translate("Modify the configured MIB file to set the Version field of any Circuit Pack MEs [6] to match the Hardware Version (if set)."),
					type="checkbox",
					default=false
				},{
					id="sw_verA",
					name=translate("Software Version A"),
					description=translate("Image specific software version sent in the Software image MEs [7] (up to 14 characters)."),
					maxlength=14,
					type="text",
					default=tools.fw_getenv{"img_versionA"}
				},{
					id="sw_verB",
					name=translate("Software Version B"),
					description=translate("Image specific software version sent in the Software image MEs [7] (up to 14 characters)."),
					maxlength=14,
					type="text",
					default=tools.fw_getenv{"img_versionB"}
				},{
					id="fw_match_b64",
					name=translate("Firmware Version Match"),
					description=translate("PCRE pattern match for automatic updating of Software Versions when OLT uploads a firmware upgrade. Must contain a single sub-pattern match."),
					type="text",
					maxlength="255",
					base64=true
				},{
					id="fw_match_num",
					name=translate("Firmware Match Number"),
					description=translate("If there are multiple matches for the Firmware Version Match pattern, use this specific match number."),
					type="number",
					min=1,
					max=99,
					default="1"
				},{
					id="override_active",
					name=translate("Override active firmware bank"),
					description=translate("Override which software bank is marked as active in the Software image MEs [7]."),
					type="select",
					default="",
					options={
						"",
						"A",
						"B"
					}
				},{
					id="override_commit",
					name=translate("Override committed firmware bank"),
					description=translate("Override which software bank is marked as committed in the Software image MEs [7]."),
					type="select",
					default="",
					options={
						"",
						"A",
						"B"
					}
				},{
					id="pon_mode",
					name=translate("PON Mode"),
					description=translate("PON mode of operation. This is where you can choose between XGS-PON (the default) or XG-PON."),
					type="select_named",
					default="xgspon",
					options={
						{
							name="XGS-PON",
							value="xgspon"
						},{
							name="XG-PON",
							value="xgpon"
						}
					}
				},{
					id="omcc_version",
					name=translate("OMCC Version"),
					description=translate("The OMCC version to use in hexadecimal format between 0x80 and 0xBF. Default is 0xA3"),
					type="text",
					default="0xA3",
					maxlength=4,
					pattern='^0x[89AB][0-9A-F]$'
				},{
					id="iop_mask",
					name=translate("OMCI Interoperability Mask"),
					description =
						translate("The OMCI Interoperability Mask is a bitmask of compatibility options for working with various OLTs. The options are:") .. "\n" ..
						translate("1 - Force Unauthorized IGMP/MLD behavior") .. "\n" ..
						translate("2 - Skip Alloc-IDs termination upon T-CONT deactivation") .. "\n" ..
						translate("4 - Drop all packets on default Downstream Extended VLAN rules") .. "\n" ..
						translate("8 - Ignore Downstream Extended VLAN rules priority matching") .. "\n" ..
						translate("16 - Convert Traffic Descriptor PIR/CIR values from kbyte/s to kbit/s") .. "\n" ..
						translate("32 - Force common IP handling - apply the IPv4 Ethertype 0x0800 to the Extended VLAN rule matching for IPv6 packets") .. "\n" ..
						translate("64 - It is unknown what this option does but it appears to affect the message length in omci_msg_send."),
					type="number",
					default="18",
					min=0,
					max=127
				},{
					id="reg_id_hex",
					name=translate("Registration ID (HEX)"),
					description=translate("Registration ID (up to 36 bytes) sent to the OLT, in hex format. This is where you would set a ploam password (which is contained in the last 12 bytes)."),
					maxlength=72,
					pattern='^([A-Fa-f0-9]{2})*$',
					type="text"
				},{
					id="loid",
					name=translate("Logical ONU ID"),
					description=translate("Logical ONU ID presented in the ONU-G ME [256] (up to 24 characters)."),
					maxlength=24,
					type="text"
				},{
					id="lpwd",
					name=translate("Logical Password"),
					description=translate("Logical Password presented in the ONU-G ME [256] (up to 12 characters)."),
					maxlength=12,
					type="text"
				},{
					id="mib_file",
					name=translate("MIB File"),
					description=translate("MIB file used by omcid. Defaults to /etc/mibs/prx300_1U.ini (U:SFU, V:HGU)"),
					type="select",
					default="/etc/mibs/prx300_1U.ini",
					options=tools.iterator2array(fs.glob("/etc/mibs/*.ini"))
				},{
					id="pon_slot",
					name=translate("PON Slot"),
					description=translate("Change the slot number that the UNI port is presented on, needed on some ISPs."),
					type="number",
					min=1,
					max=255
				},{
					id="iphost_mac",
					name=translate("IP Host MAC Address"),
					description=translate("MAC address sent in the IP host config data ME [134] (XX:XX:XX:XX:XX:XX format)."),
					maxlength=17,
					pattern='^[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){5}$',
					type="text",
					default=util.trim(util.exec(". /lib/pon.sh && pon_mac_get host")):upper()
				},{
					id="iphost_hostname",
					name=translate("IP Host Hostname"),
					description=translate("Hostname sent in the IP host config data ME [134] (up to 25 characters)."),
					maxlength=25,
					type="text"
				},{
					id="iphost_domain",
					name=translate("IP Host Domain Name"),
					description=translate("Domain name sent in the IP host config data ME [134] (up to 25 characters)."),
					maxlength=25,
					type="text"
				}
			}
		},{
			id="isp",
			category=translate("ISP Fixes"),
			items={	{
					id="fix_vlans",
					name=translate("Fix VLANs"),
					description=translate("Apply automatic fixes to the VLAN configuration from the OLT."),
					type="select_named",
					default="1",
					options={
						{
							name=translate("Disabled"),
							value="0"
						},
						{
							name=translate("Enabled"),
							value="1"
						},
						{
							name=translate("Hook script only"),
							value="2"
						}
					}
				},{
					id="internet_vlan",
					name=translate("Internet VLAN"),
					description=translate("Set the local VLAN ID to use for the Internet or 0 to make the Internet untagged (and also remove VLAN 0) (0 to 4095). Defaults to 0 (untagged)."),
					type="number",
					min=0,
					max=4095,
					default="0"
				},{
					id="services_vlan",
					name=translate("Services VLAN"),
					description=translate("Set the local VLAN ID to use for Services (ie TV/Home Phone) (1 to 4095). This fixes multi-service on Bell."),
					type="number",
					min=1,
					max=4095,
					default="34|36"
				}
			}
		},{
			id="device",
			category=translate("Device"),
			items={ {
					id="lang",
					name=translate("Language"),
					description=translate("Set the language used in the WebUI"),
					type="select_named",
					default="auto",
					options=languages,
					change=language_change
				},{
					id="bootdelay",
					name=translate("Boot Delay"),
					description=translate("Set the boot delay in seconds in which you can interupt the boot process over the serial console. With the Azores U-Boot, this also controls the number of times multicast upgrade is attempted and thus can have a significant impact in boot time. Default: 3, Recommended: 1"),
					type="select_named",
					default="3",
					base=true,
					options={
						{
							name=translate("0 (Fastest, disables multicast upgrade, not recommended)"),
							value="0"
						},{
							name=translate("1 (Fast Boot)"),
							value="1"
						},{
							name="2",
							value="2"
						},{
							name=translate("3 (Default)"),
							value="3"
						}
					}
				},{
					id="console_en",
					name=translate("Serial Console"),
					description=translate("Enable the serial console. This will cause TX_FAULT to be asserted as it shares the same SFP pin."),
					type="checkbox",
					default=false
				},{
					id="uart_select",
					name=translate("Early Serial Console"),
					description=translate("Enable the serial console early in the boot process. Disabling this may help in some devices that have issues with TX_FAULT."),
					type="checkbox_onoff",
					base=true,
					default=true,
				},{
					id="dying_gasp_en",
					name=translate("Dying Gasp"),
					description=translate("Enable dying gasp. This will cause the serial console input to break as it shares the same SFP pin."),
					type="checkbox",
					default=false
				},{
					id="rx_los",
					name=translate("RX Loss of Signal"),
					description=translate("Enable the RX_LOS pin. Disable to allow stick to be accessible without the fiber connected in all devices."),
					type="checkbox",
					default=false
				},{
					id="root_pwhash",
					name=translate("Root password hash"),
					description=translate("Custom password hash for the root user. This can be set from System > Administration"),
					maxlength=255,
					pattern="^\\$[0-9a-z]+\\$.+\\$[A-Za-z0-9.\\/]+$",
					type="text"
				},{
					id="ethtool_speed",
					name=translate("Ethtool Speed Settings"),
					description=translate("Ethtool speed settings on the eth0_0 interface (ethtool -s)."),
					maxlength=100,
					type="text"
				},{
					id="failsafe_delay",
					name=translate("Failsafe Delay"),
					description=translate("Number of seconds that we will delay the startup of omcid for at bootup (0 to 300). Defaults to 15 seconds"),
					type="number",
					min=0,
					max=300,
					default="15"
				},{
					id="hostname",
					name=translate("System Hostname"),
					description=translate("Set the system hostname visible over SSH/Console/WebUI."),
					maxlength=100,
					type="text",
					default="prx126-sfp-pon"
				},{
					id="timezone",
					name=translate("Time Zone"),
					description=translate("System Time Zone"),
					type="select",
					default="UTC",
					options=timezones
				},{
					id="ntp_servers",
					name=translate("NTP Servers"),
					description=translate("NTP server(s) to sync time from (space separated)."),
					maxlength=255,
					type="text"
				},{
					id="persist_root",
					name=translate("Persist RootFS"),
					description=translate("Allow the root file system to stay persistent (would also require that you modify the bootcmd fwenv). This is not recommended and should only be used for debug/testing purposes."),
					type="checkbox",
					default=false
				}
			}
		},{
			id="sfp",
			category=translate("SFP"),
			items={ {
					id="sfp_vendor",
					name=translate("Vendor Name"),
					description=translate("Set the vendor name presented in the virtual EEPROM (up to 16 characters)."),
					type="text",
					maxlength=16,
				},{
					id="sfp_oui",
					name=translate("Vendor OUI"),
					description=translate("Set the 3 byte vendor OUI presented in the virtual EEPROM (XX:XX:XX format)."),
					type="text",
					pattern="^[0-9A-F]{2}(:[0-9A-F]{2}){2}$",
					maxlength=8,
				},{
					id="sfp_partno",
					name=translate("Part Number"),
					description=translate("Set the vendor part number presented in the virtual EEPROM (up to 16 characters)."),
					type="text",
					maxlength=16,
				},{
					id="sfp_rev",
					name=translate("Revision"),
					description=translate("Set the vendor revision presented in the virtual EEPROM (up to 4 characters)."),
					type="text",
					maxlength=4,
				},{
					id="sfp_serial",
					name=translate("Serial Number"),
					description=translate("Set the vendor serial number presented in the virtual EEPROM (up to 16 characters)."),
					type="text",
					maxlength=16,
				},{
					id="sfp_date",
					name=translate("Date Code"),
					description=translate("Set the date code presented in the virtual EEPROM (up to 8 characters)."),
					type="text",
					pattern="^\\d{6}.{0,2}$",
					maxlength="8",
				},{
					id="sfp_vendordata",
					name=translate("Vendor Specific"),
					description=translate("Set the vendor specific data presented in the virtual EEPROM (up to 32 characters)."),
					type="text",
					maxlength=32,
				}
			}
		},{
			id="manage",
			category=translate("Management"),
			items={	{
--					Currently Broken, hide for the time being
--					id="lct_vlan",
--					name=translate("Management VLAN"),
--					description=translate("Set the management VLAN ID (0 to 4095). Defaults to 0 (untagged)."),
--					type="number",
--					min=0,
--					max=4095,
--					default="0"
--				},{
					id="ipaddr",
					name=translate("IP Address"),
					description=translate("Management IP address. Defaults to 192.168.11.1"),
					maxlength=15,
					pattern=ipv4_regex,
					type="text",
					default="192.168.11.1"
				},{
					id="netmask",
					name=translate("Subnet Mask"),
					description=translate("Management subnet mask. Defaults to 255.255.255.0"),
					maxlength=15,
					pattern=netmask_regex,
					type="text",
					default="255.255.255.0"
				},{
					id="gateway",
					name=translate("Gateway"),
					description=translate("Management gateway. Defaults to the IP address (ie. no default gateway)"),
					maxlength=15,
					pattern=ipv4_regex,
					type="text",
					default=util.trim(util.exec(". /lib/8311.sh && get_8311_ipaddr"))
				},{
					id="dns_server",
					name=translate("DNS Server"),
					description=translate("Management DNS server."),
					maxlength=15,
					pattern=ipv4_regex,
					type="text"
				},{
					id="pingd",
					name=translate("Ping Daemon"),
					description=translate("Enables a daemon that will ping an ip every 5 seconds, which can help with accessing the stick."),
					type="checkbox",
					default=true,
				},{
					id="ping_ip",
					name=translate("Ping IP"),
					description=translate("IP address to ping. Defaults to the 2nd IP address in the configured management network (ie. 192.168.11.2)."),
					maxlength=15,
					pattern=ipv4_regex,
					type="text",
					default=util.trim(util.exec(". /lib/8311.sh && get_8311_default_ping_host"))
				},{
					id="lct_mac",
					name=translate("LCT MAC Address"),
					description=translate("MAC address of the LCT management interface (XX:XX:XX:XX:XX:XX format)."),
					maxlength=17,
					pattern='^[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){5}$',
					type="text",
					default=util.trim(util.exec(". /lib/pon.sh && pon_mac_get lct")):upper()
				},{
					id="reverse_arp",
					name=translate("Reverse ARP Monitoring"),
					description=translate("Enables a reverse ARP monitoring daemon that will automatically add ARP entries from the MAC address of recieved packets." ..
						" This can help in reaching the management interface without using NAT."),
					type="checkbox",
					default=true
				},{
					id="https_redirect",
					name=translate("Redirect HTTP to HTTPs"),
					description=translate("Automatically redirect requests to the WebUI over HTTP to HTTPs. Defaults to on."),
					type="checkbox",
					default=true
				}
			}
		}
	}
end

function action_pontop(page)
	local cmd

	page = page or "status"

	local pages = pontop_pages()

	if not pages[page] then
		return false
	end

	cmd = { "/usr/bin/pontop", "-g", pages[page], "-b" }
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.sys.process.exec(cmd, luci.http.write)
end

function action_pon_status()
	local pages = pontop_page_details()

	ltemplate.render("8311/pon_status", {
		pages=pages,
	})
end

function pon_state(state)
	state = tonumber(state)
	local states = {
		[0]		= "O0, Power-up state",
		[10]	= "O1, Initial state",
		[11]	= "O1.1, Off-sync state",
		[12]	= "O1.2, Profile learning state",
		[20]	= "O2, Stand-by state",
		[23]	= "O2.3, Serial number state",
		[30]	= "O3, Serial number state",
		[40]	= "O4, Ranging state",
		[50]	= "O5, Operation state",
		[51]	= "O5.1, Associated state",
		[52]	= "O5.2, Pending state",
		[60]	= "O6, Intermittent LOS state",
		[70]	= "O7, Emergency stop state",
		[71]	= "O7.1, Emergency stop off-sync state",
		[72]	= "O7.2, Emergency stop in-sync state",
		[81]	= "O8.1, Downstream tuning off-sync state",
		[82]	= "O8.2, Downstream tuning profile learning state",
		[90]	= "O9, Upstream tuning state",
	}

	return translate(states[state] or "N/A")
end

function action_metrics()
	local metrics = tools.metrics()
	luci.http.prepare_content("application/json")
	luci.http.write("{\n")

	for i, metric in ipairs(tools.metric_names) do
		if i > 1 then
			luci.http.write(",\n")
		end

		local value = metrics[metric]
		if tools.is_finite(value) then
			local dec = 2
			if metric == "ploam_state" then
				dec = 0
			end

			value = string.format("%." .. dec .. "f", value)
		else
			value = "null"
		end

		luci.http.write('  "' .. metric .. '": ' .. value)
	end
	luci.http.write(',\n  "sample_valid": ' .. (metrics.sample_valid and "true" or "false") .. "\n}\n")
end

function temperature(t)
	if not tools.is_finite(t) then return translate("N/A") end
	return string.format(translate("%.2f °C (%.1f °F)"), t, (t * 1.8 + 32))
end

local function measurement(value, format)
	return tools.is_finite(value) and string.format(translate(format), value) or translate("N/A")
end

local function pon_status_values()
	local metrics = tools.metrics()

	local eep50 = fs.readfile("/sys/class/pon_mbox/pon_mbox0/device/eeprom50", 60) or ""
	local function eeprom_text(first, last)
		return #eep50 >= last and eep50:sub(first, last):trim() or translate("N/A")
	end

	local eth_speed = tonumber((fs.readfile("/sys/class/net/eth0_0/speed") or ""):trim())
	local vendor_name = eeprom_text(21, 36)
	local vendor_pn = eeprom_text(41, 56)
	local vendor_rev = eeprom_text(57, 60)
	local pon_mode = uci:get("gpon", "ponip", "pon_mode") or "xgspon"
	local module_type = tools.module_type() or translate("N/A")
	local active_bank = tools.active_bank() or translate("N/A")

	local rv = {
		status = pon_state(metrics.ploam_state),
		power = measurement(metrics.rx_power_dBm, "%.2f dBm") .. " / " .. measurement(metrics.tx_power_dBm, "%.2f dBm") .. " / " .. measurement(metrics.tx_bias_mA, "%.2f mA"),
		temperature = string.format("%s / %s / %s", temperature(metrics.cpu1_tempC), temperature(metrics.cpu2_tempC), temperature(metrics.optic_tempC)),
		voltage = measurement(metrics.module_voltage, "%.2f V"),
		sample_valid = metrics.sample_valid,
		pon_mode = pon_mode:upper():gsub("PON$", "-PON"),
		module_info = string.format("%s %s %s (%s)", vendor_name, vendor_pn, vendor_rev, module_type),
		eth_speed = (eth_speed and string.format(translate("%s Mbps"), eth_speed) or translate("N/A")),
		active_bank = active_bank,
	}
	return rv
end

function action_gpon_status()
	http.prepare_content("application/json")
	http.write_json(pon_status_values())
end

function action_diagnostics()
	local result = pon_status_values()
	result.links = tools.link_diagnostics()
	result.vlan = vlan_status_values()
	result.vlan_message = result.vlan.message
	http.header("Cache-Control", "no-store")
	http.prepare_content("application/json")
	http.write_json(result)
end

function action_vlans()
	ltemplate.render("8311/vlans", {})
end

function action_vlan_extvlans()
	luci.http.prepare_content("text/plain; charset=utf-8")

	if luci.sys.process.exec({"/usr/sbin/8311-extvlan-decode.sh", "-t"}, luci.http.write, luci.http.write).code == 0 then
		luci.http.write("\n\n")
		luci.sys.process.exec({"/usr/sbin/8311-extvlan-decode.sh"}, luci.http.write, luci.http.write)
	end
end

function action_get_hook_script()
    local content = fs.readfile("/ptconf/8311/vlan_fixes_hook.sh") or ''
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(content)
end

function action_save_hook_script()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		return
	end
	local content = formvalue("content")
	if type(content) ~= "string" or #content > 65536 or content:find("%z") then
		http.status(400, "Invalid hook script")
		http.write_json({ success = false })
		return
	end
	local lock, code = acquire_lock("/tmp/8311-config.lock")
	if not lock then
		http.status(code, "Configuration unavailable")
		http.write_json({ success = false }); return
	end
	-- Share the reset lock so a concurrent edit cannot recreate a removed hook.
	local ok, success = pcall(function()
		local path = "/ptconf/8311/vlan_fixes_hook.sh"
		local saved
		if content == "" then
			local removed, error_code = fs.remove(path)
			saved = removed or error_code == 2 -- ENOENT: already absent
		else
			local tmp = path .. "." .. nixio.getpid()
			saved = fs.mkdirr("/ptconf/8311", "rwx------") and
				fs.writefile(tmp, content) == #content and fs.chmod(tmp, "rw-------") and
				sys.call("/bin/sh -n " .. util.shellquote(tmp)) == 0 and fs.rename(tmp, path)
			fs.remove(tmp)
		end
		return saved and tools.request_vlan_reload()
	end)
	lock:close()
	success = ok and success
	http.status(success and 200 or 500, success and "OK" or "Unable to save or apply hook script")
	http.prepare_content("application/json")
	http.write_json({ success = not not success })
end

function action_support_download()
	local archive = ltn12.source.file(io.open(support_file))
	luci.http.prepare_content("application/x-targz")
	ltn12.pump.all(archive, luci.http.write)
end

function populate_8311_fwenvs()
	local fwenvs = fwenvs_8311()
	local fwenvs_values = tools.fw_getenvs_8311()

	for catid, cat in pairs(fwenvs) do
		for itemid, item in pairs(cat.items) do
			local value
			if item.base then
				value = tools.fw_getenv{item.id}
			else
				value = fwenvs_values[item.id] or ''
			end
			if item.base64 and value ~= '' then
				value = base64.dec(value)
			end

			fwenvs[catid]["items"][itemid]["value"] = value
		end
	end

	return fwenvs
end

function action_config()
	http.header("Cache-Control", "no-store")
	local fwenvs = populate_8311_fwenvs()

	ltemplate.render("8311/config", {
		fwenvs=fwenvs
	})
end

vlan_status_values = function()
	local status = tools.vlan_status()
	local messages = {
		starting = "VLAN monitor is starting.", scheduled = "VLAN changes are queued.",
		applying = "Applying VLAN rules.", applied = "VLAN script completed successfully.",
		disabled = "VLAN fixes are disabled.", unknown = "VLAN status is unavailable."
	}
	if status.state == "waiting" then
		status.message = translate(status.error_stage == "hook" and "Hook-only mode needs a saved hook script." or "Waiting for the PON interface.")
	elseif status.state == "error" then
		local failures = { detect="VLAN detection failed; the monitor will retry.", apply="VLAN application failed; the monitor will retry.",
			hook="The VLAN hook could not be read; the monitor will retry.", rules="VLAN rules could not be checked; the monitor will retry.",
			configuration="The VLAN mode is invalid." }
		status.message = translate(failures[status.error_stage] or messages.unknown)
	else
		status.message = translate(messages[status.state] or messages.unknown)
	end
	if status.state ~= "unknown" and not status.running then status.message = translate("VLAN monitor is not running.") end
	return status
end

function action_vlan_status()
	http.header("Cache-Control", "no-store")
	http.prepare_content("application/json")
	http.write_json(vlan_status_values())
end

local function save_config()
	local changes, errors = {}, {}
	for _, cat in ipairs(populate_8311_fwenvs()) do
		for _, item in ipairs(cat.items) do
			local value = formvalue(item.id) or ""
			local valid, message = tools.validate_config_value(item, value)
			if not valid then
				errors[item.id] = translate(message)
			else
				if item.type == "checkbox" or item.type == "checkbox_onoff" then
					local checked = value == "1"
					if item.value == "" and checked == not not item.default then
						value = ""
					elseif item.type == "checkbox_onoff" then
						value = checked and "on" or "off"
					else
						value = checked and "1" or "0"
					end
				elseif item.value == "" and item.default and value == item.default then
					value = ""
				end
				if item.value ~= value then
					table.insert(changes, { item = item, value = value })
				end
			end
		end
	end
	if next(errors) then
		return { success = false, errors = errors, message = translate("Configuration was not saved. Check the highlighted fields.") }, 400
	end
	local reload_vlans = false
	local saved, saved_names = {}, {}
	for index, change in ipairs(changes) do
		local item, value = change.item, change.value
		local stored = item.base64 and value ~= "" and base64.enc(value) or value
		local written = tools.fwenv_set(item.id, stored, not item.base, false)
		if written then
			table.insert(saved, item.id)
			table.insert(saved_names, item.name or item.id)
		end
		if not written or (item.change and not item.change(value)) then
			local pending = {}
			for i = index + 1, #changes do table.insert(pending, changes[i].item.id) end
			local message = translate("Saving stopped. Reload the page to check the stored settings before retrying.")
			if #saved_names > 0 then
				message = message .. " " .. string.format(translate("Confirmed saved: %s."), table.concat(saved_names, ", "))
			end
			return { success = false, field = item.id, saved = saved, pending = pending,
				failed_stage = written and "apply" or "write", vlan_reload = "not_requested",
				errors = { [item.id] = translate("Unable to save or apply this setting. Check its stored value.") }, message = message }, 500
		end
		if item.id == "fix_vlans" or item.id == "internet_vlan" or item.id == "services_vlan" then
			reload_vlans = true
		end
	end
	if reload_vlans and not tools.request_vlan_reload() then
		return { success = false, saved = saved, vlan_reload = "failed",
			message = translate("Configuration was saved, but VLAN reload failed. Reboot to apply it.") }, 500
	end
	local message = #changes == 0 and translate("No configuration changes to save.") or
		(reload_vlans and translate("Configuration saved. VLAN changes are scheduled; reboot to apply other settings.") or
		translate("Configuration saved. Reboot to apply the changes."))
	return { success = true, saved = saved, vlan_reload = reload_vlans and "scheduled" or "unchanged", message = message }, 200
end

function action_save()
	http.prepare_content("application/json")
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		http.write_json({ success = false })
		return
	end
	local lock, code = acquire_lock("/tmp/8311-config.lock")
	if not lock then
		http.status(code, "Configuration unavailable")
		http.write_json({ success = false, message = translate("Another save is in progress or configuration is unavailable. Retry shortly.") })
		return
	end
	-- Compute the result before emitting HTTP data: Lua 5.1 cannot yield through pcall.
	local ok, result, status = pcall(save_config)
	lock:close()
	if not ok then
		result, status = { success = false, message = translate("Saving failed unexpectedly. Reload the page to check the stored settings before retrying.") }, 500
	end
	http.status(status, status == 200 and "OK" or "Configuration not fully saved")
	http.write_json(result)
end

local recovery_hook_path = "/ptconf/8311/vlan_fixes_hook.sh"

local function stage_recovery_hook(content)
	if content == "" then return "" end
	if not fs.mkdirr("/ptconf/8311", "rwx------") or not fs.chmod("/ptconf/8311", "rwx------") then return nil end
	local path = recovery_hook_path .. ".restore." .. nixio.getpid()
	local fd = nixio.open(path, nixio.open_flags("wronly", "creat", "excl"), "rw-------")
	if not fd then return nil end
	local ok = pcall(function()
		local offset = 0
		while offset < #content do
			local written = fd:write(content, offset)
			if not written or written <= 0 then error("short hook write") end
			offset = offset + written
		end
	end)
	local closed = fd:close()
	if not ok or not closed or sys.call("/bin/sh -n " .. util.shellquote(path)) ~= 0 then
		fs.remove(path)
		return nil
	end
	return path
end

local function recover_settings(action, values)
	local recovery = require "8311.recovery"
	local raw, oversized = "", false
	local read = sys.process.exec({ "/usr/sbin/fw_printenv" }, function(chunk)
		if #raw + #chunk > 131072 then oversized = true else raw = raw .. chunk end
	end)
	if not read or read.code ~= 0 or oversized then
		return { success = false, message = translate("Unable to read the current settings. No changes were made.") }, 503
	end
	local current = {}
	for id, value in ("\n" .. raw):gmatch("\n8311_([%w_]+)=([^\r\n]*)") do current[id] = value end
	local categories = fwenvs_8311()
	local hook = ""
	if fs.lstat(recovery_hook_path) then
		if action == "reset" then hook = "present"
		else
			if fs.lstat(recovery_hook_path, "type") ~= "reg" then
				return { success = false, message = translate("Unable to read the VLAN hook. No changes were made.") }, 503
			end
			hook = fs.readfile(recovery_hook_path, recovery.hook_limit + 1)
			if not hook or #hook > recovery.hook_limit then
				return { success = false, message = translate("Unable to read the VLAN hook. No changes were made.") }, 503
			end
		end
	end
	if action == "backup" then
		local content, reason, field = recovery.export(categories, current, hook)
		if not content then return { success = false, field = field, message = translate(reason) }, 400 end
		local staged = stage_recovery_hook(hook)
		if staged == nil then return { success = false, message = translate("The VLAN hook could not be validated. No changes were made.") }, 400 end
		if staged ~= "" then fs.remove(staged) end
		return { success = true, download = content }, 200
	end
	local plan, reason, field = recovery.plan(values.content, categories, current,
		values.preserve_pon ~= "0", action == "reset", hook)
	if not plan then
		return { success = false, field = field, message = translate(reason) }, 400
	end
	local names = {}
	for _, change in ipairs(plan.changes) do table.insert(names, change.name) end
	if plan.hook_changed then table.insert(names, translate("VLAN hook script")) end
	local staged
	if plan.hook_changed then
		staged = stage_recovery_hook(plan.hook)
		if staged == nil then return { success = false, message = translate("The VLAN hook could not be validated. No changes were made.") }, 400 end
	end
	if action == "preview" then
		if staged and staged ~= "" then fs.remove(staged) end
		return { success = true, count = #names, names = names, skipped = plan.skipped,
			hook_script = plan.hook_changed and plan.hook ~= "",
			message = #names == 0 and translate("No configuration changes to save.") or
				translate("File checked. Only the listed settings will be replaced; missing settings are kept.") }, 200
	end
	local ok, response, status = pcall(function()
		local saved = {}
		for _, change in ipairs(plan.changes) do
			if not tools.fwenv_set(change.id, change.value, true, false) then
				return { success = false, field = change.id, saved = saved,
					message = string.format(translate("Restore stopped at %s. Confirmed writes: %d. Review configuration before retrying; the device was not rebooted."), change.name, #saved) }, 500
			end
			table.insert(saved, change.id)
		end
		if plan.hook_changed then
			local done, code
			if plan.hook == "" then done, code = fs.remove(recovery_hook_path)
			else done = fs.rename(staged, recovery_hook_path) end
			if not done and code ~= 2 then
				return { success = false, field = "backup_hook_b64", saved = saved,
					message = translate("Settings were saved, but the VLAN hook could not be restored. Review it before rebooting.") }, 500
			end
			table.insert(saved, "backup_hook_b64")
		end
		return { success = true, saved = saved, reboot_required = action == "reset" or #saved > 0,
			message = action == "reset" and
				translate("Default settings saved. Reboot to apply. The management address will be 192.168.11.1 and the root password will return to the firmware default.") or
				translate("Settings restored. Reboot to apply network and PON changes.") }, 200
	end)
	if staged and staged ~= "" then fs.remove(staged) end
	if not ok then error(response) end
	return response, status
end

function action_recovery()
	http.prepare_content("application/json")
	http.header("Cache-Control", "no-store")
	if http.getenv("REQUEST_METHOD") ~= "POST" then http.status(405, "Method Not Allowed"); return end
	local length = tonumber(http.getenv("CONTENT_LENGTH"))
	if not length then http.status(411, "Length Required"); return end
	-- URL-encoded UTF-8 can use three bytes per input byte, plus token and options.
	if not tools.is_finite(length) or length < 0 or length > 3 * 131072 + 8192 then
		http.status(413, "Settings upload too large"); return
	end
	-- The legacy LuCI parser defaults to 100 KiB, below a URL-encoded backup.
	-- Raise only this bounded request's parse limit, then restore the module default.
	local previous_limit = http.HTTP_MAX_CONTENT
	http.HTTP_MAX_CONTENT = 3 * 131072 + 8192
	local authenticated = dispatcher.test_post_security()
	http.HTTP_MAX_CONTENT = previous_limit
	if not authenticated then return end
	local values = formvalue()
	local action = values.action
	if (action ~= "preview" and action ~= "restore" and action ~= "reset" and action ~= "backup") or
		(values.preserve_pon ~= nil and values.preserve_pon ~= "0" and values.preserve_pon ~= "1") or
		(action ~= "preview" and action ~= "backup" and values.confirm ~= "1") then
		http.status(400, "Invalid recovery action"); return
	end
	-- Match the config editor lock and exclude simultaneous WebUI firmware actions.
	local operation_lock, code = acquire_lock("/tmp/8311-web-upgrade.lock")
	if not operation_lock then
		http.status(code, "Firmware operation in progress")
		http.write_json({ success = false, message = translate("Another operation is in progress. Retry shortly.") }); return
	end
	local config_lock
	config_lock, code = acquire_lock("/tmp/8311-config.lock")
	if not config_lock then
		operation_lock:close()
		http.status(code, "Configuration unavailable")
		http.write_json({ success = false, message = translate("Another operation is in progress. Retry shortly.") }); return
	end
	local ok, response, status = pcall(recover_settings, action, values)
	config_lock:close()
	operation_lock:close()
	if not ok then
		response, status = { success = false, message = translate("Recovery failed unexpectedly. Check configuration before retrying; the device was not rebooted.") }, 500
	end
	http.status(status, status == 200 and "OK" or "Recovery failed")
	if response.download and status == 200 then
		-- prepare_content keeps the earlier JSON type on legacy LuCI.
		http.header("Content-Type", "text/plain; charset=utf-8")
		http.header("Content-Disposition", 'attachment; filename="8311-settings.env"')
		http.header("X-Content-Type-Options", "nosniff")
		http.write(response.download)
	else
		http.write_json(response)
	end
end

function action_pon_explorer()
	local omci = util.exec("/usr/bin/luci-me-dump")

	ltemplate.render("8311/pon_me", {
		omci=omci
	})
end

function action_pon_dump(me_id, instance_id)
	cmd = { "/usr/bin/omci_pipe.sh", "meg", me_id, instance_id }
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.sys.process.exec(cmd, http.write)
end

local firmware_limit = 128 * 1024 * 1024
local firmware_directory = "/tmp/8311-web-upgrade"
local firmware_actions = { validate = true, cancel = true, install = true,
	install_reboot = true, reboot = true, switch_reboot = true, commit = true }

local function receive_firmware(path)
	if not fs.mkdir(firmware_directory, "rwx------") and
		(fs.lstat(firmware_directory, "type") ~= "dir" or fs.lstat(firmware_directory, "uid") ~= 0) then
		return false, "Unable to create the upload directory."
	end
	if not fs.chmod(firmware_directory, "rwx------") then return false, "Unable to protect the upload directory." end
	local temporary = path .. ".incoming." .. nixio.getpid()
	local fd = nixio.open(temporary, nixio.open_flags("wronly", "creat", "excl"), "rw-------")
	if not fd then return false, "Unable to create a temporary upload file." end
	local size, metadata, complete, failure = 0, nil, false, nil
	-- Authentication has parsed the multipart body. LuCI replays its temporary
	-- file here, closes that descriptor, and releases it after the copy.
	local ok = pcall(http.setfilehandler, function(meta, chunk, eof)
		if not meta or meta.name ~= "firmware_file" or failure then return end
		if metadata and metadata ~= meta then
			failure = "Upload exactly one firmware file."
			return
		end
		metadata = meta
		if chunk then
			size = size + #chunk
			if size > firmware_limit then failure = "Firmware exceeds the 128 MiB limit."; return end
			local offset = 0
			while offset < #chunk do
				local written = fd:write(chunk, offset)
				if not written or written <= 0 then failure = "Unable to write the uploaded firmware."; return end
				offset = offset + written
			end
		end
		if eof then complete = true end
	end)
	local closed = fd:close()
	if not ok or not closed or not complete or size == 0 or failure then
		fs.remove(temporary)
		return false, failure or "The firmware upload was incomplete."
	end
	if not fs.rename(temporary, path) then
		fs.remove(temporary)
		return false, "Unable to save the uploaded firmware."
	end
	return true
end

local function apply_firmware(action, values, path, bank)
	local function failed(message)
		firmwareUpgradeOutput(translate(message))
		return { code = 1 }
	end
	if action == "switch_reboot" then
		local other = bank == "A" and "B" or (bank == "B" and "A" or nil)
		if not other or not tools.bank_available(other) then
			return failed("The inactive bank is empty, incomplete or unreadable. Install a valid firmware image before switching.")
		end
		return sys.process.exec({ "/usr/sbin/8311-bankctl.sh", "trial", other }, firmwareUpgradeOutput, firmwareUpgradeOutput) or { code = 1 }
	elseif action == "reboot" or action == "commit" then
		return sys.process.exec({ "/usr/sbin/8311-bankctl.sh", action }, firmwareUpgradeOutput, firmwareUpgradeOutput) or { code = 1 }
	elseif action == "cancel" then
		if fs.lstat(path) and not fs.remove(path) then return failed("Unable to remove the uploaded firmware.") end
		return { code = 0 }
	end
	if values.firmware_file ~= nil and values.firmware_file ~= "" then
		if action ~= "validate" then return failed("Upload and validate the firmware before installing it.") end
		local received, message = receive_firmware(path)
		if not received then return failed(message) end
	end
	if fs.lstat(path, "type") ~= "reg" then return failed("Upload a firmware file first.") end
	local command = { "/usr/sbin/8311-firmware-upgrade.sh" }
	local installing = action == "install" or action == "install_reboot"
	if installing then
		table.insert(command, "--yes")
		table.insert(command, "--install")
		table.insert(command, "--no-commit")
		if action == "install_reboot" then
			table.insert(command, "--trial")
			table.insert(command, "--reboot")
		end
	else
		table.insert(command, "--validate")
	end
	table.insert(command, path)
	local result = sys.process.exec(command, firmwareUpgradeOutput, firmwareUpgradeOutput)
	local installed = installing and result and result.code == 0
	if installed then
		fs.remove("/tmp/8311-alt-firmware")
		fs.remove(path)
	elseif not installing and (not result or result.code ~= 0) then
		fs.remove(path)
	end
	return result or { code = 1 }, installed
end

function action_firmware()
	firmwareOutput = ""
	http.header("Cache-Control", "no-store")
	local method = http.getenv("REQUEST_METHOD")
	if method ~= "GET" and method ~= "POST" then http.status(405, "Method Not Allowed"); return end
	local values, action = {}, "validate"
	if method == "POST" then
		-- Bound the body before token verification parses multipart data into RAM.
		local length = tonumber(http.getenv("CONTENT_LENGTH"))
		if not length then http.status(411, "Length Required"); return end
		if not tools.is_finite(length) or length < 0 or length > firmware_limit + 65536 then
			http.status(413, "Firmware upload too large"); return
		end
		if not dispatcher.test_post_security() then return end
		values = formvalue()
		action = values.action
		if type(action) ~= "string" or not firmware_actions[action] then
			http.status(400, "Invalid firmware action"); return
		end
	end
	local session = dispatcher.context.authsession
	if type(session) ~= "string" or #session ~= 32 or not session:match("^%x+$") then
		http.status(403, "Firmware session unavailable"); return
	end
	local path = firmware_directory .. "/" .. session .. ".tar"
	local version = require "8311.version"
	version.bank = tools.active_bank()
	local result, installed
	if method == "POST" then
		local lock, code = acquire_lock("/tmp/8311-web-upgrade.lock")
		if not lock then http.status(code, "Another firmware operation is in progress"); return end
		local ok
		ok, result, installed = pcall(apply_firmware, action, values, path, version.bank)
		lock:close()
		if not ok then
			result, installed = { code = 1 }, false
			firmwareUpgradeOutput(translate("Firmware operation failed unexpectedly. Check the device before retrying."))
		end
		if result.code ~= 0 then http.status(500, "Firmware operation failed") end
	end
	local altversion = { variant = "unknown", version = "unknown", revision = "unknown",
		bank = version.bank == "A" and "B" or (version.bank == "B" and "A" or "unknown") }
	local rebooting = result and result.code == 0 and (action == "reboot" or action == "switch_reboot" or action == "install_reboot")
	local available = not rebooting and tools.bank_available(altversion.bank)
	local alternate = available and util.exec("/usr/sbin/alternate_firmware_info") or ""
	for key, value in string.gmatch(alternate, "([^\n=]+)=([^\n]+)") do
		local field = ({ FW_VARIANT = "variant", FW_VERSION = "version", FW_REVISION = "revision" })[key]
		if field then altversion[field] = value end
	end
	ltemplate.render("8311/firmware", {
		version = version, altversion = altversion, firmware_file_exists = fs.lstat(path, "type") == "reg",
		firmware_exec = result, firmware_installed = installed, firmware_output = firmwareOutput, firmware_action = action,
		bank_available = available, committed_bank = tools.fwenv_get("commit_bank")
	})
end

function action_support()
	supportOutput = ""
	local method = http.getenv("REQUEST_METHOD")
	if method ~= "GET" and method ~= "POST" then http.status(405, "Method Not Allowed"); return end
	if method == "POST" and not dispatcher.test_post_security() then return end
	local values = method == "POST" and formvalue() or {}
	local action = values["action"] or ""
	if method == "POST" and action ~= "generate" and action ~= "delete" then
		http.status(400, "Invalid support action"); return
	end

	local support_file_exists = false
	local support_output = ""
	local support_exec

	if action == "generate" then
		local cmd = { "/usr/sbin/8311-support.sh" }
		if values["include_raw"] == "1" then table.insert(cmd, "--raw") end
		support_exec = luci.sys.process.exec(cmd, supportOut, supportOut)
	elseif action == "delete" then
		fs.remove(support_file)
	end

	support_file_exists = file_exists(support_file) and (not support_exec or support_exec.code == 0)

	ltemplate.render("8311/support", {
		support_exec=support_exec,
		support_output=supportOutput,
		support_file_exists=support_file_exists
	})
end

function file_exists(filename)
	local fp = io.open(filename, "r")
	if fp ~= nil then
		io.close(fp)
		return true
	else
		return false
	end
end

function firmwareUpgradeOutput(data)
	data = data or ''
	firmwareOutput = firmwareOutput .. data:sub(1, math.max(0, 131072 - #firmwareOutput))
end

function supportOut(data)
	data = data or ''
	supportOutput = supportOutput .. data
end
