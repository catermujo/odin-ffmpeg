@echo off
setlocal EnableExtensions

set "FFMPEG_TARGET_ARCH=%1"
if not defined FFMPEG_TARGET_ARCH set "FFMPEG_TARGET_ARCH=x64"
if /I "%FFMPEG_TARGET_ARCH%"=="x86_64" set "FFMPEG_TARGET_ARCH=x64"
if /I "%FFMPEG_TARGET_ARCH%"=="amd64" set "FFMPEG_TARGET_ARCH=x64"
if /I "%FFMPEG_TARGET_ARCH%"=="arm64" set "FFMPEG_TARGET_ARCH=arm64"
if /I "%FFMPEG_TARGET_ARCH%"=="x64" (
    set "FFMPEG_MSVC_ARCH=x64"
) else if /I "%FFMPEG_TARGET_ARCH%"=="arm64" (
    set "FFMPEG_MSVC_ARCH=arm64"
) else (
    echo ERROR: Unsupported target architecture '%FFMPEG_TARGET_ARCH%'.
    exit /b 1
)

set "BASH_EXE="
for %%I in (bash.exe) do set "BASH_EXE=%%~$PATH:I"
if not defined BASH_EXE if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles%\MSYS2\usr\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\MSYS2\usr\bin\bash.exe"

if not defined BASH_EXE (
    echo Error: bash.exe not found. Install Git for Windows or MSYS2 and add bash to PATH.
    exit /b 1
)

where cl.exe >NUL 2>NUL
if errorlevel 1 (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist "%VSWHERE%" (
        for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_PATH=%%I"
    )
    if defined VS_PATH if exist "%VS_PATH%\Common7\Tools\VsDevCmd.bat" (
        call "%VS_PATH%\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=%FFMPEG_MSVC_ARCH% >NUL
    )
)

where cl.exe >NUL 2>NUL
if errorlevel 1 (
    echo Error: cl.exe not found. Open a Visual Studio x64 developer command prompt and retry.
    exit /b 1
)

"%BASH_EXE%" "%~dp0build_windows.sh" static %*
if errorlevel 1 exit /b %errorlevel%
exit /b 0
