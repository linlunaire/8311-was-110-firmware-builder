# WAS-110 固件槽与本次安装边界

2026-10-03，依据目标设备只读分区信息、启动环境和升级脚本核对。
这里记录结构与启动规则，不包含设备身份或认证数据。

## A/B 的实际用途

A、B 是两套可以轮换启动的完整固件槽，每套都有 `kernel`、`bootcore`
和 `rootfs`。两者没有固定的主用/救援身份；原升级脚本按正在运行的槽
选择另一槽写入。这与 [8311 的升级说明](https://pon.wiki/guides/install-the-8311-community-firmware-on-the-was-110/#ab-architecture)
一致。运营商侧也可能通过 OMCI 发起固件激活，因此不能把另一槽视为永不变化的救援系统。

最初安装前目标从 B 运行，`commit_bank=B`，`img_activate` 未设置。
`img_validA/B=true` 是环境标志，不能替代对固件文件和实际启动的验证。

| UBI 卷名 | 本次读取的卷 ID | 用途 |
| --- | --- | --- |
| kernelA / rootfsA / bootcoreA | 0 / 1 / 2 | 安装前未运行的 A 槽 |
| kernelB / bootcoreB / rootfsB | 4 / 5 / 6 | 安装前运行的 B 槽 |
| rootfs_data | 3 | 两槽共用的可写 overlay |
| ptconf | 7 | 两槽共用的持久配置 |

卷 ID 与升级脚本的创建顺序并不完全一致，因此必须按卷名查询，不能按
固定数字写入。升级脚本对已有卷使用 `ubinfo -N` 查询；隔离回归覆盖这类映射。
首次安装前 A 的 rootfs 容量较小，当时通过原有 `ubirsvol -N rootfsA` 流程扩容。
后续只在目标容量不足时扩容，不删除或重编号 B、配置卷或原始 MTD 分区。

## 启动选择与试启动

目标的 `select_image` 环境脚本依次处理：

1. 存在 `img_activate` 时，选择该槽，清除该标志并保存环境，然后进入内核启动。
2. 否则，选择 `commit_bank`；它表示持久默认槽。
3. 没有提交槽时，才使用脚本的 A 默认值。

这允许保留 `commit_bank=B`，用 `img_activate=A` 进行一次试启动。
按所读脚本推导，标志已被清除并成功保存后，下一次启动会回到 B，除非
之后提交 A。此结论不是断电或所有硬件故障下的恢复保证。未发现该环境
配置有 `bootcount`、`bootlimit` 或 `altbootcmd`，不能宣称自动失败计数回退。

安装时可对 CLI 的“安装”回答 `y`，对“修改 commit_bank”回答 `n`，
写入并校验备用槽后保持原默认启动槽。环境切换必须另外核对写入和读回；
不能仅因升级命令退出 0 就认定系统已经从新固件启动。

## 共享配置

该设备已有 `bootcmd` 会在启动时删除 `rootfs_data`，随后系统重新创建
overlay。8311 管理的环境配置和 `/ptconf` 独立持久保存，再由初始化流程
应用到系统。正常升级和切换槽不会自动隔离出两套不同的用户配置。
新 UI 的设置备份因此导出受支持的 8311 环境配置与 VLAN hook，而不是
把通用 OpenWrt `sysupgrade` 备份流程当成可直接替换的硬件升级流程。

本次构建保留已发布 v2.8.3 的 kernel 和 bootcore。二者与目标最初运行的
CN 固件对应卷的有效镜像字节比较完全一致（UBI 卷末尾填充不计入镜像）。
新版本不承诺迁移 CN 特有 VLAN/IGMP 参数；真实光纤、Internet/IPTV 和
断电恢复仍需分别验证。

## 网页试启动与空槽保护

网页安装保留当前默认槽；“安装并试启动”只设置 `img_activate`。
从新槽成功启动后，网页显示“确认使用当前固件”和“重启回到原默认槽”。
只有确认后才更新 `commit_bank`。试启动期间禁止安装另一份固件，避免覆盖
仍作为默认槽的回退镜像。这个流程需要设备再次重启才会返回原默认槽，
没有新增自动重启计时器，也不承诺启动卡死后的自动恢复。

页面用镜像头快速判断备用槽是否可识别。实际切换前还会验证 kernel 和
bootcore 的 uImage 头与数据 CRC、rootfs 的 SquashFS 头、大小、只读挂载
及必要启动文件。空槽、失败安装留下的 `img_valid=false`、校验失败或
正在执行另一项升级时，后台拒绝切换。启动时也会重新检查旧的有效标志；
不会仅凭 `img_valid=true` 认定镜像完整。

安装器在写入前将目标标为未完成，所有组件读回校验通过后才标为完成。
网页切换、确认、重启和 CLI 安装使用同一升级锁，环境修改保留双写与读回。
CLI 新增 `--no-commit` 和 `--trial`；原先未指定这些选项的交互流程保留。

镜像结构依据 [U-Boot legacy image header](https://github.com/u-boot/u-boot/blob/master/include/image.h)
和 [Linux SquashFS superblock](https://github.com/torvalds/linux/blob/master/fs/squashfs/squashfs_fs.h)。
这些检查用于拒绝已知无效镜像；正常启动、业务连接和断电故障仍需分别验证。

## 2026-10-03 当前安装状态

当前运行 `v2.8.3-opt1_basic_8f9e479` 的 A 槽，默认槽为 A，激活标志已清除。
经 B、A 两次试启动及网页确认后，按用户选择重新清空 B 镜像内容并保留卷结构。
空槽不能切换，配置与现有 Hook 保持不变；详见 [本轮验证记录](validation.md)。

## 2026-10-03 此前安装记录

当时安装版本为 `v2.8.3-opt1_basic_b159a2c`，运行 A，`commit_bank=A`，一次激活标志已清除。流程中先写 A 并逐组件读回，保持默认 B 后通过 `img_activate=A` 试启动；也实际回到原 B，再写入修正后的 A。确认正式镜像上的 HTTPS 管理、备份与恢复预览正常后，才两次写入默认槽并读回确认 A。

B 的 kernel、bootcore、rootfs 全卷哈希与安装前一致，所有 `8311_` 配置的规范化哈希不变，原 SSH 主机密钥仍可验证。没有恢复或重置用户配置。新控制器文件来自重新生成的 rootfs，正式运行不依赖试验用 overlay 补丁。

这次证明了正常启动和正常 A/B 切换路径；没有模拟启动崩溃、断电或 NAND 故障。设备未接光纤，PON 注册、Internet 与 IPTV 仍不在本次结论内。
