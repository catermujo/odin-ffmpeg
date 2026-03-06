@echo off
setlocal EnableExtensions

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
        call "%VS_PATH%\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=x64 >NUL
    )
)

where cl.exe >NUL 2>NUL
if errorlevel 1 (
    echo Error: cl.exe not found. Open a Visual Studio x64 developer command prompt and retry.
    exit /b 1
)

"%BASH_EXE%" "%~dp0build_windows.sh" shared %*
if errorlevel 1 exit /b %errorlevel%
exit /b 0
