// decode_audio — decode a raw MP2 audio bitstream using the bitstream parser.
//
// Reads a raw (containerless) MP2 audio file, feeds bytes through
// av_parser_parse2, decodes each extracted packet, and writes raw PCM samples
// (interleaved across channels) to /tmp/decode_audio.raw.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/decode_audio/ -- input.mp2
package main

import avcodec "../avcodec"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

INBUF_SIZE :: 4096

err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

// decode_packets drains all frames from the context, writing PCM to out_file.
decode_packets :: proc(ctx: ^avcodec.CodecContext, pkt: ^avcodec.Packet, frame: ^avutil.Frame, out_file: ^os.File) {
    if ret := avcodec.send_packet(ctx, pkt); ret < 0 {
        fmt.eprintln("avcodec_send_packet error:", err_str(ret))
        return
    }
    for {
        ret := avcodec.receive_frame(ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            break
        }
        if ret < 0 {
            fmt.eprintln("avcodec_receive_frame error:", err_str(ret))
            break
        }

        data_size := avutil.get_bytes_per_sample(avutil.SampleFormat(frame.format))
        if data_size <= 0 {
            avutil.frame_unref(frame)
            continue
        }

        // Write samples interleaved: for each sample position, emit all channels.
        nb_samples := int(frame.nb_samples)
        nb_channels := int(ctx.ch_layout.nb_channels)
        ds := int(data_size)

        for i in 0 ..< nb_samples {
            for ch in 0 ..< nb_channels {
                ch_data := (cast([^]^u8)frame.extended_data)[ch]
                os.write(out_file, (cast([^]u8)ch_data)[i * ds:(i + 1) * ds])
            }
        }

        avutil.frame_unref(frame)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: decode_audio <input.mp2>")
        os.exit(1)
    }

    // Find MP2 decoder
    codec := avcodec.find_decoder(.Mp2)
    if codec == nil {
        fmt.eprintln("MP2 decoder not found")
        os.exit(1)
    }

    // Create parser
    parser := avcodec.parser_init(.Mp2)
    if parser == nil {
        fmt.eprintln("av_parser_init failed")
        os.exit(1)
    }
    defer avcodec.parser_close(parser)

    // Allocate and open codec context
    ctx := avcodec.alloc_context3(codec)
    if ctx == nil {
        fmt.eprintln("avcodec_alloc_context3 failed")
        os.exit(1)
    }
    defer avcodec.free_context(&ctx)

    if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
        fmt.eprintln("avcodec_open2 failed:", err_str(ret))
        os.exit(1)
    }

    // Open input
    in_file, in_err := os.open(os.args[1])
    if in_err != nil {
        fmt.eprintfln("cannot open '%s'", os.args[1])
        os.exit(1)
    }
    defer os.close(in_file)

    // Open output
    out_file, out_err := os.open(
        "/tmp/decode_audio.raw",
        os.O_WRONLY | os.O_CREATE | os.O_TRUNC,
        os.Permissions_Default_File,
    )
    if out_err != nil {
        fmt.eprintln("cannot open /tmp/decode_audio.raw")
        os.exit(1)
    }
    defer os.close(out_file)

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

    // Input buffer with padding for the parser
    inbuf: [INBUF_SIZE + avcodec.AV_INPUT_BUFFER_PADDING_SIZE]u8

    NOPTS := c.int64_t(avutil.AV_NOPTS_VALUE)

    for {
        n_read, read_err := os.read(in_file, inbuf[:INBUF_SIZE])
        if n_read == 0 { break }

        data := raw_data(inbuf[:])
        data_sz := c.int(n_read)

        for data_sz > 0 {
            out_buf: ^u8
            out_buf_size: c.int
            used := avcodec.parser_parse2(parser, ctx, &out_buf, &out_buf_size, data, data_sz, NOPTS, NOPTS, NOPTS)
            if used < 0 {
                fmt.eprintln("av_parser_parse2 error")
                break
            }
            data = ([^]u8)(data)[used:]
            data_sz -= used

            if out_buf_size > 0 {
                pkt.data = out_buf
                pkt.size = out_buf_size
                decode_packets(ctx, pkt, frame, out_file)
            }
        }

        if read_err != nil { break }
    }

    // Flush decoder
    decode_packets(ctx, nil, frame, out_file)

    fmt.println("done — samples written to /tmp/decode_audio.raw")
}
