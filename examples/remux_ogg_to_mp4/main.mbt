// remux_ogg_to_mp4 —— 示例：把 Ogg Opus 重新封装成 MP4（内存内，不写文件）
//
// 运行（在仓库根目录）：moon run examples/remux_ogg_to_mp4
// 展示「写—读对称」：remux 产出 MP4 字节，再用同包的 inspect 读回摘要。
// 写文件版本见 CLI：moonmux remux testdata/opus_sample.opus out.m4a

///|
fn main {
  let path = "testdata/opus_sample.opus"
  let data = @fs.read_file_to_bytes(path) catch {
    IOError(msg) => {
      println("读取失败: " + path + " —— " + msg)
      return
    }
  }
  match @mp4.remux_ogg_opus(data) {
    Err(msg) => println("remux 失败: " + msg)
    Ok(mp4) => {
      println(
        "输入: " + path + "（" + data.length().to_string() + " 字节）",
      )
      println("输出: MP4 " + mp4.length().to_string() + " 字节")
      match @mp4.inspect(mp4) {
        Some(info) => {
          println("主品牌: " + info.major_brand)
          println("时长: " + info.duration_seconds.to_string() + " 秒")
          for track in info.tracks {
            println(
              "  轨道: " +
              track.handler +
              " / " +
              track.codec +
              " / " +
              track.channels.to_string() +
              " 声道 / " +
              track.sample_rate.to_string() +
              " Hz / " +
              track.sample_count.to_string() +
              " 样本",
            )
          }
        }
        None => println("自检失败：inspect 无法解析产物")
      }
    }
  }
}
