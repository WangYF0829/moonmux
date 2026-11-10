// moonmux —— 模块配置
// 文档：https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "WangYF0829/moonmux"

version = "0.9.2"

readme = "README.md"

repository = "https://github.com/WangYF0829/moonmux"

license = "Apache-2.0"

keywords = [ "ogg", "container", "mux", "demux", "audio", "codec" ]

description = "Audio container toolkit in pure MoonBit: Ogg read/write and CRC verification, WAV full-format read/write, Opus-in-MP4 muxing and demuxing, transcoding pipeline, and a 15-command CLI"

preferred_target = "native"

import {
  "moonbitlang/x@0.5.5",
  "LL728/moonopus@0.2.2",
  "LL728/moonvorbis@0.1.4",
}
