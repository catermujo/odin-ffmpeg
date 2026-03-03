// encode_audio — encode a 440 Hz sine wave to MP2 and write to a file.
//
// Port of FFmpeg encode_audio.c
//
// Build / run:
//   odin run vendor/ffmpeg/examples/encode_audio/ -- output.mp2
package main

import avcodec "../avcodec"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"


err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

// encode drives the encode + drain loop. Each call to avcodec_send_frame
// may produce zero or more packets; we drain them all before returning.
encode :: proc(ctx: ^avcodec.CodecContext, frame: ^avutil.Frame, pkt: ^avcodec.Packet, fd: ^os.File) {
    ret := avcodec.send_frame(ctx, frame)
    if ret < 0 {
        fmt.eprintln("error sending frame to encoder:", err_str(ret))
        os.exit(1)
    }

    for {
        ret = avcodec.receive_packet(ctx, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            return
        }
        if ret < 0 {
            fmt.eprintln("error receiving packet from encoder:", err_str(ret))
            os.exit(1)
        }

        // Write raw packet data directly to the output file.
        os.write(fd, pkt.data[:pkt.size])
        avcodec.packet_unref(pkt)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: encode_audio <output.mp2>")
        os.exit(1)
    }

    filename := os.args[1]

    // Find the MP2 encoder.
    codec := avcodec.find_encoder(.Mp2)
    if codec == nil {
        fmt.eprintln("codec MP2 not found")
        os.exit(1)
    }

    ctx := avcodec.alloc_context3(codec)
    if ctx == nil {
        fmt.eprintln("could not allocate codec context")
        os.exit(1)
    }
    defer avcodec.free_context(&ctx)

    // Use the first sample format the codec supports.
    // codec.sample_fmts is ^SampleFormat (pointer to first element of a
    // null-terminated array); treat it as [^]SampleFormat to index it.
    sample_fmts := cast([^]avutil.SampleFormat)codec.sample_fmts
    ctx.sample_fmt = sample_fmts[0]
    ctx.bit_rate = 64000
    ctx.sample_rate = 44100

    // Default stereo layout.
    avutil.channel_layout_default(&ctx.ch_layout, 2)

    // Open the codec.
    if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
        fmt.eprintln("could not open codec:", err_str(ret))
        os.exit(1)
    }

    pkt := avcodec.packet_alloc()
    if pkt == nil {
        fmt.eprintln("could not allocate packet")
        os.exit(1)
    }
    defer avcodec.packet_free(&pkt)

    // Allocate and prepare the input frame.
    frame := avutil.frame_alloc()
    if frame == nil {
        fmt.eprintln("could not allocate frame")
        os.exit(1)
    }
    defer avutil.frame_free(&frame)

    frame_size := ctx.frame_size
    frame.nb_samples = frame_size
    frame.format = c.int(ctx.sample_fmt)
    avutil.channel_layout_copy(&frame.ch_layout, &ctx.ch_layout)

    if ret := avutil.frame_get_buffer(frame, 0); ret < 0 {
        fmt.eprintln("could not allocate frame buffer:", err_str(ret))
        os.exit(1)
    }

    // Open output file.
    fd, err := os.open(filename, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default_File)
    if err != nil {
        fmt.eprintfln("could not open '%s'", filename)
        os.exit(1)
    }
    defer os.close(fd)

    // Encode 200 frames of a 440 Hz sine wave.
    // The wave is stored as interleaved int16 stereo (S16 packed).
    t := 2.0 * math.PI * 440.0 / f64(ctx.sample_rate)
    n_frames :: 200

    for i in 0 ..< n_frames {
        if ret := avutil.frame_make_writable(frame); ret < 0 {
            fmt.eprintln("frame not writable:", err_str(ret))
            os.exit(1)
        }

        samples16 := cast([^]c.int16_t)frame.data[0]
        for j in 0 ..< int(frame_size) {
            v := c.int16_t(math.sin(t * f64(i * int(frame_size) + j)) * 10000)
            samples16[2 * j] = v // left
            samples16[2 * j + 1] = v // right
        }

        frame.pts = c.int64_t(i) * c.int64_t(frame_size)
        encode(ctx, frame, pkt, fd)
    }

    // Flush the encoder.
    encode(ctx, nil, pkt, fd)

    fmt.println("encoded", n_frames, "frames to", filename)
}
