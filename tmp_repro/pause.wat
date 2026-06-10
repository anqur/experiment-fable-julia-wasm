(module
  (import "host" "pause" (func $pause (param i64)))
  (type $pair (struct (field i64) (field i64)))
  (func (export "go") (param $id i64) (param $n i64) (result i64)
    (local $i i64)
    (local $acc i64)
    (call $pause (local.get $id))
    (block $done
      (loop $l
        (br_if $done (i64.ge_s (local.get $i) (local.get $n)))
        (local.set $acc
          (i64.add (local.get $acc)
            (struct.get $pair 0
              (struct.new $pair (local.get $i) (i64.const 1)))))
        (local.set $i (i64.add (local.get $i) (i64.const 1)))
        (br $l)))
    (local.get $acc))
  (func (export "trapme") (param i64) (result i64)
    (i64.div_s (local.get 0) (i64.const 0))))
