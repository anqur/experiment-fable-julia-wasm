(module
  (type $sig (func (param i64) (result i64)))
  (import "host" "echo" (func $echo (param funcref) (result funcref)))
  (table 1 funcref)
  (func $inc (type $sig) (param i64) (result i64)
    local.get 0
    i64.const 1
    i64.add)
  (elem declare func $inc)
  (func (export "getf") (result funcref)
    ref.func $inc)
  (func (export "callf") (param funcref) (param i64) (result i64)
    i32.const 0
    local.get 0
    table.set 0
    local.get 1
    i32.const 0
    call_indirect (type $sig))
  ;; round-trip a funcref through the host and call it
  (func (export "via_host") (param i64) (result i64)
    i32.const 0
    ref.func $inc
    call $echo
    table.set 0
    local.get 0
    i32.const 0
    call_indirect (type $sig))
)
