#!/usr/bin/env python3

import ctypes
import json
import os
import sys
from pathlib import Path


def inventory(dll_path: Path) -> dict:
    # Enumerate codec metadata without a hardware context or an initialized encoder.
    with os.add_dll_directory(str(dll_path.parent)):
        codec = ctypes.CDLL(str(dll_path))

        class Codec(ctypes.Structure):
            _fields_ = [("name", ctypes.c_char_p)]

        codec.avcodec_configuration.restype = ctypes.c_char_p
        codec.av_codec_iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        codec.av_codec_iterate.restype = ctypes.POINTER(Codec)
        codec.av_codec_is_encoder.argtypes = [ctypes.c_void_p]
        codec.av_codec_is_decoder.argtypes = [ctypes.c_void_p]
        opaque = ctypes.c_void_p()
        encoders, decoders = [], []
        while item := codec.av_codec_iterate(ctypes.byref(opaque)):
            name = item.contents.name.decode()
            if codec.av_codec_is_encoder(item):
                encoders.append(name)
            if codec.av_codec_is_decoder(item):
                decoders.append(name)
        return dict(
            configuration=codec.avcodec_configuration().decode(),
            encoders=sorted(encoders),
            decoders=sorted(decoders),
        )


if __name__ == "__main__":
    print(json.dumps(inventory(Path(sys.argv[1]).resolve())))
