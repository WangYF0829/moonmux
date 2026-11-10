///|
/// 根包的版本字符串必须与 moon.mod 同步更新（发布前容易漏改，
/// 0.3.0 发布包就因此仍报 0.2.0）。
test "describe reports the current version" {
  assert_eq(describe(), "moonmux " + MOONMUX_VERSION)
}
