# WAS-110 固件工程参考调研

调研日期：2026-10-02。对应本仓库基线：`7d89440c7d9e1f209140910bb039f5d5a24dfbed`。目标是在保留上游 PON、OMCI、MIB 和硬件兼容行为的前提下，改善构建、升级、配置、后台任务和故障定位。

结论是先学习工程边界，再决定是否移植代码。最值得采用的六项设计是：依赖能力检查、分层镜像验证、明确的恢复阶段、配置校验与确认、事件合并与有限重试、能区分失败和未知的状态接口。仓库较新、包含 CI 或有成功案例，都不能证明适合当前 WAS-110 和当前运营商线路。

本文外部源码调研读取了以下固定提交的源码，并将下载的 50 个文件逐一与对应 Git tree 的 blob 哈希核对一致；这一调研过程没有运行第三方刷机脚本或访问设备，也未进行实机、断电或业务稳定性测试。下文明确区分已经存在的实现、本项目建议和仅有文档说明的行为。

| 项目 | 本次固定提交 | 实际核对的证据与边界 |
| --- | --- | --- |
| brudalevante/8311-was-110-firmware | [7754a3db60ef4acf11abe030a41ffb7c95402ad4](https://github.com/brudalevante/8311-was-110-firmware/tree/7754a3db60ef4acf11abe030a41ffb7c95402ad4) | 同类 WAS-110 构建器；读取检查器、提取器、打包器、升级器、测试和 CI。测试文件存在，但判定强度有限，见第 1、2 项。 |
| rssor/fs_xgspon_mod | [7e287a7fa9daa2786226596a3ebcd8b3eb98219b](https://github.com/rssor/fs_xgspon_mod/tree/7e287a7fa9daa2786226596a3ebcd8b3eb98219b) | CIG/FS 设备的启动脚本、库 shim、配置解析与安装代码；可证实保护逻辑存在，不能据此确认 WAS-110 可用。 |
| YuukiJapanTech/CA8271x | [ccbcb07a0a308e53087b2f1dc91b3d007753d37d](https://github.com/YuukiJapanTech/CA8271x/tree/ccbcb07a0a308e53087b2f1dc91b3d007753d37d) | 核对配置文档与 SIEPON-A 实际 shell/CGI。访问给定仓库地址未发生重定向；文档里的设备兼容表不视为本次测试结论。 |
| Anime4000/RTL960x | [ad2fde9df058e3fa70b8b079ae5bcd308d41e394](https://github.com/Anime4000/RTL960x/tree/ad2fde9df058e3fa70b8b079ae5bcd308d41e394) | 核对 VLAN 修正、IGMP 启动、外部监控及 QEMU 用户态脚本。源码存在，不等于完成了 PON 硬件仿真或实机验证。 |
| OpenWrt | [c2eb687d76a04bd66e45fdb2e47998f8f0f565b0](https://github.com/openwrt/openwrt/tree/c2eb687d76a04bd66e45fdb2e47998f8f0f565b0) | 官方依赖检查、镜像验证、sysupgrade 和 procd shell 接口；作为设计参考，不能直接替换 WAS-110 升级格式。 |
| LuCI | [aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f](https://github.com/openwrt/luci/tree/aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f) | 官方上传验证与 UCI apply/confirm 客户端；当前版本的 API 是否存在于设备旧版 LuCI/rpcd，仍须另行核对。 |
| procd | [5670ff93498d57657377d9a06fa08f7919fa0389](https://github.com/openwrt/procd/tree/5670ff93498d57657377d9a06fa08f7919fa0389) | 官方进程重启限制、日志与触发器合并源码；不建议为获得这些模式而整体升级设备的 init 系统。 |

**1. 构建前检查应检查实际能力，并保留真实失败。**

brudalevante 的 `check_deps.sh` 区分必须工具、可选工具和 Perl 模块，一次报告全部缺项；`build.sh` 也尝试在构建前调用它。这是实际实现。不过调用使用当前目录的 `./check_deps.sh` 且仅在其可执行时运行，从其他目录调用构建器可能绕过检查。[检查器][bdeps]、[调用位置][bbuild]

OpenWrt 的 `include/prereq-build.mk` 不只检查命令是否存在，还探测需要的行为，例如 GNU 工具、`stat -c%s`、`getopt --long`，并检查文件系统大小写和 umask。这种“验证实际使用的能力”的思路更适合避免宿主机差异。[官方能力检查][oprereq]

对本项目的建议：按实际构建分支检查依赖，使用构建脚本所在目录定位检查器；帮助信息不依赖完整工具链。对 GNU 参数、SquashFS 压缩算法、Perl 模块和子模块固定版本给出清楚结果。Windows 上的宿主工具、WSL/Linux 工具以及目标设备 BusyBox 应分开验证，不应把 OpenWrt 全量编译器要求照搬到这个重打包项目。

需要避开的反例：brudalevante 的 `tests/test_roundtrip.sh` 无输入时以 0 跳过；有输入时最终只比较重建文件的大小，差值超过 1 KiB 也只输出警告。`Makefile` 使用 `|| echo` 消化测试失败，CI 的依赖检查还设置了 `continue-on-error: true`。这些源码不能支持“CI 通过，因此镜像可靠”的结论。[测试实际判定][btest]、[Makefile][bmake]、[CI][bci]

建议验证：逐个移除必须依赖、替换成不支持所需选项的同名工具、从其他目录调用构建器，并检查在创建输出前失败；用固定脱敏镜像样本提取、重组、再提取，逐组件核对哈希。CI 缺样本应明确报告覆盖缺口，损坏样本和校验失败必须返回非零。

**2. 镜像验证应明确格式、设备、配置和写入结果四个边界。**

OpenWrt 的 `validate_firmware_image` 输出 `tests`、`valid`、`forceable`、`allow_backup`，把平台检查结果与总体决策分开；`fwtool.sh` 校验设备标识和配置兼容版本。LuCI 上传后先调用验证接口，再执行 `sysupgrade --test`；真正执行 sysupgrade 时后端仍会重新验证。[结构化验证][ovalidate]、[设备与兼容版本][ofwtool]、[LuCI 两步检查][lflash]、[实际升级入口][osysupgrade]

这里也有条件：OpenWrt 是否要求签名和元数据取决于 `REQUIRE_IMAGE_SIGNATURE`、`REQUIRE_IMAGE_METADATA` 等策略，不能概括成“OpenWrt 总会强制验证签名”。WAS-110 的厂商镜像、升级 tar、UBI 卷和启动环境与 OpenWrt 通用 sysupgrade 不同，不能追加不兼容元数据或直接调用现代 sysupgrade 来代替现有流程。[策略实现][ofwtool]

brudalevante 的提取器增加了固定 magic、数字长度和输出长度检查，但仍有值得防止的边界：`head -c "$POS" | tail -c "$LEN"` 在累计位置超过文件末尾时，可能从之前组件的尾部取得足够的字节，让“长度正确”成立。因此必须先检查完整头部、累计偏移与总长度、各组件顺序、数值上限，再提取；输出字节数只能作为补充检查。这是由代码路径得出的风险推断，本次未执行它的坏镜像测试。[提取器 84–122 行][bextract]

对本项目的建议：保留上游镜像协议，先把归档成员、control 字段、格式、大小、哈希和目标分区全部验证完，再进入写入阶段；对用于写入的同一份私有暂存文件做验证，避免验证后原上传文件被替换。写入备用分区后读回核对，全部通过才切换启动选择。校验和证明完整性，不单独证明发布者身份；两者在 UI 和日志中应分开表达。

建议验证：错误 magic、短头、声明超长、累计越界、负数/超大数/前导零、缺失或重复归档成员、坏 control、坏哈希、暂存空间不足、上传后替换原文件、写入失败、读回失败。所有在写入前可发现的错误都应有“UBI 和启动环境写入次数为零”的断言；不能只核对退出码。

**3. 把临时试用、启动保护和固件回滚分开设计。**

rssor 的 `rwdir/stage0.sh` 在运行修改前先创建 `disarmed` 标记并同步；未启用自动重装载时，还会移除下次启动的入口。安装更新时也先撤销既有自动重装载状态，防止新版本继承旧版本的成功许可。这是可读到的实际保护代码。[启动保护][rstage]、[安装和持久化流程][rinstall]

不过它恢复的是“是否加载修改”，不是双分区固件自动回滚。其 `payload_postboot` 等待约 100 秒、尝试启动 dropbear，再按标记重新启用；相应成功标记不能证明 PON 注册、Internet 或 IPTV 正常。README 描述的快速断电恢复也依赖 CIG 固件的共享用户分区和启动入口，不能移植成 WAS-110 的保证。[计时与重新启用][rpostboot]、[项目说明][rreadme]

对本项目的建议：升级状态区分接收、验证、写入、读回核对、切换启动选择、等待重启，以及具体失败阶段。切换前失败应保留原启动选择；Web 请求被中断不能自动解释为成功或失败。本轮采用私有暂存目录的方向与这个边界一致；可重新查询的任务状态属于后续建议，不能把现有命令输出和退出码称为持久化任务状态。

真正的“新固件启动失败自动回退”需要另行核对 WAS-110 当前 bootloader、`commit_bank`、启动计数和备用分区语义，不能仅增加一个超时脚本。尤其不应把短暂的 OLT 维护、光路中断或 IPTV 不通直接作为自动切换固件条件。

建议验证：在每个阶段注入命令失败，核对状态、锁、临时文件和启动选择；验证服务或浏览器退出后能重新查询同一任务。涉及断电和启动回退的结论只能由有恢复手段的对应硬件实验产生，离线 mock 不能代替。

**4. 配置应先完整校验，再持久化，并区分保存值和生效值。**

rssor 的 Python 配置层为不同 ISP 列出必需字段、允许的厂商标识及默认推导，参数解析也验证串号长度、十六进制和 VLAN 规则字段范围。这说明约束可以集中维护，而不应只存在于网页输入框。[配置构造][rconfig]、[参数校验][rparse]

这些范围是该实现的协议约定。例如其 VLAN 规则允许 4096、优先级字段允许到 15；它们不能直接成为普通用户 VLAN ID 或 802.1p PCP 的合法范围。应按本仓库现有 OMCI 接口对特殊值逐项解释，避免“参考项目允许，所以这里也允许”。[规则语义和范围][rparse]

CA8271x 的 `doc/scfg_files.md` 记录了 XG-99x 上多层配置覆盖和临时生成文件。它适合提醒我们显示“保存到哪里、何时生效、最终值从哪里来”，但这部分是该项目文档，本次没有验证其所述设备的加载顺序。它的实际 `set_ip_set.sh` 有 IPv4 格式检查，却直接编辑文件并报告保存，不能据此认为具备完整事务和网络可达性回退。[配置层次文档][cscfg]、[实际 IP 保存 CGI][cip]

LuCI 的 `uci.js` 已实现带超时的 apply/confirm 调用和确认重试，可借鉴“应用后确认”的交互。它依赖 rpcd/UCI 后端，不能自动撤销 WAS-110 的 `fwenv`、EEPROM 或厂商配置写入；确认 RPC 成功也不是线路业务测试。[apply/confirm 实现][luciapply]

对本项目的建议：先校验整个提交集，再写入；服务端按同一字段定义检查长度、范围、枚举、地址和跨字段关系。每次持久化检查返回值并读回；只有值确实一致才能报告保存成功。多项写入的部分失败要明确标出已经完成的项，未经验证不要宣称全部原子回退。管理 IP 等可逆配置可单独设计超时确认，PON 身份参数则保留上游应用时机。

建议验证：绕过前端直接提交、未知字段、边界值、控制字符和特殊 shell 字符、保存失败、读回不一致、并发提交、保存后尚未重载、重载后值被更高优先级覆盖。验证的目标同时包含“拒绝了坏输入”和“未损坏之前有效配置”。

**5. 后台修正应合并重复事件，只写差异，并限制失败重试。**

procd 的触发器使用待处理命令表合并重复事件，正在执行时记录一次重新排队；进程管理按运行时长、重试数与间隔识别崩溃循环，并发出 `instance.fail` 等事件。这些是实际源码中的机制，可作为轻量后台任务的参照。[触发器合并][ptrigger]、[有限 respawn][pinstance]、[shell 接口][oprocd]

RTL960x 的 `fix_vlan_fwdop.sh` 先读取现有 Entity 和 FwdOp，缺少目标或已相同就跳过；注释也把它放入统一调度循环。这种“读取、比较、必要时写入”的方式可迁移。另一份 `fix_vlan_tag.sh` 在没有 VLAN/Entity 配置时默认修改所有条目，且循环调用 CLI，不能把这种默认覆盖范围带入本项目。[单次差异修正][rvlanonce]、[全条目回退行为][rvlanloop]

对本项目的建议：保持单一任务拥有 PON/VLAN 修正入口；重载信号只标记需要刷新，让已有循环处理，避免并发 CLI 调用。外部命令须有超时，失败采用有上限的退避并输出一次可定位日志，成功后恢复正常节奏；读到相同状态不重复写入。事件不可靠时可保留低频校准，不应仅为追求事件驱动而删除已有必要兼容逻辑。

CA8271x 的实际 `ProcMonitor.sh` 每 5 秒用 `ps | grep` 检测 Web 服务，`Background_API.sh` 可每 30 秒执行强制流量操作。这些更适合作为对照：不能仅因源码在维护就认定其生命周期管理比现有 procd 更好；其 IROS 端口号和强制桥接规则尤其不适合移植到 WAS-110。[进程轮询][cproc]、[IROS 后台操作][cbg]

建议验证：重复/突发重载、CLI 长时间无响应、CLI 非零退出、连续失败后恢复、daemon 被终止、OMCI 重新下发、接口抖动及空规则集。记录实际命令次数、同时运行的子进程数和恢复时间；确认调整调度没有改变 OMCI 参数、规则顺序或默认作用范围。

**6. 状态输出需要可观测性，也需要明确的未知态。**

CA8271x 的状态 CGI 分别导出注册、上行、温度、电压和光功率；RTL960x 的外部 `kitamon` 实现了 5 秒缓存及 HTTP 超时。这些代码展示了“分层读取”和“控制读取频率”的实用方向。[CA 状态源][cstatus]、[缓存和超时][rmetrics]

也不能照抄它们的诊断结论。CA 的 CGI 用 shell 字符串直接拼 JSON；RTL 的 `calculate_los` 根据固定光功率阈值、O5 和某个 Entity 是否出现，输出诸如认证成功、OLT 拒绝等原因，而 OMCI 读取异常还可能被忽略。这只是该代码的推断模型，不能证明对应因果，也不适合作为 WAS-110 的确定故障诊断。[状态序列化][cstatus]、[诊断推断和异常处理][rdiagnostic]

对本项目的建议：接口保留原始数值、单位、采样时间、来源、命令退出状态，以及“有效、缺失、超时、解析失败”的区别。分别呈现光学、PON 注册、OMCI 配置、业务 VLAN、以太网链路和升级任务状态；未知不能填成 0 或健康。短时缓存按需要使用，避免网页每次刷新触发完整 MIB dump。

最小支持包适合包含版本、任务阶段、退出码、必要的进程/接口状态和经筛选日志；完整 fwenv、LOID/PLOAM、密钥、登录凭证和未处理的 OMCI 配置不应默认进入包。若需长期时序图，应先考虑路由器或其他主机上的外部采集，而不是在资源有限的 ONU 上增加完整监控栈。

建议验证：空/短 EEPROM、非数值光功率、CLI 卡住、部分返回、包含引号和换行的字段、时间戳过期、并行查询，以及支持包中的敏感字段抽查。每个“失败原因”必须能追溯到实际证据；仅依据多个现象作出的推断要明确标注。

**国内 VLAN / IPTV 应如何排序。**

“能注册到 OLT”“Internet 可以联网”“IPTV 直播和点播正常”应分别验收。RTL960x 的 OMCI 文档能看到一个设备存在多个业务 VLAN；其固件另有独立的 IGMP 驱动和守护程序启动脚本，说明至少在该实现中，VLAN 配置与组播处理是两个实际组件。不能从这些国外或其他芯片案例推导全国统一的 VLAN 号、OMCI 模板或 IPTV 配置。[多 VLAN 示例][romcivlan]、[IGMP 组件][rigmp]

| 当前需求 | 对本项目的优先级 | 验证范围 |
| --- | --- | --- |
| 只使用 Internet，且已有在同线路验证通过的固件 | 保持现有 VLAN/OMCI 行为是高优先级；新增 IPTV 选项可以后置 | 记录实际已下发规则、tag/untag 行为、重启与重新注册后的联网情况。不能因为换了 UI 就改变默认 VLAN 修正策略。 |
| 同时使用运营商 IPTV | 业务 VLAN 和转发行为应在迁移前重点核对 | 按当前线路分别验证 Internet、机顶盒获取业务配置、直播、换台、长时间观看、点播；实际使用组播时还要验证加入/离开与是否影响其他端口。 |
| 运营商、地区、OLT 或接入方式变化 | 重新建立兼容证据 | 先保存新线路的只读观察，再决定是否需要特殊规则；一个 ISP 的补丁不能默认为另一个 ISP 启用。 |

因此，有 IPTV 需求时国内适配很重要，但应先建立当前 xiao-k233 上的业务基线和上游行为对照。是否迁移某项规则取决于实际业务差异，不能仅凭“国内版”名称判断。上述表格是条件情形和工程优先级建议，不表示当前设备已通过线路测试；本文外部源码调研未读取该设备，也不评价它当前固件的线路稳定性。

<a id="cn-configuration-compatibility"></a>

**xiao-k233 CN 配置不能直接照搬到本轮上游优化分支。**

主任务另行对比了 CN 的固定提交 `4324d7e15318f0ee5ded1abfb518b9a8fa45dc3d` 与本仓库基线，以下是源码中的实际差异，不是线路测试结论：

| 配置 | CN 定义 | 本仓库上游定义 |
| --- | --- | --- |
| `fix_vlans=2` | TC 模式 | 仅运行 Hook 脚本 |
| `uvlan` | 为 untag 报文指定默认 PVID，也允许 `u` 模式 | 使用 `internet_vlan` 指定面向本地网络的 Internet VLAN，二者不能按字段名直接互换 |
| `mvlansource` / `multicast_vlan` | 下行组播源 VLAN / 转换后的 VLAN | `services_vlan` 是上游已有特定多业务策略的配置，不能替代这两个字段 |
| `igmp_version` | 对 ME309 使用的 IGMP 版本 | 本轮没有引入该 CN 配置项 |

这些定义可在 [CN 配置控制器](https://github.com/xiao-k233/8311-was-110-firmware-builder/blob/4324d7e15318f0ee5ded1abfb518b9a8fa45dc3d/files/basic/usr/lib/lua/luci/controller/8311.lua) 与 [上游配置控制器](https://github.com/linlunaire/8311-was-110-firmware-builder/blob/7d89440c7d9e1f209140910bb039f5d5a24dfbed/files/basic/usr/lib/lua/luci/controller/8311.lua) 中核对。即使 fwenv 值在刷机后保留，同一个值也可能触发不同的行为。

因此本轮没有进行配置值自动翻译，也未向设备部署此分支。迁移需要先确认现有配置的真实作用，再按 Internet、IPTV 直播和点播分别验收；设备里已经保存某个 VLAN 号不代表它适用于当前线路。

**平台与许可证边界。**

| 来源 | 不可直接迁移的内容 | 复制代码前的核对点 |
| --- | --- | --- |
| brudalevante | 同类硬件也不能默认 bootloader、内核、MIB、默认配置和包版本完全一致；不采用其放宽 SSH 密码认证的默认设置 | 固定 tree 未见仓库根级 LICENSE/COPYING；相关文件的来源和授权需另行明确。查看公开仓库不代表获得任意再分发许可。[固定 tree][btree]、[其 SSH 默认说明][breadme] |
| rssor | CIG 的共享用户分区启动钩子、`libvos`/MIB 符号 shim，以及指定 MIPS/glibc 构建条件 | 固定 tree 未见许可证文件，所读脚本也未给出明确授权声明。借鉴设计并自行实现；复制前确认授权。[tree][rtree]、[构建 ABI][rmake] |
| CA8271x | Cortina IROS、EPON/SIEPON、端口编号、ROM 配置和固件二进制 | 根级 LICENSE 为 GPL-3.0；仍需逐文件追溯作者和第三方素材，不能把仓库许可证当作其中厂商 blob 的统一授权。[许可证][clicense] |
| RTL960x | Realtek `omcicli`/`diag`、IGMP 模块、flash 参数和根文件系统格式 | 根级 LICENSE 为 Unlicense；固件、图像和其他第三方内容仍应分别核对来源。保留所借鉴代码中的作者信息。[许可证][rlicense] |
| OpenWrt / LuCI / procd | 通用 sysupgrade 格式、现代 ubus/UCI API、完整 init 替换 | 本次文件来源分别包含 OpenWrt GPL-2.0-only、LuCI 根级 Apache-2.0、procd 文件头 LGPL-2.1。实际复制时保留相应声明并按文件核对，不能笼统视作同一许可。[OpenWrt][olicense]、[LuCI][llicense]、[procd 文件头][plicense] |

当前最合适的落地顺序是先完成不改变线上协议行为的检查、状态和失败处理，再验证现有 VLAN 后台任务的调度，最后依据实机业务证据决定是否增加 ISP/地区策略。QEMU 用户态、Shell/Lua 测试、镜像格式测试、完整构建、实际开机、PON 注册和 Internet/IPTV 验收应分别记录；RTL960x 的 QEMU 工具也只是用户态环境，不能据此证明光模块硬件行为。[QEMU 工具实现][rqemu]

[btree]: https://github.com/brudalevante/8311-was-110-firmware/tree/7754a3db60ef4acf11abe030a41ffb7c95402ad4
[breadme]: https://github.com/brudalevante/8311-was-110-firmware/blob/7754a3db60ef4acf11abe030a41ffb7c95402ad4/README.md
[bdeps]: https://github.com/brudalevante/8311-was-110-firmware/blob/7754a3db60ef4acf11abe030a41ffb7c95402ad4/check_deps.sh#L20-L79
[bbuild]: https://github.com/brudalevante/8311-was-110-firmware/blob/7754a3db60ef4acf11abe030a41ffb7c95402ad4/build.sh#L40-L60
[btest]: https://github.com/brudalevante/8311-was-110-firmware/blob/7754a3db60ef4acf11abe030a41ffb7c95402ad4/tests/test_roundtrip.sh#L11-L68
[bmake]: https://github.com/brudalevante/8311-was-110-firmware/blob/7754a3db60ef4acf11abe030a41ffb7c95402ad4/Makefile#L20-L22
[bci]: https://github.com/brudalevante/8311-was-110-firmware/blob/7754a3db60ef4acf11abe030a41ffb7c95402ad4/.github/workflows/ci.yml#L37-L45
[bextract]: https://github.com/brudalevante/8311-was-110-firmware/blob/7754a3db60ef4acf11abe030a41ffb7c95402ad4/extract.sh#L84-L122
[oprereq]: https://github.com/openwrt/openwrt/blob/c2eb687d76a04bd66e45fdb2e47998f8f0f565b0/include/prereq-build.mk#L19-L31
[ovalidate]: https://github.com/openwrt/openwrt/blob/c2eb687d76a04bd66e45fdb2e47998f8f0f565b0/package/base-files/files/usr/libexec/validate_firmware_image#L9-L75
[ofwtool]: https://github.com/openwrt/openwrt/blob/c2eb687d76a04bd66e45fdb2e47998f8f0f565b0/package/base-files/files/lib/upgrade/fwtool.sh
[osysupgrade]: https://github.com/openwrt/openwrt/blob/c2eb687d76a04bd66e45fdb2e47998f8f0f565b0/package/base-files/files/sbin/sysupgrade#L399-L456
[lflash]: https://github.com/openwrt/luci/blob/aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js#L201-L219
[rstage]: https://github.com/rssor/fs_xgspon_mod/blob/7e287a7fa9daa2786226596a3ebcd8b3eb98219b/rwdir/stage0.sh#L3-L18
[rinstall]: https://github.com/rssor/fs_xgspon_mod/blob/7e287a7fa9daa2786226596a3ebcd8b3eb98219b/fs_xgspon_mod.py#L599-L673
[rpostboot]: https://github.com/rssor/fs_xgspon_mod/blob/7e287a7fa9daa2786226596a3ebcd8b3eb98219b/shim/shim.c#L338-L369
[rreadme]: https://github.com/rssor/fs_xgspon_mod/blob/7e287a7fa9daa2786226596a3ebcd8b3eb98219b/README.md
[rconfig]: https://github.com/rssor/fs_xgspon_mod/blob/7e287a7fa9daa2786226596a3ebcd8b3eb98219b/fs_xgspon_mod.py#L55-L126
[rparse]: https://github.com/rssor/fs_xgspon_mod/blob/7e287a7fa9daa2786226596a3ebcd8b3eb98219b/fs_xgspon_mod.py#L736-L785
[cscfg]: https://github.com/YuukiJapanTech/CA8271x/blob/ccbcb07a0a308e53087b2f1dc91b3d007753d37d/doc/scfg_files.md
[cip]: https://github.com/YuukiJapanTech/CA8271x/blob/ccbcb07a0a308e53087b2f1dc91b3d007753d37d/mod/siepon_a/SOURCE/script/web/www/cgi-bin/set_ip_set.sh
[luciapply]: https://github.com/openwrt/luci/blob/aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f/modules/luci-base/htdocs/luci-static/resources/uci.js#L980-L1019
[ptrigger]: https://github.com/openwrt/procd/blob/5670ff93498d57657377d9a06fa08f7919fa0389/service/trigger.c#L158-L188
[pinstance]: https://github.com/openwrt/procd/blob/5670ff93498d57657377d9a06fa08f7919fa0389/service/instance.c#L1091-L1114
[oprocd]: https://github.com/openwrt/openwrt/blob/c2eb687d76a04bd66e45fdb2e47998f8f0f565b0/package/system/procd/files/procd.sh
[rvlanonce]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/Firmware_Mod/DFP-34X-2C2/etc/scripts/fix_vlan_fwdop.sh
[rvlanloop]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/Firmware_Mod/DFP-34X-2C2/etc/scripts/fix_vlan_tag.sh#L8-L46
[cproc]: https://github.com/YuukiJapanTech/CA8271x/blob/ccbcb07a0a308e53087b2f1dc91b3d007753d37d/mod/siepon_a/SOURCE/script/ProcMonitor.sh
[cbg]: https://github.com/YuukiJapanTech/CA8271x/blob/ccbcb07a0a308e53087b2f1dc91b3d007753d37d/mod/siepon_a/SOURCE/script/Background_API.sh
[cstatus]: https://github.com/YuukiJapanTech/CA8271x/blob/ccbcb07a0a308e53087b2f1dc91b3d007753d37d/mod/siepon_a/SOURCE/script/web/www/cgi-bin/status.sh
[rmetrics]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/WebGui/kitamon/main.py#L75-L144
[rdiagnostic]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/WebGui/kitamon/main.py#L170-L241
[romcivlan]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/Docs/OMCI_VLAN.md#L5-L55
[rigmp]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/Firmware/TWCGPON657/scripts/runigmp.sh
[rtree]: https://github.com/rssor/fs_xgspon_mod/tree/7e287a7fa9daa2786226596a3ebcd8b3eb98219b
[rmake]: https://github.com/rssor/fs_xgspon_mod/blob/7e287a7fa9daa2786226596a3ebcd8b3eb98219b/Makefile
[clicense]: https://github.com/YuukiJapanTech/CA8271x/blob/ccbcb07a0a308e53087b2f1dc91b3d007753d37d/LICENSE
[rlicense]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/LICENSE
[olicense]: https://github.com/openwrt/openwrt/blob/c2eb687d76a04bd66e45fdb2e47998f8f0f565b0/COPYING
[llicense]: https://github.com/openwrt/luci/blob/aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f/LICENSE
[plicense]: https://github.com/openwrt/procd/blob/5670ff93498d57657377d9a06fa08f7919fa0389/service/instance.c#L1-L13
[rqemu]: https://github.com/Anime4000/RTL960x/blob/ad2fde9df058e3fa70b8b079ae5bcd308d41e394/Tools/emulator/qemu-test.sh
