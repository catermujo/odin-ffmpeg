#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

FFMPEG_ROOT = Path(__file__).resolve().parent
EXAMPLES_DIR = FFMPEG_ROOT / "examples"
SAMPLES_DIR = FFMPEG_ROOT / "samples"
PRESETS = ("system", "shared", "static")
HARDWARE_EXAMPLES = {
    "hw_decode",
    "qsv_decode",
    "qsv_transcode",
    "vaapi_encode",
    "vaapi_transcode",
}
LONG_RUNNING_EXAMPLES = {
    "avio_http_serve_files",
}
UNSUPPORTED_HW_HINTS = (
    "not supported",
    "cannot create qsv device",
    "codec not supported by qsv",
    "av_hwdevice_ctx_create (qsv)",
    "cannot allocate memory",
    "no device",
    "device type",
    "failed to initialise vaapi",
    "failed to open display",
)
TRANSCODE_ENCODER_HINTS = (
    "h264_videotoolbox",
    "open encoder: invalid argument",
)


def _default_out_name(example: str) -> str:
    suffix = ".exe" if sys.platform == "win32" else ".bin"
    return example.replace("/", "__") + suffix


def _discover_examples() -> list[str]:
    if not EXAMPLES_DIR.exists():
        return []
    examples = [
        p.stem
        for p in sorted(EXAMPLES_DIR.glob("*.odin"))
        if p.is_file() and p.name != "build.odin"
    ]
    return examples


def _normalize_presets(raw: list[str], matrix: bool) -> list[str]:
    presets = list(PRESETS) if matrix else (raw or ["system"])
    seen: set[str] = set()
    ordered: list[str] = []
    for preset in presets:
        if preset not in PRESETS:
            msg = f"Unknown preset '{preset}'. Expected one of: {', '.join(PRESETS)}."
            raise ValueError(msg)
        if preset in seen:
            continue
        seen.add(preset)
        ordered.append(preset)
    return ordered


def _split_passthrough(argv: list[str]) -> tuple[list[str], list[str]]:
    if "--" not in argv:
        return argv, []
    idx = argv.index("--")
    return argv[:idx], argv[idx + 1 :]


def _default_hw_device() -> str:
    if sys.platform == "darwin":
        return "videotoolbox"
    if sys.platform == "win32":
        return "d3d11va"
    return "vaapi"


def _ensure_nv12(path: Path, width: int, height: int, frames: int = 2) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    y_size = width * height
    uv_size = (width * height) // 2
    frame = bytes([0]) * y_size + bytes([128]) * uv_size
    with path.open("wb") as out:
        for _ in range(frames):
            out.write(frame)


def _default_run_args(example: str, *, out_dir: Path, preset: str) -> list[str] | None:
    sample = lambda name: str((SAMPLES_DIR / name).resolve())  # noqa: E731
    run_dir = (out_dir / "_run" / preset / example).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    out = lambda name: str((run_dir / name).resolve())  # noqa: E731

    if example == "avio_http_serve_files":
        return [sample("test_av.mp4"), "http://127.0.0.1:7777"]
    if example == "avio_list_dir":
        return ["."]
    if example == "avio_read_callback":
        return [sample("test_av.mp4")]
    if example == "decode":
        return [sample("test.mp4")]
    if example == "decode_audio":
        return [sample("test.mp2")]
    if example == "decode_filter_audio":
        return [sample("test_av.mp4")]
    if example == "decode_filter_video":
        return [sample("test_av.mp4")]
    if example == "decode_video":
        return [sample("test.mpeg1")]
    if example == "demux_decode":
        return [sample("test_av.mp4")]
    if example == "encode_audio":
        return [out("encode_audio.mp2")]
    if example == "encode_video":
        return [out("encode_video.h264")]
    if example == "extract_mvs":
        return [sample("test.mp4")]
    if example == "filter_audio":
        return []
    if example == "hw_decode":
        return [_default_hw_device(), sample("test_av.mp4"), out("hw_decode.raw")]
    if example == "mux":
        return [out("mux.mp4")]
    if example == "probe":
        return [sample("test_av.mp4")]
    if example == "qsv_decode":
        return [sample("test_av.mp4"), out("qsv_decode.raw")]
    if example == "qsv_transcode":
        return [sample("test_av.mp4"), "h264_qsv", out("qsv_transcode.mp4"), ""]
    if example == "remux":
        return [sample("test_av.mp4"), out("remux.mp4")]
    if example == "resample_audio":
        return [out("resample_audio.raw")]
    if example == "scale_video":
        return [sample("test.mp4"), "160x90", out("scale_video.raw")]
    if example == "show_metadata":
        return [sample("test_av.mp4")]
    if example == "transcode":
        return [sample("test_av.mp4"), out("transcode.mp4")]
    if example == "transcode_aac":
        return [sample("test.aac"), out("transcode_aac.m4a")]
    if example == "vaapi_encode":
        in_nv12 = run_dir / "input_nv12_64x64.yuv"
        _ensure_nv12(in_nv12, 64, 64)
        return ["64", "64", str(in_nv12), out("vaapi_encode.h264")]
    if example == "vaapi_transcode":
        return [sample("test_av.mp4"), "h264_vaapi", out("vaapi_transcode.mp4")]
    if example == "version":
        return []
    return None


def _parse_run_overrides(
    values: list[str], *, known_examples: set[str]
) -> dict[str, list[str]]:
    overrides: dict[str, list[str]] = {}
    for raw in values:
        if "=" not in raw:
            msg = f"Invalid -run-override value '{raw}'. Expected '<example>=<args...>'."
            raise ValueError(msg)
        name, rhs = raw.split("=", 1)
        name = name.strip()
        if name not in known_examples:
            msg = f"Unknown example in -run-override: '{name}'"
            raise ValueError(msg)
        overrides[name] = shlex.split(rhs)
    return overrides


def _runtime_env(preset: str) -> dict[str, str]:
    env = dict(os.environ)
    if preset != "shared":
        return env

    ffmpeg_path = str(FFMPEG_ROOT.resolve())
    if sys.platform == "win32":
        key, sep = "PATH", ";"
    elif sys.platform == "darwin":
        key, sep = "DYLD_LIBRARY_PATH", ":"
    else:
        key, sep = "LD_LIBRARY_PATH", ":"
    old = env.get(key, "")
    env[key] = ffmpeg_path if not old else f"{ffmpeg_path}{sep}{old}"
    return env


def _tail_lines(text: str, limit: int = 25) -> list[str]:
    lines = text.splitlines()
    return lines[-limit:] if len(lines) > limit else lines


def _looks_like_unsupported_hw(output: str) -> bool:
    lower = output.lower()
    return any(hint in lower for hint in UNSUPPORTED_HW_HINTS)


def _optional_run_skip_reason(example: str, output: str) -> str | None:
    lower = output.lower()
    if example in HARDWARE_EXAMPLES and _looks_like_unsupported_hw(output):
        return "unsupported hardware/runtime"
    if example == "avio_http_serve_files" and "cannot open server at" in lower:
        return "http listen unsupported in current FFmpeg build"
    if example == "transcode" and all(hint in lower for hint in TRANSCODE_ENCODER_HINTS):
        return "platform encoder limitation"
    return None


def main() -> int:
    raw_args, odin_passthrough = _split_passthrough(sys.argv[1:])
    parser = argparse.ArgumentParser(
        prog="build_examples.py",
        description="Compile FFmpeg Odin examples for selected link presets.",
    )
    parser.add_argument(
        "-preset",
        action="append",
        dest="presets",
        choices=PRESETS,
        help="FFMPEG link preset to test (repeatable). Default: system.",
    )
    parser.add_argument(
        "-matrix",
        action="store_true",
        help="Build all presets (system/shared/static).",
    )
    parser.add_argument(
        "-example",
        action="append",
        default=[],
        metavar="NAME",
        help="Only compile the named example (repeatable).",
    )
    parser.add_argument(
        "-list",
        action="store_true",
        help="List available examples and exit.",
    )
    parser.add_argument(
        "-list-json",
        action="store_true",
        help="List available examples as JSON and exit.",
    )
    parser.add_argument(
        "-check",
        action="store_true",
        help="Compatibility flag for build_all; build only (default behavior).",
    )
    parser.add_argument(
        "-run",
        action="store_true",
        help="Run binaries after successful build.",
    )
    parser.add_argument(
        "-run-hw",
        action="store_true",
        help="Include hardware examples when using -run.",
    )
    parser.add_argument(
        "-run-long",
        action="store_true",
        help="Include long-running examples when using -run.",
    )
    parser.add_argument(
        "-run-timeout",
        type=float,
        default=15.0,
        help="Per-process runtime timeout in seconds (default: 15).",
    )
    parser.add_argument(
        "-run-override",
        action="append",
        default=[],
        metavar="SPEC",
        help="Override args for one example: '<example>=<args...>' (repeatable).",
    )
    parser.add_argument(
        "-strict-run",
        action="store_true",
        help="Treat skipped runtime tests as failures.",
    )
    parser.add_argument(
        "-dry-run",
        action="store_true",
        help="Print commands without executing them.",
    )
    parser.add_argument(
        "-fail-fast",
        action="store_true",
        help="Stop after first failed compile.",
    )
    parser.add_argument(
        "-out-dir",
        default="/tmp/ffmpeg-example-builds",
        help="Output directory for temporary binaries.",
    )
    args = parser.parse_args(raw_args)
    if args.run_timeout <= 0:
        print("-run-timeout must be > 0")
        return 2

    examples = _discover_examples()
    if not examples:
        print(f"No Odin examples found in {EXAMPLES_DIR}.")
        return 1

    if args.list_json:
        print(json.dumps(examples))
        return 0
    if args.list:
        print("Available examples:")
        for name in examples:
            print(f"  - {name}")
        return 0

    try:
        presets = _normalize_presets(args.presets or [], args.matrix)
    except ValueError as err:
        print(err)
        return 2

    if args.example:
        requested = list(dict.fromkeys(args.example))
        missing = [name for name in requested if name not in examples]
        if missing:
            print("Unknown example(s): " + ", ".join(missing))
            return 2
        examples = requested

    try:
        run_overrides = _parse_run_overrides(
            args.run_override,
            known_examples=set(examples),
        )
    except ValueError as err:
        print(err)
        return 2

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    total = len(examples) * len(presets)
    index = 0
    build_failures: list[tuple[str, str, int]] = []
    built_binaries: dict[tuple[str, str], Path] = {}

    for preset in presets:
        for example in examples:
            index += 1
            src = EXAMPLES_DIR / f"{example}.odin"
            out_file = out_dir / preset / _default_out_name(example)
            out_file.parent.mkdir(parents=True, exist_ok=True)

            cmd = [
                "odin",
                "build",
                str(src),
                "-file",
                f"-out:{out_file}",
                f"-define:FFMPEG_LINK={preset}",
                *odin_passthrough,
            ]
            print(f"[{index}/{total}] {preset} :: {example}")
            print(f"  command: {shlex.join(cmd)}")

            if args.dry_run:
                continue

            proc = subprocess.run(
                cmd,
                cwd=FFMPEG_ROOT,
                text=True,
                capture_output=True,
            )
            if proc.returncode == 0:
                print("  status: PASS")
                built_binaries[(preset, example)] = out_file
                continue

            print(f"  status: FAIL (exit {proc.returncode})")
            output = (proc.stdout or "") + (proc.stderr or "")
            for line in _tail_lines(output):
                print(f"    {line}")
            build_failures.append((preset, example, proc.returncode))
            if args.fail_fast:
                break
        if build_failures and args.fail_fast:
            break

    print()
    print("Build Summary")
    print(f"  presets: {', '.join(presets)}")
    print(f"  examples: {len(examples)}")
    print(f"  attempted: {index}")
    print(f"  failed: {len(build_failures)}")

    if build_failures:
        print()
        print("Build Failures")
        for preset, example, returncode in build_failures:
            print(f"  - {preset} :: {example} (exit {returncode})")

    run_failures: list[tuple[str, str, str]] = []
    run_skips: list[tuple[str, str, str]] = []
    run_passed = 0
    selected_explicit = set(args.example or [])

    if args.run:
        print()
        print("Run Phase")
        run_total = len(presets) * len(examples)
        run_idx = 0

        for preset in presets:
            for example in examples:
                run_idx += 1
                print(f"[{run_idx}/{run_total}] {preset} :: {example}")

                key = (preset, example)
                if key not in built_binaries:
                    reason = "build failed"
                    run_skips.append((preset, example, reason))
                    print(f"  status: SKIP ({reason})")
                    continue

                if (
                    example in HARDWARE_EXAMPLES
                    and not args.run_hw
                    and example not in selected_explicit
                    and example not in run_overrides
                ):
                    reason = "hardware-dependent (use -run-hw or -run-override)"
                    run_skips.append((preset, example, reason))
                    print(f"  status: SKIP ({reason})")
                    continue

                if (
                    example in LONG_RUNNING_EXAMPLES
                    and not args.run_long
                    and example not in selected_explicit
                    and example not in run_overrides
                ):
                    reason = "long-running (use -run-long or -run-override)"
                    run_skips.append((preset, example, reason))
                    print(f"  status: SKIP ({reason})")
                    continue

                run_args = run_overrides.get(example)
                if run_args is None:
                    run_args = _default_run_args(example, out_dir=out_dir, preset=preset)
                if run_args is None:
                    reason = "no run arguments (use -run-override)"
                    run_skips.append((preset, example, reason))
                    print(f"  status: SKIP ({reason})")
                    continue

                cmd = [str(built_binaries[key]), *run_args]
                print(f"  command: {shlex.join(cmd)}")
                if args.dry_run:
                    print("  status: PASS")
                    run_passed += 1
                    continue

                timeout = 3.0 if example in LONG_RUNNING_EXAMPLES else args.run_timeout
                try:
                    proc = subprocess.run(
                        cmd,
                        cwd=FFMPEG_ROOT,
                        text=True,
                        capture_output=True,
                        timeout=timeout,
                        env=_runtime_env(preset),
                    )
                except subprocess.TimeoutExpired:
                    if example in LONG_RUNNING_EXAMPLES:
                        print("  status: PASS (timed out as expected)")
                        run_passed += 1
                        continue
                    reason = f"timed out after {timeout:.1f}s"
                    print(f"  status: FAIL ({reason})")
                    run_failures.append((preset, example, reason))
                    if args.fail_fast:
                        break
                    continue

                if proc.returncode == 0:
                    print("  status: PASS")
                    run_passed += 1
                    continue

                output = (proc.stdout or "") + (proc.stderr or "")
                if skip_reason := _optional_run_skip_reason(example, output):
                    reason = skip_reason
                    run_skips.append((preset, example, reason))
                    print(f"  status: SKIP ({reason})")
                    for line in _tail_lines(output):
                        print(f"    {line}")
                    continue

                reason = f"exit {proc.returncode}"
                print(f"  status: FAIL ({reason})")
                for line in _tail_lines(output):
                    print(f"    {line}")
                run_failures.append((preset, example, reason))
                if args.fail_fast:
                    break
            if args.fail_fast and run_failures:
                break

        print()
        print("Run Summary")
        print(f"  passed: {run_passed}")
        print(f"  skipped: {len(run_skips)}")
        print(f"  failed: {len(run_failures)}")
        if run_skips:
            print()
            print("Run Skips")
            for preset, example, reason in run_skips:
                print(f"  - {preset} :: {example} ({reason})")
        if run_failures:
            print()
            print("Run Failures")
            for preset, example, reason in run_failures:
                print(f"  - {preset} :: {example} ({reason})")

    if build_failures:
        return 1
    if run_failures:
        return 1
    if args.run and args.strict_run and run_skips:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
