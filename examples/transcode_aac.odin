// transcode_aac — transcode any audio input to AAC in an MP4/M4A container.
//
// Port of FFmpeg doc/examples/transcode_aac.c
//
// Uses AVAudioFifo as a sample buffer between the decoder and encoder so
// that frames fed to the AAC encoder always have the required frame_size.
//
// Usage:
//   odin run vendor/ffmpeg/examples/transcode_aac/ -- <input> <output.m4a>
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import swr "../swresample"
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
// Globals
// ---------------------------------------------------------------------------

ifmt_ctx: ^avfmt.FormatContext
ofmt_ctx: ^avfmt.FormatContext
dec_ctx: ^avcodec.CodecContext
enc_ctx: ^avcodec.CodecContext
swr_ctx: ^swr.Context
fifo: ^avutil.AudioFifo
audio_stream_idx: c.int
pts: c.int64_t

// ---------------------------------------------------------------------------
// Open input and set up decoder
// ---------------------------------------------------------------------------

open_input :: proc(filename: string) {
    cname := strings.clone_to_cstring(filename)
    defer delete(cname)

    ret := avfmt.open_input(&ifmt_ctx, cname, nil, nil)
    if ret < 0 { die("could not open input", ret) }

    ret = avfmt.find_stream_info(ifmt_ctx, nil)
    if ret < 0 { die("could not find stream info", ret) }

    dec: ^avcodec.Codec
    idx := avfmt.find_best_stream(ifmt_ctx, .Audio, -1, -1, &dec, 0)
    if idx < 0 { die("no audio stream found") }
    audio_stream_idx = idx

    dec_ctx = avcodec.alloc_context3(dec)
    if dec_ctx == nil { die("alloc dec ctx") }

    st := ifmt_ctx.streams[audio_stream_idx]
    ret = avcodec.parameters_to_context(dec_ctx, st.codecpar)
    if ret < 0 { die("parameters_to_context", ret) }

    ret = avcodec.open2(dec_ctx, dec, nil)
    if ret < 0 { die("open decoder", ret) }
}

// ---------------------------------------------------------------------------
// Open output and set up AAC encoder
// ---------------------------------------------------------------------------

open_output :: proc(filename: string) {
    cname := strings.clone_to_cstring(filename)
    defer delete(cname)

    ret := avfmt.alloc_output_context2(&ofmt_ctx, nil, nil, cname)
    if ret < 0 { die("alloc output ctx", ret) }

    enc := avcodec.find_encoder(.Aac)
    if enc == nil { die("AAC encoder not found") }

    out_stream := avfmt.new_stream(ofmt_ctx, nil)
    if out_stream == nil { die("new stream") }

    enc_ctx = avcodec.alloc_context3(enc)
    if enc_ctx == nil { die("alloc enc ctx") }

    enc_ctx.sample_fmt = .FltP
    enc_ctx.bit_rate = 128_000
    enc_ctx.sample_rate = dec_ctx.sample_rate
    avutil.channel_layout_copy(&enc_ctx.ch_layout, &dec_ctx.ch_layout)

    if .Global_Header in ofmt_ctx.oformat.flags {
        enc_ctx.flags += {.Global_Header}
    }

    ret = avcodec.open2(enc_ctx, enc, nil)
    if ret < 0 { die("open encoder", ret) }

    ret = avcodec.parameters_from_context(out_stream.codecpar, enc_ctx)
    if ret < 0 { die("parameters_from_context", ret) }

    out_stream.time_base = enc_ctx.time_base

    if .No_File not_in ofmt_ctx.oformat.flags {
        ret = avfmt.open(&ofmt_ctx.pb, cname, {.Write})
        if ret < 0 { die("avio_open", ret) }
    }

    ret = avfmt.write_header(ofmt_ctx, nil)
    if ret < 0 { die("write header", ret) }
}

// ---------------------------------------------------------------------------
// Resampler init
// ---------------------------------------------------------------------------

init_resampler :: proc() {
    out_layout := enc_ctx.ch_layout
    in_layout := dec_ctx.ch_layout
    ret := swr.alloc_set_opts2(
        &swr_ctx,
        &out_layout,
        enc_ctx.sample_fmt,
        enc_ctx.sample_rate,
        &in_layout,
        dec_ctx.sample_fmt,
        dec_ctx.sample_rate,
        0,
        nil,
    )
    if ret < 0 { die("swr_alloc_set_opts2", ret) }

    ret = swr.init(swr_ctx)
    if ret < 0 { die("swr_init", ret) }
}

// ---------------------------------------------------------------------------
// FIFO helpers
// ---------------------------------------------------------------------------

init_fifo :: proc() {
    fifo = avutil.audio_fifo_alloc(enc_ctx.sample_fmt, enc_ctx.ch_layout.nb_channels, 1)
    if fifo == nil { die("av_audio_fifo_alloc") }
}

add_samples_to_fifo :: proc(samples: ^[^]u8, nb_samples: c.int) {
    ret := avutil.audio_fifo_realloc(fifo, avutil.audio_fifo_size(fifo) + nb_samples)
    if ret < 0 { die("av_audio_fifo_realloc", ret) }

    written := avutil.audio_fifo_write(fifo, cast(rawptr)samples, nb_samples)
    if written < nb_samples {
        die("av_audio_fifo_write short write")
    }
}

// ---------------------------------------------------------------------------
// Decode one packet → resample → write to fifo
// Returns false on EOF
// ---------------------------------------------------------------------------

decode_audio_frame :: proc(frame: ^avutil.Frame, pkt: ^avcodec.Packet) -> (got_frame: bool) {
    ret := avcodec.send_packet(dec_ctx, pkt)
    if ret < 0 && ret != avutil.AVERROR_EOF { return false }

    for {
        ret = avcodec.receive_frame(dec_ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        // Resample into temporary buffer
        out_samples := swr.get_out_samples(swr_ctx, frame.nb_samples)
        if out_samples < 0 { break }

        converted: ^[^]u8
        linesize: c.int
        ret2 := avutil.samples_alloc_array_and_samples(
            &converted,
            &linesize,
            enc_ctx.ch_layout.nb_channels,
            out_samples,
            enc_ctx.sample_fmt,
            0,
        )
        if ret2 < 0 { break }

        n_converted := swr.convert(
            swr_ctx,
            cast([^][^]u8)converted,
            out_samples,
            cast([^][^]u8)frame.extended_data,
            frame.nb_samples,
        )
        if n_converted > 0 {
            add_samples_to_fifo(converted, n_converted)
        }
        avutil.freep(cast(rawptr)converted)

        got_frame = true
        avutil.frame_unref(frame)
    }
    return
}

// ---------------------------------------------------------------------------
// Encode one frame from fifo and write to output
// ---------------------------------------------------------------------------

encode_and_write :: proc(pkt: ^avcodec.Packet, flush: bool) {
    frame_size := enc_ctx.frame_size
    if !flush && avutil.audio_fifo_size(fifo) < frame_size { return }

    enc_frame: ^avutil.Frame
    if !flush {
        enc_frame = avutil.frame_alloc()
        if enc_frame == nil { die("av_frame_alloc") }

        enc_frame.nb_samples = frame_size
        enc_frame.format = c.int(enc_ctx.sample_fmt)
        enc_frame.sample_rate = enc_ctx.sample_rate
        avutil.channel_layout_copy(&enc_frame.ch_layout, &enc_ctx.ch_layout)

        if ret := avutil.frame_get_buffer(enc_frame, 0); ret < 0 {
            die("av_frame_get_buffer", ret)
        }

        n := avutil.audio_fifo_read(fifo, cast(rawptr)&enc_frame.data[0], frame_size)
        if n < frame_size { die("av_audio_fifo_read short") }

        enc_frame.pts = pts
        pts += c.int64_t(n)
    }

    ret := avcodec.send_frame(enc_ctx, enc_frame)
    if enc_frame != nil { avutil.frame_free(&enc_frame) }
    if ret < 0 && ret != avutil.AVERROR_EOF { return }

    out_stream := ofmt_ctx.streams[0]
    for {
        ret = avcodec.receive_packet(enc_ctx, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        avcodec.packet_rescale_ts(pkt, enc_ctx.time_base, out_stream.time_base)
        pkt.stream_index = 0

        ret = avfmt.interleaved_write_frame(ofmt_ctx, pkt)
        avcodec.packet_unref(pkt)
        if ret < 0 { break }
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 3 {
        fmt.eprintln("usage: transcode_aac <input> <output.m4a>")
        os.exit(1)
    }

    open_input(os.args[1])
    defer avfmt.close_input(&ifmt_ctx)
    defer avcodec.free_context(&dec_ctx)

    open_output(os.args[2])
    defer {
        avcodec.free_context(&enc_ctx)
        if .No_File not_in ofmt_ctx.oformat.flags {
            avfmt.closep(&ofmt_ctx.pb)
        }
        avfmt.free_context(ofmt_ctx)
    }

    init_resampler()
    defer swr.free(&swr_ctx)

    init_fifo()
    defer avutil.audio_fifo_free(fifo)

    pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&pkt)

    frame := avutil.frame_alloc()
    defer avutil.frame_free(&frame)

    enc_pkt := avcodec.packet_alloc()
    defer avcodec.packet_free(&enc_pkt)

    // Main demux/decode/resample/encode loop
    for {
        ret := avfmt.read_frame(ifmt_ctx, pkt)
        if ret == avutil.AVERROR_EOF { break }
        if ret < 0 { break }

        if pkt.stream_index == audio_stream_idx {
            decode_audio_frame(frame, pkt)
            // Drain fifo whenever we have enough samples
            for avutil.audio_fifo_size(fifo) >= enc_ctx.frame_size {
                encode_and_write(enc_pkt, false)
            }
        }
        avcodec.packet_unref(pkt)
    }

    // Flush decoder
    decode_audio_frame(frame, nil)

    // Drain any remaining fifo samples
    for avutil.audio_fifo_size(fifo) > 0 {
        encode_and_write(enc_pkt, false)
    }

    // Flush encoder
    encode_and_write(enc_pkt, true)

    avfmt.write_trailer(ofmt_ctx)
    fmt.printfln("transcoded '%s' -> '%s'", os.args[1], os.args[2])
}
