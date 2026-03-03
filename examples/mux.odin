// mux — synthesize audio and video and write them to a container.
//
// Port of FFmpeg mux.c (simplified version).
//
// Creates a file with:
//   - Video: MPEG-1, 352x288, yuv420p, 25 fps, 400 kbps
//   - Audio: MP2, 44100 Hz, stereo, 64 kbps
//
// 25 video frames are produced together with enough audio to keep in sync.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/mux/ -- output.mpeg
package main

import avcodec "../avcodec"
import avfmt "../avformat"
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

// OutputStream bundles the encoder context and stream together.
OutputStream :: struct {
    st:       ^avfmt.Stream,
    enc:      ^avcodec.CodecContext,
    next_pts: c.int64_t,
    frame:    ^avutil.Frame,
}

// open_video_stream opens an MPEG-1 video encoder and adds a stream to oc.
open_video_stream :: proc(oc: ^avfmt.FormatContext, ost: ^OutputStream) {
    codec := avcodec.find_encoder(.Mpeg1Video)
    if codec == nil {
        fmt.eprintln("MPEG-1 video encoder not found")
        os.exit(1)
    }

    ost.st = avfmt.new_stream(oc, nil)
    if ost.st == nil {
        fmt.eprintln("could not allocate video stream")
        os.exit(1)
    }
    ost.st.id = c.int(oc.nb_streams) - 1

    ctx := avcodec.alloc_context3(codec)
    if ctx == nil {
        fmt.eprintln("could not allocate video codec context")
        os.exit(1)
    }
    ost.enc = ctx

    ctx.codec_id = .Mpeg1Video
    ctx.bit_rate = 400_000
    ctx.width = 352
    ctx.height = 288
    ctx.time_base = avutil.Rational{1, 25}
    ctx.framerate = avutil.Rational{25, 1}
    ctx.gop_size = 12
    ctx.max_b_frames = 2
    ctx.pix_fmt = .YUV420P

    // Some formats require the global header flag.
    if .Global_Header in oc.oformat.flags {
        ctx.flags += {.Global_Header}
    }

    if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
        fmt.eprintln("could not open video codec:", err_str(ret))
        os.exit(1)
    }

    // Allocate frame.
    frame := avutil.frame_alloc()
    if frame == nil {
        fmt.eprintln("could not allocate video frame")
        os.exit(1)
    }
    frame.format = c.int(avutil.PixelFormat.YUV420P)
    frame.width = ctx.width
    frame.height = ctx.height
    if ret := avutil.frame_get_buffer(frame, 0); ret < 0 {
        fmt.eprintln("could not allocate video frame buffer:", err_str(ret))
        os.exit(1)
    }
    ost.frame = frame

    // Copy parameters to the stream.
    if ret := avcodec.parameters_from_context(ost.st.codecpar, ctx); ret < 0 {
        fmt.eprintln("could not copy video codec parameters:", err_str(ret))
        os.exit(1)
    }
    ost.st.time_base = ctx.time_base
}

// open_audio_stream opens an MP2 audio encoder and adds a stream to oc.
open_audio_stream :: proc(oc: ^avfmt.FormatContext, ost: ^OutputStream) {
    codec := avcodec.find_encoder(.Mp2)
    if codec == nil {
        fmt.eprintln("MP2 audio encoder not found")
        os.exit(1)
    }

    ost.st = avfmt.new_stream(oc, nil)
    if ost.st == nil {
        fmt.eprintln("could not allocate audio stream")
        os.exit(1)
    }
    ost.st.id = c.int(oc.nb_streams) - 1

    ctx := avcodec.alloc_context3(codec)
    if ctx == nil {
        fmt.eprintln("could not allocate audio codec context")
        os.exit(1)
    }
    ost.enc = ctx

    audio_sample_fmts := cast([^]avutil.SampleFormat)codec.sample_fmts
    ctx.sample_fmt = audio_sample_fmts[0]
    ctx.bit_rate = 64_000
    ctx.sample_rate = 44100
    avutil.channel_layout_default(&ctx.ch_layout, 2)

    if .Global_Header in oc.oformat.flags {
        ctx.flags += {.Global_Header}
    }

    if ret := avcodec.open2(ctx, codec, nil); ret < 0 {
        fmt.eprintln("could not open audio codec:", err_str(ret))
        os.exit(1)
    }

    // Allocate frame.
    frame := avutil.frame_alloc()
    if frame == nil {
        fmt.eprintln("could not allocate audio frame")
        os.exit(1)
    }
    frame.nb_samples = ctx.frame_size
    frame.format = c.int(ctx.sample_fmt)
    avutil.channel_layout_copy(&frame.ch_layout, &ctx.ch_layout)
    if ret := avutil.frame_get_buffer(frame, 0); ret < 0 {
        fmt.eprintln("could not allocate audio frame buffer:", err_str(ret))
        os.exit(1)
    }
    ost.frame = frame

    if ret := avcodec.parameters_from_context(ost.st.codecpar, ctx); ret < 0 {
        fmt.eprintln("could not copy audio codec parameters:", err_str(ret))
        os.exit(1)
    }
    ost.st.time_base = avutil.Rational{1, ctx.sample_rate}
}

// fill_video_frame generates a synthetic YUV420P test pattern for frame index n.
fill_video_frame :: proc(frame: ^avutil.Frame, n: int) {
    w := int(frame.width)
    h := int(frame.height)

    // Y plane
    for y in 0 ..< h {
        for x in 0 ..< w {
            frame.data[0][y * int(frame.linesize[0]) + x] = u8(x + y + n * 3)
        }
    }
    // Cb and Cr planes (half resolution)
    for y in 0 ..< h / 2 {
        for x in 0 ..< w / 2 {
            frame.data[1][y * int(frame.linesize[1]) + x] = u8(128 + y + n * 2)
            frame.data[2][y * int(frame.linesize[2]) + x] = u8(64 + x + n * 5)
        }
    }
}

// encode_video_frame fills and encodes one video frame, writes all resulting
// packets to oc, then returns whether we should keep encoding.
encode_video_frame :: proc(
    oc: ^avfmt.FormatContext,
    ost: ^OutputStream,
    pkt: ^avcodec.Packet,
    n_frames: int,
) -> bool {
    if ost.next_pts >= c.int64_t(n_frames) {
        // Signal EOF by flushing the encoder.
        avcodec.send_frame(ost.enc, nil)
    } else {
        if ret := avutil.frame_make_writable(ost.frame); ret < 0 {
            fmt.eprintln("video frame not writable:", err_str(ret))
            os.exit(1)
        }
        fill_video_frame(ost.frame, int(ost.next_pts))
        ost.frame.pts = ost.next_pts
        ost.next_pts += 1

        if ret := avcodec.send_frame(ost.enc, ost.frame); ret < 0 {
            fmt.eprintln("error sending video frame:", err_str(ret))
            os.exit(1)
        }
    }

    // Drain all available packets.
    got_packet := false
    for {
        ret := avcodec.receive_packet(ost.enc, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            break
        }
        if ret < 0 {
            fmt.eprintln("error receiving video packet:", err_str(ret))
            os.exit(1)
        }
        got_packet = true

        // Rescale timestamps from codec timebase to stream timebase.
        avcodec.packet_rescale_ts(pkt, ost.enc.time_base, ost.st.time_base)
        pkt.stream_index = ost.st.index

        if ret2 := avfmt.interleaved_write_frame(oc, pkt); ret2 < 0 {
            fmt.eprintln("error writing video frame:", err_str(ret2))
            os.exit(1)
        }
        avcodec.packet_unref(pkt)
    }

    if ost.next_pts >= c.int64_t(n_frames) && !got_packet {
        return false
    }
    return true
}

// encode_audio_frame generates a 440 Hz sine and encodes one audio frame.
encode_audio_frame :: proc(
    oc: ^avfmt.FormatContext,
    ost: ^OutputStream,
    pkt: ^avcodec.Packet,
    t_ptr: ^f64,
    flush: bool,
) -> bool {
    if flush {
        avcodec.send_frame(ost.enc, nil)
    } else {
        if ret := avutil.frame_make_writable(ost.frame); ret < 0 {
            fmt.eprintln("audio frame not writable:", err_str(ret))
            os.exit(1)
        }

        freq := 2.0 * math.PI * 440.0 / f64(ost.enc.sample_rate)
        samples := cast([^]c.int16_t)ost.frame.data[0]
        fs := int(ost.enc.frame_size)
        for j in 0 ..< fs {
            v := c.int16_t(math.sin(t_ptr^ * f64(int(ost.next_pts) * fs + j)) * 10000)
            samples[2 * j] = v
            samples[2 * j + 1] = v
        }
        t_ptr^ = freq

        ost.frame.pts = ost.next_pts
        ost.next_pts += c.int64_t(ost.enc.frame_size)

        if ret := avcodec.send_frame(ost.enc, ost.frame); ret < 0 {
            fmt.eprintln("error sending audio frame:", err_str(ret))
            os.exit(1)
        }
    }

    got_packet := false
    for {
        ret := avcodec.receive_packet(ost.enc, pkt)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            break
        }
        if ret < 0 {
            fmt.eprintln("error receiving audio packet:", err_str(ret))
            os.exit(1)
        }
        got_packet = true

        avcodec.packet_rescale_ts(pkt, ost.enc.time_base, ost.st.time_base)
        pkt.stream_index = ost.st.index

        if ret2 := avfmt.interleaved_write_frame(oc, pkt); ret2 < 0 {
            fmt.eprintln("error writing audio packet:", err_str(ret2))
            os.exit(1)
        }
        avcodec.packet_unref(pkt)
    }

    if flush && !got_packet {
        return false
    }
    return true
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: mux <output_file>")
        os.exit(1)
    }

    filename := strings.clone_to_cstring(os.args[1])
    defer delete(filename)

    // Allocate the output format context.
    oc: ^avfmt.FormatContext
    if ret := avfmt.alloc_output_context2(&oc, nil, nil, filename); ret < 0 {
        fmt.eprintfln("could not deduce output format for '%s': %s", os.args[1], err_str(ret))
        os.exit(1)
    }
    if oc == nil {
        fmt.eprintln("could not allocate output context")
        os.exit(1)
    }
    defer avfmt.free_context(oc)

    // Open video and audio streams.
    video_ost := OutputStream{}
    audio_ost := OutputStream{}
    defer {
        if video_ost.enc != nil { avcodec.free_context(&video_ost.enc) }
        if audio_ost.enc != nil { avcodec.free_context(&audio_ost.enc) }
        if video_ost.frame != nil { avutil.frame_free(&video_ost.frame) }
        if audio_ost.frame != nil { avutil.frame_free(&audio_ost.frame) }
    }

    open_video_stream(oc, &video_ost)
    open_audio_stream(oc, &audio_ost)

    avfmt.dump_format(oc, 0, filename, 1)

    // Open the output file if needed.
    if .No_File not_in oc.oformat.flags {
        if ret := avfmt.open(&oc.pb, filename, {.Write}); ret < 0 {
            fmt.eprintfln("could not open '%s': %s", os.args[1], err_str(ret))
            os.exit(1)
        }
    }
    defer if .No_File not_in oc.oformat.flags { avfmt.closep(&oc.pb) }

    // Write the stream header.
    if ret := avfmt.write_header(oc, nil); ret < 0 {
        fmt.eprintln("error writing output header:", err_str(ret))
        os.exit(1)
    }

    pkt := avcodec.packet_alloc()
    if pkt == nil {
        fmt.eprintln("could not allocate packet")
        os.exit(1)
    }
    defer avcodec.packet_free(&pkt)

    n_video_frames :: 25
    audio_t := 0.0
    encode_video := true
    encode_audio := true

    // Interleave: always encode whichever stream has the smallest current DTS.
    for encode_video || encode_audio {
        // Compare current presentation times in seconds.
        video_pts := f64(video_ost.next_pts) * f64(video_ost.enc.time_base.num) / f64(video_ost.enc.time_base.den)
        audio_pts := f64(audio_ost.next_pts) / f64(audio_ost.enc.sample_rate)

        if encode_video && (!encode_audio || video_pts <= audio_pts) {
            if !encode_video_frame(oc, &video_ost, pkt, n_video_frames) {
                encode_video = false
            }
        } else {
            flush := !encode_video && encode_audio
            if !encode_audio_frame(oc, &audio_ost, pkt, &audio_t, flush) {
                encode_audio = false
            }
            // Stop audio when video is done and we've caught up.
            if !encode_video && audio_pts >= video_pts {
                encode_audio = false
            }
        }
    }

    // Write the trailer.
    if ret := avfmt.write_trailer(oc); ret < 0 {
        fmt.eprintln("error writing trailer:", err_str(ret))
        os.exit(1)
    }

    fmt.println("mux complete:", os.args[1])
}
