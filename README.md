# Catermujo FFmpeg vendor

The canonical entry points are:

- `build.bat` / `build_static.bat` — Windows shared or static libraries.
- `build.sh` / `build_static.sh` — macOS or Linux shared or static libraries.
- `build_wasm.sh` — Emscripten static libraries in `*.wasm.a`; Web has no shared-library mode.

The Web build stages one archive per FFmpeg library. Odin's WebAssembly branches import those archives, while the root
build system adds them automatically to Emscripten application links when `vendor/ffmpeg` is a dependency.
The build enables Emscripten pthread support because current FFmpeg requires a thread backend for its compatibility
API.

Run it from this directory after installing Emscripten:

```bash
./build_wasm.sh
```

## Windows build with D3D12VA, NVENC, QSV, and AMF

The vendor build enables D3D12VA H.264, NVIDIA NVENC, Intel QSV, and AMD AMF. GPU drivers are only needed when using the encoders;
the build needs their development headers and libraries.

Install the Windows build tools and SDK headers from PowerShell:

```powershell
scoop install git make pkg-config vcpkg cmake
vcpkg install ffnvcodec:x64-windows amd-amf:x64-windows
```

QSV needs oneVPL development files. Check the package before building:

```powershell
pkg-config --modversion vpl
pkg-config --exists "vpl >= 2.6"
```

If that check fails, build and install oneVPL from source. The dispatcher is enough for the build; the Intel graphics
driver supplies the runtime implementation:

```powershell
git clone https://github.com/oneapi-src/oneVPL.git C:\deps\oneVPL
cmake -S C:\deps\oneVPL -B C:\deps\oneVPL-build -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_INSTALL_PREFIX=C:\deps\oneVPL-install -DINSTALL_EXAMPLES=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF
cmake --build C:\deps\oneVPL-build --config Release --target install --parallel
```

AMF needs headers version 1.5.2 or newer. The vcpkg package may be older than FFmpeg accepts. If configure reports
`amf requested but not found`, an AMF version error, or the package has no `AMF/core/*.h`, use the current AMF source:

```bat
git clone https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git C:\deps\AMF
mklink /J C:\deps\AMF\amf\public\include\AMF C:\deps\AMF\amf\public\include
```

Run `mklink` from an elevated Command Prompt. Skip it when using an SDK that already has `include\AMF\core`;
in that case, replace `C:/deps/AMF/amf/public/include` below with that SDK's include directory.

Run the build from an **x64 Native Tools Command Prompt for VS 2022**. Expose both `.pc` directories and the
development headers:

```bat
cd /d C:\path\to\catermujo\vendor\ffmpeg
set "PATH=C:\Users\<you>\scoop\apps\pkg-config\current;C:\Users\<you>\scoop\apps\vcpkg\current;%PATH%"
set "PKG_CONFIG_PATH=C:\Users\<you>\scoop\apps\vcpkg\current\installed\x64-windows\lib\pkgconfig;C:\deps\oneVPL-install\lib\pkgconfig"
set "FFMPEG_EXTRA_CFLAGS=-IC:/deps/AMF/amf/public/include -IC:/Users/<you>/scoop/apps/vcpkg/current/installed/x64-windows/include"
pkg-config --modversion vpl
pkg-config --modversion ffnvcodec
python build_windows.py shared x64
python build_windows.py static x64
```

From the catermujo root, `./tool vendor build ffmpeg` builds both shared and static variants. The direct commands above
select either variant explicitly.

At runtime, keep `libvpl.dll` from `C:\deps\oneVPL-install\bin` beside the application or on `PATH` when using
QSV. NVIDIA and AMD GPU drivers provide the NVENC and AMF runtime components. D3D12VA uses the Windows D3D12 video
encode interfaces supplied by the graphics driver.

The explicit `--enable-d3d12va` flag is required because FFmpeg's D3D12VA encoder is not enabled by every Windows
autodetection environment. The encoder is exposed at runtime as `h264_d3d12va` and consumes D3D12 NV12 frames.

For a D3D12-only build on a machine without the optional NVIDIA, AMD, or oneVPL SDKs, set
`FFMPEG_D3D12_ONLY=1` before running the Windows build. This keeps the D3D12 encoder while disabling those unrelated
hardware backends and their development-package checks.

### Missing dependency fixes

- `cl.exe`: install Visual Studio 2022 Desktop development with C++ and use its x64 Native Tools prompt.
- `bash.exe`: install Git for Windows or MSYS2; `scoop install git` provides Git Bash.
- `make`: install GNU Make with `scoop install make`, or use MSYS2 Make.
- `pkg-config`: install `scoop install pkg-config` and put its Scoop directory on `PATH`.
- `vcpkg`: install `scoop install vcpkg`, or install vcpkg and put it on `PATH`.
- `ffnvcodec`: run `vcpkg install ffnvcodec:x64-windows`; add its `lib\pkgconfig` directory to `PKG_CONFIG_PATH`.
- `libvpl >= 2.6`: build oneVPL above and add its `lib\pkgconfig` directory to `PKG_CONFIG_PATH`.
- AMF: use AMF 1.5.2+ headers and add the directory containing `AMF/core/*.h` to `FFMPEG_EXTRA_CFLAGS`.

The build clones FFmpeg source automatically when `FFmpeg` is missing; set `FFMPEG_SRC_REMOTE` to use a mirror.


## Windows Vulkan compute encoding

Windows shared/static builds explicitly enable Vulkan hardware contexts and `prores_ks_vulkan` while retaining
the existing D3D12VA/NVENC/AMF/oneVPL configuration. Both batch entry points delegate to `build_windows.py`, which
locates and initializes Visual Studio even when launched through the monorepo vendor workflow.

The build requires Vulkan headers >= 1.3.277 and a supported GLSL-to-SPIR-V compiler. It uses `VULKAN_SDK/Include`
or the sibling Slang checkout's Vulkan-Headers, and locates `glslc`, `glslang`, or `glslangValidator` on PATH.
When no shader compiler is available, it builds the sibling Slang checkout's official glslang sources with CMake
into `FFmpeg/.build-deps/glslang-build`; this does not install a system package. Override discovery with
`FFMPEG_VULKAN_INCLUDE`, `FFMPEG_GLSLC`, or `FFMPEG_GLSLANG_SOURCE` for standalone vendor builds.

The Vulkan loader and graphics driver are runtime requirements. ProRes Vulkan is a compute encoder: hardware
frames and planar image conversion must be supplied explicitly. Encoder availability does not prove D3D12 texture
import support or zero-readback application integration. Verify `prores_ks_vulkan` enumeration and actual Vulkan
frames/encoder initialization with the newly built DLLs before pinning or publishing them.

Windows builds require zlib to preserve PNG/APNG and compressed codecs. Put its headers/libraries in
FFMPEG_EXTRA_CFLAGS/FFMPEG_EXTRA_LDFLAGS or pkg-config. A local `.build-deps/zlib-install/bin/zlib.dll` is
staged automatically; set `FFMPEG_ZLIB_RUNTIME` for another runtime path. Configure fails if zlib is missing.

With upstream CMake zlib headers on MSVC, zconf.h must treat HAVE_UNISTD_H as a boolean: use
`#if defined(HAVE_UNISTD_H) && HAVE_UNISTD_H` instead of `#ifdef HAVE_UNISTD_H` in the local build prefix.
FFmpeg defines the unavailable feature as 0; a presence-only check would incorrectly include unistd.h.
`windows_x64/build_manifest.json` records each variant's source revision, embedded configuration, artifact hashes,
codec inventory for native shared builds, and the exact local compatibility header hash used.
