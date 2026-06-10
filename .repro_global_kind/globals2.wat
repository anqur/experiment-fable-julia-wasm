(module
  (global $ga (export "g_any") (mut anyref) (ref.null any))
  (global $gv (export "g_v128") (mut v128) (v128.const i64x2 0 0))
  (global $gi (export "g_i64") (mut i64) (i64.const 7))
  (func (export "any_is_null") (result i32)
    (ref.is_null (global.get $ga)))
  (func (export "set_any_i31") (param i32)
    (global.set $ga (ref.i31 (local.get 0))))
)
