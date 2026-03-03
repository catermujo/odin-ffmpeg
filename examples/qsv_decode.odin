// qsv_decode — Intel QSV H.264 hardware decode (Linux/Intel only).
//
// Port of FFmpeg doc/examples/qsv_decode.c
//
// Decodes an H.264 input file using the h264_qsv decoder. Each decoded
// frame is transferred from the QSV surface to a software frame and the
// raw plane data is written to the output via an AVIOContext.
//
// Usage:
//   odin run vendor/ffmpeg/examples/qsv_decode/ -- <input> <output_raw>
//
// Note: Linux/Intel only. Requires Intel Media SDK and QSV-capable hardware.
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"


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
// get_format callback: return QSV pixel format
// ---------------------------------------------------------------------------

get_qsv_format :: proc "c" (ctx: ^avcodec.CodecContext, pix_fmts: ^avutil.PixelFormat) -> avutil.PixelFormat {
    fmts := cast([^]avutil.PixelFormat)pix_fmts
    i := 0
    for {
        p := fmts[i]
        if p == .None { break }
        if p == .QSV { return .QSV }
        i += 1
    }
    return .None
}

// ---------------------------------------------------------------------------
// Write frame planes to AVIOContext
// ---------------------------------------------------------------------------

write_frame_to_avio :: proc(output_ctx: ^avfmt.IOContext, frame: ^avutil.Frame) {
    // NV12: plane 0 = Y (full height), plane 1 = UV (half height interleaved)
    max_planes := 2 // NV12 has 2 planes
    for p in 0 ..< max_planes {
        if frame.data[p] == nil { break }
        plane_height := frame.height
        if p > 0 { plane_height = frame.height / 2 }

        for row in 0 ..< int(plane_height) {
            row_ptr := ([^]u8)(uintptr(rawptr(frame.data[p])) + uintptr(row) * uintptr(frame.linesize[p]))
            avfmt.write(output_ctx, row_ptr, frame.width)
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 3 {
        fmt.eprintln("usage: qsv_decode <input> <output_raw>")
        os.exit(1)
    }

    // Open input
    input_cname := strings.clone_to_cstring(os.args[1])
    defer delete(input_cname)

    ifmt_ctx: ^avfmt.FormatContext
    ret := avfmt.open_input(&ifmt_ctx, input_cname, nil, nil)
    if ret < 0 { die("open input", ret) }
    defer avfmt.close_input(&ifmt_ctx)

    ret = avfmt.find_stream_info(ifmt_ctx, nil)
    if ret < 0 { die("find stream info", ret) }

    // Find H.264 video stream
    video_stream := -1
    for i in 0 ..< int(ifmt_ctx.nb_streams) {
        st := ifmt_ctx.streams[i]
        if st.codecpar.codec_type == .Video && st.codecpar.codec_id == .H264 {
            video_stream = i
            break
        }
    }
    if video_stream < 0 { die("no H.264 video stream found") }

    // Create QSV device
    device_ref: ^avutil.BufferRef
    ret = avutil.hwdevice_ctx_create(&device_ref, .Qsv, "auto", nil, 0)
    if ret < 0 { die("av_hwdevice_ctx_create (QSV)", ret) }
    defer avutil.buffer_unref(&device_ref)

    // Find h264_qsv decoder
    dec := avcodec.find_decoder_by_name("h264_qsv")
    if dec == nil { die("h264_qsv decoder not found") }

    // Allocate decoder context
    decoder_ctx := avcodec.alloc_context3(dec)
    if decoder_ctx == nil { die("alloc decoder ctx") }
    defer avcodec.free_context(&decoder_ctx)

    // Set codec_id and copy extradata from codecpar
    st := ifmt_ctx.streams[video_stream]
    decoder_ctx.codec_id = .H264

    if st.codecpar.extradata_size > 0 {
        extra_size := c.size_t(st.codecpar.extradata_size) + avcodec.AV_INPUT_BUFFER_PADDING_SIZE
        extra_buf := cast([^]u8)avutil.mallocz(extra_size)
        if extra_buf == nil { die("av_mallocz extradata") }
        mem.copy(extra_buf, st.codecpar.extradata, int(st.codecpar.extradata_size))
        decoder_ctx.extradata = extra_buf
        decoder_ctx.extradata_size = st.codecpar.extradata_size
    }

    decoder_ctx.hw_device_ctx = avutil.buffer_ref(device_ref)
    decoder_ctx.get_format = get_qsv_format
    decoder_ctx.width = st.codecpar.width
    decoder_ctx.height = st.codecpar.height

    // Open decoder (pass nil codec — decoder_ctx.codec_id drives selection)
    ret = avcodec.open2(decoder_ctx, dec, nil)
    if ret < 0 { die("avcodec_open2", ret) }

    // Open output via AVIOContext
    output_cname := strings.clone_to_cstring(os.args[2])
    defer delete(output_cname)

    output_ctx: ^avfmt.IOContext
    ret = avfmt.open(&output_ctx, output_cname, {.Write})
    if ret < 0 { die("avio_open output", ret) }
    defer avfmt.close(output_ctx)

    // Allocate packets and frames
    pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&pkt)
    frame := avutil.frame_alloc()
    defer avutil.frame_free(&frame)
    sw_frame := avutil.frame_alloc()
    defer avutil.frame_free(&sw_frame)

    drain_frames :: proc(
        decoder_ctx: ^avcodec.CodecContext,
        frame, sw_frame: ^avutil.Frame,
        output_ctx: ^avfmt.IOContext,
    ) {
        for {
            ret := avcodec.receive_frame(decoder_ctx, frame)
            if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { return }
            if ret < 0 { return }

            // Transfer QSV → SW
            ret = avutil.hwframe_transfer_data(sw_frame, frame, 0)
            if ret < 0 {
                avutil.frame_unref(frame)
                continue
            }

            sw_frame.width = frame.width
            sw_frame.height = frame.height

            write_frame_to_avio(output_ctx, sw_frame)

            avutil.frame_unref(frame)
            avutil.frame_unref(sw_frame)
        }
    }

    // Main demux/decode loop
    for {
        ret = avfmt.read_frame(ifmt_ctx, pkt)
        if ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        if int(pkt.stream_index) == video_stream {
            ret = avcodec.send_packet(decoder_ctx, pkt)
            avcodec.packet_unref(pkt)
            if ret < 0 { break }
            drain_frames(decoder_ctx, frame, sw_frame, output_ctx)
        } else {
            avcodec.packet_unref(pkt)
        }
    }

    // Flush decoder
    avcodec.send_packet(decoder_ctx, nil)
    drain_frames(decoder_ctx, frame, sw_frame, output_ctx)

    avfmt.avio_flush(output_ctx)
    fmt.printfln("qsv_decode: wrote raw output to '%s'", os.args[2])
}
