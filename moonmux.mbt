// moonmux.mbt —— 模块级信息

///|
/// 模块版本号：代码内唯一副本。
///
/// 与 `moon.mod` 的一致性由 `scripts/check_version.sh` 在 CI 里断言。
pub const MOONMUX_VERSION : String = "0.9.1"

///|
/// 模块名称与版本，供命令行工具的输出使用。
pub fn describe() -> String {
  "moonmux " + MOONMUX_VERSION
}
