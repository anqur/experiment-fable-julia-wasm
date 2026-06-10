#include <stdio.h>
#include <stddef.h>
#include <wasm.h>
#include <wasmtime.h>

int main(void) {
    printf("wasmtime_val_t size=%zu align=%zu kind_off=%zu of_off=%zu\n",
        sizeof(wasmtime_val_t), _Alignof(wasmtime_val_t),
        offsetof(wasmtime_val_t, kind), offsetof(wasmtime_val_t, of));
    printf("wasmtime_valunion_t size=%zu align=%zu\n",
        sizeof(wasmtime_valunion_t), _Alignof(wasmtime_valunion_t));
    printf("wasmtime_extern_t size=%zu kind_off=%zu of_off=%zu union_size=%zu\n",
        sizeof(wasmtime_extern_t), offsetof(wasmtime_extern_t, kind),
        offsetof(wasmtime_extern_t, of), sizeof(wasmtime_extern_union_t));
    printf("wasmtime_func_t size=%zu store_id_off=%zu priv_off=%zu\n",
        sizeof(wasmtime_func_t), offsetof(wasmtime_func_t, store_id),
        offsetof(wasmtime_func_t, __private));
    printf("wasmtime_instance_t size=%zu\n", sizeof(wasmtime_instance_t));
    printf("wasmtime_externref_t size=%zu p1_off=%zu p2_off=%zu p3_off=%zu\n",
        sizeof(wasmtime_externref_t), offsetof(wasmtime_externref_t, __private1),
        offsetof(wasmtime_externref_t, __private2), offsetof(wasmtime_externref_t, __private3));
    printf("wasmtime_anyref_t size=%zu\n", sizeof(wasmtime_anyref_t));
    printf("wasmtime_global_t size=%zu p1=%zu p2=%zu p3=%zu\n",
        sizeof(wasmtime_global_t), offsetof(wasmtime_global_t, __private1),
        offsetof(wasmtime_global_t, __private2), offsetof(wasmtime_global_t, __private3));
    printf("wasmtime_memory_t size=%zu p1=%zu p2=%zu\n",
        sizeof(wasmtime_memory_t), offsetof(wasmtime_memory_t, __private1),
        offsetof(wasmtime_memory_t, __private2));
    printf("wasmtime_table_t size=%zu p1=%zu p2=%zu\n",
        sizeof(wasmtime_table_t), offsetof(wasmtime_table_t, __private1),
        offsetof(wasmtime_table_t, __private2));
    printf("wasm_byte_vec_t size=%zu\n", sizeof(wasm_byte_vec_t));
    printf("wasm_valtype_vec_t size=%zu\n", sizeof(wasm_valtype_vec_t));
#ifdef WASMTIME_VERSION
    printf("wasmtime version: %s\n", WASMTIME_VERSION);
#endif
    return 0;
}
