// decode_video — decode a raw MPEG-1 bitstream using the bitstream parser.
//
// Reads a raw (containerless) MPEG-1 video file, feeds bytes through
// av_parser_parse2, decodes each extracted packet, and writes every decoded
// frame as a PGM (luma plane) to /tmp/frame_NNN.pgm.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/decode_video/ -- input.mpeg1
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

write_pgm :: proc(frame: ^avutil.Frame, idx: int) {
    path := fmt.tprintf("/tmp/frame_%03d.pgm", idx)
    width := int(frame.width)
    height := int(frame.height)
    ls := int(frame.linesize[0])
    data := frame.data[0]

    header := fmt.tprintf("P5\n%d %d\n255\n", width, height)
    buf := make([]u8, len(header) + width * height)
    defer delete(buf)

    copy(buf, transmute([]u8)header)
    off := len(header)
    for row in 0 ..< height {
        copy(buf[off:], ([^]u8)(data[row * ls:])[:width])
        off += width
    }
    if err := os.write_entire_file(path, buf); err == nil {
        fmt.println("wrote", path)
    } else {
        fmt.eprintln("failed to write", path)
    }
}

// decode_packets drains all frames from the codec context and writes PGMs.
decode_packets :: proc(ctx: ^avcodec.CodecContext, pkt: ^avcodec.Packet, frame: ^avutil.Frame, frame_count: ^int) {
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
        write_pgm(frame, frame_count^)
        frame_count^ += 1
        avutil.frame_unref(frame)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: decode_video <input.mpeg1>")
        os.exit(1)
    }

    // Find the MPEG-1 video decoder
    codec := avcodec.find_decoder(.Mpeg1Video)
    if codec == nil {
        fmt.eprintln("MPEG-1 video decoder not found")
        os.exit(1)
    }

    // Create a parser context
    parser := avcodec.parser_init(.Mpeg1Video)
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

    // Open the raw input file
    in_file, err := os.open(os.args[1])
    if err != nil {
        fmt.eprintfln("cannot open '%s'", os.args[1])
        os.exit(1)
    }
    defer os.close(in_file)

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

    // Input buffer with padding for the bitstream parser
    inbuf: [INBUF_SIZE + avcodec.AV_INPUT_BUFFER_PADDING_SIZE]u8

    frame_count := 0
    NOPTS := c.int64_t(avutil.AV_NOPTS_VALUE)

    for {
        n_read, read_err := os.read(in_file, inbuf[:INBUF_SIZE])
        if n_read == 0 { break }

        data := raw_data(inbuf[:])
        data_sz := c.int(n_read)

        for data_sz > 0 {
            // Parse the next packet from the raw bytestream
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
                decode_packets(ctx, pkt, frame, &frame_count)
            }
        }

        if read_err != nil { break }
    }

    // Flush the decoder
    decode_packets(ctx, nil, frame, &frame_count)

    fmt.printf("decoded %d frame(s)\n", frame_count)
}
