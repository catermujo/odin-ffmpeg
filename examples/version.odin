// version — print version strings for all 7 FFmpeg libraries.
//
// Build:
//   odin run vendor/ffmpeg/examples/version/
package main

import avcodec "../avcodec"
import avdevice "../avdevice"
import avfilter "../avfilter"
import avfmt "../avformat"
import avutil "../avutil"
import swresample "../swresample"
import swscale "../swscale"
import "core:fmt"

ver :: proc(v: u32) -> string {
    return fmt.tprintf("%d.%d.%d", v >> 16, (v >> 8) & 0xFF, v & 0xFF)
}

main :: proc() {
    fmt.printf("avutil:     %s\n", ver(avutil.version()))
    fmt.printf("avcodec:    %s\n", ver(avcodec.version()))
    fmt.printf("avformat:   %s\n", ver(avfmt.version()))
    fmt.printf("avfilter:   %s\n", ver(avfilter.version()))
    fmt.printf("swscale:    %s\n", ver(swscale.version()))
    fmt.printf("swresample: %s\n", ver(swresample.version()))
    fmt.printf("avdevice:   %s\n", ver(avdevice.version()))
}
