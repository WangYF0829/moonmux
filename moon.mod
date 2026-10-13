// moonmux —— 模块配置
// 文档：https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "moonmux"

version = "0.1.0"

readme = "README.md"

license = "Apache-2.0"

keywords = [
  "ogg",
  "container",
  "mux",
  "demux",
  "audio",
  "codec",
]

description = "Audio container toolkit in pure MoonBit: Ogg page/packet read and write, CRC-32 verification, WAV parsing, and a demux-to-WAV transcoding pipeline"

preferred_target = "native"

import {
  "moonbitlang/x@0.5.5",
}
