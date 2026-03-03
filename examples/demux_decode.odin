// demux_decode — demux + decode audio and video streams.
//
// Opens any media file, finds all streams, and decodes them.
// Video: writes first decoded frame as a PGM (luma plane) to /tmp/demux_video.pgm
// Audio: writes raw PCM samples from channel 0 to /tmp/demux_audio.raw
//
// Build / run:
//   odin run vendor/ffmpeg/examples/demux_decode/ -- /path/to/file.mp4
package main

import avcodec "../avcodec"
import avfmt "../avformat"
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

StreamDecoder :: struct {
    ctx:   ^avcodec.CodecContext,
    codec: ^avcodec.Codec,
    type:  avutil.MediaType,
}

// write_pgm writes a PGM (luma plane) from a decoded video frame.
// Only the first `width` bytes of each row are used (ignoring linesize padding).
write_pgm :: proc(path: string, data: [^]u8, linesize, width, height: int) {
    header := fmt.tprintf("P5\n%d %d\n255\n", width, height)
    buf := make([]u8, len(header) + width * height)
    defer delete(buf)
    copy(buf, transmute([]u8)header)
    off := len(header)
    for row in 0 ..< height {
        copy(buf[off:], ([^]u8)(data[row * linesize:])[:width])
        off += width
    }
    if err := os.write_entire_file(path, buf); err == nil {
        fmt.println("wrote", path)
    } else {
        fmt.eprintln("failed to write", path)
    }
}

decode_and_output :: proc(
    dec: ^StreamDecoder,
    frame: ^avutil.Frame,
    video_idx: int,
    audio_idx: int,
    stream_idx: int,
    wrote_video: ^bool,
    audio_file: ^os.File,
) {
    for {
        ret := avcodec.receive_frame(dec.ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            break
        }
        if ret < 0 {
            fmt.eprintln("error receiving frame:", err_str(ret))
            break
        }

        if dec.type == .Video && !wrote_video^ {
            // Allocate a contiguous image buffer and copy the luma plane into it.
            pointers: [8][^]u8
            linesizes: [8]c.int
            pix_fmt := avutil.PixelFormat(frame.format)
            sz := avutil.image_alloc(
                cast([^][^]u8)&pointers[0],
                cast([^]c.int)&linesizes[0],
                frame.width,
                frame.height,
                pix_fmt,
                1,
            )
            if sz < 0 {
                fmt.eprintln("av_image_alloc failed:", err_str(sz))
                avutil.frame_unref(frame)
                continue
            }
            avutil.image_copy2(
                cast([^][^]u8)&pointers[0],
                cast([^]c.int)&linesizes[0],
                cast([^][^]u8)&frame.data[0],
                cast([^]c.int)&frame.linesize[0],
                pix_fmt,
                frame.width,
                frame.height,
            )
            // Write just the luma (Y) plane — plane 0.
            write_pgm("/tmp/demux_video.pgm", pointers[0], int(linesizes[0]), int(frame.width), int(frame.height))
            avutil.freep(&pointers[0])
            wrote_video^ = true

        } else if dec.type == .Audio && audio_file != nil {
            // Write raw samples from channel 0.
            data_size := avutil.get_bytes_per_sample(avutil.SampleFormat(frame.format))
            if data_size < 0 {
                avutil.frame_unref(frame)
                continue
            }
            ch0 := (cast([^]^u8)frame.extended_data)[0]
            nb := int(frame.nb_samples) * int(data_size)
            os.write(audio_file, (cast([^]u8)ch0)[:nb])
        }

        avutil.frame_unref(frame)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: demux_decode <file>")
        os.exit(1)
    }

    path := strings.clone_to_cstring(os.args[1])
    defer delete(path)

    // Open input
    fmt_ctx: ^avfmt.FormatContext
    if ret := avfmt.open_input(&fmt_ctx, path, nil, nil); ret < 0 {
        fmt.eprintfln("cannot open '%s': %s", os.args[1], err_str(ret))
        os.exit(1)
    }
    defer avfmt.close_input(&fmt_ctx)

    if ret := avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
        fmt.eprintln("could not read stream info:", err_str(ret))
        os.exit(1)
    }

    // Open a decoder for every stream
    decoders := make([]StreamDecoder, int(fmt_ctx.nb_streams))
    defer {
        for i in 0 ..< int(fmt_ctx.nb_streams) {
            if decoders[i].ctx != nil {
                avcodec.free_context(&decoders[i].ctx)
            }
        }
        delete(decoders)
    }

    video_idx := -1
    audio_idx := -1

    for i in 0 ..< int(fmt_ctx.nb_streams) {
        st := fmt_ctx.streams[i]
        par := st.codecpar

        media_type := par.codec_type
        if media_type != .Video && media_type != .Audio {
            continue
        }

        codec := avcodec.find_decoder(par.codec_id)
        if codec == nil {
            fmt.printf("stream %d: no decoder for %s, skipping\n", i, avcodec.get_name(par.codec_id))
            continue
        }

        ctx := avcodec.alloc_context3(codec)
        if ctx == nil {
            fmt.eprintln("avcodec_alloc_context3 failed for stream", i)
            continue
        }

        if ret := avcodec.parameters_to_context(ctx, par); ret < 0 {
            fmt.eprintln("avcodec_parameters_to_context failed:", err_str(ret))
            avcodec.free_context(&ctx)
            continue
        }

        if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
            fmt.eprintln("avcodec_open2 failed:", err_str(ret))
            avcodec.free_context(&ctx)
            continue
        }

        decoders[i] = StreamDecoder {
            ctx   = ctx,
            codec = codec,
            type  = media_type,
        }

        if media_type == .Video && video_idx < 0 {
            video_idx = i
            fmt.printf("stream %d: video  %s  %dx%d\n", i, avcodec.get_name(par.codec_id), par.width, par.height)
        } else if media_type == .Audio && audio_idx < 0 {
            audio_idx = i
            fmt.printf("stream %d: audio  %s\n", i, avcodec.get_name(par.codec_id))
        }
    }

    if video_idx < 0 && audio_idx < 0 {
        fmt.eprintln("no decodable video or audio streams found")
        os.exit(1)
    }

    // Open audio output file
    audio_file: ^os.File = nil
    if audio_idx >= 0 {
        handle, err := os.open(
            "/tmp/demux_audio.raw",
            os.O_WRONLY | os.O_CREATE | os.O_TRUNC,
            os.Permissions_Default_File,
        )
        if err == nil {
            audio_file = handle
        } else {
            fmt.eprintln("cannot open /tmp/demux_audio.raw")
        }
    }
    defer if audio_file != nil { os.close(audio_file) }

    frame := avutil.frame_alloc()
    pkt := avcodec.packet_alloc()
    defer {
        avutil.frame_free(&frame)
        avcodec.packet_free(&pkt)
    }

    wrote_video := false

    // Demux loop
    for avfmt.read_frame(fmt_ctx, pkt) >= 0 {
        si := int(pkt.stream_index)
        dec := &decoders[si]
        if dec.ctx == nil {
            avcodec.packet_unref(pkt)
            continue
        }

        if ret := avcodec.send_packet(dec.ctx, pkt); ret < 0 {
            fmt.eprintln("avcodec_send_packet error:", err_str(ret))
        } else {
            decode_and_output(dec, frame, video_idx, audio_idx, si, &wrote_video, audio_file)
        }
        avcodec.packet_unref(pkt)
    }

    // Flush decoders
    for i in 0 ..< int(fmt_ctx.nb_streams) {
        dec := &decoders[i]
        if dec.ctx == nil { continue }
        avcodec.send_packet(dec.ctx, nil)
        decode_and_output(dec, frame, video_idx, audio_idx, i, &wrote_video, audio_file)
    }

    fmt.println("done")
}
