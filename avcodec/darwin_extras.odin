package avcodec

// Extra macOS system frameworks required when linking libavcodec statically.
// FFmpeg uses VideoToolbox and AudioToolbox for hardware-accelerated codecs
// and CoreFoundation/CoreMedia/CoreVideo for their data types.
when ODIN_OS == .Darwin {
    when #config(FFMPEG_LINK, "system") == "static" {
        @require foreign import _at    "system:AudioToolbox.framework"
        @require foreign import _vt    "system:VideoToolbox.framework"
        @require foreign import _cf    "system:CoreFoundation.framework"
        @require foreign import _cm    "system:CoreMedia.framework"
        @require foreign import _cv    "system:CoreVideo.framework"
        @require foreign import _bz2   "system:bz2"
        @require foreign import _z     "system:z"
    }
}
