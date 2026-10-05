# 8311 WAS-110 固件

基于 [8311 社区固件](https://github.com/djGrrr/8311-was-110-firmware-builder) 的 WAS-110 / PRX126 固件项目，改进配置管理、固件升级和状态页面。

## 功能

- 配置备份、导入预览和恢复，支持保留 PON 参数的重置。
- 固件上传校验、升级结果检查和错误提示。
- 状态查询与页面轮询优化，减少重复读取。
- VLAN 自动修正、失败重试和配置变更刷新。
- 简体中文界面，适配桌面与手机。
- 轻量管理主题，支持跟随系统、浅色与深色。

## 下载与升级

1. 从 [GitHub Actions](https://github.com/linlunaire/8311-was-110-firmware-builder/actions/workflows/test.yml) 下载 `master` 分支最新成功构建的 `WAS110-basic-*` 产物。
2. 解压后，按 `SHA256SUMS` 核对文件校验值。
3. 打开管理页面的 **系统 → 备份与更新**，先生成配置备份，再上传 `local-upgrade.tar`。
4. 校验通过后安装并重启。需要恢复配置时，选择备份的 `.env` 文件，预览后确认导入。

默认管理地址为 `192.168.11.1`，用户名 `root`，默认无密码；首次使用请设置管理密码。

## 注意事项

- 刷写期间保持供电，使用适用于 WAS-110 的固件包。
- 配置备份含 PON 认证信息，请妥善保管，只导入可信来源的备份。
- CN 固件的部分 VLAN / IPTV 参数与本项目不同，迁移前请查看 [兼容性说明](docs/reference-designs.md#cn-configuration-compatibility)。

## 文档

- [构建与测试](docs/building.md)
- [配置字段](docs/configuration-reference.md)
- [轻量管理主题](docs/theme.md)
- [自定义 VLAN 与 IPTV](docs/vlan-hook.md)
- [验证记录](docs/validation.md)
- [全项目检查与改进](docs/code-audit.md)
- [稳定性与资源边界](docs/stability.md)
- [固件槽说明](docs/firmware-banks.md)

感谢 8311 社区及上游作者。源码与相关组件保留各自的许可证声明。
