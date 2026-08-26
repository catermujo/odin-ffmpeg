#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


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


def run_with_msvc_env(bash_path: Path, mode: str, arch: str) -> int:
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
        env=bash_env(bash_path),
        shell=True,
    ).returncode


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

    if shutil.which("cl.exe"):
        return subprocess.run(
            [str(bash_path), str(BUILD_SCRIPT), mode, arch],
            cwd=ROOT,
            check=False,
            env=bash_env(bash_path),
        ).returncode

    return run_with_msvc_env(bash_path, mode, arch)


if __name__ == "__main__":
    raise SystemExit(main())
