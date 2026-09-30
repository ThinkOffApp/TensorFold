// C entry points over Gufo's exact quantized GEMM (vendor/, MIT). Every row takes the decode GEMV's arithmetic order
// whatever the row count, so a drafted row's bits equal its serial bits.
#include <hip/hip_runtime.h>

#include <cstddef>

#include "src/models/qwen/hip/ops/gemm.hpp"

extern "C" int tf_gguf_linear(int type, const void* w, const float* x, float* y, std::size_t rows, std::size_t m,
                              std::size_t k, void* stream) {
  gufo::hip::LaunchBatchedQuantGEMMFp32(static_cast<gufo::core::GgmlType>(type), w, x, y, rows, m, k,
                                        static_cast<hipStream_t>(stream));
  return static_cast<int>(hipGetLastError());
}

extern "C" int tf_gguf_dequant_bf16(int type, const void* w, void* out, std::size_t n, void* stream) {
  gufo::hip::LaunchDequantizeToBf16(static_cast<gufo::core::GgmlType>(type), w, static_cast<hip_bfloat16*>(out), n,
                                    static_cast<hipStream_t>(stream));
  return static_cast<int>(hipGetLastError());
}
