(module
  (type $pair (struct (field i64) (field i64)))
  (func (export "churn") (param $n i64) (result i64)
    (local $i i64)
    (local $acc i64)
    (block $done
      (loop $l
        (br_if $done (i64.ge_s (local.get $i) (local.get $n)))
        (local.set $acc
          (i64.add (local.get $acc)
            (struct.get $pair 0
              (struct.new $pair (local.get $i) (i64.const 1)))))
        (local.set $i (i64.add (local.get $i) (i64.const 1)))
        (br $l)))
    (local.get $acc)))
