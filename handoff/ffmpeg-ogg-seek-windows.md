# Ogg Vorbis seek timestamps on Windows

Change `qxunllpm` in this checkout adds `patches/0006` and `patches/0007`. They are backports of upstream FFmpeg
commits `b863390a8d` and `1d83e7145c`. Without them, libavformat 63.6.100 gives the first page of Ogg Vorbis packets
after a seek timestamps counted back from the end of the stream. The stream also reports `start_time=-128` and a
duration that is 128 samples too long.

The macOS libraries are rebuilt. The `windows_x64` libraries are not rebuilt yet. The monorepo change `ppnulryz`
removes the bside workaround for this bug. Thus Ogg Vorbis seeks in bside on Windows land about 1 s early until you
rebuild these libraries.

## Rebuild

Use an x64 Native Tools Command Prompt for VS 2022, with the environment that `README.md` gives:

```bat
cd /d C:\path\to\monorepo
.\tool.bat vendor build ffmpeg
```

The source preparation must print these two lines:

```text
Applying: lavf/oggparsevorbis: restore page-start timestamp calculation after seek
Applying: lavf/oggparsevorbis: set stream start_time before applying ts_offset
```

Commit the rebuilt `windows_x64` files in `vendor/ffmpeg`, push `main`, then run `.\tool.bat vendor lock ffmpeg` and
commit `vendor.lock` from the monorepo root.

## Check

```bat
set SDL_AUDIO_DRIVER=dummy
.\tool.bat test bside/play
```

All tests must pass. `spotify_files_decrypt_past_their_header` seeks to 3 s of a 4 s Ogg Vorbis file and expects
1 s of audio after the seek, within 2%.

If it reports about 93600 frames after the seek (1.95 s at 48 kHz), the old `avformat-63.dll` is still in use.

Remove this file after the check passes.

Windows execution is not verified on the macOS host.
