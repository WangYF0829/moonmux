// cli_remux_wbtest.mbt —— remux 子命令的参数解析测试

///|
test "cli parse: remux takes input and output" {
  match parse(["remux", "in.ogg", "out.m4a"]) {
    Remux(src, out) => {
      assert_eq(src, "in.ogg")
      assert_eq(out, "out.m4a")
    }
    _ => assert_true(false)
  }
}

///|
test "cli parse: remux arity errors" {
  match parse(["remux"]) {
    Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["remux", "a.ogg"]) {
    Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
  match parse(["remux", "a.ogg", "b.m4a", "extra"]) {
    Bad(_, _) => assert_true(true)
    _ => assert_true(false)
  }
}

///|
test "cli usage mentions remux and m4a" {
  assert_true(usage().contains("remux"))
  assert_true(usage().contains("m4a"))
  assert_true(usage_for("remux").contains("MP4"))
}
