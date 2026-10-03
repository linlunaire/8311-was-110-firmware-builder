# WAS-110 固件槽与本次安装边界

2026-10-03，依据目标设备只读分区信息、启动环境和升级脚本核对。
这里记录结构与启动规则，不包含设备身份或认证数据。

## A/B 的实际用途

A、B 是两套可以轮换启动的完整固件槽，每套都有 `kernel`、`bootcore`
和 `rootfs`。两者没有固定的主用/救援身份；原升级脚本按正在运行的槽
选择另一槽写入。这与 [8311 的升级说明](https://pon.wiki/guides/install-the-8311-community-firmware-on-the-was-110/#ab-architecture)
一致。运营商侧也可能通过 OMCI 发起固件激活，因此不能把另一槽视为永不变化的救援系统。

安装前目标从 B 运行，`commit_bank=B`，`img_activate` 未设置。
`img_validA/B=true` 是环境标志，不能替代对固件文件和实际启动的验证。

| UBI 卷名 | 本次读取的卷 ID | 用途 |
| --- | --- | --- |
| kernelA / rootfsA / bootcoreA | 0 / 1 / 2 | 安装前未运行的 A 槽 |
| kernelB / bootcoreB / rootfsB | 4 / 5 / 6 | 安装前运行的 B 槽 |
| rootfs_data | 3 | 两槽共用的可写 overlay |
| ptconf | 7 | 两槽共用的持久配置 |

卷 ID 与升级脚本的创建顺序并不完全一致，因此必须按卷名查询，不能按
固定数字写入。升级脚本对已有卷使用 `ubinfo -N` 查询；隔离回归覆盖这类映射。
目标 A 的 rootfs 容量比当前发布版镜像小，写入更大 rootfs 前需要由原有
`ubirsvol -N rootfsA` 流程扩容；不会删除或重编号 B、配置卷或原始 MTD 分区。

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

本次构建保留已发布 v2.8.3 的 kernel 和 bootcore。二者与目标正在运行的
CN 固件对应卷的有效镜像字节比较完全一致（UBI 卷末尾填充不计入镜像）。
新版本不承诺迁移 CN 特有 VLAN/IGMP 参数；真实光纤、Internet/IPTV 和
断电恢复仍需分别验证。

## 2026-10-03 实际安装结果

最终安装版本为 `v2.8.3-opt1_basic_b159a2c`，当前运行 A，`commit_bank=A`，一次激活标志已清除。流程中先写 A 并逐组件读回，保持默认 B 后通过 `img_activate=A` 试启动；也实际回到原 B，再写入修正后的 A。确认正式镜像上的 HTTPS 管理、备份与恢复预览正常后，才两次写入默认槽并读回确认 A。

B 的 kernel、bootcore、rootfs 全卷哈希与安装前一致，所有 `8311_` 配置的规范化哈希不变，原 SSH 主机密钥仍可验证。没有恢复或重置用户配置。新控制器文件来自重新生成的 rootfs，正式运行不依赖试验用 overlay 补丁。

这次证明了正常启动和正常 A/B 切换路径；没有模拟启动崩溃、断电或 NAND 故障。设备未接光纤，PON 注册、Internet 与 IPTV 仍不在本次结论内。
