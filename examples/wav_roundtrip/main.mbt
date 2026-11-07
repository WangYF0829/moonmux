// wav_roundtrip —— 最小库用法示例：WAV 编码 → 解析
//
// 运行：moon run examples/wav_roundtrip
// 这一个例子只依赖 wav/ 包（零三方依赖），可直接复用为其他项目的起点。

///|
fn main {
  let format : @wav.WavFormat = {
    channels: 1,
    sample_rate: 8000,
    bits_per_sample: 16,
  }
  // 4 个 16 位 PCM 样本（8000 Hz 单声道）
  let pcm : Bytes = b"\x00\x00\x01\x00\x02\x00\x03\x00"
  let wav = @wav.encode_wav(format, pcm)
  match @wav.WavFile::parse(wav) {
    Some(f) =>
      println(
        "WAV roundtrip ok: " +
        f.format.channels.to_string() +
        " 声道 / " +
        f.format.sample_rate.to_string() +
        " Hz / " +
        f.format.bits_per_sample.to_string() +
        " 位 / " +
        f.data.length().to_string() +
        " 字节 PCM",
      )
    None => println("WAV roundtrip FAILED")
  }
}
