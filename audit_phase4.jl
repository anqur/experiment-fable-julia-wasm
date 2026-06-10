# Phase 4: decode/re-encode every smith-generated module; the re-encoded module
# must (a) validate with wasm-tools, (b) decode back equal-by-reencode (idempotent),
# (c) decode without error in the first place.
using WasmTools
using WasmTools: decode, encode

const WT = "/workspace/tools/wasm-tools-dist/wasm-tools"

function run_wt(args::Vector{String}, input::Vector{UInt8})
    inbuf = IOBuffer(input)
    out = IOBuffer(); err = IOBuffer()
    p = run(pipeline(ignorestatus(`$WT $args -`), stdin=inbuf, stdout=out, stderr=err); wait=true)
    return p.exitcode, take!(out), String(take!(err))
end

files = sort(filter(endswith(".wasm"), readdir("/tmp/smith"; join=true)))
issues = String[]
ok = 0
for f in files
    bytes = read(f)
    m = try
        decode(bytes)
    catch e
        push!(issues, "$f: decode threw $(sprint(showerror, e))")
        continue
    end
    re = try
        encode(m)
    catch e
        push!(issues, "$f: re-encode threw $(sprint(showerror, e))")
        continue
    end
    vcode, _, verr = run_wt(["validate", "--features", "all"], re)
    if vcode != 0
        push!(issues, "$f: re-encoded module fails validation: $(first(split(verr,'\n')))")
        continue
    end
    re2 = encode(decode(re))
    if re2 != re
        push!(issues, "$f: encode∘decode not idempotent on self-produced bytes")
        continue
    end
    # semantic comparison: print text of theirs vs ours must match modulo
    # canonicalizations; compare instruction multiset crudely via sorted lines
    global ok += 1
end
println("=== PHASE 4 RESULTS ===")
println("checked $(length(files)) modules, passed $ok")
for i in issues
    println("ISSUE: ", i)
end
