// manifest_public_test.mbt —— 黑盒测试：只用 manifest 包发布出来的公开 API。
//
// 与 *_wbtest.mbt 的白盒测试互补：这里不访问任何私有符号。

///|
test "public api: render then parse roundtrip" {
  let granules : Array[Int64] = [0L, 960L, 288312L]
  let text = @manifest.render(1647431420U, 3, granules)
  match @manifest.parse(text) {
    Err(msg) => abort("render 产物被 parse 拒绝: " + msg)
    Ok(m) => {
      match m.serial {
        Some(s) => assert_eq(s, 1647431420U)
        None => assert_true(false)
      }
      match m.chain {
        Some(c) => assert_eq(c, 3)
        None => assert_true(false)
      }
      // render 写出的 packets 就是粒度行数
      match m.packets {
        Some(p) => assert_eq(p, 3)
        None => assert_true(false)
      }
      assert_eq(m.granules.length(), 3)
      assert_eq(m.granules[2], 288312L)
      assert_eq(@manifest.granule_at(m.granules, 2), 288312L)
      assert_eq(@manifest.granule_at(m.granules, 3), 0L)
      assert_true(@manifest.starts_with(text, "# moonmux manifest v1"))
      assert_true(@manifest.ends_with(text, "288312\n"))
    }
  }
}

///|
test "public api: check_count validates rows and declared packet count" {
  let m = match
    @manifest.parse("# serial=1\n# packets=2\n# chain=1\n0\n100\n") {
    Err(msg) => abort("合法清单被拒绝: " + msg)
    Ok(m) => m
  }
  match @manifest.check_count(m, 2, "目录") {
    Ok(_) => assert_true(true)
    Err(msg) => abort("check_count 拒绝了匹配的清单: " + msg)
  }
  match @manifest.check_count(m, 3, "目录") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.length() > 0)
  }
  match @manifest.check_count(m, 1, "目录") {
    Ok(_) => assert_true(false)
    Err(msg) => assert_true(msg.length() > 0)
  }
}

///|
test "public api: malformed manifests are rejected" {
  assert_true(@manifest.parse("") is Err(_))
  assert_true(@manifest.parse("# moonmux manifest v1\n") is Err(_))
  assert_true(@manifest.parse("# packets=1\nabc\n") is Err(_))
  // 粒度 < -1、非单调都不合法
  assert_true(@manifest.parse("# packets=2\n-2\n0\n") is Err(_))
  assert_true(@manifest.parse("# packets=2\n100\n50\n") is Err(_))
  // 头部字段必须是纯整数；重复头部、未知头部必须拒绝
  assert_true(@manifest.parse("# serial=123 # v2\n0\n") is Err(_))
  assert_true(@manifest.parse("# packets=1\n# packets=2\n0\n") is Err(_))
  assert_true(@manifest.parse("# seriall=7\n0\n") is Err(_))
  // 32 位流号越界
  assert_true(@manifest.parse("# serial=4294967296\n0\n") is Err(_))
  // 边界值本身可用
  assert_true(@manifest.parse("# serial=4294967295\n0\n") is Ok(_))
  assert_true(@manifest.parse("# packets=2\n-1\n100\n") is Ok(_))
}
