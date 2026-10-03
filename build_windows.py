#!/usr/bin/env python3

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from validate_shader_payloads import validate_shader_payloads

ROOT = Path(__file__).resolve().parent
BUILD_SCRIPT = ROOT / "build_windows.sh"


def find_bash() -> Path | None:
    program_files = os.environ.get("ProgramFiles", "")
    for candidate in (
        Path(program_files) / "Git" / "bin" / "bash.exe",
        Path(program_files) / "MSYS2" / "usr" / "bin" / "bash.exe",
    ):
        if candidate.exists():
            return candidate

    if bash_path := shutil.which("bash.exe"):
        return Path(bash_path)
    if bash_path := shutil.which("bash"):
        return Path(bash_path)
    return None


def bash_env(bash_path: Path) -> dict[str, str]:
    env = dict(os.environ)
    path_entries = [str(bash_path.parent)]
    git_usr_bin = bash_path.parent.parent / "usr" / "bin"
    if git_usr_bin.exists():
        path_entries.append(str(git_usr_bin))

    existing = env.get("PATH", "")
    if existing:
        path_entries.append(existing)
    env["PATH"] = os.pathsep.join(path_entries)
    return env


def find_vsdevcmd() -> Path | None:
    program_files_x86 = os.environ.get("ProgramFiles(x86)", "")
    if program_files_x86:
        vswhere = (
            Path(program_files_x86)
            / "Microsoft Visual Studio"
            / "Installer"
            / "vswhere.exe"
        )
        if vswhere.exists():
            proc = subprocess.run(
                [
                    str(vswhere),
                    "-latest",
                    "-products",
                    "*",
                    "-requires",
                    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                    "-property",
                    "installationPath",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            install_path = proc.stdout.strip()
            if install_path:
                candidate = Path(install_path) / "Common7" / "Tools" / "VsDevCmd.bat"
                if candidate.exists():
                    return candidate

    for base in filter(None, (program_files_x86, os.environ.get("ProgramFiles", ""))):
        root = Path(base) / "Microsoft Visual Studio" / "2022"
        for edition in ("Community", "Professional", "Enterprise", "BuildTools"):
            candidate = root / edition / "Common7" / "Tools" / "VsDevCmd.bat"
            if candidate.exists():
                return candidate
    return None


def normalize_arch(raw_arch: str) -> str | None:
    arch = raw_arch.strip().lower()
    if arch in {"x64", "x86_64", "amd64"}:
        return "x64"
    if arch in {"arm64", "aarch64"}:
        return "arm64"
    return None


def run_with_msvc_env(
    bash_path: Path, mode: str, arch: str, env: dict[str, str]
) -> int:
    vsdevcmd = find_vsdevcmd()
    if vsdevcmd is None:
        print(
            "Error: cl.exe not found and VsDevCmd.bat could not be located. "
            "Install Visual Studio 2022 C++ tools or use an x64 Native Tools prompt.",
            file=sys.stderr,
        )
        return 1

    command = (
        f'call "{vsdevcmd}" -host_arch=x64 -arch={arch} >NUL '
        f'&& "{bash_path}" "{BUILD_SCRIPT}" {mode} {arch}'
    )
    return subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        env=env,
        shell=True,
    ).returncode


def prepare_vulkan(env: dict[str, str]) -> None:
    # DUMBAI: Reuse the monorepo's verified headers and host shader compiler sources without a system SDK install.
    candidates = [
        Path(env["FFMPEG_VULKAN_INCLUDE"])
        if env.get("FFMPEG_VULKAN_INCLUDE")
        else None,
        Path(env["VULKAN_SDK"]) / "Include" if env.get("VULKAN_SDK") else None,
        ROOT.parent / "slang" / "external" / "vulkan" / "include",
    ]
    headers = next(
        (p for p in candidates if p and (p / "vulkan" / "vulkan.h").is_file()), None
    )
    if headers is None:
        raise RuntimeError(
            "Vulkan headers missing: set FFMPEG_VULKAN_INCLUDE or VULKAN_SDK; Vulkan >= 1.3.277 required"
        )
    compiler = env.get("FFMPEG_GLSLC") or next(
        (
            path
            for name in ("glslc", "glslang", "glslangValidator")
            if (path := shutil.which(name))
        ),
        None,
    )
    if compiler is None:
        source = Path(
            env.get(
                "FFMPEG_GLSLANG_SOURCE",
                str(ROOT.parent / "slang" / "external" / "glslang"),
            )
        )
        if not (source / "CMakeLists.txt").is_file():
            raise RuntimeError(
                "GLSL compiler missing: set FFMPEG_GLSLC or FFMPEG_GLSLANG_SOURCE"
            )
        build = ROOT / "FFmpeg" / ".build-deps" / "glslang-build"
        subprocess.run(
            [
                "cmake",
                "-S",
                str(source),
                "-B",
                str(build),
                "-G",
                "Visual Studio 17 2022",
                "-A",
                "x64",
                "-DENABLE_GLSLANG_BINARIES=ON",
                "-DENABLE_SPIRV=ON",
                "-DENABLE_OPT=OFF",
                "-DBUILD_TESTING=OFF",
            ],
            check=True,
            env=env,
        )
        subprocess.run(
            [
                "cmake",
                "--build",
                str(build),
                "--config",
                "Release",
                "--target",
                "glslang-standalone",
                "--parallel",
                env.get("NUMBER_OF_PROCESSORS", "4"),
            ],
            check=True,
            env=env,
        )
        compiler = str(build / "StandAlone" / "Release" / "glslang.exe")
        if not Path(compiler).is_file():
            raise RuntimeError(f"GLSL compiler build did not produce {compiler}")
    env["FFMPEG_GLSLC"] = Path(compiler).as_posix()
    include_flag = f'-I"{headers.as_posix()}"'
    env["FFMPEG_EXTRA_CFLAGS"] = " ".join(
        filter(None, (env.get("FFMPEG_EXTRA_CFLAGS"), include_flag))
    )


def write_manifest(mode: str, arch: str) -> None:
    output = ROOT / f"windows_{arch}"
    manifest_path = output / "build_manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {}
    source = ROOT / "FFmpeg"
    configuration = next(
        line.removeprefix("FFMPEG_CONFIGURATION=")
        for line in (source / "ffbuild" / "config.mak").read_text().splitlines()
        if line.startswith("FFMPEG_CONFIGURATION=")
    )
    artifacts = sorted(
        path
        for path in output.iterdir()
        if path.is_file()
        and (
            path.name.endswith("_static.lib")
            if mode == "static"
            else path.suffix in {".dll", ".lib"}
            and not path.name.endswith("_static.lib")
        )
    )
    shader_payloads = validate_shader_payloads(source)
    if shader_payloads["compression"]:
        raise RuntimeError(
            "Windows Vulkan build must disable shader compression explicitly"
        )
    data = {
        "shaders": shader_payloads,
        "ffmpeg_source_revision": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source, text=True
        ).strip(),
        "configuration": configuration,
        "artifacts_sha256": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in artifacts
        },
    }
    zconf = source / ".build-deps" / "zlib-install" / "include" / "zconf.h"
    if zconf.is_file():
        data["local_zconf_sha256"] = hashlib.sha256(zconf.read_bytes()).hexdigest()
    native_arch = normalize_arch(platform.machine())
    if mode == "shared" and arch == native_arch:
        # DUMBAI: Enumerate without creating any hardware context or opening the costly Vulkan encoder.
        with os.add_dll_directory(str(output)):
            codec = ctypes.CDLL(str(next(output.glob("avcodec-*.dll"))))

            class Codec(ctypes.Structure):
                _fields_ = [("name", ctypes.c_char_p)]

            codec.avcodec_configuration.restype = ctypes.c_char_p
            data["configuration"] = codec.avcodec_configuration().decode()
            codec.av_codec_iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
            codec.av_codec_iterate.restype = ctypes.POINTER(Codec)
            codec.av_codec_is_encoder.argtypes = [ctypes.c_void_p]
            codec.av_codec_is_decoder.argtypes = [ctypes.c_void_p]
            opaque = ctypes.c_void_p()
            encoders, decoders = [], []
            while item := codec.av_codec_iterate(ctypes.byref(opaque)):
                name = item.contents.name.decode()
                if codec.av_codec_is_encoder(item):
                    encoders.append(name)
                if codec.av_codec_is_decoder(item):
                    decoders.append(name)
            data["encoders"] = sorted(encoders)
            data["decoders"] = sorted(decoders)
    manifest[mode] = data
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2:
        print("Usage: build_windows.py <shared|static> <x64|arm64>", file=sys.stderr)
        return 1

    mode, raw_arch = args
    if mode not in {"shared", "static"}:
        print(f"Error: unsupported mode '{mode}'", file=sys.stderr)
        return 1

    arch = normalize_arch(raw_arch)
    if arch is None:
        print(f"Error: unsupported arch '{raw_arch}'", file=sys.stderr)
        return 1

    bash_path = find_bash()
    if bash_path is None:
        print(
            "Error: bash.exe not found. Install Git for Windows or MSYS2 "
            "(scoop install git or scoop install msys2), then add bash to PATH.",
            file=sys.stderr,
        )
        return 1

    env = bash_env(bash_path)
    prepare_vulkan(env)

    if shutil.which("cl.exe"):
        result = subprocess.run(
            [str(bash_path), str(BUILD_SCRIPT), mode, arch],
            cwd=ROOT,
            check=False,
            env=env,
        ).returncode
    else:
        result = run_with_msvc_env(bash_path, mode, arch, env)
    if result == 0:
        write_manifest(mode, arch)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
