#!/bin/bash
# Phase 4: smith-based differential fuzz. Generates N random modules using
# supported proposals, then a Julia loop decodes/re-encodes/validates each.
set -u
WT=/workspace/tools/wasm-tools-dist/wasm-tools
DIR=/tmp/smith
mkdir -p $DIR
rm -f $DIR/*.wasm
N=${1:-300}
for i in $(seq 1 $N); do
  head -c 4096 /dev/urandom | $WT smith \
    --gc-enabled true --exceptions-enabled true --tail-call-enabled true \
    --reference-types-enabled true --memory64-enabled true \
    --multi-value-enabled true --extended-const-enabled true \
    --max-memories 3 --max-tables 4 \
    --simd-enabled false --relaxed-simd-enabled false --threads-enabled false \
    --shared-everything-threads-enabled false --custom-descriptors-enabled false \
    --custom-page-sizes-enabled false --wide-arithmetic-enabled false \
    --generate-custom-sections true \
    -o $DIR/$i.wasm 2>/dev/null || rm -f $DIR/$i.wasm
done
ls $DIR | wc -l
