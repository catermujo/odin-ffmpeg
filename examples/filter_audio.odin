// filter_audio — generate a sine wave and filter it through an avfilter graph.
//
// Generates 10 seconds of stereo 8000 Hz AV_SAMPLE_FMT_S16 sine wave in
// 1-second chunks, passes each chunk through:
//   abuffer -> volume=0.9 -> aformat -> abuffersink
// then computes an MD5 digest of all output samples and prints it.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/filter_audio/
package main

import avfilt "../avfilter"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

SAMPLE_RATE :: 8000
DURATION_SECS :: 10
SAMPLES_PER_CHUNK :: SAMPLE_RATE // 1 second
TONE_FREQ :: 440.0

err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

init_filter_graph :: proc(
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

    // abuffer args: time_base, sample_rate, sample_fmt, channel_layout
    abuffer_args: cstring = "time_base=1/8000:sample_rate=8000:sample_fmt=s16:channel_layout=stereo"

    buffersrc_ctx: ^avfilt.FilterContext
    ret := avfilt.graph_create_filter(&buffersrc_ctx, abuffer_filt, "in", abuffer_args, nil, graph)
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

    // Parse the filter chain between abuffer and abuffersink
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

    filter_spec: cstring = "volume=0.9,aformat=sample_fmts=s16:channel_layouts=stereo:sample_rates=8000"
    ret = avfilt.graph_parse_ptr(graph, filter_spec, &inputs, &outputs, nil)
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

main :: proc() {
    // Allocate AVMD5 context
    md5_ctx := avutil.md5_alloc()
    if md5_ctx == nil {
        fmt.eprintln("av_md5_alloc failed")
        os.exit(1)
    }
    defer avutil.free(md5_ctx)
    avutil.md5_init(md5_ctx)

    graph: ^avfilt.FilterGraph
    buffersrc_ctx: ^avfilt.FilterContext
    buffersink_ctx: ^avfilt.FilterContext
    if !init_filter_graph(&graph, &buffersrc_ctx, &buffersink_ctx) {
        os.exit(1)
    }
    defer avfilt.graph_free(&graph)

    in_frame := avutil.frame_alloc()
    if in_frame == nil {
        fmt.eprintln("av_frame_alloc failed")
        os.exit(1)
    }
    defer avutil.frame_free(&in_frame)

    out_frame := avutil.frame_alloc()
    if out_frame == nil {
        fmt.eprintln("av_frame_alloc failed")
        os.exit(1)
    }
    defer avutil.frame_free(&out_frame)

    // Generate and feed 10 one-second chunks
    for chunk_idx in 0 ..< DURATION_SECS {
        in_frame.nb_samples = SAMPLES_PER_CHUNK
        in_frame.format = c.int(avutil.SampleFormat.S16)
        in_frame.sample_rate = SAMPLE_RATE
        avutil.channel_layout_default(&in_frame.ch_layout, 2)

        if ret := avutil.frame_get_buffer(in_frame, 0); ret < 0 {
            fmt.eprintln("av_frame_get_buffer failed:", err_str(ret))
            os.exit(1)
        }

        // Fill with stereo sine wave (S16 interleaved)
        // data[0] holds interleaved samples for S16
        samples := ([^]i16)(in_frame.data[0])
        base_sample := chunk_idx * SAMPLES_PER_CHUNK
        for i in 0 ..< SAMPLES_PER_CHUNK {
            t := f64(base_sample + i) * (2.0 * math.PI * TONE_FREQ / SAMPLE_RATE)
            val := i16(math.sin(t) * 10000.0)
            samples[i * 2 + 0] = val // left
            samples[i * 2 + 1] = val // right
        }

        in_frame.pts = c.int64_t(base_sample)

        // Push frame into filter graph
        ret := avfilt.add_frame_flags(buffersrc_ctx, in_frame, {})
        if ret < 0 {
            fmt.eprintln("av_buffersrc_add_frame_flags failed:", err_str(ret))
            os.exit(1)
        }

        // Pull all available output frames and accumulate into MD5
        for {
            ret2 := avfilt.get_frame(buffersink_ctx, out_frame)
            if ret2 == avutil.AVERROR_EOF || ret2 == avutil.AVERROR_EAGAIN {
                break
            }
            if ret2 < 0 {
                fmt.eprintln("av_buffersink_get_frame error:", err_str(ret2))
                break
            }

            // Update MD5 with the frame's audio data
            // S16 interleaved: all samples in data[0]
            nb_channels := int(out_frame.ch_layout.nb_channels)
            nb_samples := int(out_frame.nb_samples)
            data_size := nb_channels * nb_samples * size_of(i16)
            if out_frame.data[0] != nil && data_size > 0 {
                avutil.md5_update(md5_ctx, out_frame.data[0], c.size_t(data_size))
            }

            avutil.frame_unref(out_frame)
        }

        avutil.frame_unref(in_frame)
    }

    // Flush the filter graph
    avfilt.add_frame_flags(buffersrc_ctx, nil, {.Push})
    for {
        ret := avfilt.get_frame(buffersink_ctx, out_frame)
        if ret == avutil.AVERROR_EOF || ret == avutil.AVERROR_EAGAIN {
            break
        }
        if ret < 0 {
            break
        }
        nb_channels := int(out_frame.ch_layout.nb_channels)
        nb_samples := int(out_frame.nb_samples)
        data_size := nb_channels * nb_samples * size_of(i16)
        if out_frame.data[0] != nil && data_size > 0 {
            avutil.md5_update(md5_ctx, out_frame.data[0], c.size_t(data_size))
        }
        avutil.frame_unref(out_frame)
    }

    // Finalize and print MD5
    digest: [16]u8
    avutil.md5_final(md5_ctx, &digest[0])

    fmt.printf("MD5: ")
    for b in digest {
        fmt.printf("%02x", b)
    }
    fmt.println()
}
