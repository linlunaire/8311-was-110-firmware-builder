# 构建与测试

使用 Linux 环境，保留源码中的文件权限和符号链接。先初始化子模块：

```sh
git submodule update --init
```

## 基于发布底包构建

适用于 basic 变体的脚本和 WebUI 更新。需要 Python 3、Git、GNU coreutils、patch、squashfs-tools 和 7z。

从 [上游 v2.8.3](https://github.com/djGrrr/8311-was-110-firmware-builder/releases/tag/v2.8.3) 的 basic 归档提取 `local-upgrade.tar`，保存到下面指定的路径：

```sh
sudo python3 tools/build_from_release.py \
  --base stock/upstream-v2.8.3-local-upgrade.tar \
  --output out/release
```

构建器核对固定底包哈希，保留内核、驱动和固件二进制，叠加已提交的源码并编译翻译。打包后重新解包核对文件内容、权限和链接。工作区必须干净，输出目录必须尚不存在。

两种构建方式都对复制进镜像的固定 VLAN 子模块脚本应用
`patches/8311-xgspon-bypass-failures.patch`，补齐检测错误传播。子模块源码保持不变；
补丁不匹配时停止构建，升级子模块后应重新检查补丁与 `tests/test_topology.py`。

输出包含升级包、组件、`SHA256SUMS` 和 `build-manifest.json`。后者记录源码提交及底包来源。

```sh
(cd out/release && sha256sum --check SHA256SUMS)
```

## 使用原厂镜像构建

需要 Bash、GNU 工具（含 patch）、Python 3、Perl、sudo、squashfs-tools、u-boot-tools 和 mtd-utils。生成 `--release` 归档还需要 7z。

准备 BFW 原厂升级镜像，以及 basic 原厂的 `bootcore.bin`、`kernel.bin`、`rootfs.img`：

```sh
./build.sh --bfw-image-file stock/bfw.img --basic-image-dir stock/basic \
  --basic -o out/local-upgrade.img -O out/local-upgrade.tar
```

`--image` / `--image-dir` 是兼容别名。此流程应使用原厂输入，避免对已经修改的镜像重复应用补丁。完整参数见 `./build.sh --help`、`./create.sh --help` 和 `./extract.sh --help`。

原厂输入应放在 `stock/` 等独立目录，不能放在 `out/` 或 `rootfs*` 生成目录内。
构建保留 `out/` 中其他发布与验证产物；同名构建输出仍会更新。升级包和整片镜像
先在临时目录完整生成，失败不会发布半成品。`create.sh` 不修改输入文件时间戳。

## 测试

```sh
sudo apt-get install lua5.1 pcre2-utils busybox patch python3-venv
python3 -m venv .test-tmp/venv
. .test-tmp/venv/bin/activate
python3 -m pip install --only-binary=:all: --no-deps lupa==2.6
python3 -m unittest discover -s tests -v
TEST_SHELL=busybox TEST_SHELL_ARGS=sh python3 -m unittest discover -s tests -v
node tests/status_poll_smoke.cjs
```

离线回归使用模拟 UBI、EEPROM、环境变量和 LuCI 服务。Windows 可用 Git Bash、Python 和 Lupa 的 Lua 5.1 运行。

浏览器测试需要 Playwright 和对应的浏览器引擎：

```sh
node tests/frontend_smoke.cjs
node tests/management_frontend.cjs
node tests/theme_frontend.cjs
```

可用 `BROWSER_CHANNEL=msedge` 或 `chrome` 选择已安装的浏览器，或设置
`BROWSER_ENGINE=chromium`、`firefox`、`webkit`。CI 在 sh、BusyBox 及三个浏览器
引擎的回归全部通过后构建 basic 固件，具体记录见 [验证记录](validation.md)。
