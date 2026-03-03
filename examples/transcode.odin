// transcode — full A/V transcode with filter graphs.
//
// Port of FFmpeg doc/examples/transcode.c
//
// For each audio/video stream the example:
//   1. Opens a decoder matching the source codec.
//   2. Opens an encoder for the same codec type.
//   3. Builds a simple passthrough filter graph (buffer → buffersink).
//   4. Runs the main demux → decode → filter → encode → mux loop.
//
// Usage:
//   odin run vendor/ffmpeg/examples/transcode/ -- <input> <output>
package main

import avcodec "../avcodec"
import avfilt "../avfilter"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"


// AV_OPT_SEARCH_CHILDREN from FFmpeg opt.h
AV_OPT_SEARCH_CHILDREN :: c.int(2)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

die :: proc(msg: string, code: c.int = 0) {
    if code != 0 {
        fmt.eprintfln("ERROR: %s: %s", msg, err_str(code))
    } else {
        fmt.eprintfln("ERROR: %s", msg)
    }
    os.exit(1)
}

// ---------------------------------------------------------------------------
// Per-stream state
// ---------------------------------------------------------------------------

StreamContext :: struct {
    dec_ctx: ^avcodec.CodecContext,
    enc_ctx: ^avcodec.CodecContext,
}

FilteringContext :: struct {
    buffersrc_ctx:  ^avfilt.FilterContext,
    buffersink_ctx: ^avfilt.FilterContext,
    filter_graph:   ^avfilt.FilterGraph,
}

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

ifmt_ctx: ^avfmt.FormatContext
ofmt_ctx: ^avfmt.FormatContext
stream_ctx: []StreamContext
filter_ctx: []FilteringContext

// ---------------------------------------------------------------------------
// Open input streams
// ---------------------------------------------------------------------------

open_input_file :: proc(filename: string) {
    cname := strings.clone_to_cstring(filename)
    defer delete(cname)

    ret := avfmt.open_input(&ifmt_ctx, cname, nil, nil)
    if ret < 0 { die("open input", ret) }

    ret = avfmt.find_stream_info(ifmt_ctx, nil)
    if ret < 0 { die("find stream info", ret) }

    stream_ctx = make([]StreamContext, ifmt_ctx.nb_streams)

    for i in 0 ..< int(ifmt_ctx.nb_streams) {
        st := ifmt_ctx.streams[i]
        typ := st.codecpar.codec_type
        if typ != .Video && typ != .Audio { continue }

        dec := avcodec.find_decoder(st.codecpar.codec_id)
        if dec == nil { die("decoder not found") }

        dc := avcodec.alloc_context3(dec)
        if dc == nil { die("alloc dec ctx") }

        ret = avcodec.parameters_to_context(dc, st.codecpar)
        if ret < 0 { die("parameters_to_context", ret) }

        if typ == .Video {
            dc.framerate = avfmt.guess_frame_rate(ifmt_ctx, st, nil)
        }

        ret = avcodec.open2(dc, dec, nil)
        if ret < 0 { die("open decoder", ret) }

        stream_ctx[i].dec_ctx = dc
    }

    avfmt.dump_format(ifmt_ctx, 0, cname, 0)
}

// ---------------------------------------------------------------------------
// Open output streams — encode with same codec type
// ---------------------------------------------------------------------------

open_output_file :: proc(filename: string) {
    cname := strings.clone_to_cstring(filename)
    defer delete(cname)

    ret := avfmt.alloc_output_context2(&ofmt_ctx, nil, nil, cname)
    if ret < 0 { die("alloc output ctx", ret) }

    for i in 0 ..< int(ifmt_ctx.nb_streams) {
        in_st := ifmt_ctx.streams[i]
        typ := in_st.codecpar.codec_type
        if typ != .Video && typ != .Audio { continue }

        dc := stream_ctx[i].dec_ctx

        out_st := avfmt.new_stream(ofmt_ctx, nil)
        if out_st == nil { die("new stream") }

        // Find encoder for the same codec (prefer lossless/copy approach: use same codec id)
        enc := avcodec.find_encoder(in_st.codecpar.codec_id)
        if enc == nil {
            // Fallback: use default encoder for the type
            if typ == .Video { enc = avcodec.find_encoder(.Mpeg4) } else {
                enc = avcodec.find_encoder(.Mp2)
            }
        }
        if enc == nil { die("encoder not found") }

        ec := avcodec.alloc_context3(enc)
        if ec == nil { die("alloc enc ctx") }

        if typ == .Video {
            ec.width = dc.width
            ec.height = dc.height
            ec.time_base = avutil.Rational{dc.framerate.den, dc.framerate.num}
            ec.framerate = dc.framerate
            ec.pix_fmt = dc.pix_fmt
            if ec.pix_fmt == .None { ec.pix_fmt = .YUV420P }
        } else {
            ec.sample_rate = dc.sample_rate
            ec.sample_fmt = dc.sample_fmt
            if ec.sample_fmt == .None { ec.sample_fmt = .FltP }
            avutil.channel_layout_copy(&ec.ch_layout, &dc.ch_layout)
            ec.time_base = avutil.Rational{1, dc.sample_rate}
        }

        if .Global_Header in ofmt_ctx.oformat.flags {
            ec.flags += {.Global_Header}
        }

        ret = avcodec.open2(ec, enc, nil)
        if ret < 0 { die("open encoder", ret) }

        ret = avcodec.parameters_from_context(out_st.codecpar, ec)
        if ret < 0 { die("parameters_from_context", ret) }

        out_st.time_base = ec.time_base
        stream_ctx[i].enc_ctx = ec
    }

    avfmt.dump_format(ofmt_ctx, 0, cname, 1)

    if .No_File not_in ofmt_ctx.oformat.flags {
        ret = avfmt.open(&ofmt_ctx.pb, cname, {.Write})
        if ret < 0 { die("avio_open", ret) }
    }

    ret = avfmt.write_header(ofmt_ctx, nil)
    if ret < 0 { die("write header", ret) }
}

// ---------------------------------------------------------------------------
// Filter graph init (simple passthrough: buffer → buffersink)
// ---------------------------------------------------------------------------

init_filter :: proc(idx: int) {
    dc := stream_ctx[idx].dec_ctx
    ec := stream_ctx[idx].enc_ctx
    typ := dc.codec_type

    graph := avfilt.graph_alloc()
    if graph == nil { die("avfilter_graph_alloc") }

    buffersrc := avfilt.get_by_name("buffer" if typ == .Video else "abuffer")
    buffersink := avfilt.get_by_name("buffersink" if typ == .Video else "abuffersink")

    src_ctx, sink_ctx: ^avfilt.FilterContext

    in_st := ifmt_ctx.streams[idx]
    args_str: string
    if typ == .Video {
        args_str = fmt.tprintf(
            "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
            dc.width,
            dc.height,
            c.int(dc.pix_fmt),
            in_st.time_base.num,
            in_st.time_base.den,
            dc.sample_aspect_ratio.num,
            dc.sample_aspect_ratio.den,
        )
    } else {
        args_str = fmt.tprintf(
            "time_base=%d/%d:sample_rate=%d:sample_fmt=%d:channel_layout=",
            in_st.time_base.num,
            in_st.time_base.den,
            dc.sample_rate,
            c.int(dc.sample_fmt),
        )
        // channel_layout name: use "stereo" or "mono" heuristic
        nb := dc.ch_layout.nb_channels
        ch_name := "stereo" if nb == 2 else "mono"
        args_str = fmt.tprintf("%s%s", args_str, ch_name)
    }

    args_cstr := strings.clone_to_cstring(args_str)
    defer delete(args_cstr)

    ret := avfilt.graph_create_filter(&src_ctx, buffersrc, "in", args_cstr, nil, graph)
    if ret < 0 { die("create src filter", ret) }

    ret = avfilt.graph_create_filter(&sink_ctx, buffersink, "out", nil, nil, graph)
    if ret < 0 { die("create sink filter", ret) }

    if typ == .Video {
        pix_fmts := [2]avutil.PixelFormat{ec.pix_fmt, .None}
        avutil.opt_set_bin(
            sink_ctx,
            "pix_fmts",
            cast([^]u8)&pix_fmts[0],
            size_of(avutil.PixelFormat),
            AV_OPT_SEARCH_CHILDREN,
        )
    } else {
        sample_fmts := [2]avutil.SampleFormat{ec.sample_fmt, .None}
        avutil.opt_set_bin(
            sink_ctx,
            "sample_fmts",
            cast([^]u8)&sample_fmts[0],
            size_of(avutil.SampleFormat),
            AV_OPT_SEARCH_CHILDREN,
        )
    }

    // Link src → sink
    ret = avfilt.link(src_ctx, 0, sink_ctx, 0)
    if ret < 0 { die("avfilter_link", ret) }

    ret = avfilt.graph_config(graph, nil)
    if ret < 0 { die("avfilter_graph_config", ret) }

    filter_ctx[idx].buffersrc_ctx = src_ctx
    filter_ctx[idx].buffersink_ctx = sink_ctx
    filter_ctx[idx].filter_graph = graph
}

init_filters :: proc() {
    filter_ctx = make([]FilteringContext, ifmt_ctx.nb_streams)
    for i in 0 ..< int(ifmt_ctx.nb_streams) {
        dc := stream_ctx[i].dec_ctx
        if dc == nil { continue }
        init_filter(i)
    }
}

// ---------------------------------------------------------------------------
// Encode + write one frame
// ---------------------------------------------------------------------------

encode_write_frame :: proc(frame: ^avutil.Frame, stream_idx: int, pkt: ^avcodec.Packet) {
    ec := stream_ctx[stream_idx].enc_ctx
    out_st := ofmt_ctx.streams[stream_idx]
    in_st := ifmt_ctx.streams[stream_idx]

    ret := avcodec.send_frame(ec, frame)
    if ret < 0 { return }

    for {
        ret = avcodec.receive_packet(ec, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        avcodec.packet_rescale_ts(pkt, in_st.time_base, out_st.time_base)
        pkt.stream_index = i32(stream_idx)

        avfmt.interleaved_write_frame(ofmt_ctx, pkt)
        avcodec.packet_unref(pkt)
    }
}

// ---------------------------------------------------------------------------
// Filter + encode a decoded frame
// ---------------------------------------------------------------------------

filter_encode_write :: proc(frame: ^avutil.Frame, stream_idx: int, pkt: ^avcodec.Packet) {
    fc := &filter_ctx[stream_idx]

    ret := avfilt.add_frame_flags(fc.buffersrc_ctx, frame, {})
    if ret < 0 { return }

    for {
        filt_frame := avutil.frame_alloc()
        if filt_frame == nil { break }
        ret = avfilt.get_frame(fc.buffersink_ctx, filt_frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            avutil.frame_free(&filt_frame)
            break
        }
        if ret < 0 {
            avutil.frame_free(&filt_frame)
            break
        }
        filt_frame.pict_type = .None
        encode_write_frame(filt_frame, stream_idx, pkt)
        avutil.frame_free(&filt_frame)
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 3 {
        fmt.eprintln("usage: transcode <input> <output>")
        os.exit(1)
    }

    open_input_file(os.args[1])
    defer avfmt.close_input(&ifmt_ctx)

    open_output_file(os.args[2])
    defer {
        for i in 0 ..< len(stream_ctx) {
            if stream_ctx[i].dec_ctx != nil { avcodec.free_context(&stream_ctx[i].dec_ctx) }
            if stream_ctx[i].enc_ctx != nil { avcodec.free_context(&stream_ctx[i].enc_ctx) }
        }
        delete(stream_ctx)
    }
    defer {
        for i in 0 ..< len(filter_ctx) {
            if filter_ctx[i].filter_graph != nil {
                avfilt.graph_free(&filter_ctx[i].filter_graph)
            }
        }
        delete(filter_ctx)
    }
    defer {
        if .No_File not_in ofmt_ctx.oformat.flags {
            avfmt.closep(&ofmt_ctx.pb)
        }
        avfmt.free_context(ofmt_ctx)
    }

    init_filters()

    pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&pkt)
    frame := avutil.frame_alloc()
    defer avutil.frame_free(&frame)

    // Main loop
    for {
        ret := avfmt.read_frame(ifmt_ctx, pkt)
        if ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        idx := int(pkt.stream_index)
        dc := stream_ctx[idx].dec_ctx
        if dc == nil {
            avcodec.packet_unref(pkt)
            continue
        }

        ret = avcodec.send_packet(dc, pkt)
        avcodec.packet_unref(pkt)
        if ret < 0 { continue }

        for {
            ret = avcodec.receive_frame(dc, frame)
            if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
            if ret < 0 { break }

            frame.pts = frame.best_effort_timestamp
            filter_encode_write(frame, idx, pkt)
            avutil.frame_unref(frame)
        }
    }

    // Flush decoders → filters → encoders
    for i in 0 ..< int(ifmt_ctx.nb_streams) {
        dc := stream_ctx[i].dec_ctx
        if dc == nil { continue }

        avcodec.send_packet(dc, nil)
        for {
            ret := avcodec.receive_frame(dc, frame)
            if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
            if ret < 0 { break }
            frame.pts = frame.best_effort_timestamp
            filter_encode_write(frame, i, pkt)
            avutil.frame_unref(frame)
        }

        // Flush filter graph
        avfilt.add_frame_flags(filter_ctx[i].buffersrc_ctx, nil, {})
        for {
            filt_frame := avutil.frame_alloc()
            if filt_frame == nil { break }
            ret := avfilt.get_frame(filter_ctx[i].buffersink_ctx, filt_frame)
            if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
                avutil.frame_free(&filt_frame)
                break
            }
            if ret < 0 {
                avutil.frame_free(&filt_frame)
                break
            }
            encode_write_frame(filt_frame, i, pkt)
            avutil.frame_free(&filt_frame)
        }

        // Flush encoder
        encode_write_frame(nil, i, pkt)
    }

    avfmt.write_trailer(ofmt_ctx)
    fmt.printfln("transcoded '%s' -> '%s'", os.args[1], os.args[2])
}
