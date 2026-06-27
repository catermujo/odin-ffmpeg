@echo off
setlocal EnableExtensions

set "FFMPEG_TARGET_ARCH=%1"
if not defined FFMPEG_TARGET_ARCH set "FFMPEG_TARGET_ARCH=%VSCMD_ARG_TGT_ARCH%"
if not defined FFMPEG_TARGET_ARCH set "FFMPEG_TARGET_ARCH=x64"
python "%~dp0build_windows.py" static %FFMPEG_TARGET_ARCH%
exit /b %errorlevel%
