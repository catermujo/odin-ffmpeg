// decode — decode a video file and scale frames to RGB24 via swscale.
//
// Demonstrates the full demux → decode → pixel-format-convert pipeline.
// Decodes all video frames; writes the first decoded frame as /tmp/frame.ppm.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/decode/ -- /path/to/file.mp4
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import sws "../swscale"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

// AVERROR(EAGAIN) on every platform == -EAGAIN.  We only need to distinguish
// "try again" vs "real error", so a simple < 0 check for the inner loop is
// sufficient for a teaching example.

err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

write_ppm :: proc(path: string, data: []u8, w, h, stride: int) {
    header := fmt.tprintf("P6\n%d %d\n255\n", w, h)
    buf := make([]u8, len(header) + stride * h)
    defer delete(buf)
    copy(buf, transmute([]u8)header)
    off := len(header)
    for row in 0 ..< h {
        copy(buf[off:], data[row * stride:][:w * 3])
        off += w * 3
    }
    _ = os.write_entire_file(path, buf)
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: decode <file>")
        os.exit(1)
    }

    path := strings.clone_to_cstring(os.args[1])
    defer delete(path)

    // ── Open input ───────────────────────────────────────────────────────────
    fmt_ctx: ^avfmt.FormatContext
    if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
        fmt.eprintfln("error: cannot open '%s': %s", os.args[1], err_str(ret))
        os.exit(1)
    }
    defer avfmt.close_input(&fmt_ctx)

    if avfmt.find_stream_info(fmt_ctx, nil) < 0 {
        fmt.eprintln("error: could not read stream info")
        os.exit(1)
    }

    // ── Find best video stream ────────────────────────────────────────────────
    video_idx := avfmt.find_best_stream(fmt_ctx, .Video, -1, -1, nil, 0)
    if video_idx < 0 {
        fmt.eprintln("error: no video stream found")
        os.exit(1)
    }

    st := fmt_ctx.streams[video_idx]
    par := st.codecpar

    // ── Open decoder ─────────────────────────────────────────────────────────
    codec := avcodec.find_decoder(par.codec_id)
    if codec == nil {
        fmt.eprintln("error: no decoder found for", avcodec.get_name(par.codec_id))
        os.exit(1)
    }

    codec_ctx := avcodec.alloc_context3(codec)
    defer avcodec.free_context(&codec_ctx)

    avcodec.parameters_to_context(codec_ctx, par)
    if avcodec.open2(codec_ctx, codec, nil) < 0 {
        fmt.eprintln("error: could not open codec")
        os.exit(1)
    }

    src_w := int(par.width)
    src_h := int(par.height)
    src_fmt := avutil.PixelFormat(par.format)

    fmt.printf("Video stream #%d: %s  %dx%d\n", video_idx, avcodec.get_name(par.codec_id), src_w, src_h)

    // ── Create swscale context (src pixel format → RGB24) ────────────────────
    sws_ctx := sws.getContext(
        c.int(src_w),
        c.int(src_h),
        src_fmt,
        c.int(src_w),
        c.int(src_h),
        .RGB24,
        sws.Flags{.Bilinear},
        nil,
        nil,
        nil,
    )
    if sws_ctx == nil {
        fmt.eprintln("error: could not create sws context")
        os.exit(1)
    }
    defer sws.freeContext(sws_ctx)

    // ── Allocate output RGB buffer ────────────────────────────────────────────
    rgb_stride := src_w * 3
    rgb_buf := make([]u8, rgb_stride * src_h)
    defer delete(rgb_buf)

    // dst_data / dst_stride wrappers for sws_scale
    dst_data: [8][^]u8 = {}
    dst_strides: [8]c.int = {}
    dst_data[0] = raw_data(rgb_buf)
    dst_strides[0] = c.int(rgb_stride)

    // ── Decode loop ───────────────────────────────────────────────────────────
    frame := avutil.frame_alloc()
    pkt := avcodec.packet_alloc()
    defer { avutil.frame_free(&frame); avcodec.packet_free(&pkt) }

    n_frames := 0
    wrote_first := false

    for avfmt.read_frame(fmt_ctx, pkt) >= 0 {
        if int(pkt.stream_index) != int(video_idx) {
            avcodec.packet_unref(pkt)
            continue
        }

        if avcodec.send_packet(codec_ctx, pkt) < 0 {
            avcodec.packet_unref(pkt)
            continue
        }
        avcodec.packet_unref(pkt)

        for {
            ret := avcodec.receive_frame(codec_ctx, frame)
            if ret < 0 { break }

            // Scale decoded frame → RGB24
            src_data := cast([^][^]u8)&frame.data[0]
            src_strides := cast([^]c.int)&frame.linesize[0]
            sws.scale(
                sws_ctx,
                src_data,
                src_strides,
                0,
                c.int(src_h),
                cast([^][^]u8)&dst_data[0],
                cast([^]c.int)&dst_strides[0],
            )

            n_frames += 1

            // Write first frame as a PPM for easy visual inspection
            if !wrote_first {
                write_ppm("/tmp/frame.ppm", rgb_buf, src_w, src_h, rgb_stride)
                fmt.println("Wrote first frame to /tmp/frame.ppm")
                wrote_first = true
            }

            avutil.frame_unref(frame)
        }
    }

    // Flush decoder
    avcodec.send_packet(codec_ctx, nil)
    for {
        if avcodec.receive_frame(codec_ctx, frame) < 0 { break }
        n_frames += 1
        avutil.frame_unref(frame)
    }

    fmt.printf("Decoded %d video frame(s)\n", n_frames)
}
