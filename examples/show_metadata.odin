// show_metadata — open a media file and print all metadata key/value pairs.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/show_metadata/ -- /path/to/file.mp4
package main

import avfmt "../avformat"
import avutil "../avutil"
import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: show_metadata <file>")
        os.exit(1)
    }

    path := strings.clone_to_cstring(os.args[1])
    defer delete(path)

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

    fmt.printf("Metadata for: %s\n", os.args[1])

    // Container-level metadata
    tag: ^avutil.DictionaryEntry = nil
    for {
        tag = avutil.dict_iterate(ctx.metadata, tag)
        if tag == nil { break }
        fmt.printf("  %-20s = %s\n", tag.key, tag.value)
    }

    // Per-stream metadata
    for i in 0 ..< ctx.nb_streams {
        st := ctx.streams[i]
        tag = nil
        for {
            tag = avutil.dict_iterate(st.metadata, tag)
            if tag == nil { break }
            fmt.printf("  [stream %d] %-16s = %s\n", i, tag.key, tag.value)
        }
    }
}
