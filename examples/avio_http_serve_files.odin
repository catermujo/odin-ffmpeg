// avio_http_serve_files — serve a local file over HTTP to multiple clients.
//
// Uses fork() to handle each connection in a child process.
// Note: POSIX-only (macOS / Linux). Not supported on Windows.
//
// Build / run:
//   odin run vendor/ffmpeg/examples/avio_http_serve_files/ -- /local/file.mp4 http://0.0.0.0:8080
package main

import avfmt "../avformat"
import avutil "../avutil"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// AV_OPT_SEARCH_CHILDREN from FFmpeg opt.h
AV_OPT_SEARCH_CHILDREN :: c.int(2)

process_client :: proc(client: ^avfmt.IOContext, in_uri: cstring) {
    resource: [^]u8 = nil
    defer {
        avfmt.avio_flush(client)
        avfmt.close(client)
        avutil.freep(&resource)
    }

    // Complete HTTP handshake: keep calling until it returns ≤ 0.
    handshake_ok := true
    for {
        ret := avfmt.handshake(client)
        if ret <= 0 {
            if ret < 0 { handshake_ok = false }
            break
        }
        // Peek at the requested resource path.
        avutil.opt_get(client, "resource", AV_OPT_SEARCH_CHILDREN, &resource)
        if resource != nil && resource[0] != 0 { break }
        avutil.freep(&resource)
    }
    if !handshake_ok { return }

    reply_code: c.int
    if resource != nil && resource[0] == '/' && cstring(&resource[1]) == in_uri {
        reply_code = 200
    } else {
        reply_code = avutil.AVERROR_HTTP_NOT_FOUND
    }
    avutil.opt_set_int(client, "reply_code", c.int64_t(reply_code), AV_OPT_SEARCH_CHILDREN)

    for avfmt.handshake(client) > 0 {  }

    if reply_code != 200 { return }

    // Open and stream the file.
    input: ^avfmt.IOContext = nil
    if avfmt.open2(&input, in_uri, {.Read}, nil, nil) < 0 {
        fmt.eprintfln("error: cannot open '%s'", in_uri)
        return
    }
    buf: [1024]u8
    for {
        n := avfmt.read(input, raw_data(buf[:]), len(buf))
        if n < 0 { break }
        avfmt.write(client, raw_data(buf[:]), n)
        avfmt.avio_flush(client)
    }
    avfmt.close(input)
}

main :: proc() {
    if len(os.args) < 3 {
        fmt.eprintln("usage: avio_http_serve_files <input_file> http://host[:port]")
        os.exit(1)
    }

    in_uri := strings.clone_to_cstring(os.args[1])
    out_uri := strings.clone_to_cstring(os.args[2])
    defer { delete(in_uri); delete(out_uri) }

    avutil.log_set_level(.Trace)
    avfmt.network_init()

    options: ^avutil.Dictionary = nil
    avutil.dict_set(&options, "listen", "2", {})

    server: ^avfmt.IOContext = nil
    if avfmt.open2(&server, out_uri, {.Write}, nil, &options) < 0 {
        fmt.eprintfln("error: cannot open server at '%s'", os.args[2])
        os.exit(1)
    }
    avutil.dict_free(&options)

    fmt.eprintln("Entering server loop. Ctrl-C to quit.")
    for {
        client: ^avfmt.IOContext = nil
        if avfmt.accept(server, &client) < 0 { break }

        pid := posix.fork()
        if int(pid) < 0 {
            fmt.eprintln("error: fork failed")
            break
        }
        if int(pid) == 0 {
            // Child process
            process_client(client, in_uri)
            avfmt.close(server)
            posix.exit(0)
        }
        // Parent: close client fd
        avfmt.close(client)
    }

    avfmt.close(server)
}
