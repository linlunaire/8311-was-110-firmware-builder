# 8311 WAS-110 Firmware Builder

## Reliability improvements in this fork

This fork keeps the upstream PON, MIB and VLAN defaults. It does not add ISP
profiles, change the kernel, or claim higher line throughput.

This is not a drop-in replacement for the xiao-k233 CN firmware. In that fork,
`fix_vlans=2` selects TC mode; upstream uses the same value for Hook script only.
CN's PVID, multicast and IGMP settings are not migrated by this branch. Verify
the existing line's Internet/IPTV behavior before considering migration; see
the [CN comparison](docs/reference-designs.md#cn-configuration-compatibility).

- Firmware installation always validates all three images under the upgrade
  lock before writing. Extraction, size, hash, UBI write/readback and boot-bank
  errors return failure to the caller. The existing two environment writes are
  retained. Exit status `2` means the initial installation prompt was cancelled.
  Images are staged privately in `/tmp` so the bytes installed are the bytes
  validated; installation needs additional free RAM-backed storage for the
  uncompressed kernel, bootcore and rootfs files. A staging failure occurs before
  any flash write. Validation alone stages one image at a time.
- Stock-image extraction checks the complete header table and component bounds
  before replacing output files. Invalid lengths and truncated tails cannot
  silently produce components containing bytes from earlier parts of the image.
- Configuration saves validate every field using the same definitions as the
  form, write only changed values and check both command status and readback.
  Web saves are serialized. Failed saves identify the failed field, confirmed
  saved fields and remaining fields; writes across multiple variables are
  **not atomic**. A failed batch does not request VLAN application. Config and
  Hook saves use LuCI's POST/token protection. Hook replacement checks shell
  syntax and file operations before replacing the old file.
- Firmware and support actions require POST and the LuCI session token; GET
  only displays their pages. Firmware uploads have a 128 MiB limit, private
  session-specific staging and checked writes/atomic promotion. Web firmware
  operations are serialized, failed installations retain the uploaded file,
  and successful installations or cancellation remove it. Abandoned uploads
  remain in RAM until cancellation or reboot. Installation still validates
  all components again before any flash write. Only confirmed installation
  success invalidates alternate-bank metadata or offers the reboot button.
- Missing/short EEPROM data and missing thermal/PON readings no longer break
  status requests. Unavailable numeric metrics are JSON `null`; `sample_valid`
  is false if any numeric metric is unavailable. Zero optical power has no
  finite dBm reading. Monitoring clients that assumed numeric values must handle
  `null`. Optical temperature is decoded as signed Q8.8, as specified in
  [SFF-8472](https://members.snia.org/document/dl/25916).
- Dynamic EEPROM reads use only bytes 96–105; drivers without seek support
  fall back to a bounded 106-byte read. Module text needs only the first 60
  bytes of EEPROM 50. Status requests reuse the existing module-type cache,
  parse the active bank directly from the kernel command line, and bound the
  PON command with a timeout. Hidden pages skip PON refresh requests and
  concurrent requests from one status panel share the same pending response.
  RX_LOS polling uses shell builtin reads at the original one-/three-second
  cadence. No resident service or CPU-governor change is added.
- VLAN display avoids one redundant decoder invocation. The VLAN daemon keeps
  the healthy five-second poll, retries failures at 5/10/20/40/60-second
  intervals, uses a nonblocking apply lock, and bounds detection/apply commands
  with the bundled BusyBox `timeout`. Successful saves notify the daemon and
  invalidate its cached local VLAN settings. Hook content changes are detected
  even if the network topology is unchanged. After changing VLAN environment
  values directly, run `touch /tmp/8311-vlans.reload`. Disabling fixes stops new
  applications; reboot to remove previously applied rules.
- Support archives default to numeric VLAN/daemon settings and VLAN tables.
  Other environment values are redacted; raw logs, pontop, TC and OMCI dumps
  are omitted. Use `8311-support.sh --raw` or explicitly check **Include raw
  diagnostics** in LuCI when a private investigation needs those sources.
  Review archives before sharing. Registration ID, logical password and root
  password hash values are no longer logged during configuration.

## Restore and firmware update

**System → Restore / Flash Firmware** provides the two sections without a
backup-generation section. The old `/admin/8311/firmware` URL remains usable.
The page uses the existing LuCI theme and includes Simplified Chinese strings.

Reset offers two scopes: keep PON identity/authentication (default), or also
clear known PON settings. Both clear the other known 8311 overrides and the
VLAN hook. Factory calibration, bootloader variables, firmware banks, SSH keys
and certificates are kept. This resets 8311-managed configuration, not arbitrary
files or unknown settings from another fork. After reboot the management IP is
`192.168.11.1` and the root password returns to the image's default.

Configuration restore accepts plain-text `8311_key=value` files up to 64 KiB,
including compatible `fwenvs_backup.env` files. It validates the entire file,
previews changed field names without exposing credentials, and requires a
separate confirmation. Missing fields are kept; an empty value removes an
override. Unknown/duplicate keys, invalid values, bootloader variables and
enabling persistent RootFS are rejected. CN-specific settings and generic
OpenWrt backup archives are not supported. Disable persistent RootFS and reboot
before using recovery. Imports and resets share the WebUI configuration and
firmware locks, check each write, report partial failures, and never reboot
automatically. Reboot is a separate action after success.

Firmware updates continue to accept WAS-110 `local-upgrade.tar` packages with
the existing dual-bank validation and installation flow. These are not generic
ImmortalWrt/OpenWrt sysupgrade images. The distribution comparison and hardware
support evidence are in [immortalwrt-assessment.md](docs/immortalwrt-assessment.md).

## Building and testing

Use a Linux build environment with Bash, GNU tools, Python 3, Perl, `sudo`,
`squashfs-tools`, `u-boot-tools` and `mtd-utils` (plus `7z` for `--release`).
The stock BFW upgrade image and the basic firmware's three extracted components
must be supplied separately. Initialize the pinned submodule over HTTPS:

```sh
git submodule update --init
./build.sh --bfw-image-file stock/bfw.img --basic-image-dir stock/basic \
  --basic -o out/local-upgrade.img -O out/local-upgrade.tar
```

`--image` and `--image-dir` remain accepted aliases. Caller-relative paths work
when invoking `build.sh` from another directory. Missing option values, inputs,
submodule files or required image tools fail before existing build output is
removed. Use a Linux checkout to preserve the firmware's symlinks and modes.

Offline regressions use fake UBI devices, environment writers, EEPROMs and LuCI
services; they do not flash hardware or need proprietary stock images:

```sh
sudo apt-get install lua5.1 pcre2-utils busybox
python3 -m unittest discover -s tests -v
TEST_SHELL=busybox TEST_SHELL_ARGS=sh python3 -m unittest discover -s tests -v
```

Windows can run the same tests with Git Bash, Python and `lupa` (its Lua 5.1
runtime is selected explicitly). The CI workflow defines Linux shell and BusyBox
variants. `tests/frontend_smoke.cjs` is an optional Playwright/Chromium test of the
real frontend JavaScript against local fixture endpoints; run it with
`node tests/frontend_smoke.cjs` in an environment where Playwright is installed.
Set `BROWSER_CHANNEL=msedge` or `chrome` to use that installed browser instead.
Run `node tests/status_poll_smoke.cjs` to check visibility, request coalescing
and retries without browser dependencies.
Passing these checks does not validate a built firmware, booting, PON
registration, OLT interoperability or real link performance. Those require the
appropriate stock images and a WAS-110 test device.

See [reference-designs.md](docs/reference-designs.md) for the source-pinned
comparison with other ONU projects, OpenWrt, LuCI and procd, including which
designs can be reused and which still need hardware or ISP verification.
The checks actually performed and remaining coverage gaps are recorded in
[validation.md](docs/validation.md).
Device measurements and the boundary between response-time improvements and
unverified thermal effects are documented in
[performance-analysis.md](docs/performance-analysis.md).

## Custom fwenvs
```
8311_fix_vlans=1
8311_internet_vlan=0
8311_services_vlan=36

8311_ipaddr=192.168.11.1
8311_netmask=255.255.255.0
8311_gateway=192.168.11.254
8311_ping_ip=192.168.11.2

8311_console_en=1
8311_ethtool_speed=speed 2500 autoneg off duplex full
8311_failsafe_delay=30
8311_persist_root=0
8311_root_pwhash=$1$BghTQV7M$ZhWWiCgQptC1hpUdIfa0e.
8311_rx_los=0

8311_cp_hw_ver_sync=1
8311_device_sn=DM222XXXXXXXXXX
8311_equipment_id=5690
8311_gpon_sn=SMBSXXXXXXXX
8311_hw_ver=Fast5689EBell
8311_mib_file=/etc/mibs/prx300_1V.ini
8311_reg_id_hex=00
8311_sw_verA=SGC830007C
8311_sw_verB=SGC830006E
8311_vendor_id=SMBS
```


### ISP Fix fwenvs
`8311_fix_vlans` - **Fix VLANs**  
Set to `0` to disable the automatic fixes that are applied to VLANs.  

`8311_internet_vlan` - **Internet VLAN**  
Set the local VLAN ID to use for the Internet or `0` to make the Internet untagged (and also remove VLAN 0) (0 to 4095). Defaults to `0` (untagged).  

`8311_services_vlan` - **Services VLAN**  
Set the local VLAN ID to use for Services (ie TV/Home Phone) (1 to 4095). This fixes multi-service on Bell.  


### Management fwenvs
`8311_ipaddr` - **IP Address**  
Set the management IP address. Defaults to `192.168.11.1`  

`8311_netmask` - **Subnet Mask**  
Set the management subnet mask. Defaults to `255.255.255.0`  

`8311_gateway` - **Gateway**  
Set the management gateway. Defaults to the IP address (ie. no default gateway)  

`8311_ping_ip` - **Ping IP**  
Sets an IP address to ping every 5 seconds, this can helps with reaching the stick. Defaults to the 2nd ip address in the configured management network (ie. 192.168.11.2).  


### Device fwenvs
`8311_console_en` - **Serial console**  
Set to `1` to enable the serial console, this will cause TX_FAULT to be asserted as it shares the same SFP pin.  

`8311_ethtool_speed` - **Ethtool Speed Settings**  
Set ethtool speed settings on the eth0_0 interface (ethtool -s).  

`8311_factory_mode` - **Factory Mode**  
Set to 1 to enable factory mode, otherwise factory mode will be automatically disabled on boot.  

`8311_failsafe_delay` - **Failsafe Delay**  
Sets the number of seconds that we will delay the startup of omcid for at bootup (30 to 300). Defaults to 30 seconds.  

`8311_lct_mac` - **LCT MAC Address**  
Set the MAC address on the LCT management interface.  

`8311_persist_root` - **Persist RootFS**  
Set to `1` to allow the root file system to stay persistent (would also require that you modify the bootcmd fwenv). This is not recommended and should only be used for debug/testing purposes.  

`8311_root_pwhash` - **Root password hash**  
Allows you to set a custom root password by setting the hash.  

`8311_rx_los` - **RX_LOS Workaround**  
Set to `0` to monitor the status of the RX_LOS pin to disable it any time it gets enabled. This will allow the stick to be accessible in devices which disable access to the port if RX_LOS is being asserted.  


### PON fwenvs
`8311_cp_hw_ver_sync` - **Sync Circuit Pack Version**  
When set to `1` and `8311_hw_ver` is also set, will modify the configured mib file to set the Version field of any Circuit Pack MEs to match the Hardware version.  

`8311_device_sn` - **Device Serial Number**  
Sets the physical device S/N, this is more or less display only.  

`8311_equipment_id` - **Equipment ID**  
Sets the PON Equipment ID field in the ONU2-G ME (257).  

`8311_gpon_sn` - **GPON Serial Number / ONT ID**  
Sets the GPON Serial Number sent to the OLT in various MEs (4 letters, followed by 8 hex digits).  

`8311_hw_ver` - **Hardware Version**  
Set the Hardware version string sent to the OLT in various MEs (up to 14 characters).  

`8311_iphost_domain` - **IP Host Domain Name**  
Set the domain name sent to the OLT in ME 134 (up to 25 characters).  

`8311_iphost_hostname` - **IP Host Hostname**  
Set the hostname sent to the OLT in ME 134 (up to 25 characters).  

`8311_iphost_mac` - **IP Host MAC Address**  
Set the MAC address sent to the OLT in ME 134.  

`8311_loid` - **Logical ONU ID**  
Sets the Logical ONU ID presented to the OLT in ME 256 (up to 24 characters).  

`8311_lpwd` - **Logical Password**  
Sets the Logical Password prsented to the OLT in ME 256 (up to 12 characters).  

`8311_mib_file` - **MIB File**  
Sets the MIB file used by omcid. Defaults to `/etc/mibs/prx300_1U.ini`  

`8311_pon_slot` - **PON Slot**  
Sets the slot number that the UNI port is presented on, needed on some ISPs.  

`8311_reg_id_hex` - **Registration ID**  
Sets the Registration ID (up to 36 characters [72 hex]) sent to the OLT in hex format. This is where you would set a ploam password (which is contained in the last 12 characters).  

`8311_sw_verA` / `8311_sw_verB` - **Software Versions**  
Sets the image specific software versions sent in the Software image MEs (7).  

`8311_vendor_id` - **Vendor ID**  
Sets the PON Vendor ID sent to the OLT, automatically derived from the GPON Serial Number if not set (4 letters).  



## Authentication
SSH host keys (all of `/etc/dropbear`) and authorized_keys (all of `/root/.ssh`) are now stored persistently.
Previous UCI settings will be automatically migrated.

The current root password (change with `passwd`) can be persisted using the `8311-persist-root-password.sh` command



## Scripts

### build.sh
Tool for building new modded WAS-110 firmware images
```
Usage: ./build.sh [options]

Options:
-i --image <filename>           Specify stock local upgrade image file.
-I --image-dir <dir>            Specify stock image directory (must contain bootcore.bin, kernel.bin, and rootfs.img).
-o --image-out <filename>       Specify local upgrade image to output.
-h --help                       This help text
```

### create.sh
Tool for creating new WAS-110 local upgrade images
```
Usage: ./create.sh [options]

Options:
-i --image <filename>           Specify local upgrade image file to create (required).
-H --header <filename>          Specify filename of image header to base image off of (default: header.bin).
-b --bootcore <filename>        Specify filename of bootcore image to place in created image (default: bootcore.bin).
-k --kernel <filename>          Specify filename of kernel image to place in created image (default: kernel.bin).
-r --rootfs <filename>          Specify filename of rootfs image to place in created image (default: rootfs.img).
-V --image-version <version>    Specify version string to set on created image (14 characters max).
-h --help                       This help text
```


### extract.sh
Tool for extracting stock WAS-110 local upgrade images
```
Usage: ./extract.sh [options]

Options:
-i --image <filename>           Specify local upgrade image file to extract (required).
-H --header <filename>          Specify filename to extract image header to (default: header.bin).
-b --bootcore <filename>        Specify filename to extract bootcore image to (default: bootcore.bin).
-k --kernel <filename>          Specify filename to extract kernel image to (default: kernel.bin).
-r --rootfs <filename>          Specify filename to extract rootfs image to (default: rootfs.img).
-h --help                       This help text
```
