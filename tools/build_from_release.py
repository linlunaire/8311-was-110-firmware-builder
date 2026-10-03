#!/usr/bin/env python3
"""Build the basic tar from a pinned public release, preserving its binary ABI."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE_URL = "https://github.com/djGrrr/8311-was-110-firmware-builder/releases/tag/v2.8.3"
BASE_SHA256 = "9c40000d29b19bdf1b46f081f1438cc54638713d8925836e6935fbaa76d9b653"
COMPONENTS = {
    "kernel.bin": (2274800, "d66b24cf873cc1071a3aa2d155bf677f503f10d221513e469083f8a591f6b96c"),
    "bootcore.bin": (5426656, "e99e25332bdcb3c9b0447abad1be9b1e54511b6bda99f2b51ae2499db5b905a4"),
    "rootfs.img": (6197248, "756da584829d8ef144bdd8e400fb763ff31711e2b84e430912118fb6093b7e33"),
}


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def validate_base(path):
    if sha256(path) != BASE_SHA256:
        raise ValueError("Input is not the pinned upstream v2.8.3 basic local-upgrade.tar")
    with tarfile.open(path) as archive:
        members = archive.getmembers()
        if sorted(item.name for item in members) != sorted(["upgrade.sh", "control", *COMPONENTS]):
            raise ValueError("Unexpected base archive members")
        for item in members:
            if not item.isfile():
                raise ValueError("The base archive must contain only regular files")
        for name, (size, digest) in COMPONENTS.items():
            data = archive.extractfile(name).read()
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("Base component mismatch: " + name)


def run(*args):
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def git(*args):
    return subprocess.check_output(["git", "-c", f"safe.directory={ROOT}", *args], cwd=ROOT, text=True).strip()


def snapshot(root):
    """Record files without following device nodes or absolute firmware symlinks."""
    entries = {}
    for folder, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(folder) / name
            info = path.lstat()
            entry = {"mode": stat.S_IMODE(info.st_mode), "kind": stat.S_IFMT(info.st_mode)}
            if stat.S_ISLNK(info.st_mode):
                entry["target"] = os.readlink(path)
            elif stat.S_ISREG(info.st_mode):
                entry["sha256"] = sha256(path)
            elif stat.S_ISCHR(info.st_mode) or stat.S_ISBLK(info.st_mode):
                entry["device"] = info.st_rdev
            entries[path.relative_to(root).as_posix()] = entry
    return entries


def protected_binaries(root, entries):
    protected = {}
    for name, entry in entries.items():
        keep = name.startswith(("lib/modules/", "lib/firmware/"))
        if entry["kind"] == stat.S_IFREG:
            with (root / name).open("rb") as source:
                keep = keep or source.read(4) == b"\x7fELF"
        if keep:
            protected[name] = entry
    if not protected:
        raise ValueError("No protected binary payloads found in the base image")
    return protected


def build(base, output, version):
    # Validate before creating or replacing any output.
    validate_base(base)
    if os.name != "posix" or os.geteuid() != 0:
        raise ValueError("Run in a Linux checkout as root to preserve firmware ownership and device nodes")
    for tool in ("unsquashfs", "mksquashfs", "cp", "git"):
        if not shutil.which(tool):
            raise ValueError("Missing build tool: " + tool)
    if output.exists():
        raise ValueError("Output already exists; choose a new directory")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+-]{0,14}", version):
        raise ValueError("Use a version of 1-15 letters, digits, dots, pluses or hyphens")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Build from a clean committed checkout")
    revision = git("rev-parse", "HEAD")
    epoch = int(git("log", "-1", "--format=%ct"))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-build-", dir=output.parent) as temporary:
        work = Path(temporary)
        root = work / "rootfs"
        with tarfile.open(base) as archive:
            for name in COMPONENTS:
                (work / name).write_bytes(archive.extractfile(name).read())
        run("unsquashfs", "-no-progress", "-d", root, work / "rootfs.img")
        original = snapshot(root)
        protected = protected_binaries(root, original)
        # This base already has vendor/binary/package patches; never apply them twice.
        for variant in ("common", "basic"):
            run("cp", "-a", str(ROOT / "files" / variant) + "/.", str(root) + "/")
        for name, folder in (("8311-detect-config.sh", "usr/sbin"),
                             ("8311-fix-vlans.sh", "usr/sbin"), ("8311-vlans-lib.sh", "lib")):
            run("cp", "-a", ROOT / "8311-xgspon-bypass" / name, root / folder / name)
        for po in sorted((ROOT / "i18n/po").glob("*.po")):
            if not po.name.endswith(".en.po"):
                run("python3", ROOT / "tools/po2lmo.py", po, root / "usr/lib/lua/luci/i18n" / (po.stem + ".lmo"))
        values = {"FW_VER": version, "FW_VERSION": version,
                  "FW_LONG_VERSION": f"{version}_basic_{revision[:7]}",
                  "FW_REV": revision[:7], "FW_REVISION": revision[:7], "FW_VARIANT": "basic", "FW_SUFFIX": ""}
        version_text = "".join(f"{key}={value}\n" for key, value in values.items())
        (root / "etc/8311_version").write_text(version_text)
        (root / "usr/lib/lua/8311/version.lua").write_text(
            f'module "8311.version"\nvariant = "basic"\nversion = "{version}"\nrevision = "{revision[:7]}"\n')
        banner = root / "etc/banner"
        text, count = re.subn(r"^.*8311 Community Firmware MOD.*$",
                             f" 8311 Community Firmware MOD [basic] - {version} ({revision[:7]})",
                             banner.read_text(), flags=re.M)
        if count != 1:
            raise ValueError("Unexpected base banner")
        banner.write_text(text)
        expected = snapshot(root)
        if protected_binaries(root, expected) != protected:
            raise ValueError("A kernel module, firmware blob or ELF binary was changed")
        package = work / "package"
        package.mkdir()
        image = package / "rootfs.img"
        run("mksquashfs", root, image, "-all-root", "-noappend", "-no-xattrs", "-comp", "xz", "-b", "256K",
            "-all-time", epoch, "-mkfs-time", epoch, "-no-progress", "-processors", "2")
        verification = work / "verified"
        run("unsquashfs", "-no-progress", "-d", verification, image)
        if snapshot(verification) != expected:
            raise ValueError("Re-extracted image differs in content, symlinks or modes")
        control = version_text + "\n"
        for name, key in (("kernel.bin", "KERNEL"), ("bootcore.bin", "BOOTCORE"), ("rootfs.img", "ROOTFS")):
            path = image if name == "rootfs.img" else work / name
            control += f"SIZE_{key}={path.stat().st_size}\nSHA256_{key}={sha256(path)}\n"
        (package / "control").write_text(control)
        shutil.copyfile(ROOT / "files/common/usr/sbin/8311-firmware-upgrade.sh", package / "upgrade.sh")
        for name in ("kernel.bin", "bootcore.bin"):
            shutil.copyfile(work / name, package / name)
        tar = package / "local-upgrade.tar"
        with tarfile.open(tar, "w", format=tarfile.USTAR_FORMAT) as archive:
            for name in ("upgrade.sh", "control", "kernel.bin", "bootcore.bin", "rootfs.img"):
                data = (package / name).read_bytes()
                info = tarfile.TarInfo(name)
                info.size, info.mtime, info.mode = len(data), epoch, 0o755 if name == "upgrade.sh" else 0o644
                archive.addfile(info, io.BytesIO(data))
        manifest = {"method": "pinned upstream release plus source overlays", "source_commit": revision,
                    "version": version, "base_url": BASE_URL, "base_tar_sha256": BASE_SHA256,
                    "unchanged_binary_entries": len(protected), "rootfs_roundtrip_verified": True,
                    "files": {path.name: sha256(path) for path in sorted(package.iterdir())}}
        (package / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (package / "SHA256SUMS").write_text("".join(f"{sha256(path)}  {path.name}\n" for path in sorted(package.iterdir())))
        os.rename(package, output)
    print(f"Built {version} ({revision[:7]}); {len(protected)} protected binary entries unchanged; image round trip verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", default="v2.8.3-opt1")
    args = parser.parse_args()
    try:
        build(args.base.resolve(), args.output.resolve(), args.version)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Build failed: {error}\n")
