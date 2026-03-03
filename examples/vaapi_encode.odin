// vaapi_encode — VAAPI H.264 encoder (Linux only).
//
// Port of FFmpeg doc/examples/vaapi_encode.c
//
// Reads raw NV12 frames from a file and encodes them to H.264 using the
// VAAPI h264_vaapi encoder. The output is a raw H.264 Annex-B bitstream.
//
// Usage:
//   odin run vendor/ffmpeg/examples/vaapi_encode/ -- <width> <height> <input_nv12> <output.h264>
//
// Note: Linux only. Requires a VAAPI-capable GPU and driver.
package main

import avcodec "../avcodec"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"


// AVHWFramesContext from FFmpeg hwcontext.h (simplified — fields used by this example)
AVHWFramesContext :: struct {
    av_class:          ^avutil.Class,
    internal:          rawptr,
    device_ctx:        ^AVHWDeviceContext,
    hwctx:             rawptr,
    free:              rawptr,
    user_opaque:       rawptr,
    pool:              rawptr,
    initial_pool_size: c.int,
    format:            avutil.PixelFormat,
    sw_format:         avutil.PixelFormat,
    width:             c.int,
    height:            c.int,
}

// AVHWDeviceContext opaque forward ref
AVHWDeviceContext :: struct {}

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
// set_hwframe_ctx — allocate and initialise the VAAPI frame pool
// ---------------------------------------------------------------------------

set_hwframe_ctx :: proc(avctx: ^avcodec.CodecContext, hw_device_ctx: ^avutil.BufferRef, width, height: c.int) {
    hw_frames_ref := avutil.hwframe_ctx_alloc(hw_device_ctx)
    if hw_frames_ref == nil { die("av_hwframe_ctx_alloc") }

    frames_ctx := cast(^AVHWFramesContext)hw_frames_ref.data
    frames_ctx.format = .VAAPI
    frames_ctx.sw_format = .NV12
    frames_ctx.width = width
    frames_ctx.height = height
    frames_ctx.initial_pool_size = 20

    ret := avutil.hwframe_ctx_init(hw_frames_ref)
    if ret < 0 {
        avutil.buffer_unref(&hw_frames_ref)
        die("av_hwframe_ctx_init", ret)
    }

    avctx.hw_frames_ctx = avutil.buffer_ref(hw_frames_ref)
    avutil.buffer_unref(&hw_frames_ref)
}

// ---------------------------------------------------------------------------
// encode — send frame to encoder and drain output packets
// ---------------------------------------------------------------------------

encode :: proc(avctx: ^avcodec.CodecContext, frame: ^avutil.Frame, pkt: ^avcodec.Packet, output_fd: ^os.File) {
    ret := avcodec.send_frame(avctx, frame)
    if ret < 0 { return }

    for {
        ret = avcodec.receive_packet(avctx, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        os.write(output_fd, pkt.data[:pkt.size])
        avcodec.packet_unref(pkt)
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 5 {
        fmt.eprintln("usage: vaapi_encode <width> <height> <input_nv12> <output.h264>")
        os.exit(1)
    }

    width := c.int(strconv.parse_int(os.args[1], 10) or_else 0)
    height := c.int(strconv.parse_int(os.args[2], 10) or_else 0)
    if width <= 0 || height <= 0 { die("invalid width/height") }

    input_fd, err := os.open(os.args[3])
    if err != nil { die("open input file") }
    defer os.close(input_fd)

    output_fd, err2 := os.open(os.args[4], os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default_File)
    if err2 != nil { die("open output file") }
    defer os.close(output_fd)

    // Create VAAPI device
    hw_device_ctx: ^avutil.BufferRef
    ret := avutil.hwdevice_ctx_create(&hw_device_ctx, .Vaapi, nil, nil, 0)
    if ret < 0 { die("av_hwdevice_ctx_create", ret) }
    defer avutil.buffer_unref(&hw_device_ctx)

    // Find h264_vaapi encoder
    enc := avcodec.find_encoder_by_name("h264_vaapi")
    if enc == nil { die("h264_vaapi encoder not found") }

    avctx := avcodec.alloc_context3(enc)
    if avctx == nil { die("alloc codec context") }
    defer avcodec.free_context(&avctx)

    avctx.width = width
    avctx.height = height
    avctx.time_base = avutil.Rational{1, 25}
    avctx.framerate = avutil.Rational{25, 1}
    avctx.pix_fmt = .VAAPI

    set_hwframe_ctx(avctx, hw_device_ctx, width, height)

    ret = avcodec.open2(avctx, enc, nil)
    if ret < 0 { die("avcodec_open2", ret) }

    sw_frame := avutil.frame_alloc()
    if sw_frame == nil { die("alloc sw frame") }
    defer avutil.frame_free(&sw_frame)

    hw_frame := avutil.frame_alloc()
    if hw_frame == nil { die("alloc hw frame") }
    defer avutil.frame_free(&hw_frame)

    pkt := avcodec.packet_alloc()
    if pkt == nil { die("alloc pkt") }
    defer avcodec.packet_free(&pkt)

    y_size := int(width * height)
    uv_size := y_size / 2

    y_buf := make([]u8, y_size)
    defer delete(y_buf)
    uv_buf := make([]u8, uv_size)
    defer delete(uv_buf)

    frame_idx: c.int64_t = 0

    for {
        // Read Y plane
        n_y, y_err := os.read(input_fd, y_buf)
        if n_y == 0 || y_err != nil { break }
        if n_y < y_size { break }

        // Read UV plane
        n_uv, uv_err := os.read(input_fd, uv_buf)
        if n_uv == 0 || uv_err != nil { break }
        if n_uv < uv_size { break }

        // Set up SW frame (NV12)
        sw_frame.width = width
        sw_frame.height = height
        sw_frame.format = c.int(avutil.PixelFormat.NV12)

        ret = avutil.frame_get_buffer(sw_frame, 0)
        if ret < 0 { die("av_frame_get_buffer", ret) }

        // Copy Y plane
        for row in 0 ..< int(height) {
            dst := sw_frame.data[0][row * int(sw_frame.linesize[0]):]
            src := y_buf[row * int(width):]
            copy(dst[:int(width)], src[:int(width)])
        }

        // Copy UV plane (interleaved, height/2 rows)
        uv_rows := int(height) / 2
        for row in 0 ..< uv_rows {
            dst := sw_frame.data[1][row * int(sw_frame.linesize[1]):]
            src := uv_buf[row * int(width):]
            copy(dst[:int(width)], src[:int(width)])
        }

        // Allocate HW frame and upload
        ret = avutil.hwframe_get_buffer(avctx.hw_frames_ctx, hw_frame, 0)
        if ret < 0 { die("av_hwframe_get_buffer", ret) }

        ret = avutil.hwframe_transfer_data(hw_frame, sw_frame, 0)
        if ret < 0 { die("av_hwframe_transfer_data", ret) }

        hw_frame.pts = frame_idx
        frame_idx += 1

        encode(avctx, hw_frame, pkt, output_fd)

        avutil.frame_unref(sw_frame)
        avutil.frame_unref(hw_frame)
    }

    // Flush encoder
    encode(avctx, nil, pkt, output_fd)

    fmt.printfln("encoded %d frames to '%s'", frame_idx, os.args[4])
}
