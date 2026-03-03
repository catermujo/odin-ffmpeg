// encode_video — encode synthetic YUV420P frames to a video stream.
//
// Generates 25 synthetic YUV frames and encodes them using MPEG-1 video
// (or a codec specified on the command line), writing the raw bitstream to
// the output file.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/encode_video/ -- output.mpeg1
//   odin run vendor/ffmpeg/examples/encode_video/ -- output.h264 libx264
package main

import avcodec "../avcodec"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"


err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

// encode sends one frame (or nil to flush) and writes all output packets.
encode :: proc(ctx: ^avcodec.CodecContext, frame: ^avutil.Frame, pkt: ^avcodec.Packet, out_file: ^os.File) -> bool {
    ret := avcodec.send_frame(ctx, frame)
    if ret < 0 {
        fmt.eprintln("avcodec_send_frame error:", err_str(ret))
        return false
    }

    for {
        ret = avcodec.receive_packet(ctx, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            break
        }
        if ret < 0 {
            fmt.eprintln("avcodec_receive_packet error:", err_str(ret))
            return false
        }
        os.write(out_file, ([^]u8)(pkt.data)[:pkt.size])
        avcodec.packet_unref(pkt)
    }
    return true
}

fill_yuv_image :: proc(frame: ^avutil.Frame, frame_idx: int) {
    w := int(frame.width)
    h := int(frame.height)
    i := frame_idx

    // Y plane
    ls0 := int(frame.linesize[0])
    y_plane := frame.data[0]
    for y in 0 ..< h {
        for x in 0 ..< w {
            y_plane[y * ls0 + x] = u8((x + y + i * 3) & 0xFF)
        }
    }

    // Cb plane (half width, half height for YUV420P)
    ls1 := int(frame.linesize[1])
    cb_plane := frame.data[1]
    for y in 0 ..< h / 2 {
        for x in 0 ..< w / 2 {
            cb_plane[y * ls1 + x] = u8((128 + y + i * 2) & 0xFF)
        }
    }

    // Cr plane
    ls2 := int(frame.linesize[2])
    cr_plane := frame.data[2]
    for y in 0 ..< h / 2 {
        for x in 0 ..< w / 2 {
            cr_plane[y * ls2 + x] = u8((64 + x + i * 5) & 0xFF)
        }
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: encode_video <output_file> [codec_name]")
        os.exit(1)
    }

    out_path := os.args[1]
    codec_name := "mpeg1video"
    if len(os.args) >= 3 {
        codec_name = os.args[2]
    }

    // Find encoder
    codec_name_cstr := strings.clone_to_cstring(codec_name)
    defer delete(codec_name_cstr)

    codec := avcodec.find_encoder_by_name(codec_name_cstr)
    if codec == nil {
        // Fall back to MPEG-1
        fmt.printf("codec '%s' not found, falling back to mpeg1video\n", codec_name)
        codec = avcodec.find_encoder(.Mpeg1Video)
    }
    if codec == nil {
        fmt.eprintln("no encoder found")
        os.exit(1)
    }
    fmt.println("using encoder:", avcodec.get_name(codec.id))

    // Allocate codec context and set encoding parameters
    ctx := avcodec.alloc_context3(codec)
    if ctx == nil {
        fmt.eprintln("avcodec_alloc_context3 failed")
        os.exit(1)
    }
    defer avcodec.free_context(&ctx)

    ctx.bit_rate = 400_000
    ctx.width = 352
    ctx.height = 288
    ctx.time_base = avutil.Rational {
        num = 1,
        den = 25,
    }
    ctx.framerate = avutil.Rational {
        num = 25,
        den = 1,
    }
    ctx.gop_size = 10
    ctx.max_b_frames = 1
    ctx.pix_fmt = .YUV420P

    if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
        fmt.eprintln("avcodec_open2 failed:", err_str(ret))
        os.exit(1)
    }

    // Open output file
    out_file, file_err := os.open(out_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default_File)
    if file_err != nil {
        fmt.eprintfln("cannot open '%s' for writing", out_path)
        os.exit(1)
    }
    defer os.close(out_file)

    // Allocate frame and packet
    frame := avutil.frame_alloc()
    if frame == nil {
        fmt.eprintln("av_frame_alloc failed")
        os.exit(1)
    }
    defer avutil.frame_free(&frame)

    frame.format = c.int(avutil.PixelFormat.YUV420P)
    frame.width = ctx.width
    frame.height = ctx.height

    if ret := avutil.frame_get_buffer(frame, 0); ret < 0 {
        fmt.eprintln("av_frame_get_buffer failed:", err_str(ret))
        os.exit(1)
    }

    pkt := avcodec.packet_alloc()
    if pkt == nil {
        fmt.eprintln("av_packet_alloc failed")
        os.exit(1)
    }
    defer avcodec.packet_free(&pkt)

    // Encode 25 synthetic frames
    for i in 0 ..< 25 {
        // Ensure the frame buffer is writable before modifying pixel data.
        if ret := avutil.frame_make_writable(frame); ret < 0 {
            fmt.eprintln("av_frame_make_writable failed:", err_str(ret))
            os.exit(1)
        }

        fill_yuv_image(frame, i)
        frame.pts = c.int64_t(i)

        if !encode(ctx, frame, pkt, out_file) {
            os.exit(1)
        }
    }

    // Flush encoder
    encode(ctx, nil, pkt, out_file)

    fmt.printf("encoded 25 frames to '%s'\n", out_path)
}
