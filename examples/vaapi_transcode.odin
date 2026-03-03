// vaapi_transcode — VAAPI decode + encode video transcode (Linux only).
//
// Port of FFmpeg doc/examples/vaapi_transcode.c
//
// Decodes the first video stream of the input using a VAAPI decoder,
// then re-encodes it with the user-specified VAAPI encoder (e.g. "h264_vaapi",
// "hevc_vaapi") and writes the output to the container inferred from the
// output filename.
//
// Usage:
//   odin run vendor/ffmpeg/examples/vaapi_transcode/ -- <input> <codec_name> <output>
//
// Example:
//   ./vaapi_transcode input.mp4 h264_vaapi output.mp4
//
// Note: Linux only. Requires a VAAPI-capable GPU and driver.
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
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
// get_vaapi_format callback: return VAAPI pixel format
// ---------------------------------------------------------------------------

get_vaapi_format :: proc "c" (ctx: ^avcodec.CodecContext, pix_fmts: ^avutil.PixelFormat) -> avutil.PixelFormat {
    fmts := cast([^]avutil.PixelFormat)pix_fmts
    i := 0
    for {
        p := fmts[i]
        if p == .None { break }
        if p == .VAAPI { return .VAAPI }
        i += 1
    }
    return .None
}

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

hw_device_ctx: ^avutil.BufferRef
ifmt_ctx: ^avfmt.FormatContext
ofmt_ctx: ^avfmt.FormatContext
decoder_ctx: ^avcodec.CodecContext
encoder_ctx: ^avcodec.CodecContext
video_stream: int = -1
encoder_inited: bool

// ---------------------------------------------------------------------------
// Initialise encoder from first decoded frame's HW frames context
// ---------------------------------------------------------------------------

init_encoder :: proc(enc_codec: ^avcodec.Codec, frame: ^avutil.Frame) {
    encoder_ctx.hw_frames_ctx = avutil.buffer_ref(decoder_ctx.hw_frames_ctx)
    encoder_ctx.pix_fmt = .VAAPI
    encoder_ctx.time_base = avutil.inv_q(decoder_ctx.framerate)
    encoder_ctx.width = decoder_ctx.width
    encoder_ctx.height = decoder_ctx.height
    encoder_ctx.framerate = decoder_ctx.framerate

    if .Global_Header in ofmt_ctx.oformat.flags {
        encoder_ctx.flags += {.Global_Header}
    }

    ret := avcodec.open2(encoder_ctx, enc_codec, nil)
    if ret < 0 { die("open encoder", ret) }

    out_st := avfmt.new_stream(ofmt_ctx, nil)
    if out_st == nil { die("new stream") }

    ret = avcodec.parameters_from_context(out_st.codecpar, encoder_ctx)
    if ret < 0 { die("parameters_from_context", ret) }

    out_st.time_base = encoder_ctx.time_base

    output_cname := strings.clone_to_cstring(os.args[3])
    defer delete(output_cname)

    if .No_File not_in ofmt_ctx.oformat.flags {
        ret = avfmt.open(&ofmt_ctx.pb, output_cname, {.Write})
        if ret < 0 { die("avio_open", ret) }
    }

    ret = avfmt.write_header(ofmt_ctx, nil)
    if ret < 0 { die("write header", ret) }

    encoder_inited = true
}

// ---------------------------------------------------------------------------
// Encode frame and write to output
// ---------------------------------------------------------------------------

encode_write :: proc(enc_codec: ^avcodec.Codec, frame: ^avutil.Frame, pkt: ^avcodec.Packet) {
    if !encoder_inited && frame != nil {
        init_encoder(enc_codec, frame)
    }
    if !encoder_inited { return }

    out_st := ofmt_ctx.streams[0]

    ret := avcodec.send_frame(encoder_ctx, frame)
    if ret < 0 && ret != avutil.AVERROR_EOF { return }

    for {
        ret = avcodec.receive_packet(encoder_ctx, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        avcodec.packet_rescale_ts(pkt, encoder_ctx.time_base, out_st.time_base)
        pkt.stream_index = 0

        avfmt.interleaved_write_frame(ofmt_ctx, pkt)
        avcodec.packet_unref(pkt)
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 4 {
        fmt.eprintln("usage: vaapi_transcode <input> <codec_name> <output>")
        os.exit(1)
    }

    // Create VAAPI device
    ret := avutil.hwdevice_ctx_create(&hw_device_ctx, .Vaapi, nil, nil, 0)
    if ret < 0 { die("av_hwdevice_ctx_create", ret) }
    defer avutil.buffer_unref(&hw_device_ctx)

    // Open input
    input_cname := strings.clone_to_cstring(os.args[1])
    defer delete(input_cname)

    ret = avfmt.open_input(&ifmt_ctx, input_cname, nil, nil)
    if ret < 0 { die("open input", ret) }
    defer avfmt.close_input(&ifmt_ctx)

    ret = avfmt.find_stream_info(ifmt_ctx, nil)
    if ret < 0 { die("find stream info", ret) }

    // Find best video stream and decoder
    dec: ^avcodec.Codec
    video_stream = int(avfmt.find_best_stream(ifmt_ctx, .Video, -1, -1, &dec, 0))
    if video_stream < 0 { die("no video stream") }

    // Set up decoder context with VAAPI
    decoder_ctx = avcodec.alloc_context3(dec)
    if decoder_ctx == nil { die("alloc decoder ctx") }
    defer avcodec.free_context(&decoder_ctx)

    st := ifmt_ctx.streams[video_stream]
    ret = avcodec.parameters_to_context(decoder_ctx, st.codecpar)
    if ret < 0 { die("parameters_to_context", ret) }

    decoder_ctx.hw_device_ctx = avutil.buffer_ref(hw_device_ctx)
    decoder_ctx.get_format = get_vaapi_format
    decoder_ctx.framerate = avfmt.guess_frame_rate(ifmt_ctx, st, nil)

    ret = avcodec.open2(decoder_ctx, dec, nil)
    if ret < 0 { die("open decoder", ret) }

    // Find encoder
    enc_cname := strings.clone_to_cstring(os.args[2])
    defer delete(enc_cname)

    enc_codec := avcodec.find_encoder_by_name(enc_cname)
    if enc_codec == nil { die("encoder not found") }

    // Allocate output context
    output_cname := strings.clone_to_cstring(os.args[3])
    defer delete(output_cname)

    ret = avfmt.alloc_output_context2(&ofmt_ctx, nil, nil, output_cname)
    if ret < 0 { die("alloc output ctx", ret) }
    defer {
        if encoder_inited {
            if .No_File not_in ofmt_ctx.oformat.flags {
                avfmt.closep(&ofmt_ctx.pb)
            }
        }
        avfmt.free_context(ofmt_ctx)
    }

    // Allocate encoder context (opened later, on first frame)
    encoder_ctx = avcodec.alloc_context3(enc_codec)
    if encoder_ctx == nil { die("alloc encoder ctx") }
    defer avcodec.free_context(&encoder_ctx)

    // Allocate packet and frames
    pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&pkt)
    frame := avutil.frame_alloc()
    defer avutil.frame_free(&frame)

    // Main decode → encode loop
    for {
        ret = avfmt.read_frame(ifmt_ctx, pkt)
        if ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        if int(pkt.stream_index) != video_stream {
            avcodec.packet_unref(pkt)
            continue
        }

        ret = avcodec.send_packet(decoder_ctx, pkt)
        avcodec.packet_unref(pkt)
        if ret < 0 { break }

        for {
            ret = avcodec.receive_frame(decoder_ctx, frame)
            if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
            if ret < 0 { break }

            encode_write(enc_codec, frame, pkt)
            avutil.frame_unref(frame)
        }
    }

    // Flush decoder
    avcodec.send_packet(decoder_ctx, nil)
    for {
        ret = avcodec.receive_frame(decoder_ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }
        encode_write(enc_codec, frame, pkt)
        avutil.frame_unref(frame)
    }

    // Flush encoder
    encode_write(enc_codec, nil, pkt)

    if encoder_inited {
        avfmt.write_trailer(ofmt_ctx)
    }

    fmt.printfln("vaapi_transcode '%s' -> '%s' done", os.args[1], os.args[3])
}
