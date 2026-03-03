// remux — copy all streams from input to output without re-encoding.
//
// Demonstrates packet-level copy with timestamp rescaling.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/remux/ -- input.mp4 output.mkv
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

main :: proc() {
    if len(os.args) < 3 {
        fmt.eprintln("usage: remux <input> <output>")
        os.exit(1)
    }

    in_path := strings.clone_to_cstring(os.args[1])
    out_path := strings.clone_to_cstring(os.args[2])
    defer { delete(in_path); delete(out_path) }

    // ── Open input ────────────────────────────────────────────────────────
    ifmt_ctx: ^avfmt.FormatContext
    if ret := avfmt.open_input(&ifmt_ctx, in_path, nil, nil); ret < 0 {
        fmt.eprintfln("error: cannot open input '%s': %s", os.args[1], err_str(ret))
        os.exit(1)
    }
    defer avfmt.close_input(&ifmt_ctx)

    if avfmt.find_stream_info(ifmt_ctx, nil) < 0 {
        fmt.eprintln("error: could not read stream info")
        os.exit(1)
    }

    // ── Open output ───────────────────────────────────────────────────────
    ofmt_ctx: ^avfmt.FormatContext
    if avfmt.alloc_output_context2(&ofmt_ctx, nil, nil, out_path) < 0 {
        fmt.eprintln("error: could not create output context")
        os.exit(1)
    }
    defer {
        if ofmt_ctx != nil && ofmt_ctx.oformat != nil && .No_File not_in ofmt_ctx.oformat.flags {
            avfmt.closep(&ofmt_ctx.pb)
        }
        avfmt.free_context(ofmt_ctx)
    }

    // Copy stream parameters to output.
    stream_map := make([]int, ifmt_ctx.nb_streams)
    defer delete(stream_map)
    out_idx := 0
    for i in 0 ..< ifmt_ctx.nb_streams {
        in_st := ifmt_ctx.streams[i]
        par := in_st.codecpar
        if par.codec_type != .Video && par.codec_type != .Audio && par.codec_type != .Subtitle {
            stream_map[i] = -1
            continue
        }
        stream_map[i] = out_idx
        out_idx += 1

        out_st := avfmt.new_stream(ofmt_ctx, nil)
        if out_st == nil {
            fmt.eprintln("error: cannot allocate output stream")
            os.exit(1)
        }
        if avcodec.parameters_copy(out_st.codecpar, par) < 0 {
            fmt.eprintln("error: cannot copy codec parameters")
            os.exit(1)
        }
        out_st.codecpar.codec_tag = 0
    }

    if ofmt_ctx.oformat != nil && .No_File not_in ofmt_ctx.oformat.flags {
        if avfmt.open(&ofmt_ctx.pb, out_path, {.Write}) < 0 {
            fmt.eprintfln("error: cannot open output file '%s'", os.args[2])
            os.exit(1)
        }
    }

    if avfmt.write_header(ofmt_ctx, nil) < 0 {
        fmt.eprintln("error: cannot write output header")
        os.exit(1)
    }

    // ── Packet copy loop ──────────────────────────────────────────────────
    pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&pkt)

    for avfmt.read_frame(ifmt_ctx, pkt) >= 0 {
        si := int(pkt.stream_index)
        if si >= int(ifmt_ctx.nb_streams) || stream_map[si] < 0 {
            avcodec.packet_unref(pkt)
            continue
        }

        in_st := ifmt_ctx.streams[si]
        out_si := stream_map[si]
        out_st := ofmt_ctx.streams[out_si]

        pkt.stream_index = c.int(out_si)
        avcodec.packet_rescale_ts(pkt, in_st.time_base, out_st.time_base)
        pkt.pos = -1

        avfmt.interleaved_write_frame(ofmt_ctx, pkt)
        avcodec.packet_unref(pkt)
    }

    avfmt.write_trailer(ofmt_ctx)
    fmt.println("Remux complete.")
}
