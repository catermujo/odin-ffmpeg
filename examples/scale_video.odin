// scale_video — decode video from a file, scale each frame to a new size,
// and write raw YUV planes to an output file.
//
// Port of FFmpeg scale_video.c
//
// Usage:
//   scale_video <input_file> <WxH> <output_file>
// Example:
//   scale_video input.mp4 640x480 scaled.yuv
//
// Build / run:
//   odin run vendor/ffmpeg/examples/scale_video/ -- input.mp4 640x480 out.yuv
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import sws "../swscale"
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
    if len(os.args) < 4 {
        fmt.eprintln("usage: scale_video <input_file> <WxH> <output_file>")
        os.exit(1)
    }

    input_path := strings.clone_to_cstring(os.args[1])
    size_str := strings.clone_to_cstring(os.args[2])
    output_path := os.args[3]
    defer {
        delete(input_path)
        delete(size_str)
    }

    // Parse destination size string (e.g. "640x480").
    dst_w, dst_h: c.int
    if ret := avutil.parse_video_size(&dst_w, &dst_h, size_str); ret < 0 {
        fmt.eprintfln("invalid size string '%s': %s", os.args[2], err_str(ret))
        os.exit(1)
    }
    fmt.printf("output size: %dx%d\n", dst_w, dst_h)

    // Open input file.
    fmt_ctx: ^avfmt.FormatContext
    if ret := avfmt.open_input(&fmt_ctx, input_path, nil, nil); ret < 0 {
        fmt.eprintfln("could not open '%s': %s", os.args[1], err_str(ret))
        os.exit(1)
    }
    defer avfmt.close_input(&fmt_ctx)

    if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
        fmt.eprintln("could not read stream info:", err_str(ret))
        os.exit(1)
    }

    // Find the best video stream.
    video_idx := avfmt.find_best_stream(fmt_ctx, .Video, -1, -1, nil, 0)
    if video_idx < 0 {
        fmt.eprintln("no video stream found in input")
        os.exit(1)
    }

    st := fmt_ctx.streams[video_idx]
    par := st.codecpar

    // Open the decoder.
    codec := avcodec.find_decoder(par.codec_id)
    if codec == nil {
        fmt.eprintln("no decoder found for codec", avcodec.get_name(par.codec_id))
        os.exit(1)
    }

    dec_ctx := avcodec.alloc_context3(codec)
    if dec_ctx == nil {
        fmt.eprintln("could not allocate decoder context")
        os.exit(1)
    }
    defer avcodec.free_context(&dec_ctx)

    if ret := avcodec.parameters_to_context(dec_ctx, par); ret < 0 {
        fmt.eprintln("avcodec_parameters_to_context:", err_str(ret))
        os.exit(1)
    }

    if ret := avcodec.open2(dec_ctx, codec, nil); ret < 0 {
        fmt.eprintln("could not open decoder:", err_str(ret))
        os.exit(1)
    }

    src_w := dec_ctx.width
    src_h := dec_ctx.height
    src_fmt := dec_ctx.pix_fmt
    dst_fmt := avutil.PixelFormat.YUV420P

    fmt.printf("source: %dx%d  pix_fmt=%s\n", src_w, src_h, avutil.get_pix_fmt_name(src_fmt))

    // Create a scaling context.
    sws_ctx := sws.getContext(
        src_w,
        src_h,
        src_fmt,
        dst_w,
        dst_h,
        dst_fmt,
        sws.Flags{.Bilinear},
        nil,
        nil,
        nil,
    )
    if sws_ctx == nil {
        fmt.eprintln("could not create sws context")
        os.exit(1)
    }
    defer sws.freeContext(sws_ctx)

    // Allocate destination image buffer.
    dst_pointers: [4][^]u8
    dst_linesizes: [4]c.int
    buf_size := avutil.image_alloc(
        cast([^][^]u8)&dst_pointers[0],
        cast([^]c.int)&dst_linesizes[0],
        dst_w,
        dst_h,
        dst_fmt,
        1,
    )
    if buf_size < 0 {
        fmt.eprintln("could not allocate destination image buffer:", err_str(buf_size))
        os.exit(1)
    }
    defer avutil.freep(&dst_pointers[0])

    // Open the output file for raw YUV writing.
    out_fd, open_err := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default_File)
    if open_err != nil {
        fmt.eprintfln("could not open '%s' for writing", output_path)
        os.exit(1)
    }
    defer os.close(out_fd)

    frame := avutil.frame_alloc()
    pkt := avcodec.packet_alloc()
    defer {
        avutil.frame_free(&frame)
        avcodec.packet_free(&pkt)
    }

    frame_count := 0

    // Decode loop.
    for {
        ret := avfmt.read_frame(fmt_ctx, pkt)
        if ret < 0 { break }

        if pkt.stream_index != c.int(video_idx) {
            avcodec.packet_unref(pkt)
            continue
        }

        if ret2 := avcodec.send_packet(dec_ctx, pkt); ret2 < 0 {
            avcodec.packet_unref(pkt)
            continue
        }
        avcodec.packet_unref(pkt)

        for {
            ret3 := avcodec.receive_frame(dec_ctx, frame)
            if ret3 == avutil.AVERROR_EAGAIN || ret3 == avutil.AVERROR_EOF { break }
            if ret3 < 0 {
                fmt.eprintln("error receiving frame:", err_str(ret3))
                break
            }

            // Scale the decoded frame into dst_pointers.
            sws.scale(
                sws_ctx,
                cast([^][^]u8)&frame.data[0],
                cast([^]c.int)&frame.linesize[0],
                0,
                frame.height,
                cast([^][^]u8)&dst_pointers[0],
                cast([^]c.int)&dst_linesizes[0],
            )

            // Write luma (Y) plane.
            for row in 0 ..< int(dst_h) {
                os.write(out_fd, dst_pointers[0][row * int(dst_linesizes[0]):][:dst_w])
            }
            // Write Cb plane (half height/width).
            for row in 0 ..< int(dst_h) / 2 {
                os.write(out_fd, dst_pointers[1][row * int(dst_linesizes[1]):][:dst_w / 2])
            }
            // Write Cr plane (half height/width).
            for row in 0 ..< int(dst_h) / 2 {
                os.write(out_fd, dst_pointers[2][row * int(dst_linesizes[2]):][:dst_w / 2])
            }

            frame_count += 1
            avutil.frame_unref(frame)
        }
    }

    // Flush the decoder.
    avcodec.send_packet(dec_ctx, nil)
    for {
        ret := avcodec.receive_frame(dec_ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        sws.scale(
            sws_ctx,
            cast([^][^]u8)&frame.data[0],
            cast([^]c.int)&frame.linesize[0],
            0,
            frame.height,
            cast([^][^]u8)&dst_pointers[0],
            cast([^]c.int)&dst_linesizes[0],
        )

        for row in 0 ..< int(dst_h) {
            os.write(out_fd, dst_pointers[0][row * int(dst_linesizes[0]):][:dst_w])
        }
        for row in 0 ..< int(dst_h) / 2 {
            os.write(out_fd, dst_pointers[1][row * int(dst_linesizes[1]):][:dst_w / 2])
        }
        for row in 0 ..< int(dst_h) / 2 {
            os.write(out_fd, dst_pointers[2][row * int(dst_linesizes[2]):][:dst_w / 2])
        }

        frame_count += 1
        avutil.frame_unref(frame)
    }

    fmt.printf("scaled %d frames -> %s (%dx%d yuv420p)\n", frame_count, output_path, dst_w, dst_h)
}
