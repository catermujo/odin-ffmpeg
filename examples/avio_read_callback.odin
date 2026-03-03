// avio_read_callback — open a file via a custom AVIOContext with read callback.
//
// Demonstrates memory-mapped file access with av_file_map + avio_alloc_context.
// Opens the file entirely in memory and probes its format.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/avio_read_callback/ -- /path/to/file.mp4
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

// Buffer used by the custom read callback.
BufferData :: struct {
    ptr:  [^]u8,
    size: c.size_t,
}

read_packet :: proc "c" (opaque: rawptr, buf: [^]u8, buf_size: c.int) -> c.int {
    bd := cast(^BufferData)opaque
    to_read := min(c.size_t(buf_size), bd.size)
    if to_read == 0 {
        return avutil.AVERROR_EOF
    }
    // copy to_read bytes from bd.ptr into buf
    for i in 0 ..< int(to_read) {
        buf[i] = bd.ptr[i]
    }
    bd.ptr = bd.ptr[to_read:]
    bd.size -= to_read
    return c.int(to_read)
}

AVIO_BUFFER_SIZE :: 4096

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: avio_read_callback <file>")
        os.exit(1)
    }

    path_str := strings.clone_to_cstring(os.args[1])
    defer delete(path_str)

    // Memory-map the file.
    file_data: ^u8
    file_size: c.size_t
    if avutil.file_map(path_str, &file_data, &file_size, 0, nil) < 0 {
        fmt.eprintfln("error: cannot map file '%s'", os.args[1])
        os.exit(1)
    }
    defer avutil.file_unmap(cast([^]u8)file_data, file_size)

    bd := BufferData {
        ptr  = cast([^]u8)file_data,
        size = file_size,
    }

    // Allocate a custom AVIOContext.
    avio_buf := cast([^]u8)avutil.malloc(AVIO_BUFFER_SIZE)
    if avio_buf == nil {
        fmt.eprintln("error: cannot allocate avio buffer")
        os.exit(1)
    }

    avio_ctx := avfmt.avio_alloc_context(avio_buf, AVIO_BUFFER_SIZE, 0, &bd, read_packet, nil, nil)
    if avio_ctx == nil {
        fmt.eprintln("error: cannot allocate avio context")
        avutil.free(avio_buf)
        os.exit(1)
    }

    fmt_ctx := avfmt.alloc_context()
    if fmt_ctx == nil {
        fmt.eprintln("error: cannot allocate format context")
        os.exit(1)
    }
    fmt_ctx.pb = avio_ctx
    defer {
        avfmt.close_input(&fmt_ctx)
        // avio_ctx and avio_buf are freed by avformat_close_input when
        // fmt_ctx.pb is set; nothing else to free here.
    }

    if avfmt.open_input(&fmt_ctx, nil, nil, nil) < 0 {
        fmt.eprintln("error: avformat_open_input failed")
        os.exit(1)
    }

    if avfmt.find_stream_info(fmt_ctx, nil) < 0 {
        fmt.eprintln("error: could not read stream info")
        os.exit(1)
    }

    fmt.printf("File:     %s\n", os.args[1])
    fmt.printf("Format:   %s\n", fmt_ctx.iformat != nil ? fmt_ctx.iformat.name : "unknown")
    fmt.printf("Duration: %.3f s\n", f64(fmt_ctx.duration) / f64(avutil.AV_TIME_BASE))
    fmt.printf("Streams:  %d\n", fmt_ctx.nb_streams)

    for i in 0 ..< fmt_ctx.nb_streams {
        st := fmt_ctx.streams[i]
        par := st.codecpar
        fmt.printf("  Stream #%d: %s\n", i, avcodec.get_name(par.codec_id))
    }
}
