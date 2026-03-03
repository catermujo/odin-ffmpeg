// decode_filter_audio — demux + decode audio, filter through avfilter, write PCM.
//
// Opens an audio/video file, finds the best audio stream, decodes it, passes
// each decoded frame through:
//   abuffer -> aresample=8000,aformat=sample_fmts=s16:channel_layouts=mono -> abuffersink
// then writes the resulting raw PCM to /tmp/decode_filter_audio.raw.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/decode_filter_audio/ -- <input_file>
package main

import avcodec "../avcodec"
import avfilt "../avfilter"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

FILTER_SPEC :: "aresample=8000,aformat=sample_fmts=s16:channel_layouts=mono"

err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

init_filter_graph :: proc(
    codec_ctx: ^avcodec.CodecContext,
    stream: ^avfmt.Stream,
    graph_out: ^^avfilt.FilterGraph,
    buffersrc_out: ^^avfilt.FilterContext,
    buffersink_out: ^^avfilt.FilterContext,
) -> bool {
    graph := avfilt.graph_alloc()
    if graph == nil {
        fmt.eprintln("avfilter_graph_alloc failed")
        return false
    }

    abuffer_filt := avfilt.get_by_name("abuffer")
    if abuffer_filt == nil {
        fmt.eprintln("could not find 'abuffer' filter")
        avfilt.graph_free(&graph)
        return false
    }
    abuffersink_filt := avfilt.get_by_name("abuffersink")
    if abuffersink_filt == nil {
        fmt.eprintln("could not find 'abuffersink' filter")
        avfilt.graph_free(&graph)
        return false
    }

    // Build abuffer args from codec context
    ch_buf: [64]c.char
    avutil.channel_layout_describe(&codec_ctx.ch_layout, &ch_buf[0], size_of(ch_buf))
    ch_str := strings.clone_from_cstring(cstring(&ch_buf[0]))
    defer delete(ch_str)

    fmt_name := avutil.get_sample_fmt_name(codec_ctx.sample_fmt)
    if fmt_name == nil { fmt_name = "s16" }

    tb := stream.time_base
    abuffer_args := fmt.tprintf(
        "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
        tb.num,
        tb.den,
        codec_ctx.sample_rate,
        fmt_name,
        ch_str,
    )

    buffersrc_ctx: ^avfilt.FilterContext
    ret := avfilt.graph_create_filter(
        &buffersrc_ctx,
        abuffer_filt,
        "in",
        strings.clone_to_cstring(abuffer_args),
        nil,
        graph,
    )
    if ret < 0 {
        fmt.eprintln("avfilter_graph_create_filter (abuffer) failed:", err_str(ret))
        avfilt.graph_free(&graph)
        return false
    }

    buffersink_ctx: ^avfilt.FilterContext
    ret = avfilt.graph_create_filter(&buffersink_ctx, abuffersink_filt, "out", nil, nil, graph)
    if ret < 0 {
        fmt.eprintln("avfilter_graph_create_filter (abuffersink) failed:", err_str(ret))
        avfilt.graph_free(&graph)
        return false
    }

    outputs := avfilt.inout_alloc()
    inputs := avfilt.inout_alloc()
    if outputs == nil || inputs == nil {
        fmt.eprintln("avfilter_inout_alloc failed")
        avfilt.inout_free(&outputs)
        avfilt.inout_free(&inputs)
        avfilt.graph_free(&graph)
        return false
    }

    outputs.name = avutil.strdup("in")
    outputs.filter_ctx = buffersrc_ctx
    outputs.pad_idx = 0
    outputs.next = nil

    inputs.name = avutil.strdup("out")
    inputs.filter_ctx = buffersink_ctx
    inputs.pad_idx = 0
    inputs.next = nil

    ret = avfilt.graph_parse_ptr(graph, FILTER_SPEC, &inputs, &outputs, nil)
    if ret < 0 {
        fmt.eprintln("avfilter_graph_parse_ptr failed:", err_str(ret))
        avfilt.inout_free(&inputs)
        avfilt.inout_free(&outputs)
        avfilt.graph_free(&graph)
        return false
    }
    avfilt.inout_free(&inputs)
    avfilt.inout_free(&outputs)

    ret = avfilt.graph_config(graph, nil)
    if ret < 0 {
        fmt.eprintln("avfilter_graph_config failed:", err_str(ret))
        avfilt.graph_free(&graph)
        return false
    }

    graph_out^ = graph
    buffersrc_out^ = buffersrc_ctx
    buffersink_out^ = buffersink_ctx
    return true
}

filter_and_write :: proc(
    buffersrc_ctx: ^avfilt.FilterContext,
    buffersink_ctx: ^avfilt.FilterContext,
    frame: ^avutil.Frame,
    filt_frame: ^avutil.Frame,
    out_file: ^os.File,
) {
    ret := avfilt.add_frame_flags(buffersrc_ctx, frame, {})
    if ret < 0 {
        fmt.eprintln("av_buffersrc_add_frame_flags failed:", err_str(ret))
        return
    }
    for {
        ret2 := avfilt.get_frame(buffersink_ctx, filt_frame)
        if ret2 == avutil.AVERROR_EAGAIN || ret2 == avutil.AVERROR_EOF {
            break
        }
        if ret2 < 0 {
            fmt.eprintln("av_buffersink_get_frame error:", err_str(ret2))
            break
        }
        // Write raw PCM: S16 mono interleaved — all in data[0]
        nb_samples := int(filt_frame.nb_samples)
        data_size := nb_samples * size_of(i16) // mono
        if filt_frame.data[0] != nil && data_size > 0 {
            os.write(out_file, ([^]u8)(filt_frame.data[0])[:data_size])
        }
        avutil.frame_unref(filt_frame)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: decode_filter_audio <input_file>")
        os.exit(1)
    }
    input_file := os.args[1]

    // Open input
    fmt_ctx: ^avfmt.FormatContext
    ret := avfmt.open_input(&fmt_ctx, strings.clone_to_cstring(input_file), nil, nil)
    if ret < 0 {
        fmt.eprintln("avformat_open_input failed:", err_str(ret))
        os.exit(1)
    }
    defer avfmt.close_input(&fmt_ctx)

    if ret = avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
        fmt.eprintln("avformat_find_stream_info failed:", err_str(ret))
        os.exit(1)
    }

    // Find best audio stream
    decoder: ^avcodec.Codec
    audio_stream_idx := avfmt.find_best_stream(fmt_ctx, .Audio, -1, -1, &decoder, 0)
    if audio_stream_idx < 0 {
        fmt.eprintln("no audio stream found")
        os.exit(1)
    }
    if decoder == nil {
        fmt.eprintln("no decoder found for audio stream")
        os.exit(1)
    }

    stream := fmt_ctx.streams[audio_stream_idx]

    // Allocate and configure codec context
    codec_ctx := avcodec.alloc_context3(decoder)
    if codec_ctx == nil {
        fmt.eprintln("avcodec_alloc_context3 failed")
        os.exit(1)
    }
    defer avcodec.free_context(&codec_ctx)

    ret = avcodec.parameters_to_context(codec_ctx, stream.codecpar)
    if ret < 0 {
        fmt.eprintln("avcodec_parameters_to_context failed:", err_str(ret))
        os.exit(1)
    }
    codec_ctx.pkt_timebase = stream.time_base

    ret = avcodec.open2(codec_ctx, decoder, nil)
    if ret < 0 {
        fmt.eprintln("avcodec_open2 failed:", err_str(ret))
        os.exit(1)
    }

    // Build filter graph
    graph: ^avfilt.FilterGraph
    buffersrc_ctx: ^avfilt.FilterContext
    buffersink_ctx: ^avfilt.FilterContext
    if !init_filter_graph(codec_ctx, stream, &graph, &buffersrc_ctx, &buffersink_ctx) {
        os.exit(1)
    }
    defer avfilt.graph_free(&graph)

    // Open output file
    out_file, out_err := os.open(
        "/tmp/decode_filter_audio.raw",
        os.O_WRONLY | os.O_CREATE | os.O_TRUNC,
        os.Permissions_Default_File,
    )
    if out_err != nil {
        fmt.eprintln("cannot open /tmp/decode_filter_audio.raw")
        os.exit(1)
    }
    defer os.close(out_file)

    pkt := avcodec.packet_alloc()
    if pkt == nil {
        fmt.eprintln("av_packet_alloc failed")
        os.exit(1)
    }
    defer avcodec.packet_free(&pkt)

    frame := avutil.frame_alloc()
    if frame == nil {
        fmt.eprintln("av_frame_alloc failed")
        os.exit(1)
    }
    defer avutil.frame_free(&frame)

    filt_frame := avutil.frame_alloc()
    if filt_frame == nil {
        fmt.eprintln("av_frame_alloc (filt) failed")
        os.exit(1)
    }
    defer avutil.frame_free(&filt_frame)

    // Demux / decode / filter loop
    for avfmt.read_frame(fmt_ctx, pkt) >= 0 {
        if pkt.stream_index != audio_stream_idx {
            avcodec.packet_unref(pkt)
            continue
        }

        ret = avcodec.send_packet(codec_ctx, pkt)
        avcodec.packet_unref(pkt)
        if ret < 0 {
            fmt.eprintln("avcodec_send_packet error:", err_str(ret))
            break
        }

        for {
            ret2 := avcodec.receive_frame(codec_ctx, frame)
            if ret2 == avutil.AVERROR_EAGAIN || ret2 == avutil.AVERROR_EOF {
                break
            }
            if ret2 < 0 {
                fmt.eprintln("avcodec_receive_frame error:", err_str(ret2))
                break
            }
            filter_and_write(buffersrc_ctx, buffersink_ctx, frame, filt_frame, out_file)
            avutil.frame_unref(frame)
        }
    }

    // Flush decoder
    avcodec.send_packet(codec_ctx, nil)
    for {
        ret2 := avcodec.receive_frame(codec_ctx, frame)
        if ret2 == avutil.AVERROR_EAGAIN || ret2 == avutil.AVERROR_EOF {
            break
        }
        if ret2 < 0 { break }
        filter_and_write(buffersrc_ctx, buffersink_ctx, frame, filt_frame, out_file)
        avutil.frame_unref(frame)
    }

    // Flush filter graph
    avfilt.add_frame_flags(buffersrc_ctx, nil, {.Push})
    for {
        ret2 := avfilt.get_frame(buffersink_ctx, filt_frame)
        if ret2 == avutil.AVERROR_EAGAIN || ret2 == avutil.AVERROR_EOF {
            break
        }
        if ret2 < 0 { break }
        nb_samples := int(filt_frame.nb_samples)
        data_size := nb_samples * size_of(i16)
        if filt_frame.data[0] != nil && data_size > 0 {
            os.write(out_file, ([^]u8)(filt_frame.data[0])[:data_size])
        }
        avutil.frame_unref(filt_frame)
    }

    fmt.println("done — PCM written to /tmp/decode_filter_audio.raw")
}
