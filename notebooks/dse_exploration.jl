### A Pluto.jl notebook ###
# v0.20.0

using Markdown
using InteractiveUtils

# This Pluto notebook demonstrates the FPGACompiler CoDesign module
# for Design Space Exploration (DSE) of FPGA kernels.

# ╔═╡ 00000001-0001-0001-0001-000000000001
begin
    import Pkg
    Pkg.activate("..")
    using FPGACompiler
    using FPGACompiler.CoDesign
end

# ╔═╡ 00000001-0001-0001-0001-000000000002
md"""
# FPGA Design Space Exploration

This notebook demonstrates how to explore the design space for FPGA kernels using the FPGACompiler CoDesign module.

## What is DSE?

Design Space Exploration (DSE) is the process of finding optimal hardware configurations for a given workload. Key parameters include:

- **Unroll Factor**: How many parallel compute units to instantiate
- **Initiation Interval (II)**: How many cycles between starting new operations
- **BRAM Ports**: Number of simultaneous memory accesses
- **Pipeline Depth**: Number of pipeline stages

"""

# ╔═╡ 00000001-0001-0001-0001-000000000003
md"## Step 1: Define the Workload"

# ╔═╡ 00000001-0001-0001-0001-000000000004
# Define a 2D convolution workload (common in image processing and ML)
workload = conv2d_workload(
    kernel_size = 3,     # 3x3 convolution kernel
    img_height = 28,     # MNIST-sized image
    img_width = 28
)

# ╔═╡ 00000001-0001-0001-0001-000000000005
md"""
### Workload Properties

- **NDRange**: $(workload.ndrange) - output dimensions
- **Total Items**: $(total_items(workload)) pixels to process
- **Multiplies per Item**: $(workload.multiplies_per_item) (kernel window)
- **Reads per Item**: $(workload.reads_per_item)
- **Writes per Item**: $(workload.writes_per_item)
"""

# ╔═╡ 00000001-0001-0001-0001-000000000006
md"## Step 2: Create DSE Parameters"

# ╔═╡ 00000001-0001-0001-0001-000000000007
# Slider controls (in Pluto, these would be interactive)
unroll_factor_slider = 4  # @bind unroll_factor Slider(1:16, default=4)
ii_slider = 1             # @bind ii Slider(1:4, default=1)
bram_ports_slider = 2     # @bind bram_ports Slider(1:8, default=2)

# ╔═╡ 00000001-0001-0001-0001-000000000008
# Create DSE configuration
dse = DSEParameters(
    unroll_factor = unroll_factor_slider,
    initiation_interval = ii_slider,
    bram_ports = bram_ports_slider,
    max_dsps = 64,
    pipeline_depth = 5
)

# ╔═╡ 00000001-0001-0001-0001-000000000009
md"## Step 3: Create and Run Parametric Simulation"

# ╔═╡ 00000001-0001-0001-0001-000000000010
# Create kernel
kernel = CoDesignKernel("conv2d_kernel"; workload=workload, dse=dse)

# ╔═╡ 00000001-0001-0001-0001-000000000011
# Get performance estimate (quick, no full simulation)
estimate = FPGACompiler.CoDesign.estimate_performance(kernel.parametric_sim)

# ╔═╡ 00000001-0001-0001-0001-000000000012
md"""
### Performance Estimate

| Metric | Value |
|--------|-------|
| Estimated Cycles | $(estimate.estimated_cycles) |
| Throughput | $(round(estimate.estimated_throughput, digits=4)) items/cycle |
| Bottleneck | $(estimate.bottleneck) |
| Memory Bound | $(estimate.memory_bound) |
| Compute Bound | $(estimate.compute_bound) |
"""

# ╔═╡ 00000001-0001-0001-0001-000000000013
md"## Step 4: Sweep DSE Space"

# ╔═╡ 00000001-0001-0001-0001-000000000014
# Sweep different unroll factors
sweep_results = sweep_unroll_factor(workload, 1:8)

# ╔═╡ 00000001-0001-0001-0001-000000000015
# Display as table
begin
    println("Unroll Factor | Cycles | Throughput | Memory Bound")
    println("-" ^ 50)
    for r in sweep_results
        println("$(r.unroll_factor) | $(r.cycles) | $(round(r.throughput, digits=4)) | $(r.memory_bound)")
    end
end

# ╔═╡ 00000001-0001-0001-0001-000000000016
md"## Step 5: Find Optimal Configuration"

# ╔═╡ 00000001-0001-0001-0001-000000000017
# Find best configuration
best_config = find_optimal_config(workload; optimize_for=:throughput, max_dsps=64)

# ╔═╡ 00000001-0001-0001-0001-000000000018
md"""
### Optimal Configuration Found

| Parameter | Value |
|-----------|-------|
| Unroll Factor | $(best_config.unroll_factor) |
| Initiation Interval | $(best_config.initiation_interval) |
| BRAM Ports | $(best_config.bram_ports) |
"""

# ╔═╡ 00000001-0001-0001-0001-000000000019
md"## Step 6: Target Specific FPGA Device"

# ╔═╡ 00000001-0001-0001-0001-000000000020
# Create virtual Zynq-7020 device
device = zynq_7020()

# ╔═╡ 00000001-0001-0001-0001-000000000021
md"""
### Target Device: $(device.name)

| Resource | Available |
|----------|-----------|
| LUTs | $(device.total_luts) |
| FFs | $(device.total_ffs) |
| BRAMs | $(device.total_brams) |
| DSPs | $(device.total_dsps) |
| Clock | $(device.clock_freq_mhz) MHz |
"""

# ╔═╡ 00000001-0001-0001-0001-000000000022
# Constrained optimization
constrained_best = find_optimal_config(workload;
    optimize_for = :throughput,
    max_dsps = device.total_dsps,
    max_brams = device.total_brams
)

# ╔═╡ 00000001-0001-0001-0001-000000000023
md"""
### Device-Constrained Optimal Configuration

| Parameter | Value |
|-----------|-------|
| Unroll Factor | $(constrained_best.unroll_factor) |
| Initiation Interval | $(constrained_best.initiation_interval) |
| BRAM Ports | $(constrained_best.bram_ports) |
"""

# ╔═╡ 00000001-0001-0001-0001-000000000024
md"## Step 7: Compare Different Workloads"

# ╔═╡ 00000001-0001-0001-0001-000000000025
begin
    workloads = [
        ("3x3 Conv", conv2d_workload(kernel_size=3, img_height=28, img_width=28)),
        ("5x5 Conv", conv2d_workload(kernel_size=5, img_height=28, img_width=28)),
        ("64x64 MatMul", matmul_workload(M=64, N=64, K=64)),
        ("16-tap FIR", fir_filter_workload(taps=16, samples=1024))
    ]

    println("Workload | Total Items | Multiplies/item | Est. Cycles")
    println("-" ^ 60)
    for (name, w) in workloads
        est = quick_sim(w)
        println("$name | $(total_items(w)) | $(w.multiplies_per_item) | $(est.estimated_cycles)")
    end
end

# ╔═╡ 00000001-0001-0001-0001-000000000026
md"""
## Summary

This notebook demonstrated:

1. **Workload Definition**: Describing kernel characteristics without compilation
2. **DSE Parameters**: Configuring hardware design tradeoffs
3. **Performance Estimation**: Quick throughput/latency estimates
4. **Design Space Sweeping**: Exploring parameter ranges
5. **Optimal Configuration Finding**: Automatic optimization
6. **Device-Aware Design**: Constraining to real FPGA resources

The CoDesign module enables rapid hardware-software co-design iteration without requiring full FPGA compilation.
"""

# ╔═╡ 00000001-0001-0001-0001-000000000027
# Cell order preserved from creation
