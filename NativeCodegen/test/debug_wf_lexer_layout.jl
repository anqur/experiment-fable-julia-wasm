using NativeCodegen: CC, NCGInterp
import Base.JuliaSyntax as JS

const INTERP = NCGInterp()

# Dereference io+0 directly (avoid pointer_from_objref which fails on Memory).
io = IOBuffer(b"hello")
p = pointer_from_objref(io)
data_ptr_field = unsafe_load(Ptr{Ptr{Cvoid}}(p + 0))   # the :data field value
println("io+0 (the :data field as pointer) = 0x", string(UInt(data_ptr_field), base=16))
# Read what's at that address: is it {length@0, ptr@8}?
len_at = unsafe_load(Ptr{Int64}(data_ptr_field + 0))
ptr_at = unsafe_load(Ptr{Ptr{UInt8}}(data_ptr_field + 8))
println("  [io+0]+0 as Int64 = ", len_at, "  (io.data length is 5)")
println("  [io+0]+8 as Ptr   = 0x", string(UInt(ptr_at), base=16))
if ptr_at != C_NULL
    b0 = unsafe_load(ptr_at)
    println("  byte at [io+0]+8 -> ", string(b0, base=16), " ('h'=0x68)")
end
println("=> :data field IS a pointer to {length@0, ptr@8}: ", len_at == 5 && ptr_at != C_NULL)

# Now: how does codegen SEE :data? Check fieldoffset used by codegen.
println("\nfieldoffset(IOBuffer,:data) = ", fieldoffset(IOBuffer, :data))
println("fieldtype(IOBuffer,:data)   = ", fieldtype(IOBuffer, :data))

# Memory field offsets (the codegen uses these for getfield(mem,:length)/getfield(mem,:ptr))
mt = fieldtype(IOBuffer, :data)
println("Memory fields: ", fieldnames(mt))
println("  fieldoffset(Memory,:length) = ", fieldoffset(mt, 1))
println("  fieldoffset(Memory,:ptr)    = ", fieldoffset(mt, 2))
