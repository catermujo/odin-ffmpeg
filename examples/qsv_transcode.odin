// qsv_transcode — Intel QSV-accelerated video transcode with dynamic option changes.
//
// Requires Intel GPU + QSV runtime (Linux only).
//
// Build / run:
//   odin run vendor/ffmpeg/examples/qsv_transcode/ -- input.mp4 h264_qsv output.mp4 "g 60"
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

AVERROR_ENOMEM :: -12

hw_device_ctx: ^avutil.BufferRef
ifmt_ctx: ^avfmt.FormatContext
ofmt_ctx: ^avfmt.FormatContext
decoder_ctx: ^avcodec.CodecContext
encoder_ctx: ^avcodec.CodecContext
video_stream: c.int = -1

DynamicSetting :: struct {
    frame_number: int,
    optstr:       string,
}

dynamic_settings: []DynamicSetting
cur_setting: int
frame_counter: int

get_format_qsv :: proc "c" (avctx: ^avcodec.CodecContext, pix_fmts: ^avutil.PixelFormat) -> avutil.PixelFormat {
    fmts := cast([^]avutil.PixelFormat)pix_fmts
    i := 0
    for {
        if fmts[i] == .None { break }
        if fmts[i] == .QSV { return .QSV }
        i += 1
    }
    return .None
}

open_input :: proc(filename: cstring) -> c.int {
    if ret := avfmt.open_input(&ifmt_ctx, filename, nil, nil); ret < 0 {
        fmt.eprintfln("error: cannot open input '%s'", filename)
        return ret
    }
    if ret := avfmt.find_stream_info(ifmt_ctx, nil); ret < 0 {
        fmt.eprintln("error: find_stream_info failed")
        return ret
    }
    ret := avfmt.find_best_stream(ifmt_ctx, .Video, -1, -1, nil, 0)
    if ret < 0 {
        fmt.eprintln("error: no video stream")
        return ret
    }
    video_stream = ret
    st := ifmt_ctx.streams[video_stream]

    decoder_name: cstring
    #partial switch st.codecpar.codec_id {
    case .H264:
        decoder_name = "h264_qsv"
    case .Hevc:
        decoder_name = "hevc_qsv"
    case .Vp9:
        decoder_name = "vp9_qsv"
    case .Vp8:
        decoder_name = "vp8_qsv"
    case .Av1:
        decoder_name = "av1_qsv"
    case .Mpeg2Video:
        decoder_name = "mpeg2_qsv"
    case .Mjpeg:
        decoder_name = "mjpeg_qsv"
    case:
        fmt.eprintln("error: codec not supported by QSV")
        return -1
    }

    decoder := avcodec.find_decoder_by_name(decoder_name)
    if decoder == nil {
        fmt.eprintfln("error: QSV decoder '%s' not found", decoder_name)
        return -1
    }

    decoder_ctx = avcodec.alloc_context3(decoder)
    if decoder_ctx == nil { return AVERROR_ENOMEM }

    if ret := avcodec.parameters_to_context(decoder_ctx, st.codecpar); ret < 0 { return ret }

    decoder_ctx.framerate = avfmt.guess_frame_rate(ifmt_ctx, st, nil)
    decoder_ctx.hw_device_ctx = avutil.buffer_ref(hw_device_ctx)
    decoder_ctx.get_format = get_format_qsv
    decoder_ctx.pkt_timebase = st.time_base

    if ret := avcodec.open2(decoder_ctx, decoder, nil); ret < 0 {
        fmt.eprintln("error: cannot open decoder")
        return ret
    }
    return 0
}

encode_write :: proc(enc_pkt: ^avcodec.Packet, frame: ^avutil.Frame) -> c.int {
    avcodec.packet_unref(enc_pkt)

    // Apply dynamic settings if due.
    frame_counter += 1
    if cur_setting < len(dynamic_settings) && frame_counter == dynamic_settings[cur_setting].frame_number {
        opts: ^avutil.Dictionary = nil
        str_to_dict(dynamic_settings[cur_setting].optstr, &opts)
        avutil.opt_set_dict(encoder_ctx, &opts)
        avutil.opt_set_dict(encoder_ctx.priv_data, &opts)
        avutil.dict_free(&opts)
        cur_setting += 1
    }

    if ret := avcodec.send_frame(encoder_ctx, frame); ret < 0 { return ret }

    for {
        ret := avcodec.receive_packet(encoder_ctx, enc_pkt)
        if ret != 0 {
            if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { return 0 }
            return ret
        }
        enc_pkt.stream_index = 0
        avcodec.packet_rescale_ts(enc_pkt, ifmt_ctx.streams[video_stream].time_base, ofmt_ctx.streams[0].time_base)
        avfmt.interleaved_write_frame(ofmt_ctx, enc_pkt)
    }
}

dec_enc :: proc(pkt: ^avcodec.Packet, enc_codec: ^avcodec.Codec, optstr: string) -> c.int {
    if ret := avcodec.send_packet(decoder_ctx, pkt); ret < 0 { return ret }

    for {
        frame := avutil.frame_alloc()
        if frame == nil { return AVERROR_ENOMEM }
        defer avutil.frame_free(&frame)

        ret := avcodec.receive_frame(decoder_ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { return 0 }
        if ret < 0 { return ret }

        if encoder_ctx.hw_frames_ctx == nil {
            encoder_ctx.hw_frames_ctx = avutil.buffer_ref(decoder_ctx.hw_frames_ctx)
            if encoder_ctx.hw_frames_ctx == nil { return AVERROR_ENOMEM }
            encoder_ctx.time_base = avutil.inv_q(decoder_ctx.framerate)
            encoder_ctx.pix_fmt = .QSV
            encoder_ctx.width = decoder_ctx.width
            encoder_ctx.height = decoder_ctx.height

            opts: ^avutil.Dictionary = nil
            str_to_dict(optstr, &opts)
            if ret2 := avcodec.open2(encoder_ctx, enc_codec, &opts); ret2 < 0 {
                avutil.dict_free(&opts)
                return ret2
            }
            avutil.dict_free(&opts)

            ost := avfmt.new_stream(ofmt_ctx, enc_codec)
            if ost == nil { return AVERROR_ENOMEM }
            ost.time_base = encoder_ctx.time_base
            avcodec.parameters_from_context(ost.codecpar, encoder_ctx)
            avfmt.write_header(ofmt_ctx, nil)
        }

        frame.pts = avutil.rescale_q(frame.pts, decoder_ctx.pkt_timebase, encoder_ctx.time_base)
        enc_pkt := avcodec.packet_alloc()
        defer avcodec.packet_free(&enc_pkt)
        encode_write(enc_pkt, frame)
    }
}

str_to_dict :: proc(optstr: string, opt: ^^avutil.Dictionary) {
    parts := strings.split(optstr, " ")
    defer delete(parts)
    i := 0
    for i + 1 < len(parts) {
        k := strings.clone_to_cstring(parts[i])
        v := strings.clone_to_cstring(parts[i + 1])
        avutil.dict_set(opt, k, v, {})
        delete(k); delete(v)
        i += 2
    }
}

main :: proc() {
    if len(os.args) < 5 || (len(os.args) - 5) % 2 != 0 {
        fmt.eprintln("usage: qsv_transcode <input> <encoder> <output> <\"opts\"> [frame_num \"opts\"]...")
        os.exit(1)
    }

    // Parse dynamic settings from remaining args.
    n_dynamic := (len(os.args) - 5) / 2
    dynamic_settings = make([]DynamicSetting, n_dynamic)
    defer delete(dynamic_settings)
    for i in 0 ..< n_dynamic {
        dynamic_settings[i].frame_number = strconv.parse_int(os.args[5 + i * 2], 10) or_else 0
        dynamic_settings[i].optstr = os.args[5 + i * 2 + 1]
    }

    in_path := strings.clone_to_cstring(os.args[1])
    out_path := strings.clone_to_cstring(os.args[3])
    defer { delete(in_path); delete(out_path) }

    if ret := avutil.hwdevice_ctx_create(&hw_device_ctx, .Qsv, nil, nil, 0); ret < 0 {
        fmt.eprintln("error: cannot create QSV device")
        os.exit(1)
    }
    defer avutil.buffer_unref(&hw_device_ctx)

    if open_input(in_path) < 0 { os.exit(1) }
    defer avfmt.close_input(&ifmt_ctx)
    defer avcodec.free_context(&decoder_ctx)

    enc_codec := avcodec.find_encoder_by_name(strings.clone_to_cstring(os.args[2]))
    if enc_codec == nil {
        fmt.eprintfln("error: encoder '%s' not found", os.args[2])
        os.exit(1)
    }

    avfmt.alloc_output_context2(&ofmt_ctx, nil, nil, out_path)
    if ofmt_ctx == nil {
        fmt.eprintln("error: cannot create output context")
        os.exit(1)
    }
    defer avfmt.free_context(ofmt_ctx)

    encoder_ctx = avcodec.alloc_context3(enc_codec)
    if encoder_ctx == nil { os.exit(1) }
    defer avcodec.free_context(&encoder_ctx)

    if avfmt.open(&ofmt_ctx.pb, out_path, {.Write}) < 0 {
        fmt.eprintln("error: cannot open output file")
        os.exit(1)
    }

    dec_pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&dec_pkt)

    for avfmt.read_frame(ifmt_ctx, dec_pkt) >= 0 {
        if int(dec_pkt.stream_index) == int(video_stream) {
            dec_enc(dec_pkt, enc_codec, os.args[4])
        }
        avcodec.packet_unref(dec_pkt)
    }

    // Flush
    dec_enc(dec_pkt, enc_codec, os.args[4])
    enc_pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&enc_pkt)
    encode_write(enc_pkt, nil)

    avfmt.write_trailer(ofmt_ctx)
}
