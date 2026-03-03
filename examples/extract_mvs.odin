// extract_mvs — decode a video with AV_CODEC_FLAG2_EXPORT_MVS and print
// the motion vectors embedded in each frame's side data.
//
// Ports extract_mvs.c from the FFmpeg examples.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/extract_mvs/ -- <input_file>
package main

import avcodec "../avcodec"
import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"


// AV_FRAME_DATA_MOTION_VECTORS = 8 in FFmpeg source (frame.h)
MV_SIDE_DATA_TYPE :: avutil.FrameSideDataType(8) // Motion_Vectors

// AVMotionVector from FFmpeg motion_vector.h
MotionVector :: struct {
    source:       c.int32_t,
    w:            c.uint8_t,
    h:            c.uint8_t,
    src_x:        c.int16_t,
    src_y:        c.int16_t,
    dst_x:        c.int16_t,
    dst_y:        c.int16_t,
    flags:        c.uint64_t,
    motion_x:     c.int32_t,
    motion_y:     c.int32_t,
    motion_scale: c.uint16_t,
}

err_str :: proc(code: c.int) -> string {
    buf: [avutil.AV_ERROR_MAX_STRING_SIZE]c.char
    avutil.strerror(code, &buf[0], size_of(buf))
    return strings.clone_from_cstring(cstring(&buf[0]))
}

frame_count: int

print_motion_vectors :: proc(frame: ^avutil.Frame) {
    side_data_arr := ([^]^avutil.FrameSideData)(frame.side_data)
    for i in 0 ..< int(frame.nb_side_data) {
        sd := side_data_arr[i]
        if sd == nil { continue }
        if sd.type != MV_SIDE_DATA_TYPE { continue }

        nb_mvs := int(sd.size) / size_of(MotionVector)
        mvs := ([^]MotionVector)(sd.data)
        for j in 0 ..< nb_mvs {
            mv := mvs[j]
            fmt.printf(
                "frame=%d src=%2d width=%2d height=%2d src_x=%4d src_y=%4d dst_x=%4d dst_y=%4d\n",
                frame_count,
                mv.source,
                int(mv.w),
                int(mv.h),
                int(mv.src_x),
                int(mv.src_y),
                int(mv.dst_x),
                int(mv.dst_y),
            )
        }
    }
    frame_count += 1
}

decode_packets :: proc(codec_ctx: ^avcodec.CodecContext, pkt: ^avcodec.Packet, frame: ^avutil.Frame) {
    if ret := avcodec.send_packet(codec_ctx, pkt); ret < 0 {
        fmt.eprintln("avcodec_send_packet error:", err_str(ret))
        return
    }
    for {
        ret := avcodec.receive_frame(codec_ctx, frame)
        if ret == avutil.AVERROR_EAGAIN || ret == avutil.AVERROR_EOF {
            break
        }
        if ret < 0 {
            fmt.eprintln("avcodec_receive_frame error:", err_str(ret))
            break
        }
        print_motion_vectors(frame)
        avutil.frame_unref(frame)
    }
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: extract_mvs <input_file>")
        os.exit(1)
    }
    input_file := os.args[1]

    // Open input
    fmt_ctx: ^avfmt.FormatContext
    ret := avfmt.open_input(&fmt_ctx, strings.clone_to_cstring(input_file), nil, nil)
    if ret < 0 {
        fmt.eprintln("avformat_open_input failed:", err_str(ret))
        os.exit(1)
    }
    defer avfmt.close_input(&fmt_ctx)

    if ret = avfmt.find_stream_info(fmt_ctx, nil); ret < 0 {
        fmt.eprintln("avformat_find_stream_info failed:", err_str(ret))
        os.exit(1)
    }

    // Find best video stream
    decoder: ^avcodec.Codec
    video_stream_idx := avfmt.find_best_stream(fmt_ctx, .Video, -1, -1, &decoder, 0)
    if video_stream_idx < 0 {
        fmt.eprintln("no video stream found")
        os.exit(1)
    }
    if decoder == nil {
        fmt.eprintln("no decoder found for video stream")
        os.exit(1)
    }

    stream := fmt_ctx.streams[video_stream_idx]

    // Allocate and configure codec context
    codec_ctx := avcodec.alloc_context3(decoder)
    if codec_ctx == nil {
        fmt.eprintln("avcodec_alloc_context3 failed")
        os.exit(1)
    }
    defer avcodec.free_context(&codec_ctx)

    ret = avcodec.parameters_to_context(codec_ctx, stream.codecpar)
    if ret < 0 {
        fmt.eprintln("avcodec_parameters_to_context failed:", err_str(ret))
        os.exit(1)
    }
    codec_ctx.pkt_timebase = stream.time_base

    // Enable motion vector export
    codec_ctx.flags2 += {.Export_MVS}

    ret = avcodec.open2(codec_ctx, decoder, nil)
    if ret < 0 {
        fmt.eprintln("avcodec_open2 failed:", err_str(ret))
        os.exit(1)
    }

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

    // Demux / decode loop
    for avfmt.read_frame(fmt_ctx, pkt) >= 0 {
        if pkt.stream_index == video_stream_idx {
            decode_packets(codec_ctx, pkt, frame)
        }
        avcodec.packet_unref(pkt)
    }

    // Flush decoder
    decode_packets(codec_ctx, nil, frame)

    fmt.printf("processed %d frames\n", frame_count)
}
