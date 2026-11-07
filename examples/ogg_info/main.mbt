// ogg_info —— 示例：用 ogg/ + codec/ 的公开 API 读取 Ogg 容器信息
//
// 运行（在仓库根目录）：moon run examples/ogg_info
// 展示「容器层可独立复用」：不经过 CLI、不依赖解码器。

///|
fn main {
  let path = "testdata/opus_sample.opus"
  let data = @fs.read_file_to_bytes(path) catch {
    IOError(msg) => {
      println("读取失败: " + path + " —— " + msg)
      return
    }
  }
  let pages = @ogg.parse_pages(data)
  if pages.length() == 0 {
    println("不是合法的 Ogg 文件")
    return
  }
  println("文件: " + path)
  println("字节: " + data.length().to_string())
  println("页数: " + pages.length().to_string())
  println("包数: " + @ogg.count_packets(pages).to_string())
  println("逻辑流: " + @ogg.serials_of(pages).length().to_string())
  // 每条流的首个包（标识头）→ 编码参数
  let firsts = @ogg.first_packets(pages)
  for serial in @ogg.serials_of(pages) {
    match firsts.get(serial) {
      Some(head) =>
        match @codec.parse_audio_header(head) {
          Some(info) =>
            println(
              "  serial=" +
              serial.to_string() +
              "  " +
              info.codec +
              "  " +
              info.channels.to_string() +
              " 声道 / " +
              info.sample_rate.to_string() +
              " Hz",
            )
          None =>
            println("  serial=" + serial.to_string() + "  （非音频流）")
        }
      None => ()
    }
  }
}
