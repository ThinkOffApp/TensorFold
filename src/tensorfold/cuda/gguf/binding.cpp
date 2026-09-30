// torch entry points for libtfgguf (capi.hip): quantized rows in, fp32 rows out, on the current stream.
#include <ATen/hip/HIPContext.h>
#include <torch/extension.h>

extern "C" int tf_gguf_linear(int, const void*, const float*, float*, size_t, size_t, size_t, void*);
extern "C" int tf_gguf_dequant_bf16(int, const void*, void*, size_t, void*);

torch::Tensor linear(torch::Tensor x, torch::Tensor w, int64_t type, int64_t m) {
  TORCH_CHECK(x.is_cuda() && x.scalar_type() == torch::kFloat32 && x.dim() == 2 && x.is_contiguous(), "x: fp32 (rows, K)");
  TORCH_CHECK(w.is_cuda() && w.scalar_type() == torch::kUInt8 && w.is_contiguous(), "w: packed uint8 blocks");
  auto y = torch::empty({x.size(0), m}, x.options());
  if (x.size(0) == 0) return y;
  auto stream = at::hip::getCurrentHIPStream().stream();
  int err = tf_gguf_linear(static_cast<int>(type), w.data_ptr(), x.data_ptr<float>(), y.data_ptr<float>(), x.size(0),
                           m, x.size(1), stream);
  TORCH_CHECK(err == 0, "tf_gguf_linear: HIP error ", err);
  return y;
}

torch::Tensor dequant_bf16(torch::Tensor w, int64_t type, int64_t n) {
  TORCH_CHECK(w.is_cuda() && w.scalar_type() == torch::kUInt8 && w.is_contiguous(), "w: packed uint8 blocks");
  auto out = torch::empty({n}, w.options().dtype(torch::kBFloat16));
  auto stream = at::hip::getCurrentHIPStream().stream();
  int err = tf_gguf_dequant_bf16(static_cast<int>(type), w.data_ptr(), out.data_ptr(), n, stream);
  TORCH_CHECK(err == 0, "tf_gguf_dequant_bf16: HIP error ", err);
  return out;
}

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("linear", &linear);
  m.def("dequant_bf16", &dequant_bf16);
}
