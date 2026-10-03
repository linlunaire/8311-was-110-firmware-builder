# 8311 WAS-110 固件：可靠性与管理界面优化

基于 [djGrrr/8311-was-110-firmware-builder](https://github.com/djGrrr/8311-was-110-firmware-builder) 的个人维护分支，面向 WAS-110 / PRX126。保留上游的 PON 驱动、内核和默认业务逻辑，修复升级与配置保存中的错误处理，并减少管理页面的重复读取和轮询。

当前候选版本为 **v2.8.3-opt1 / basic**。它是基于已发布 v2.8.3 固件重新构建的脚本与 WebUI 更新。**没有移植 ImmortalWrt，没有承诺提高线路速率或降低温度，也没有完成运营商兼容性认证。**

2026-10-03 已在一台未接光纤的 WAS-110 上完成 `v2.8.3-opt1_basic_b159a2c` 的 A 槽启动和管理接口验证，并保留原 B 槽。实际 Internet / IPTV、断电恢复及长期稳定性仍未验收。

## 使用前必须了解的风险

| 风险 | 具体影响与边界 |
| --- | --- |
| 刷写或切换启动失败 | 断电、错误镜像、存储故障或环境写入失败可能导致无法启动。只有适用于本设备的 `local-upgrade.tar` 可以走本项目升级流程，不能使用普通 OpenWrt / ImmortalWrt sysupgrade 镜像。 |
| A/B 不是两套独立配置 | A、B 是原厂已有的两套完整固件槽，正常升级写入未运行的槽；`fwenv`、`ptconf` 和 overlay 共享。切回旧固件不等于恢复旧配置，也不能承诺所有故障都自动回退。见 [分区与试启动说明](docs/firmware-banks.md)。 |
| CN 配置不完全兼容 | 本分支不是 xiao-k233 CN 固件的直接替代品。上游 `fix_vlans=2` 表示仅执行 Hook，CN 中表示 TC 模式；CN 的 PVID、多播及 IGMP 参数没有在本分支实现或自动迁移。迁移前必须逐项核对 Internet / IPTV 配置。 |
| 备份中含有凭证 | `.env` 备份包含 PON 身份、认证信息和 root 密码覆盖值。它是未加密的私密文件，不能提交到 Git、公开工单或聊天截图。自定义 Hook 是可执行脚本，只恢复自己信任的备份。 |
| 重置可能失去管理或 PON 连接 | 重置后需手动重启，管理地址恢复为 `192.168.11.1`，root 密码恢复镜像默认值。本次 basic 底包默认 root 无密码，应在可信管理网络中设置密码并持久化。清除 PON 参数还可能使设备无法向 OLT 注册。 |
| 多字段配置不是原子事务 | 全文件校验发生在写入前，但设备故障仍可能使部分字段保存成功。界面报告已确认写入和失败的字段；不能把报错理解为“完全没有改动”。 |
| 固件和硬件有既有限制 | 保留的 Linux 4.9.308 与闭源 PON 栈并未因此获得现代系统的全部修复。勿把管理界面直接暴露到不可信网络。光纤业务、散热、断电恢复及长期运行需要单独实测。 |

## 本分支改进了什么

- **升级流程能可靠报错。** 安装前在锁内校验全部三个组件，检查解包、尺寸、SHA-256、UBI 写入和读回、启动环境写入。校验失败时不写镜像，安装失败不会显示成功或提供误导性的重启提示。
- **配置保存可核对。** 后端与表单共用字段定义；只写有变化的值，检查命令结果和读回值；Web 配置、Hook 和恢复操作互斥。Hook 先检查语法与文件操作，再替换原文件。
- **备份、恢复、重置和更新放到同一页面。** 保留 LuCI 原主题，提供简体中文、手机布局、明确的影响提示与分步确认。
- **状态查询减少开销。** 动态 EEPROM 只读取所需范围，静态信息复用缓存；PON 查询有超时，隐藏页面暂停轮询，同一面板合并进行中的请求。缺失数据返回 `null`，页面显示不可用值，不把缺失读数误报成零。
- **VLAN daemon 更少空转。** 正常时保留五秒周期，失败时按 5/10/20/40/60 秒退避；检测和应用有超时与互斥，配置/Hook 改动可通知刷新。关闭自动修正会停止新应用，已应用规则需重启清除。
- **诊断信息默认脱敏。** 默认支持包只包含必要数值配置与 VLAN 表，其他环境值脱敏，不收集原始认证日志。仅在私密排查确有需要时启用原始诊断，分享前仍需检查。
- **构建输入提前检查。** 修复输出参数、调用路径和截断镜像处理；无效输入在覆盖输出前失败，保留 Linux 的文件模式和符号链接。

同一台设备、同一会话中，将修改前后的状态函数加载到内存，各预热一次并测量五次：基础指标平均 **74.20 → 36.45 ms**，完整状态平均 **194.55 → 50.46 ms**。这只是函数耗时，不是整页、线路吞吐或温度的改善幅度。测量条件见 [性能分析](docs/performance-analysis.md)。

## 备份与更新怎么用

入口为 **系统 → 备份与更新**；旧 `/admin/8311/firmware` 地址仍可访问。

### 生成备份

点击“生成备份”，浏览器下载 `8311-settings-*.env`。文件包含本版本支持的全部 8311 设置及自定义 VLAN Hook；未设置的字段也记为空值，以便恢复镜像默认值。页面不回显备份内容，下载响应禁止缓存。

不包含 SSH 密钥、TLS 证书、任意系统文件、原始 bootloader 变量、校准数据，以及其他分支的未知字段。普通升级会保留现有持久设置和 Hook；备份用于手动迁移或恢复，并不意味着升级会自动清空配置。

### 导入旧配置

1. 选择本页面生成的 `.env`，或兼容的 `8311_key=value` / `fwenvs_backup.env` 文件，最大 128 KiB。
2. 根据需要选择完整恢复，或保留当前 PON 身份与认证信息。完整恢复为导入默认范围，并要求额外确认。
3. 点击预览，核对将改变的字段名称，再确认恢复。含非空 Hook 时还会单独确认脚本安装。
4. 看到成功结果后，再按需点击重启。恢复和重置都不会自行重启设备。

文件必须先通过全部字段检查。缺失字段保持原值；空值删除对应覆盖。未知或重复字段、非法值、bootloader 字段及启用持久 RootFS 会被拒绝。**不接受普通 OpenWrt 备份 tar.gz，也不自动翻译 CN 特有参数。**

Hook 使用保留字段 `8311_backup_hook_b64`，解码后最大 64 KiB；空字段删除 Hook，旧备份不含该字段则保留原 Hook。先暂存并检查 shell 语法，再写配置；所有配置写入成功后才原子替换 Hook。使用持久 RootFS 的调试设备应先关闭该功能并重启，再使用备份/恢复。

### 重置设置

可选“保留 PON 身份与认证”（默认）或“同时清除已知 PON 设置”。两者都会清除其他已知 8311 覆盖值与 VLAN Hook；保留校准、bootloader 变量、固件槽、SSH 密钥和证书。此操作只重置 8311 管理的配置，不清理任意文件或 CN 未知字段。

### 更新固件

上传匹配 WAS-110 的 `local-upgrade.tar`，先校验，再安装到备用槽，最后单独重启。上传限制为 128 MiB；私有临时目录位于 RAM，安装还需要容纳三个未压缩组件。暂存空间不足会在写入前报错。取消或成功安装后删除上传文件，放弃的上传会保留到取消或重启。

不要仅看到“上传完成”就断电，也不要把“安装成功”当作已从新固件启动。应核对运行版本、活动槽、管理连接及真实线路业务。A/B 启动选择、一次试启动与持久默认槽的区别见 [固件槽说明](docs/firmware-banks.md)。

## 获取构建产物

[GitHub Actions](https://github.com/linlunaire/8311-was-110-firmware-builder/actions/workflows/test.yml) 在 Linux `sh` 和 BusyBox 两组回归通过后构建 basic 固件。进入成功的运行记录，下载 `WAS110-basic-<完整提交号>` artifact。

产物含 `local-upgrade.tar`、组件、`control`、`upgrade.sh`、`SHA256SUMS` 与 `build-manifest.json`。校验清单和 manifest 记录输入来源、源码提交及产物哈希；核对后再使用。CI 从不连接或刷写设备。

```sh
sha256sum --check SHA256SUMS
```

修正版构建：[b159a2c 的 Actions 记录](https://github.com/linlunaire/8311-was-110-firmware-builder/actions/runs/37109375958)。该版本包含真实设备验证中发现的旧 LuCI 权限参数修复，不要使用先前 `9b74460` 候选包。运行时验证与线路验证分开记录，详情见 [验证记录](docs/validation.md)。

## 从源码构建

需要 Linux checkout，以正确保留符号链接、文件权限和设备节点。先初始化固定版本的子模块：

```sh
git submodule update --init
```

### 使用固定的公开发布底包

适用于 basic 变体的脚本和 WebUI 更新，依赖 Python 3、Git、GNU coreutils 和 squashfs-tools。另需 7z 解包上游发布归档。底包来自 [上游 v2.8.3](https://github.com/djGrrr/8311-was-110-firmware-builder/releases/tag/v2.8.3) 中的 basic 归档，提取其 `local-upgrade.tar`：

```sh
sudo python3 tools/build_from_release.py \
  --base stock/upstream-v2.8.3-local-upgrade.tar \
  --output out/release
```

构建器强制核对固定底包及组件哈希，要求干净的已提交源码；叠加源码、编译翻译，并保持全部 ELF、内核模块和固件 blob 不变。打包后重新解包，逐项比较文件内容、权限、符号链接和设备节点。已有输出目录不会被覆盖。

**这是基于发布底包的重新构建，不是从厂商 SDK 重编内核或驱动。** 当前版本也没有声称字节级可复现构建；工具链版本仍可能影响生成镜像。

### 原厂镜像构建流程

原有 `build.sh` 保留，需要 Bash、GNU 工具、Python 3、Perl、sudo、squashfs-tools、u-boot-tools、mtd-utils；`--release` 还需要 7z。必须自行提供 BFW 原厂升级镜像和 basic 的三个原始组件：

```sh
./build.sh --bfw-image-file stock/bfw.img --basic-image-dir stock/basic \
  --basic -o out/local-upgrade.img -O out/local-upgrade.tar
```

`--image` / `--image-dir` 是兼容别名。不能把已经修改过的发布版冒充原厂输入重复套用补丁。全部选项以 `./build.sh --help`、`./create.sh --help` 和 `./extract.sh --help` 为准。本轮没有执行这条完整原厂输入构建流程。

## 开发与验证

```sh
sudo apt-get install lua5.1 pcre2-utils busybox
python3 -m unittest discover -s tests -v
TEST_SHELL=busybox TEST_SHELL_ARGS=sh python3 -m unittest discover -s tests -v
node tests/status_poll_smoke.cjs
```

离线测试用临时目录模拟 UBI、环境写入、EEPROM 和 LuCI，不会刷设备。Windows 可用 Git Bash、Python 和 Lupa 的 Lua 5.1 运行回归。可选 `node tests/frontend_smoke.cjs` 使用已安装的 Playwright/Chromium；`BROWSER_CHANNEL=msedge` 或 `chrome` 可选择现有浏览器。

当前验证包括：两组 Linux CI、32 项 Python/Shell 回归（其中包含 Lua 入口）、39 组 Lua 回归、14 组本地浏览器测试、原生 LuCI 模板检查，以及构建产物解包和哈希核对。各项检查的环境和限制见 [验证记录](docs/validation.md)。**测试通过不能替代启动、PON 注册、Internet、IPTV、断电恢复及长期运行。**

## 后续还能优化什么

| 方向 | 下一步需要的证据 | 当前决定 |
| --- | --- | --- |
| VLAN 应用结果回显 | daemon 已完成、失败及重试状态，与实际规则一致 | 可继续完善管理体验；目前只反馈配置已保存和刷新已安排。 |
| CN 的 PVID / IPTV 兼容 | 对照具体运营商、OLT、标签和组播流量逐项测试 | 不静默翻译 CN 参数，不先加入未经实测的线路规则。 |
| 并发状态查询共享缓存 | 同时打开多个管理客户端时的请求量、数据新鲜度 | 保留当前单面板合并；跨请求缓存要带时间戳并证明收益。 |
| 功耗和温度 | 接光纤后的注册、负载、温度稳态与丢包对照 | 保留原调频和驱动；没有降温收益证据前不改默认频率。 |
| 长期升级可靠性 | 实际启动与业务验收、断电恢复、更多设备回归 | 继续扩展实测覆盖，不能用脚本测试代替硬件恢复保证。 |

## 文档与来源

- [配置字段参考](docs/configuration-reference.md)：保留上游字段说明，示例不是运营商预设。
- [固件槽与本次安装边界](docs/firmware-banks.md)：A/B、共享配置与启动选择。
- [验证记录](docs/validation.md)：已经做过和仍未完成的检查。
- [流畅度、负载与温度](docs/performance-analysis.md)：设备上的测量方法和优化边界。
- [参考项目比较](docs/reference-designs.md)：CN、其他 ONU 项目、LuCI 和 procd 的可借鉴设计。
- [ImmortalWrt 可行性](docs/immortalwrt-assessment.md)：硬件支持核对与界面借鉴；没有可直接用于本设备的迁移结论。

感谢 8311 社区、原上游及子模块作者。本分支保留已有来源和文件内的许可证声明；不同上游源码、子模块和厂商二进制应分别遵守其适用许可，不能因重新打包就视为全部自研或统一许可。
