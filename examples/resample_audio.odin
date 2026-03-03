// resample_audio — resample synthetic audio from 44100 Hz S16 stereo to
// 22050 Hz S16 stereo and write the raw samples to a file.
//
// Port of FFmpeg resample_audio.c
//
// Usage:
//   resample_audio <output_file>
// Example:
//   resample_audio out.raw
//   # Play with: ffplay -f s16le -ar 22050 -ac 2 out.raw
//
// Build / run:
//   odin run vendor/ffmpeg/examples/resample_audio/ -- out.raw
package main

import avutil "../avutil"
import swr "../swresample"
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

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: resample_audio <output_file>")
        os.exit(1)
    }

    output_path := os.args[1]

    // Describe input and output channel layouts.
    in_layout: avutil.ChannelLayout
    out_layout: avutil.ChannelLayout
    avutil.channel_layout_default(&in_layout, 2) // stereo
    avutil.channel_layout_default(&out_layout, 2) // stereo (same channels, half rate)

    in_sample_rate :: c.int(44100)
    out_sample_rate :: c.int(22050)
    in_sample_fmt :: avutil.SampleFormat.S16
    out_sample_fmt :: avutil.SampleFormat.S16

    // Allocate and configure the resampler.
    swr_ctx: ^swr.Context
    if ret := swr.alloc_set_opts2(
        &swr_ctx,
        &out_layout,
        out_sample_fmt,
        out_sample_rate,
        &in_layout,
        in_sample_fmt,
        in_sample_rate,
        0,
        nil,
    ); ret < 0 {
        fmt.eprintln("swr_alloc_set_opts2 failed:", err_str(ret))
        os.exit(1)
    }
    defer swr.free(&swr_ctx)

    if ret := swr.init(swr_ctx); ret < 0 {
        fmt.eprintln("swr_init failed:", err_str(ret))
        os.exit(1)
    }

    // Open the output file.
    out_fd, open_err := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default_File)
    if open_err != nil {
        fmt.eprintfln("could not open '%s' for writing", output_path)
        os.exit(1)
    }
    defer os.close(out_fd)

    // Process 100 chunks of 1024 input samples each.
    in_samples :: c.int(1024)
    n_chunks :: 100
    freq := 2.0 * math.PI * 440.0 / f64(in_sample_rate)

    // Allocate an aligned input buffer via av_samples_alloc.
    // For packed S16 stereo: 1 plane, nb_channels=2.
    in_data: [^]u8
    in_linesize: c.int
    if ret := avutil.samples_alloc(&in_data, &in_linesize, 2, in_samples, in_sample_fmt, 0); ret < 0 {
        fmt.eprintln("av_samples_alloc (input) failed:", err_str(ret))
        os.exit(1)
    }
    defer avutil.freep(&in_data)

    // Compute the maximum number of output samples we might ever need.
    // swr_get_out_samples gives a safe upper bound.
    max_out := swr.get_out_samples(swr_ctx, in_samples)

    out_data: [^]u8
    out_linesize: c.int
    if ret := avutil.samples_alloc(&out_data, &out_linesize, 2, max_out, out_sample_fmt, 0); ret < 0 {
        fmt.eprintln("av_samples_alloc (output) failed:", err_str(ret))
        os.exit(1)
    }
    defer avutil.freep(&out_data)

    total_in := 0
    total_out := 0

    for chunk in 0 ..< n_chunks {
        // Fill the input buffer with a 440 Hz sine wave (interleaved stereo S16).
        samples16 := cast([^]c.int16_t)in_data
        for j in 0 ..< int(in_samples) {
            v := c.int16_t(math.sin(freq * f64(total_in + j)) * 16000)
            samples16[2 * j] = v
            samples16[2 * j + 1] = v
        }
        total_in += int(in_samples)

        // swr_convert takes [^][^]u8 for both in and out.
        // For packed formats there is only 1 plane.
        in_planes: [1][^]u8 = {in_data}
        out_planes: [1][^]u8 = {out_data}

        n_out := swr.convert(swr_ctx, cast([^][^]u8)&out_planes[0], max_out, cast([^][^]u8)&in_planes[0], in_samples)
        if n_out < 0 {
            fmt.eprintln("swr_convert failed:", err_str(c.int(n_out)))
            os.exit(1)
        }

        if n_out > 0 {
            // Bytes per sample * channels * sample count.
            bytes_out := int(avutil.get_bytes_per_sample(out_sample_fmt)) * 2 * int(n_out)
            os.write(out_fd, out_data[:bytes_out])
            total_out += int(n_out)
        }

        _ = chunk
    }

    // Flush any samples buffered inside the resampler.
    in_planes: [1][^]u8 = {nil}
    out_planes: [1][^]u8 = {out_data}
    for {
        n_out := swr.convert(swr_ctx, cast([^][^]u8)&out_planes[0], max_out, cast([^][^]u8)&in_planes[0], 0)
        if n_out <= 0 { break }
        bytes_out := int(avutil.get_bytes_per_sample(out_sample_fmt)) * 2 * int(n_out)
        os.write(out_fd, out_data[:bytes_out])
        total_out += int(n_out)
    }

    fmt.printf("resampled %d -> %d samples (44100->22050 Hz stereo S16) -> %s\n", total_in, total_out, output_path)
}
