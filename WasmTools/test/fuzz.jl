# Differential fuzz test: WasmTools decode/encode vs `wasm-tools smith`.
#
# Standalone (NOT wired into runtests.jl):
#     julia --project=WasmTools WasmTools/test/fuzz.jl
#
# For each of NUM_MODULES deterministic seeds, generates a valid wasm module
# with `wasm-tools smith` (GC, function references, reference types, tail
# calls, exceptions, bulk memory enabled; SIMD/relaxed-SIMD/threads/memory64/
# custom-descriptors/custom-page-sizes disabled) and checks:
#
#   1. m  = WasmTools.decode(bytes) does not throw
#   2. c1 = WasmTools.encode(m) does not throw
#   3. `wasm-tools validate --features all` accepts c1
#   4. encode(decode(c1)) == c1  (byte-stability of self-produced binaries)
#   5. `wasm-tools print` of the original and of c1 agree after stripping
#      custom sections from both sides (so loss of non-function name
#      subsections is ignored).
#
# Skips gracefully (exit 0) when wasm-tools is not available. Set the
# WASM_TOOLS env var to point at the binary explicitly.

using Test
using WasmTools

# --- locate wasm-tools -------------------------------------------------------

const WASM_TOOLS = let
    cand = get(ENV, "WASM_TOOLS", "/workspace/tools/wasm-tools-dist/wasm-tools")
    isfile(cand) && Sys.isexecutable(cand) ? cand : Sys.which("wasm-tools")
end

if WASM_TOOLS === nothing
    @info "fuzz.jl: wasm-tools binary not found (set WASM_TOOLS); skipping fuzz tests"
    exit(0)
end

# --- deterministic PRNG (SplitMix64; independent of Julia's RNG streams) -----

mutable struct SM64
    s::UInt64
end
function nextu64!(r::SM64)
    r.s += 0x9e3779b97f4a7c15
    z = r.s
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return z ⊻ (z >> 31)
end
function randbytes(r::SM64, n::Int)
    out = Vector{UInt8}(undef, n)
    i = 1
    while i <= n
        v = nextu64!(r)
        for k in 0:7
            i > n && break
            out[i] = UInt8((v >> (8k)) & 0xff)
            i += 1
        end
    end
    return out
end

# --- wasm-tools helpers -------------------------------------------------------

const SMITH_FLAGS = [
    "--reference-types-enabled", "true",
    "--gc-enabled", "true",                 # implies function references
    "--tail-call-enabled", "true",
    "--exceptions-enabled", "true",
    "--bulk-memory-enabled", "true",
    "--simd-enabled", "false",
    "--relaxed-simd-enabled", "false",
    "--threads-enabled", "false",
    "--shared-everything-threads-enabled", "false",
    "--memory64-enabled", "false",
    "--custom-descriptors-enabled", "false",
    "--custom-page-sizes-enabled", "false",
    "--wide-arithmetic-enabled", "false",
]

smith(seed::Vector{UInt8}, out::String) =
    success(pipeline(`$WASM_TOOLS smith $SMITH_FLAGS -o $out`,
                     stdin=IOBuffer(seed), stderr=devnull))

wt_validate(path::String) =
    success(pipeline(`$WASM_TOOLS validate --features all $path`, stderr=devnull))

wt_print(path::String) =
    try
        read(`$WASM_TOOLS print $path`, String)
    catch
        nothing
    end

wt_strip(inp::String, outp::String) =
    success(pipeline(`$WASM_TOOLS strip -a -o $outp $inp`, stderr=devnull))

# --- per-module check ---------------------------------------------------------

"""
Run all round-trip checks for one wasm binary. Returns `(ok, reason)`.
"""
function check_module(bytes::Vector{UInt8}, dir::String)
    m = try
        WasmTools.decode(bytes)
    catch e
        return false, "decode threw: $(sprint(showerror, e))"
    end
    c1 = try
        WasmTools.encode(m)
    catch e
        return false, "encode threw: $(sprint(showerror, e))"
    end
    origpath = joinpath(dir, "orig.wasm")
    c1path = joinpath(dir, "c1.wasm")
    write(origpath, bytes)
    write(c1path, c1)
    wt_validate(c1path) ||
        return false, "re-encoded module fails `wasm-tools validate --features all`"
    c2 = try
        WasmTools.encode(WasmTools.decode(c1))
    catch e
        return false, "decode/encode of re-encoded module threw: $(sprint(showerror, e))"
    end
    c2 == c1 || return false, "encode(decode(c1)) != c1 (not byte-stable)"
    so = joinpath(dir, "orig_stripped.wasm")
    sc = joinpath(dir, "c1_stripped.wasm")
    if wt_strip(origpath, so) && wt_strip(c1path, sc)
        po = wt_print(so)
        pc = wt_print(sc)
        if po !== nothing && pc !== nothing && po != pc
            return false, "`wasm-tools print` mismatch after stripping custom sections"
        end
    end
    return true, ""
end

# --- minimized regressions found by this fuzzer -------------------------------

# A function whose `block` result is a concrete reference type, encoded with
# the spec's valtype-shorthand block type (0x63 <typeidx>):
#   (module (type (func))
#           (func (block (result (ref null 0)) unreachable) drop))
# decode() accepts it but encode() must be able to re-emit it.
const REGRESSION_CONCRETE_REF_BLOCKTYPE =
    hex2bytes("0061736d01000000010401600000030201000a0a010800026300000b1a0b")

# A declarative element segment in expression form with element type funcref
# (flag 7, empty init vector): (module (elem declare funcref))
# The Elem IR records the binary flavor, so this must round-trip byte-identically.
const REGRESSION_ELEM_FLAG7 =
    hex2bytes("0061736d01000000090401077000")

# --- main ----------------------------------------------------------------------

const NUM_MODULES = 100
const SEED_BASE = UInt64(0x000057A510)   # fixed: deterministic campaign

@testset "fuzz: decode/encode vs wasm-tools smith" begin
    mktempdir() do dir
        for (name, bytes) in [
            ("concrete-ref blocktype", REGRESSION_CONCRETE_REF_BLOCKTYPE),
            ("elem expr-form flag 7", REGRESSION_ELEM_FLAG7),
        ]
            @testset "regression: $name" begin
                rp = joinpath(dir, "regression.wasm")
                write(rp, bytes)
                @test wt_validate(rp)   # sanity: input is valid wasm
                ok, reason = check_module(bytes, dir)
                ok || @info "regression \"$name\" failed" reason
                @test ok
            end
        end

        ngen = 0
        nskip = 0
        failures = Tuple{Int,String}[]
        for i in 1:NUM_MODULES
            rng = SM64(SEED_BASE + UInt64(i))
            len = 200 + Int(nextu64!(rng) % 3800)
            seed = randbytes(rng, len)
            modpath = joinpath(dir, "smith.wasm")
            if !smith(seed, modpath)
                nskip += 1   # smith exit code 2: seed yields no module; fine
                continue
            end
            ngen += 1
            ok, reason = check_module(read(modpath), dir)
            ok || push!(failures, (i, reason))
            @testset "module seed=$i" begin
                @test ok
            end
        end
        @info "fuzz campaign finished" generated = ngen skipped = nskip failures = length(failures)
        for (i, reason) in failures
            @info "fuzz failure" seed = i reason
        end
        # The campaign must have actually exercised the decoder.
        @test ngen >= NUM_MODULES ÷ 2
    end
end
