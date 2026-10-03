# ImmortalWrt 迁移与“恢复／更新固件”页面评估

调研日期：2026-10-03。本次外部源码调研只读取官方仓库、官方发布目录和本仓库源码，没有访问或修改设备。本文区分设计可行性、已有代码和实测收益；调研本身不测量部署效果，不能据此报告设备已经更流畅、负载下降或温度降低。后续构建与实机进展单独记在 [验证记录](validation.md)。

**可行动结论。**

1. 本轮已在本地代码中增加“系统 → 备份与更新”，沿用现有 LuCI 主题，提供“恢复”和“更新固件”两栏，省略“生成备份”区；配置恢复仅接受经过校验的 8311 `.env` 文件，固件更新沿用 8311 双分区后端。保留现有内核、厂商 PON/OMCI、驱动和 MIB，不调用通用 sysupgrade 或 firstboot。尚未部署到设备。
2. 本次对比的 ImmortalWrt 与 OpenWrt 官方 LuCI `flash.js`，仅有三处重连域名不同。将 `immortalwrt.lan` 替换为 `openwrt.lan` 后，全文文本一致。因此这套页面交互可以独立采用。[ImmortalWrt 页面][iflash]、[OpenWrt 页面][oflash]
3. 在本次核对的官方主线、稳定版目标树和发布目录中，未发现可直接用于 WAS-110／PRX126／PRX300 的官方设备适配和刷机路径。这个结论限定于下述检查范围，不排除未检查的分支、独立厂商 SDK 或第三方移植。
4. 没有证据表明仅更换发行版名称或采用这两栏 UI，就能降低该 WAS-110 的运行负载或温度。完整系统移植的兼容工作应单独评估；眼下优先完成现有代码优化、页面后端适配及对应验证。

**本次固定的证据。**

| 来源 | 固定版本 | 用途 |
| --- | --- | --- |
| ImmortalWrt 主线 | [5233c153ef7f119c567b54a92feea6919b167e84][itree] | 目标目录、内核版本、升级后端和内核包依赖 |
| ImmortalWrt 稳定版 v25.12.2 | [4fc16f2985a358bd43bb522e43f05395fcbd6ed5][istable] | 与主线交叉核对目标支持；调研时官方下载首页列为当前稳定版 |
| ImmortalWrt LuCI | [5fc1fac5684cac6eee2c7fbff78c65b867980dd8][iltree] | 页面、菜单、权限和运行时依赖 |
| OpenWrt LuCI | [aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f][oltree] | 同一路径页面的全文比较 |
| 本仓库基线 | [7d89440c7d9e1f209140910bb039f5d5a24dfbed][bbase] | 默认非持久 rootfs、原厂二进制处理与双分区升级语义 |

ImmortalWrt 官方 README 将其描述为 OpenWrt 分支，提供更多软件包、设备支持、默认配置优化与本地化；这描述了项目方向，没有给出当前 WAS-110 的性能或温度对照数据。[官方项目说明][ireadme]

**官方目标支持的核对范围。**

通过 GitHub 官方 tree API 读取主线完整树 13,218 项、v25.12.2 完整树 12,673 项，两次返回的 `truncated` 均为 false；对路径中的 WAS-110、PRX126、PRX300、intel_mips、omcid、pon_adapter 等候选名称检索未命中。随后实际阅读 Lantiq 目标、Falcon 子目标和 Falcon image 定义，而非只依赖搜索引擎结果。[主线完整树][itreeapi]、[稳定版完整树][istableapi]

主线 `target/linux/lantiq/Makefile` 的子目标为 xrx200、xrx200_legacy、xway、xway_legacy、falcon、ase，内核系列为 6.18；稳定版同一目标采用 6.12。Falcon 的 `target.mk` 虽然写着 MIPS / 24kc，也明确带有 `source-only` 标志；其 `image/falcon.mk` 列的是 EASY98xxx、Falcon SFP 等具体板型，没有 WAS-110。CPU 名称相同不构成板级、闪存布局、驱动或 PON 兼容证据。[主线 Lantiq][ilantiq]、[稳定版 Lantiq][islantiq]、[Falcon 子目标][ifalcon]、[Falcon 设备定义][ifalconimages]

官方 v25.12.2 的 Lantiq 发布目录本次只列出 xrx200、xrx200_legacy 和 xway。它与源码中的 Falcon `source-only` 标记相互印证，但也不能据此推断所有 Lantiq 系统都不支持 PON，更不能把某个 Falcon SFP 固件直接视作 WAS-110 固件。[官方发布目录][idownloadlantiq]、[官方版本入口][idownload]

主任务提供的当前运行环境是 Linux 4.9.308+、MIPS24kc、Lua 5.1.5，并依赖厂商 PON/OMCI 及驱动。现有构建器也针对特定原厂 `omcid`、`libpon`、`libponnet` 二进制哈希进行处理。更换根文件系统、libc、内核或 init 组件时，必须验证这些程序和驱动的接口；ImmortalWrt 的内核包依赖本身也绑定 Linux 版本与 vermagic。因此“保留几个原厂文件，再刷通用 ImmortalWrt”尚不构成可用移植方案。[本仓库二进制处理][bbinary]、[内核包的版本依赖][ikernel]

**页面来源与后端假设。**

官方两栏位于 `modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js`，菜单入口为 `admin/system/flash`，权限依赖 `luci-mod-system-flash`。页面是通过 LuCI 的 view、form、rpc、fs、ui 模块工作，不是只复制一段 HTML 就会生效。[页面源码][iflash]、[菜单定义][imenu]、[权限定义][iacl]

| 用户操作 | 官方源码实际执行 | WAS-110 需要保留或重新定义的语义 |
| --- | --- | --- |
| 上传恢复包 | 上传到 `/tmp/backup.tar.gz`，运行 `tar -tzf`，展示包内文件列表 | 可读 tar 只证明容器可解析；还要检查备份格式、字段、大小、路径、归属设备和可恢复范围。 |
| 确认恢复 | `sysupgrade --restore-backup` 成功后重启 | 官方 sysupgrade 在没有平台恢复钩子时解压到 `/`；本设备必须映射到实际持久化配置，不能仅覆盖普通 rootfs 文件。 |
| 恢复默认设置 | `firstboot -r -y` | 必须定义重置哪些用户设置，避免用通用 overlay 清空操作代替对 fwenv／ptconf 的正确处理。 |
| 上传固件 | 上传后调用 `system.validate_firmware_image` 和 `sysupgrade --test`，显示大小与校验信息 | 改用当前 WAS-110 镜像／control 格式和目标 UBI 卷检查；通用 sysupgrade 格式不是本机升级格式。 |
| 确认刷写 | 调用 sysupgrade，等待重连 | 延续本机备用 bank 写入、逐组件读回校验、最后切换启动选择的流程。网页断连不等于写入成功。 |

表中流程均可在固定页面与后端源码中追溯。现代页面仅用 `platform.sh` 文件是否存在判断是否显示刷机入口；容量还依据 `/proc/mtd` 和 `/proc/partitions` 的常见分区名称估算。页面按钮可用和粗略容量估算不能替代 WAS-110 各 UBI 卷及两个 bank 的实际验证。[恢复与刷机调用][iflash]、[恢复后端][irestore]、[容量与入口判断][iflash]

官方升级校验返回 `valid`、`forceable`、`allow_backup`；真正执行 sysupgrade 时再次检查镜像。页面里的“保留设置”由 sysupgrade 生成配置包并交给后续升级流程处理，不代表逐字保留旧 rootfs。默认 NAND 辅助脚本以 kernel、rootfs、ubi、rootfs_data 等约定工作，具体平台须提供正确的覆盖和升级实现。[验证结果][ivalidate]、[实际升级流程][isysupgrade]、[NAND 存储处理][inand]

本仓库默认未启用 `8311_persist_root` 时，启动命令包含移除 `rootfs_data`；另有 ptconf 持久化区。直接解压通用 OpenWrt 备份到 `/` 后重启，不能保证这些恢复值仍然存在，也不能恢复未写入其中的 fwenv。现有升级器则分别写入 `kernel$INSTALL_BANK`、`bootcore$INSTALL_BANK`、`rootfs$INSTALL_BANK`，完成后修改 `commit_bank`。这些约定应由本机后端负责。[rootfs 行为][bpersist]、[ptconf 挂载][bptconf]、[双分区流程][bupgrade]

现代 ImmortalWrt `luci-base` 还依赖 rpcd、rpcd-mod-file、rpcd-mod-ucode、ucode 及多个 ucode 模块；设备现有 Lua 5.1.5 不能被当作这些新 API 已存在的证明。当前适合复用布局、文案和“上传—校验—预览—确认—结果”的交互，在现有 Lua/HTML 控制器中实现相应接口。是否整体更新 LuCI，属于另一项依赖与回归工作。[LuCI 运行时依赖][ilucibase]

**两栏的具体落地边界。**

本轮最终实现“备份与恢复”栏：由页面生成私密的 8311 `.env` 备份，再接受同格式或兼容旧 `.env` 文件。导出全部已知设置与自定义 VLAN Hook；恢复按已定义的字段和值解析，不把配置文件当作 shell 脚本执行。其他固件备份如需兼容，应另行定义转换规则；当前不能把通用 OpenWrt tar 归档描述为受支持输入。恢复前展示将修改的项目名、跳过数量和重启提示，不回显配置值或凭证。

后端应在任何写入前验证整个恢复集：文件大小上限、允许字段、重复项、非法值及超长内容；普通配置恢复不接受 bootcmd、commit_bank、分区布局、校准数据和任意文件。唯一脚本入口为已声明的 VLAN Hook 备份字段，必须经过大小、编码和 shell 语法检查，并在界面单独确认；备份仍只能来自可信来源。需要持久化的值通过本机配置写入接口处理并读回，失败报告具体项目；没有事务保障时不宣称已经完整回滚。导入配置和清空系统是不同操作，本轮不通过恢复按钮隐式调用 firstboot。

“更新固件”栏复用现有受支持的 WAS-110 升级入口。上传、校验和实际刷写使用同一份私有暂存文件；并发操作互斥，验证完整 control、组件大小／哈希及目标 bank，全部满足后才写入。校验失败应停止，不能照搬官方通用页面的“强制升级”选项来绕过本机规则。固件接受格式必须在页面上明确，不能由于页面外观相似就暗示兼容任意 ImmortalWrt sysupgrade 镜像。

两个写操作都应保留现有登录、POST 和会话令牌保护；服务端验证必须独立于前端。官方 LuCI 的 flash ACL 也明确区分读取与上传／执行权限，可借鉴这个权限边界，而不复制它对原始 MTD 下载、firstboot 和通用 sysupgrade 的全部授权。[官方 ACL][iacl]

本地实现提供两种重置范围：默认保留 PON 身份和认证参数，也可选择同时重置全部已知 PON 设置；两种都保留原厂校准、引导程序、固件分区、SSH 密钥和证书。重置仅覆盖当前字段定义中的 8311 配置与 VLAN 钩子，不代表清空任意文件或其他分支的未知字段。导入上限 64 KiB，先预览项目名，再确认写入；恢复默认管理地址和 root 密码的影响会在确认前显示。启用了持久化 RootFS 时，要求先关闭并重启；恢复／重置成功后也单独提供重启操作。验证范围见 [验证记录](validation.md)。

页面是基于现有模板与后端的改写，没有直接复制现代 `flash.js`。若后续直接复用 LuCI 代码，应保留 Apache-2.0 及相应作者／NOTICE 信息；页面许可证不包含厂商 PON 二进制的再分发授权。[LuCI 模块声明][imodule]、[LuCI LICENSE][ilicense]

**如何验证流畅度、负载和温度收益。**

| 指标 | 建议对照方法 | 不能据此代替的结论 |
| --- | --- | --- |
| 页面流畅度 | 同一浏览器、同一连接方式比较首次加载、状态接口延迟、点击响应和请求数量；区分浏览器渲染与设备命令等待 | 页面更快不能证明链路吞吐提高。 |
| CPU／负载 | 分别测网页关闭、状态页开启、固定网络流量时的 CPU、进程数、后台命令频次；重复采样并保留波动 | 一个 load average 数值不能证明功耗下降。 |
| 温度 | 固定环境温度、主机 SFP 插槽、散热方式、链路速率、光纤接入状态和业务负载，等待温度稳定后比较同一传感器 | 未接光纤的闲置状态不能与在线高负载直接比较；温度变化不能仅归因于发行版。 |
| 功能兼容 | 开机、管理口、恢复后的持久值、备用分区升级、PON 注册、OMCI 下发、Internet 和实际需要的 IPTV 分别验收 | UI 成功、编译成功、镜像校验成功和实际业务成功属于不同验证层次。 |

本地可先验证旧 Lua／BusyBox 下的语法与 mock 后端、异常恢复包、上传中断、重复提交、坏镜像、写入失败和读回不一致。实际负载、温度和业务兼容性只能在部署到对应设备并控制实验条件后报告；本文未执行这些实验，也不提供未经测量的百分比或降温数值。

[itree]: https://github.com/immortalwrt/immortalwrt/tree/5233c153ef7f119c567b54a92feea6919b167e84
[istable]: https://github.com/immortalwrt/immortalwrt/tree/4fc16f2985a358bd43bb522e43f05395fcbd6ed5
[iltree]: https://github.com/immortalwrt/luci/tree/5fc1fac5684cac6eee2c7fbff78c65b867980dd8
[oltree]: https://github.com/openwrt/luci/tree/aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f
[bbase]: https://github.com/linlunaire/8311-was-110-firmware-builder/tree/7d89440c7d9e1f209140910bb039f5d5a24dfbed
[ireadme]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/README.md#L3-L15
[itreeapi]: https://api.github.com/repos/immortalwrt/immortalwrt/git/trees/5233c153ef7f119c567b54a92feea6919b167e84?recursive=1
[istableapi]: https://api.github.com/repos/immortalwrt/immortalwrt/git/trees/4fc16f2985a358bd43bb522e43f05395fcbd6ed5?recursive=1
[ilantiq]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/target/linux/lantiq/Makefile
[islantiq]: https://github.com/immortalwrt/immortalwrt/blob/4fc16f2985a358bd43bb522e43f05395fcbd6ed5/target/linux/lantiq/Makefile
[ifalcon]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/target/linux/lantiq/falcon/target.mk
[ifalconimages]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/target/linux/lantiq/image/falcon.mk
[idownloadlantiq]: https://downloads.immortalwrt.org/releases/25.12.2/targets/lantiq/
[idownload]: https://downloads.immortalwrt.org/
[bbinary]: https://github.com/linlunaire/8311-was-110-firmware-builder/blob/7d89440c7d9e1f209140910bb039f5d5a24dfbed/mods/binary-mods.sh
[ikernel]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/include/kernel.mk#L202-L215
[iflash]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js
[oflash]: https://github.com/openwrt/luci/blob/aa3d48836e90ae0706c8d8f9b46b8371e45cfe1f/modules/luci-mod-system/htdocs/luci-static/resources/view/system/flash.js
[imenu]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/modules/luci-mod-system/root/usr/share/luci/menu.d/luci-mod-system.json#L162-L172
[iacl]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/modules/luci-mod-system/root/usr/share/rpcd/acl.d/luci-mod-system.json#L166-L212
[irestore]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/package/base-files/files/sbin/sysupgrade#L355-L368
[ivalidate]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/package/base-files/files/usr/libexec/validate_firmware_image
[isysupgrade]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/package/base-files/files/sbin/sysupgrade#L399-L456
[inand]: https://github.com/immortalwrt/immortalwrt/blob/5233c153ef7f119c567b54a92feea6919b167e84/package/base-files/files/lib/upgrade/nand.sh
[bpersist]: https://github.com/linlunaire/8311-was-110-firmware-builder/blob/7d89440c7d9e1f209140910bb039f5d5a24dfbed/files/common/lib/8311.sh#L42-L58
[bptconf]: https://github.com/linlunaire/8311-was-110-firmware-builder/blob/7d89440c7d9e1f209140910bb039f5d5a24dfbed/files/basic/lib/preinit/90_8311_mounts
[bupgrade]: https://github.com/linlunaire/8311-was-110-firmware-builder/blob/7d89440c7d9e1f209140910bb039f5d5a24dfbed/files/common/usr/sbin/8311-firmware-upgrade.sh#L257-L267
[ilucibase]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/modules/luci-base/Makefile#L15-L31
[imodule]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/modules/luci-mod-system/Makefile#L1-L12
[ilicense]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/LICENSE
