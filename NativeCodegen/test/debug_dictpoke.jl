using NativeCodegen: compile_native, native_callable_from_so

const D = Dict{Int64,Int64}(1 => 100, 2 => 200, 3 => 300)
println("host D.slots = ", D.slots, " (length ", length(D.slots), ")")
println("host D.keys  = ", D.keys)

# Read slots[4] and keys[4] (key 1's bucket per hashindex)
fslots(i::Int64) = D.slots[i]
fkeys(i::Int64) = D.keys[i]

c1 = compile_native(fslots, Tuple{Int64}; name="ds")
nfs = native_callable_from_so(c1, UInt8, Int64)
print("native D.slots: ")
for i in 1:length(D.slots); print(nfs(i), " "); end
println()
rm(c1.so_path)

c2 = compile_native(fkeys, Tuple{Int64}; name="dk")
nfk = native_callable_from_so(c2, Int64, Int64)
print("native D.keys:  ")
for i in 1:length(D.keys); print(nfk(i), " "); end
println()
rm(c2.so_path)
