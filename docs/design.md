<!--
作者：Claude Code
创建日期：2026-10-13
用途：moonmux 架构与设计说明
-->

# moonmux 设计说明

## 一、要解决的问题

MoonBit 生态在音频方向存在一个**单边断层**：

| 环节 | 生态现状 |
|---|---|
| 读容器（demux） | `isobmff`（MP4 解析）、`moontsinspect`（TS 检查） |
| 解码 | `moonopus`、`moonvorbis`、`mp3.mbt`、`moon-wav`、`moonwavkit` |
| 播放 | `moon_rodio`、`moon_cpal` |
| **写容器（mux）** | **没有** |
| **转码管线** | **没有** |

也就是说：音频数据能解码、能播放，但**存不回文件**。这条链的出口是堵死的。

moonmux 补的是出口 —— 容器写入与转码管线。

## 二、技术选型

**容器格式选 Ogg 而非 MP4。** 理由：

1. Ogg 的页结构简单（固定头 + 段表），一个页的解析器可以在数百行内写透；ISOBMFF 的 box 树、track 交织、moov/mdat 布局复杂度高一个量级。
2. 生态里已有 `moonopus` 与 `moonvorbis` 两个纯 MoonBit 的 Ogg 音频解码器 —— 补上封装层即可闭环，形成「解码 → 封装」的完整链路。
3. 相比 MP4，Ogg 方向的实现者更少，空白更彻底。

**不依赖任何三方包。** 容器格式的正确性必须能被独立验证，不该被解码器的实现缺陷掩盖。写字节用的 `Buffer` 来自 prelude，无需额外引入。

## 三、模块结构

```
moonmux/
├── ogg/         Ogg 容器层（核心）
│   ├── crc.mbt      CRC-32，RFC 3533 参数
│   ├── page.mbt     页结构：解析与序列化
│   ├── packet.mbt   段 → 包重组、包 → 段表切分
│   └── stream.mbt   字节流 ↔ 页序列
├── wav/         WAV 容器层
│   └── wav.mbt      RIFF/PCM 解析与编码
├── cli/         命令行解析（纯逻辑，无副作用）
│   └── cli.mbt      argv → Command 值
└── cmd/main/    命令行入口（仅做 I/O）
```

## 四、三个关键设计决策

### 1. CRC 用「两次构造」而非「先写占位再回填」

Ogg 的 CRC 计算范围是**除捕获模式外的整页字节**，且计算时 CRC 字段自身必须置零。直觉做法是先写一个占位的 0，算完再回填 —— 但 MoonBit 的 `Bytes` 是不可变的，没有索引赋值。

因此改为：把「写入页体」抽成一个接受 CRC 参数的函数，第一次传 0 用于计算校验值，第二次传真实值构造最终字节。代价是页体写两遍，收益是不需要任何可变字节缓冲，也不需要危险的回填操作。

### 2. `cli/` 与 `cmd/main/` 分离

参数解析最容易出「答非所问」的错误 —— 拼错的子命令被当作文件名、缺参数时报出无关提示、多余的参数被静默忽略。这类 bug 只有在真敲命令时才会暴露，因为解析逻辑通常长在不做测试的入口函数里。

把 argv → Command 的映射抽成无副作用的纯函数后，每条分支都能被断言钉住（见 `cli_wbtest.mbt` 的 7 个测试），入口层退化为纯粹的 I/O。

### 3. 截断的流宁可少给包，不给半截数据

`reassemble` 在遇到「段表以 255 结尾但后面没有更多的页」时，会丢弃这段不完整的数据而不产生包。容器解析的常见错误是把不完整数据当作合法结果交出去，让问题在下游以更难定位的形式爆发。

## 五、接口一览

```moonbit
// 页
pub fn Page::parse(data : Bytes, offset : Int) -> (Page, Int)?
pub fn Page::to_bytes(self : Page) -> Bytes
pub fn is_page_start(data : Bytes, offset : Int) -> Bool

// 包
pub fn reassemble(pages : Array[Page]) -> Array[Packet]
pub fn segments_for(len : Int) -> Array[Int]

// 流
pub fn parse_pages(data : Bytes) -> Array[Page]
pub fn serialize_pages(pages : Array[Page]) -> Bytes

// CRC
pub fn crc32(data : Bytes) -> UInt

// WAV
pub fn WavFile::parse(bytes : Bytes) -> WavFile?
pub fn encode_wav(format : WavFormat, data : Bytes) -> Bytes
```

## 六、测试策略

测试走 `wasm-gc` 后端，不依赖 C 编译器，便于在任意机器上复现。

覆盖的不变量：

- **CRC 参数正确性**：用权威校验值 `0x89A1897F` 钉死。该值经独立实现交叉验证，并通过 cksum 对照值 `0x765E7680` 反推确认。参数取错会导致生成的 Ogg 被所有解码器静默拒绝。
- **往返一致性**：页的序列化与解析互逆；重新序列化逐字节幂等。
- **边界条件**：长度恰为 255 的包的段表必须是 `[255, 0]`；空输入 CRC 为 0。
- **跨页包**：256 字节的包跨两页时能被重组成一个包，而不是两个碎片。
- **CLI 分支**：每条参数错误路径都有断言。

## 七、后续计划

| 阶段 | 内容 |
|---|---|
| 已完成 | Ogg 容器层、WAV 层、CLI 解析层，13 个测试通过 |
| 下一步 | `cmd/main/` 入口（native）、真实 Ogg 文件解析验证 |
| 再下一步 | 转码管线：Ogg（Opus/Vorbis）→ WAV，对接生态中已有的解码器 |
| 可选 | Ogg 封装（mux）：把包序列写成合法的 Ogg 文件 |

## 八、参考规范

- RFC 3533 — The Ogg Encapsulation Format Version 0
- RFC 3534 — The application/ogg Media Type
- RFC 7845 — Ogg Encapsulation for the Opus Audio Codec
- RFC 7845 Appendix — Ogg Opus 的 granule position 语义
- Microsoft RIFF / WAVE 格式说明
