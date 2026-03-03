package avformat

// Extra macOS system framework required when linking libavformat statically.
// FFmpeg uses SecureTransport (Security.framework) for HTTPS/TLS support.
when ODIN_OS == .Darwin {
    when #config(FFMPEG_LINK, "system") == "static" {
        @require foreign import _sec "system:Security.framework"
        // avformat links against swresample and swscale internally
        @require foreign import _swr "../libswresample.darwin.a"
        @require foreign import _sws "../libswscale.darwin.a"
    }
}
