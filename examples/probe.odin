// probe — open a media file and print its format, duration, and stream info.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/probe/ -- /path/to/file.mp4
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: probe <file>")
        os.exit(1)
    }

    path := strings.clone_to_cstring(os.args[1])
    defer delete(path)

    // Open input
    ctx: ^avfmt.FormatContext
    if avfmt.open_input(&ctx, path, nil, nil) < 0 {
        fmt.eprintfln("error: cannot open '%s'", os.args[1])
        os.exit(1)
    }
    defer avfmt.close_input(&ctx)

    if avfmt.find_stream_info(ctx, nil) < 0 {
        fmt.eprintln("error: could not read stream info")
        os.exit(1)
    }

    // Format-level info
    format_name := ctx.iformat != nil ? ctx.iformat.name : "unknown"
    dur_s := f64(ctx.duration) / f64(avutil.AV_TIME_BASE)
    fmt.printf("File:      %s\n", os.args[1])
    fmt.printf("Format:    %s\n", format_name)
    fmt.printf("Duration:  %.3f s\n", dur_s)
    fmt.printf("Bit rate:  %d bps\n", ctx.bit_rate)
    fmt.printf("Streams:   %d\n\n", ctx.nb_streams)

    // Per-stream info
    for i in 0 ..< ctx.nb_streams {
        st := ctx.streams[i]
        par := st.codecpar
        codec_name := avcodec.get_name(par.codec_id)
        type_name := avutil.get_media_type_string(par.codec_type)

        #partial switch par.codec_type {
        case .Video:
            fmt.printf("  Stream #%d [video]  codec=%-14s %dx%d\n", i, codec_name, par.width, par.height)
        case .Audio:
            fmt.printf(
                "  Stream #%d [audio]  codec=%-14s %d Hz  %d ch\n",
                i,
                codec_name,
                par.sample_rate,
                par.ch_layout.nb_channels,
            )
        case:
            fmt.printf("  Stream #%d [%-8s] codec=%s\n", i, type_name, codec_name)
        }
    }
}
