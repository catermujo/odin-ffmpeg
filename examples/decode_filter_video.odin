// decode_filter_video — demux + decode a video file and run it through a
// "vflip" filter, printing the pts of each output frame.
//
// Ports filtering_video.c from the FFmpeg examples. For each output frame it
// prints the pts and waits ~40 ms (av_usleep) to simulate playback rate.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/decode_filter_video/ -- <input_file>
package main

import avcodec "../avcodec"
import avfilt "../avfilter"
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

init_filter_graph :: proc(
    codec_ctx: ^avcodec.CodecContext,
    stream: ^avfmt.Stream,
    filter_descr: string,
    graph_out: ^^avfilt.FilterGraph,
    buffersrc_out: ^^avfilt.FilterContext,
    buffersink_out: ^^avfilt.FilterContext,
) -> bool {
    graph := avfilt.graph_alloc()
    if graph == nil {
        fmt.eprintln("avfilter_graph_alloc failed")
        return false
    }

    buffer_filt := avfilt.get_by_name("buffer")
    if buffer_filt == nil {
        fmt.eprintln("could not find 'buffer' filter")
        avfilt.graph_free(&graph)
        return false
    }
    buffersink_filt := avfilt.get_by_name("buffersink")
    if buffersink_filt == nil {
        fmt.eprintln("could not find 'buffersink' filter")
        avfilt.graph_free(&graph)
        return false
    }

    // Build buffer filter args:
    // video_size=WxH:pix_fmt=<int>:time_base=N/D:pixel_aspect=N/D
    tb := codec_ctx.pkt_timebase
    sar := codec_ctx.sample_aspect_ratio

    buffer_args := fmt.tprintf(
        "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
        codec_ctx.width,
        codec_ctx.height,
        c.int(codec_ctx.pix_fmt),
        tb.num,
        tb.den,
        sar.num,
        sar.den,
    )

    buffersrc_ctx: ^avfilt.FilterContext
    ret := avfilt.graph_create_filter(
        &buffersrc_ctx,
        buffer_filt,
        "in",
        strings.clone_to_cstring(buffer_args),
        nil,
        graph,
    )
    if ret < 0 {
        fmt.eprintln("avfilter_graph_create_filter (buffer) failed:", err_str(ret))
        avfilt.graph_free(&graph)
        return false
    }

    buffersink_ctx: ^avfilt.FilterContext
    ret = avfilt.graph_create_filter(&buffersink_ctx, buffersink_filt, "out", nil, nil, graph)
    if ret < 0 {
        fmt.eprintln("avfilter_graph_create_filter (buffersink) failed:", err_str(ret))
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

    ret = avfilt.graph_parse_ptr(graph, strings.clone_to_cstring(filter_descr), &inputs, &outputs, nil)
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

decode_and_filter :: proc(
    codec_ctx: ^avcodec.CodecContext,
    pkt: ^avcodec.Packet,
    frame: ^avutil.Frame,
    filt_frame: ^avutil.Frame,
    buffersrc_ctx: ^avfilt.FilterContext,
    buffersink_ctx: ^avfilt.FilterContext,
) {
    if ret := avcodec.send_packet(codec_ctx, pkt); ret < 0 {
        fmt.eprintln("avcodec_send_packet error:", err_str(ret))
        return
    }
    for {
        ret := avcodec.receive_frame(codec_ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            break
        }
        if ret < 0 {
            fmt.eprintln("avcodec_receive_frame error:", err_str(ret))
            break
        }
        frame.pts = frame.best_effort_timestamp

        // Push into filter
        ret2 := avfilt.add_frame_flags(buffersrc_ctx, frame, {})
        if ret2 < 0 {
            fmt.eprintln("av_buffersrc_add_frame_flags failed:", err_str(ret2))
            avutil.frame_unref(frame)
            continue
        }

        // Pull filtered frames
        for {
            ret3 := avfilt.get_frame(buffersink_ctx, filt_frame)
            if ret3 == avutil.AVERROR_EAGAIN || ret3 == avutil.AVERROR_EOF {
                break
            }
            if ret3 < 0 {
                fmt.eprintln("av_buffersink_get_frame error:", err_str(ret3))
                break
            }
            fmt.printf("pts: %d\n", filt_frame.pts)
            // Throttle to simulate ~25fps playback (40ms per frame)
            avutil.usleep(1000 * 40)
            avutil.frame_unref(filt_frame)
        }

        avutil.frame_unref(frame)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: decode_filter_video <input_file>")
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

    // Find best video stream
    decoder: ^avcodec.Codec
    video_stream_idx := avfmt.find_best_stream(fmt_ctx, .Video, -1, -1, &decoder, 0)
    if video_stream_idx < 0 {
        fmt.eprintln("no video stream found")
        os.exit(1)
    }
    if decoder == nil {
        fmt.eprintln("no decoder found for video stream")
        os.exit(1)
    }

    stream := fmt_ctx.streams[video_stream_idx]

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

    // Build filter graph: buffer -> vflip -> buffersink
    graph: ^avfilt.FilterGraph
    buffersrc_ctx: ^avfilt.FilterContext
    buffersink_ctx: ^avfilt.FilterContext
    if !init_filter_graph(codec_ctx, stream, "vflip", &graph, &buffersrc_ctx, &buffersink_ctx) {
        os.exit(1)
    }
    defer avfilt.graph_free(&graph)

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
        if pkt.stream_index == video_stream_idx {
            decode_and_filter(codec_ctx, pkt, frame, filt_frame, buffersrc_ctx, buffersink_ctx)
        }
        avcodec.packet_unref(pkt)
    }

    // Flush decoder
    decode_and_filter(codec_ctx, nil, frame, filt_frame, buffersrc_ctx, buffersink_ctx)

    // Flush filter graph
    avfilt.add_frame_flags(buffersrc_ctx, nil, {.Push})
    for {
        ret2 := avfilt.get_frame(buffersink_ctx, filt_frame)
        if ret2 == avutil.AVERROR_EAGAIN || ret2 == avutil.AVERROR_EOF {
            break
        }
        if ret2 < 0 { break }
        fmt.printf("pts: %d (flushed)\n", filt_frame.pts)
        avutil.frame_unref(filt_frame)
    }
}
