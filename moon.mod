// moonmux —— 模块配置
// 文档：https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "WangYF0829/moonmux"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/WangYF0829/moonmux"

license = "Apache-2.0"

keywords = [ "ogg", "container", "mux", "demux", "audio", "codec" ]

description = "Audio container toolkit in pure MoonBit: Ogg page/packet read and write, CRC-32 verification, WAV parsing and encoding, and an Ogg-to-WAV transcoding pipeline"

preferred_target = "native"

import {
  "moonbitlang/x@0.5.5",
  "LL728/moonopus@0.2.2",
  "LL728/moonvorbis@0.1.4",
}
