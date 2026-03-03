// hw_decode — hardware-accelerated video decode using a specified device type.
//
// Port of FFmpeg doc/examples/hw_decode.c
//
// Decodes a video stream using the hardware decoder for the given device type.
// Each decoded frame is transferred to a software frame and written as raw
// pixel data to the output file.
//
// Usage:
//   odin run vendor/ffmpeg/examples/hw_decode/ -- <device_type> <input> <output_raw>
//
// Example (VAAPI):
//   ./hw_decode vaapi input.mp4 /tmp/out.raw
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"


// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

hw_device_type: avutil.HWDeviceType
hw_pix_fmt: avutil.PixelFormat

// ---------------------------------------------------------------------------
// get_format callback: scans pix_fmts list for hw_pix_fmt
// ---------------------------------------------------------------------------

get_hw_format :: proc "c" (ctx: ^avcodec.CodecContext, pix_fmts: ^avutil.PixelFormat) -> avutil.PixelFormat {
    fmts := cast([^]avutil.PixelFormat)pix_fmts
    i := 0
    for {
        p := fmts[i]
        if p == .None { break }
        if p == hw_pix_fmt { return p }
        i += 1
    }
    return .None
}

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
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 4 {
        fmt.eprintln("usage: hw_decode <device_type> <input> <output_raw>")
        // List available device types
        t := avutil.hwdevice_iterate_types(.None)
        for t != .None {
            fmt.println(" ", avutil.hwdevice_get_type_name(t))
            t = avutil.hwdevice_iterate_types(t)
        }
        os.exit(1)
    }

    type_name := strings.clone_to_cstring(os.args[1])
    defer delete(type_name)

    hw_device_type = avutil.hwdevice_find_type_by_name(type_name)
    if hw_device_type == .None {
        fmt.eprintfln("Device type '%s' not found. Available types:", os.args[1])
        t := avutil.hwdevice_iterate_types(.None)
        for t != .None {
            fmt.println(" ", avutil.hwdevice_get_type_name(t))
            t = avutil.hwdevice_iterate_types(t)
        }
        os.exit(1)
    }

    // Open input
    input_cname := strings.clone_to_cstring(os.args[2])
    defer delete(input_cname)

    ifmt_ctx: ^avfmt.FormatContext
    ret := avfmt.open_input(&ifmt_ctx, input_cname, nil, nil)
    if ret < 0 { die("open input", ret) }
    defer avfmt.close_input(&ifmt_ctx)

    ret = avfmt.find_stream_info(ifmt_ctx, nil)
    if ret < 0 { die("find stream info", ret) }

    // Find best video stream
    dec: ^avcodec.Codec
    video_stream := avfmt.find_best_stream(ifmt_ctx, .Video, -1, -1, &dec, 0)
    if video_stream < 0 { die("no video stream found") }

    // Find HW config for this device type
    hw_pix_fmt = .None
    for i: c.int = 0;; i += 1 {
        config := avcodec.get_hw_config(dec, i)
        if config == nil { break }
        if .HW_Device_Ctx in config.methods &&
           config.device_type == hw_device_type {
            hw_pix_fmt = config.pix_fmt
            break
        }
    }
    if hw_pix_fmt == .None { die("no HW config found for device type") }

    // Allocate and configure decoder context
    decoder_ctx := avcodec.alloc_context3(dec)
    if decoder_ctx == nil { die("alloc decoder ctx") }
    defer avcodec.free_context(&decoder_ctx)

    st := ifmt_ctx.streams[video_stream]
    ret = avcodec.parameters_to_context(decoder_ctx, st.codecpar)
    if ret < 0 { die("parameters_to_context", ret) }

    decoder_ctx.get_format = get_hw_format

    // Create HW device context
    hw_device_ctx: ^avutil.BufferRef
    ret = avutil.hwdevice_ctx_create(&hw_device_ctx, hw_device_type, nil, nil, 0)
    if ret < 0 { die("av_hwdevice_ctx_create", ret) }
    defer avutil.buffer_unref(&hw_device_ctx)

    decoder_ctx.hw_device_ctx = avutil.buffer_ref(hw_device_ctx)

    ret = avcodec.open2(decoder_ctx, dec, nil)
    if ret < 0 { die("open decoder", ret) }

    // Open output file
    output_cname := strings.clone_to_cstring(os.args[3])
    defer delete(output_cname)

    output_fd, open_err := os.open(os.args[3], os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default_File)
    if open_err != nil { die("open output file") }
    defer os.close(output_fd)

    pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&pkt)
    frame := avutil.frame_alloc()
    defer avutil.frame_free(&frame)
    sw_frame := avutil.frame_alloc()
    defer avutil.frame_free(&sw_frame)

    decode_frames :: proc(
        decoder_ctx: ^avcodec.CodecContext,
        hw_pix_fmt: avutil.PixelFormat,
        frame, sw_frame: ^avutil.Frame,
        output_fd: ^os.File,
    ) {
        for {
            ret := avcodec.receive_frame(decoder_ctx, frame)
            if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { return }
            if ret < 0 { return }

            tmp_frame: ^avutil.Frame
            if avutil.PixelFormat(frame.format) == hw_pix_fmt {
                // Transfer HW → SW
                if avutil.hwframe_transfer_data(sw_frame, frame, 0) < 0 {
                    avutil.frame_unref(frame)
                    continue
                }
                tmp_frame = sw_frame
            } else {
                tmp_frame = frame
            }

            // Write frame planes to output
            size := avutil.image_get_buffer_size(
                avutil.PixelFormat(tmp_frame.format),
                tmp_frame.width,
                tmp_frame.height,
                1,
            )
            if size < 0 {
                avutil.frame_unref(frame)
                avutil.frame_unref(sw_frame)
                continue
            }

            buf := cast([^]u8)avutil.malloc(c.size_t(size))
            if buf != nil {
                copied := avutil.image_copy_to_buffer(
                    buf,
                    size,
                    cast([^][^]u8)&tmp_frame.data[0],
                    cast([^]c.int)&tmp_frame.linesize[0],
                    avutil.PixelFormat(tmp_frame.format),
                    tmp_frame.width,
                    tmp_frame.height,
                    1,
                )
                if copied > 0 {
                    os.write(output_fd, buf[:copied])
                }
                avutil.freep(&buf)
            }

            avutil.frame_unref(frame)
            avutil.frame_unref(sw_frame)
        }
    }

    // Main decode loop
    for {
        ret = avfmt.read_frame(ifmt_ctx, pkt)
        if ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        if int(pkt.stream_index) == int(video_stream) {
            ret = avcodec.send_packet(decoder_ctx, pkt)
            avcodec.packet_unref(pkt)
            if ret < 0 { break }
            decode_frames(decoder_ctx, hw_pix_fmt, frame, sw_frame, output_fd)
        } else {
            avcodec.packet_unref(pkt)
        }
    }

    // Flush decoder
    avcodec.send_packet(decoder_ctx, nil)
    decode_frames(decoder_ctx, hw_pix_fmt, frame, sw_frame, output_fd)

    fmt.println("hw_decode done")
}
