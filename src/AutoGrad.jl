module AutoGrad
export Param, differentiate, gradient, value, grad, gradloss, getval
export @primitive, @zerograd, @primitive1, @zerograd1, @diff

### New interface:
"""
    x = Param([1 2 3])
    sum(abs2, x) => 14
    y = differentiate(sum, abs2, x)
    gradient(y, x) => [2 4 6]
    value(x) => [1 2 3]
    value(y) => 14

Given a scalar valued function `f` and its arguments, `differentiate` returns `y` such that
`value(y) == f(x...; o...)` and `gradient(y, p)` gives the gradient of `y` with respect to
any parameter `p::Param`.  `p` may or may not be a part of the input arguments. `gradient`
will return `nothing` if `p` has no effect on `value(y)`.

`Param(x)` returns a struct that acts like `x` but marks it as a parameter you want to
compute gradients with respect to.

`value(x)` returns the value associated with `x` if `x` is a `Param` or the output of
`differentiate`, otherwise returns `x`.
"""
Param, differentiate, gradient, value

### Old interface:
"""
    x = [1 2 3]
    f(x) = sum(abs2, x)
    f(x) => 14
    grad(f)(x) => [2 4 6]
    gradloss(f)(x) => ([2 4 6], 14)

Given a scalar valued function `f`, `grad` returns another function `g` which takes the same
inputs as `f` and returns the gradient of the output with respect to the first
argument. `gradloss` is similar except the resulting function also returns f's output.

See also: [`differentiate`](@ref), [`gradient`](@ref), [`Param`](@ref), [`value`](@ref).
"""
grad, gradloss

using LinearAlgebra, Statistics, SpecialFunctions
include("core.jl")
include("broadcast.jl")
include("macros.jl")
include("getindex.jl")
include("iterate.jl")
include("sum_outgrads.jl")
include("base.jl")
include("math.jl")
include("statistics.jl")
include("linearalgebra.jl")
include("specialfunctions.jl")
include("cat.jl")
include("show.jl")
include("../test/gradcheck.jl")

"Use `AutoGrad.dir(path...)` to construct paths relative to AutoGrad root."
dir(path...) = joinpath(dirname(dirname(@__FILE__)),path...)

"Use `using AutoGrad.Abbrev` to get the shortcuts gr, df, pa."
module Abbrev
using ..AutoGrad
const gr = gradient
const df = differentiate
const pa = Param
export gr,df,pa
end

# Deprecations:
@deprecate Rec Value
@deprecate getval value

end # module
