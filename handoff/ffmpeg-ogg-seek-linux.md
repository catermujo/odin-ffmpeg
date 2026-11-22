# Ogg Vorbis seek timestamps on Linux

Change `qxunllpm` in this checkout adds `patches/0006` and `patches/0007`. They are backports of upstream FFmpeg
commits `b863390a8d` and `1d83e7145c`. Without them, libavformat 63.6.100 gives the first page of Ogg Vorbis packets
after a seek timestamps counted back from the end of the stream. The stream also reports `start_time=-128` and a
duration that is 128 samples too long.

The macOS libraries are rebuilt. The `linux_x64` and `linux_arm64` libraries are not rebuilt yet. The monorepo change
`ppnulryz` removes the bside workaround for this bug. Thus Ogg Vorbis seeks in bside on Linux land about 1 s early
until you rebuild these libraries.

## Rebuild

On a Linux x64 host, from the monorepo root:

```bash
./tool vendor build ffmpeg
```

Do the same on a Linux arm64 host for `linux_arm64`.

The source preparation must print these two lines:

```text
Applying: lavf/oggparsevorbis: restore page-start timestamp calculation after seek
Applying: lavf/oggparsevorbis: set stream start_time before applying ts_offset
```

`linux_x64/build_manifest.json` must name the new source revision and patch hashes. Commit the rebuilt files in
`vendor/ffmpeg`, push `main`, then run `./tool vendor lock ffmpeg` and commit `vendor.lock` from the monorepo root.

## Check

```bash
SDL_AUDIO_DRIVER=dummy ./tool test bside/play
```

All tests must pass. `spotify_files_decrypt_past_their_header` seeks to 3 s of a 4 s Ogg Vorbis file and expects
1 s of audio after the seek, within 2%.

If it reports about 93600 frames after the seek (1.95 s at 48 kHz), the old `libavformat.so.63` is still in use.

Remove this file after the check passes.

Linux execution is not verified on the macOS host.
