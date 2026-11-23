import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("build", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("mode", choices=("shared", "static"))
    args = parser.parse_args()
    manifest_path = args.output / "build_manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    config = (args.build / "config.h").read_text()
    configuration = re.search(
        r'^#define FFMPEG_CONFIGURATION "(.*)"$', config, re.M
    ).group(1)
    git = ["git", "-C", str(args.source)]
    revision = subprocess.check_output([*git, "rev-parse", "HEAD"], text=True).strip()
    tree = subprocess.check_output(
        [*git, "rev-parse", "HEAD^{tree}"], text=True
    ).strip()
    dirty = bool(
        subprocess.check_output(
            [*git, "diff", "HEAD", "--name-only"], text=True
        ).strip()
    )
    header_version = None
    synchronized_queues = False
    kvazaar_revision = None
    if "#define CONFIG_LIBKVAZAAR 1" in config:
        kvazaar_revision = subprocess.check_output(
            ["git", "-C", str(args.build / "kvazaar/source"), "rev-parse", "HEAD"], text=True
        ).strip()
    if "#define CONFIG_VULKAN 1" in config:
        make_config = (args.build / "ffbuild/config.mak").read_text()
        compiler = re.search(r"^CC=(.+)$", make_config, re.M).group(1)
        macros = subprocess.check_output(
            [
                *shlex.split(compiler),
                "-dM",
                "-E",
                "-include",
                "vulkan/vulkan_core.h",
                "-",
            ],
            input="",
            text=True,
            cwd=args.build,
        )
        header_version = int(
            re.search(r"^#define VK_HEADER_VERSION (\d+)$", macros, re.M).group(1)
        )
        synchronized_queues = (
            "#define VK_KHR_internally_synchronized_queues 1" in macros
        )
    artifacts = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(args.output.iterdir())
        if path.is_file()
        and not path.is_symlink()
        and path.name.startswith(("libav", "libsw"))
        and (path.suffix == ".a" or ".so" in path.name)
    }
    # Preserve source and artifact identity for each Linux build variant.
    manifest.setdefault("builds", {})[args.mode] = {
        "source_revision": revision,
        "source_tree": tree,
        "source_dirty": dirty,
        "configuration": configuration,
        "vulkan_header_version": header_version,
        "internally_synchronized_queues": synchronized_queues,
        "kvazaar_revision": kvazaar_revision,
    }
    manifest.update(
        {
            "source_revision": revision,
            "source_tree": tree,
            "vulkan_header_version": header_version,
            "internally_synchronized_queues": synchronized_queues,
            f"{args.mode}_configuration": configuration,
            "artifacts": artifacts,
            "patches": {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted((args.source.parent / "patches").glob("*.patch"))
            },
        }
    )
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
