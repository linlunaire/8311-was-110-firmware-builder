# 自定义 VLAN Hook

模板在 [examples/vlan_fixes_hook.sh](../examples/vlan_fixes_hook.sh)。它不会随固件自动安装或覆盖现有 Hook。

先把模板中的上网 VLAN 改成原光猫业务配置中确认的值。模板要求 `INTERNET_CONVERT=0`，向路由器输出不带标签的上网流量，适合 WAN 直接在物理接口拨号的配置。如果路由器使用 VLAN 子接口，需要分别编写双向转换规则；只修改下行 VLAN 并不能完成双向映射。

保存路径为 `/ptconf/8311/vlan_fixes_hook.sh`，界面选择“Hook script only”。守护进程会载入所需函数库。模板也可以单独执行，但执行会立即更改 TC 规则。

脚本只替换列出的 handle、pref、protocol 组合，保留其他规则；任一规则失败都会返回非零状态，让守护进程重试。TC 更新不是事务，失败前已经成功的规则不会自动回滚。不能同时让另一个脚本管理这些相同的规则。

模板针对普通无标签 PPPoE 和单层 802.1Q 流量。`pass` 会结束当前分类，保留其他规则不代表同一数据包仍会经过它们；含 802.1ad 或 QinQ 的上行需要单独调整，不能当成无标签流量处理。[tc-vlan 说明](https://github.com/iproute2/iproute2/blob/main/man/man8/tc-vlan.8)

## 以后在普通 LAN 内使用 IPTV

`IPTV_ENABLED=0` 默认不修改组播出口。以后确认 IPTV 的业务参数和实际封装后，填写 `IPTV_VLAN` 并设置 `IPTV_ENABLED=1`。这些规则将组播出口映射为带标签的 IPTV VLAN；802.1ad 的修改仅影响外层标签，不能把 QinQ 自动转换为单标签。

以软路由 WAN 为 `eth1`、上网 VLAN 为 41、IPTV VLAN 为 43 为例：

| 业务 | 猫棒到软路由 | 软路由接口 |
| --- | --- | --- |
| 上网 | 不带 VLAN 标签 | `eth1`，PPPoE |
| IPTV | VLAN 43 | `eth1.43`，获取地址方式按原光猫配置 |
| LAN 观看 | 组播代理转发 | `br-lan` |

软路由还需要独立的 IPTV 接口、从 IPTV 到 LAN 的 IGMP 代理及相应防火墙规则。IPTV 是否使用 DHCP、特殊 DHCP 选项或 PPPoE，必须从原光猫确认。普通 LAN 内观看不需要把某个 LAN 口直接桥接到运营商 IPTV 网络。

更换旧 Hook 时，应检查旧脚本留下的规则。禁用 IPTV 或删除 Hook 不会自动撤销已经生效的 TC 规则；重启可以重新建立驱动规则，但不能替代运营商侧的拨号、IGMP 和实际播放验证。
