# Vendor Integration Guide

This guide covers how to use FPGACompiler.jl output with various FPGA HLS tools.

## Overview

FPGACompiler.jl generates LLVM IR that can be consumed by multiple HLS tools:

| Vendor | Tool | Input Format | Status |
|--------|------|--------------|--------|
| Intel | oneAPI / aoc | LLVM IR (.ll) | Supported |
| AMD/Xilinx | Vitis HLS | LLVM IR (.ll) | Supported |
| Open Source | Bambu | LLVM IR (.ll) | Supported |
| Open Source | CIRCT/LLHD | LLVM IR (.ll) | Experimental |

## Output Formats

FPGACompiler.jl can generate two output formats:

```julia
# Text LLVM IR (.ll) - Human readable
fpga_code_native(kernel, types, format=:ll)

# LLVM Bitcode (.bc) - Binary format
fpga_code_native(kernel, types, format=:bc)
```

Most HLS tools accept both formats, but `.ll` is preferred for debugging.

---

## Intel oneAPI / FPGA

### Prerequisites

- Intel oneAPI Base Toolkit
- Intel FPGA Add-on for oneAPI

### Installation

```bash
# Download from Intel
# https://www.intel.com/content/www/us/en/developer/tools/oneapi/fpga.html

# Set up environment
source /opt/intel/oneapi/setvars.sh
```

### Workflow

1. **Generate LLVM IR:**

```julia
using FPGACompiler

@fpga_kernel function vector_add(A, B, C, n)
    for i in 1:n
        @inbounds C[i] = A[i] + B[i]
    end
end

# Generate IR
path = fpga_code_native(
    vector_add,
    Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int64},
    format=:ll,
    output="vector_add.ll"
)
```

2. **Compile with Intel FPGA Compiler:**

```bash
# Emulation (fast, for testing)
aoc -march=emulator vector_add.ll -o vector_add_emu.aocx

# Hardware compilation (slow, generates actual FPGA bitstream)
aoc vector_add.ll -o vector_add.aocx -board=<your_board>

# Report only (fast, shows resource estimates)
aoc -rtl vector_add.ll -o vector_add_report
```

3. **View Reports:**

```bash
# Open the HTML report
firefox vector_add_report/reports/report.html
```

### Intel-Specific Metadata

Intel tools recognize these LLVM metadata patterns:

```llvm
; Loop pipelining
!llvm.loop.pipeline.enable
!llvm.loop.pipeline.initiationinterval

; Memory attributes
!intel.fpga.ivdep           ; Independent iterations
!intel.fpga.ii              ; Initiation interval
!intel.fpga.max_concurrency ; Maximum parallel iterations
```

### Kernel Interface

Intel expects specific function signatures. Use wrapper scripts to adapt:

```cpp
// host_wrapper.cpp
#include <CL/sycl.hpp>

extern "C" void vector_add(float* A, float* B, float* C, int64_t n);

int main() {
    sycl::queue q(sycl::ext::intel::fpga_selector{});

    // Allocate and launch...
}
```

---

## AMD Vitis HLS

### Prerequisites

- AMD Vitis Unified Software Platform 2023.1+
- Valid license for HLS synthesis

### Installation

```bash
# Download from AMD
# https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vitis.html

# Set up environment
source /tools/Xilinx/Vitis/2023.1/settings64.sh
```

### Workflow

1. **Generate LLVM IR:**

```julia
using FPGACompiler

@fpga_kernel function matrix_multiply(A, B, C, M, N, K)
    for i in 1:M
        for j in 1:N
            sum = 0.0f0
            @pipeline II=1 for k in 1:K
                @inbounds sum += A[(i-1)*K + k] * B[(k-1)*N + j]
            end
            @inbounds C[(i-1)*N + j] = sum
        end
    end
end

path = fpga_code_native(
    matrix_multiply,
    Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int, Int, Int},
    format=:ll,
    output="matmul.ll"
)
```

2. **Create Vitis HLS Project:**

```bash
# Create project
vitis_hls -f <<EOF
open_project matmul_hls
set_top matrix_multiply
add_files matmul.ll
open_solution "solution1"
set_part {xcu250-figd2104-2L-e}
create_clock -period 10 -name default
csynth_design
exit
EOF
```

3. **Or use TCL Script:**

```tcl
# run_hls.tcl
open_project matmul_hls
set_top matrix_multiply

add_files matmul.ll

open_solution "solution1" -flow_target vitis
set_part {xcu250-figd2104-2L-e}
create_clock -period 10 -name default

# Set interface directives
set_directive_interface -mode m_axi -offset slave -bundle gmem0 matrix_multiply A
set_directive_interface -mode m_axi -offset slave -bundle gmem1 matrix_multiply B
set_directive_interface -mode m_axi -offset slave -bundle gmem2 matrix_multiply C
set_directive_interface -mode s_axilite -bundle control matrix_multiply

# Run synthesis
csynth_design

# Export IP
export_design -format ip_catalog

exit
```

```bash
vitis_hls -f run_hls.tcl
```

### AMD-Specific Metadata

AMD Vitis HLS recognizes:

```llvm
; Loop pipelining
!llvm.loop.pipeline.enable
!llvm.loop.pipeline.initiationinterval

; Loop unrolling
!llvm.loop.unroll.count
!llvm.loop.unroll.full

; Array partitioning (via pragmas in wrapper)
```

### Interface Mapping

AMD Vitis requires explicit interface directives. Create a wrapper header:

```cpp
// matmul_wrapper.h
#include <ap_int.h>
#include <hls_stream.h>

extern "C" {
void matrix_multiply(
    float* A,      // AXI master interface
    float* B,      // AXI master interface
    float* C,      // AXI master interface
    int M,         // AXI-Lite register
    int N,         // AXI-Lite register
    int K          // AXI-Lite register
);
}
```

---

## Bambu (Open Source)

### Prerequisites

- Bambu HLS from PandA project
- GCC or Clang for frontend

### Installation

```bash
# Ubuntu/Debian
git clone https://github.com/ferrandi/PandA-bambu.git
cd PandA-bambu
mkdir build && cd build
cmake ..
make -j$(nproc)
sudo make install
```

### Workflow

1. **Generate LLVM IR:**

```julia
using FPGACompiler

@fpga_kernel function fir_filter(input, coeffs, output, n_samples, n_taps)
    for i in 1:n_samples
        acc = 0.0f0
        @pipeline II=1 for j in 1:n_taps
            idx = i - j + 1
            if idx >= 1
                @inbounds acc += input[idx] * coeffs[j]
            end
        end
        @inbounds output[i] = acc
    end
end

path = fpga_code_native(
    fir_filter,
    Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int, Int},
    format=:ll,
    output="fir.ll"
)
```

2. **Run Bambu:**

```bash
# Basic synthesis
bambu fir.ll --top-fname=fir_filter \
    --device=xc7z020-1clg484-VVD \
    --clock-period=10

# With Verilog output
bambu fir.ll --top-fname=fir_filter \
    --device=xc7z020-1clg484-VVD \
    --clock-period=10 \
    --generate-vcd \
    --simulate \
    --simulator=VERILATOR
```

3. **View Results:**

```bash
# Check synthesis report
cat fir_filter/synthesis_results.txt

# Verilog output
ls fir_filter/*.v
```

### Bambu Options

```bash
# Target device
--device=<device_string>

# Clock constraint
--clock-period=<ns>

# Optimization level
-O2, -O3

# Memory mapping
--memory-allocation-policy=LSS  # Local scratch pad
--memory-allocation-policy=GSS  # Global shared

# Pipelining
--pipelining                    # Enable loop pipelining
--speculation                   # Enable speculative execution
```

---

## CIRCT / LLHD (Experimental)

### Overview

CIRCT (Circuit IR Compilers and Tools) is an LLVM/MLIR-based project for hardware design. Support is experimental.

### Installation

```bash
git clone https://github.com/llvm/circt.git
cd circt
mkdir build && cd build
cmake -G Ninja ../llvm/llvm \
    -DLLVM_ENABLE_PROJECTS=mlir \
    -DLLVM_EXTERNAL_PROJECTS=circt \
    -DLLVM_EXTERNAL_CIRCT_SOURCE_DIR=..
ninja
```

### Workflow

```bash
# Convert LLVM IR to CIRCT dialects (experimental)
llhd-sim fir.ll -o fir.circt

# Lower to Verilog
circt-opt fir.circt | firtool -format=mlir --verilog
```

---

## Debugging Tips

### 1. Inspect Generated IR

```julia
# Print IR to console
ir = fpga_code_llvm(kernel, types)
println(ir)

# Look for problematic patterns
if occursin("jl_gc", ir)
    @warn "IR contains GC calls - synthesis will fail"
end
```

### 2. Verify No Unsupported Operations

Check the IR for:
- `call @jl_*` - Julia runtime calls
- `invoke` - Exception handling
- `malloc`/`free` - Dynamic allocation

### 3. Test with Emulation First

```bash
# Intel
aoc -march=emulator kernel.ll

# AMD (csim)
vitis_hls -f "csim_design"

# Bambu
bambu kernel.ll --simulate
```

### 4. Check Resource Estimates

Use vendor report tools before full synthesis:

```bash
# Intel
aoc -rtl kernel.ll

# AMD
vitis_hls -f "csynth_design"  # Much faster than full synthesis
```

---

## Common Issues

### Issue: "Undefined reference to jl_*"

**Cause:** Julia runtime functions not stripped.

**Solution:** Ensure GPUCompiler properly removes runtime. Check `optimize.jl` is processing the module.

### Issue: "Dynamic allocation detected"

**Cause:** Array growth or heap allocation in kernel.

**Solution:** Use fixed-size arrays or PartitionedArray.

### Issue: "Loop II not achieved"

**Cause:** Memory dependencies prevent pipelining.

**Solution:**
- Use PartitionedArray for parallel access
- Check for loop-carried dependencies
- Add `@ivdep` hints if iterations are independent

### Issue: "Resource limit exceeded"

**Cause:** Design too large for target FPGA.

**Solution:**
- Reduce unroll factor
- Use smaller data types (FixedInt)
- Partition work across multiple kernels

---

## Performance Optimization

### 1. Memory Bandwidth

```julia
# Partition for parallel access
A = PartitionedArray(data; factor=4, style=CYCLIC)

# Match unroll factor to partition factor
@unroll factor=4 for i in 1:4:n
    # Access 4 elements per cycle
end
```

### 2. Pipeline Depth

```julia
# Deep pipeline for high frequency
@pipeline II=1 for i in 1:n
    # Simple operations
end

# Shallow pipeline for complex operations
@pipeline II=4 for i in 1:n
    # Complex math - needs more cycles
end
```

### 3. Data Types

```julia
# Use minimal bit widths
counter = UInt12(0)      # 12-bit counter vs 64-bit
pixel = FixedInt{8, UInt8}(0)  # 8-bit pixel value
```

---

## Reference: LLVM IR Output Example

A typical FPGACompiler.jl output for a vector add:

```llvm
; ModuleID = 'vector_add'
target triple = "spir64-unknown-unknown"

define void @julia_vector_add(float* noalias %A, float* noalias %B, float* noalias %C, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %ptr.A = getelementptr float, float* %A, i64 %i
  %ptr.B = getelementptr float, float* %B, i64 %i
  %ptr.C = getelementptr float, float* %C, i64 %i
  %a = load float, float* %ptr.A
  %b = load float, float* %ptr.B
  %c = fadd float %a, %b
  store float %c, float* %ptr.C
  %i.next = add i64 %i, 1
  %cond = icmp slt i64 %i.next, %n
  br i1 %cond, label %loop, label %exit, !llvm.loop !0

exit:
  ret void
}

!0 = distinct !{!0, !1, !2}
!1 = !{!"llvm.loop.pipeline.enable"}
!2 = !{!"llvm.loop.pipeline.initiationinterval", i32 1}
```

This IR is ready for any of the vendor tools described above.
