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

## Windows build with NVENC, QSV, and AMF

The vendor build enables NVIDIA NVENC, Intel QSV, and AMD AMF. GPU drivers are only needed when using the encoders;
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

From the catermujo root, `./tool vendor build ffmpeg` builds the shared variant. The direct commands above build shared
and static variants explicitly.

At runtime, keep `libvpl.dll` from `C:\deps\oneVPL-install\bin` beside the application or on `PATH` when using
QSV. NVIDIA and AMD GPU drivers provide the NVENC and AMF runtime components.

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
