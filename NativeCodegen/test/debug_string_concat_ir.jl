# Debug string operations IR - comprehensive analysis
# This script dumps the complete IRCode for various string operations

using NativeCodegen
using NativeCodegen: WasmInterp
using Core.Compiler

println("=" ^ 80)
println("STRING OPERATIONS IR ANALYSIS")
println("=" ^ 80)

# Helper function to dump IR for a given function
function dump_ir(func, argtypes::Type, name::String)
    println("\n" * "=" ^ 80)
    println("Function: $name")
    println("Signature: $argtypes")
    println("=" ^ 80)
    
    interp = WasmInterp()
    tt = Base.signature_type(func, argtypes)
    
    try
        matches = Base._methods_by_ftype(tt, -1, interp.world)
        if matches === nothing || isempty(matches)
            println("No method matches found!")
            return
        end
        
        mi = Core.Compiler.specialize_method(matches[1].method, tt, Core.svec())
        result = Base.code_ircode_by_type(mi.specTypes; world=interp.world, interp=interp)
        
        if isempty(result)
            println("No IRCode generated!")
            return
        end
        
        ir, rettype = result[1]
        
        println("\nReturn type: $rettype")
        println("\nIRCode statements:")
        println("-" ^ 80)
        
        for (i, stmt) in enumerate(ir.stmts)
            stmt_type = stmt[:type]
            stmt_expr = stmt[:stmt]
            
            println("%$i :: $stmt_type  $stmt_expr")
            
            # Additional analysis for specific node types
            if stmt_expr isa Expr
                if stmt_expr.head == :foreigncall
                    println("  → FOREIGNCALL detected:")
                    println("     - Function: $(stmt_expr.args[1])")
                    println("     - Return type: $(stmt_expr.args[2])")
                    if length(stmt_expr.args) >= 3
                        argtypes_expr = stmt_expr.args[3]
                        println("     - Arg types: $argtypes_expr")
                    end
                elseif stmt_expr.head == :invoke
                    println("  → INVOKE detected:")
                    println("     - Function: $(stmt_expr.args[1])")
                    println("     - Args: $(stmt_expr.args[2:end])")
                elseif stmt_expr.head == :call
                    println("  → CALL detected:")
                    println("     - Function: $(stmt_expr.args[1])")
                    println("     - Args: $(stmt_expr.args[2:end])")
                end
            end
        end
        
        println("\n" * "-" ^ 80)
        println("Code info:")
        println("  - Number of statements: $(length(ir.stmts))")
        println("  - Argument types: $(ir.argtypes)")
        
    catch e
        println("ERROR dumping IR: $e")
        println("Stack trace:")
        for (exc, bt) in Base.catch_stack()
            showerror(IOContext(stderr, :backtrace => bt), exc)
            println(stderr)
        end
    end
end

# ==============================================================================
# Test 1: String concatenation (MOST IMPORTANT)
# ==============================================================================
println("\n" * "#" ^ 80)
println("# TEST 1: String concatenation (cat2) - MOST IMPORTANT")
println("#" ^ 80)

cat2(a::String, b::String) = a * b
dump_ir(cat2, Tuple{String, String}, "cat2(a::String, b::String) = a * b")

# ==============================================================================
# Test 2: Three-way concatenation
# ==============================================================================
println("\n" * "#" ^ 80)
println("# TEST 2: Three-way concatenation")
println("#" ^ 80)

cat3(a::String, b::String, c::String) = a * b * c
dump_ir(cat3, Tuple{String, String, String}, "cat3(a, b, c) = a * b * c")

# ==============================================================================
# Test 3: String literal return (constant folding test)
# ==============================================================================
println("\n" * "#" ^ 80)
println("# TEST 3: String literal return")
println("#" ^ 80)

mkstr() = "hello"
dump_ir(mkstr, Tuple{}, "mkstr() = \"hello\"")

# ==============================================================================
# Test 4: String from byte array
# ==============================================================================
println("\n" * "#" ^ 80)
println("# TEST 4: String from byte array")
println("#" ^ 80)

frombytes(bytes::Vector{UInt8}) = String(bytes)
dump_ir(frombytes, Tuple{Vector{UInt8}}, "frombytes(bytes::Vector{UInt8}) = String(bytes)")

# ==============================================================================
# Test 5: string() with non-string argument
# ==============================================================================
println("\n" * "#" ^ 80)
println("# TEST 5: string() with Int argument")
println("#" ^ 80)

mkstr2(n::Int64) = string("x", n)
dump_ir(mkstr2, Tuple{Int64}, "mkstr2(n::Int64) = string(\"x\", n)")

# ==============================================================================
# Test 6: Alternative - simpler string() call
# ==============================================================================
println("\n" * "#" ^ 80)
println("# TEST 6: Simple string() call")
println("#" ^ 80)

mkintstr(n::Int64) = string(n)
dump_ir(mkintstr, Tuple{Int64}, "mkintstr(n::Int64) = string(n)")

println("\n" * "=" ^ 80)
println("END OF STRING OPERATIONS IR ANALYSIS")
println("=" ^ 80)
