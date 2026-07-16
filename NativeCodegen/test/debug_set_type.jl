import Base.JuliaSyntax as JS
x = JS._nonunique_kind_names
println("typeof: ", typeof(x))
println("ismutabletype: ", Base.ismutabletype(typeof(x)))
println("isbitstype: ", Base.isbitstype(typeof(x)))
println("supertype: ", supertype(typeof(x)))
println("length: ", length(x))
println("first: ", first(x))
