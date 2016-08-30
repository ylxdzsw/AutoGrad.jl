# Uncomment to debug:
# macro dbgcore(x); esc(:(println(_dbg($x)))); end
macro dbgcore(x); end


# Contents:

# Here are the rough steps performed by g(x) where g=grad(f):
# 1. g is called with the same inputs as f.
# 2. g calls forward_pass which boxes x in a Value type and calls f(Value(x)).
# 3. If a primitive operator inside f gets a Value input, it records its action and returns a Value output.
# 4. g calls backward_pass which returns the gradient df/dx.

# And some background info:
# 5. How recording is done.
# 6. How new primitives and their gradients are defined.
# 7. How higher order gradients work.
# 8. Support functions.

# Details:

# 1. g is called with the same inputs as f.
# 1.1 g supports both regular and keyword args.
# 1.2 only one of the regular args is the gradient target, specified by the argnum argument of grad (defaults to 1).
# 1.3 in a typical model f would take parameters, return loss, with data kept in global variables.
# 1.4 to support multiple parameters, they can be grouped in a single arg using Array, Dict, or Tuple.


"""
grad(fun, argnum=1) -> gradfun    

* fun: X->Y    
* gradfun: X->dX   

Returns a function which computes the gradient of `fun` with respect to
positional argument number `argnum`. The returned function takes the same
arguments as `fun`, but returns the gradient instead. The function `fun`
should be scalar-valued. The gradient has the same type as the argument.
"""
function grad(fun::Function, argnum::Int=1)
    @dbgcore((:grad,fun,argnum))
    function gradfun(args...; kwargs...)
        backward_pass(forward_pass(fun, args, kwargs, argnum)...)
    end
    return gradfun
end


# 2. g calls forward_pass which boxes argnum'th arg x in a Value type and calls f(Value(x))
# 2.1 f must be defined generically to accept Value arguments.
# 2.2 before the call a new Tape (tape1) is created (this is the only place a new tape is created)
# 2.3 v1=Value(x,tape1) is created, each boxed value is associated with one or more tapes.
# 2.4 x may already be boxed in a v0=Value(x,tape0) from another tape (this happens with higher order derivatives)
# 2.5 if 2.4, another v2=Value(x,[tape0,tape1]) is created by merge_tapes connecting both tapes with dependencies on v0 and v1.
# 2.6 if not 2.4, merge_tapes simply returns v1.
# 2.7 f is called with v1 or v2 (depending on 2.4).
# 2.8 if v2, the downstream operations on x are recorded on both tape0 and tape1.
# 2.9 the output of f (end_value) could be a boxed Value or a regular value (if it does not depend on x)

function forward_pass(fun, args, kwargs, argnum)
    @dbgcore((:forw, argnum, fun, args..., kwargs...))
    tape = Tape()
    arg_wrt = args[argnum]
    start_value = Value(tofloat(getval(arg_wrt)),tape)
    args = Any[args...] # to make args writeable
    args[argnum] = merge_tapes(start_value, arg_wrt)
    @dbgcore((:fcall, fun, args..., kwargs...))
    end_value = fun(args...; kwargs...)
    return start_value, end_value, tape
end

# forward_pass type: ((N(X)->N(Y)/Y),N(X)/X,K,I)->(N(X),N(Y)/Y,T)
# forward_pass deps: Tape, Value, getval, tofloat, merge_tapes


# 3. If a primitive operator inside f gets a Value input, it records its action and returns a Value output.

# 3.1 We implement this by dispatching f to r=recorder(f) if any of
# its arguments is a Value.  r unboxes the arguments, calls f, boxes
# and returns the result, recording the result and its dependencies on
# each boxed argument.

# We only need one recorder per function, but recorder(f) may be
# called many times for different methods.  To avoid duplication we
# hold recorders in a hash.

let fdict=ObjectIdDict()
global recorder

"""
recorder(fun) returns rfun, a recording version of fun.  It is used to
define primitive operations. rfun is defined with a generic signature
r(args...; kwargs...) and is intended to catch all invocations that
have at least one Value argument.
"""
function recorder(f)
r = get(fdict,f,0)
r != 0 && return r

function rfun(args...; kwargs...)
    @dbgcore((:call, f, args..., kwargs...))
    argvals = map(getval,args)
    result = f(argvals...; kwargs...)
    for argnum = 1:length(args)
        arg = args[argnum]
        isa(arg,Value) || continue
        for t=1:length(arg.tapes)
            tape = arg.tapes[t]
            iscomplete(tape) && continue
            parent = arg.nodes[t]
            if !isa(result,Value) 
                result = Value(result, tape; func=f, args=args, kwargs=kwargs)
                rnode = result.nodes[1]
            else
                s = findeq(result.tapes, tape)
                if s > 0
                    rnode = result.nodes[s]
                else
                    rnode = Node(result)
                    push!(result.tapes, tape)
                    push!(result.nodes, rnode)
                end
            end
            rnode.parents[argnum] = parent
        end
    end
    return result
end # function rfun
return (fdict[f] = rfun)
end # function recorder
end # let fdict

# recorder deps: Value, Node, iscomplete, findeq


# 4. g calls backward_pass which returns the gradient df/dx.

# 4.1 backward_pass is called with start_value: Value(x), end_value:
# f(Value(x)) (which may or may not be a boxed Value), and the tape
# created by the corresponding forward_pass.  Note that Value(x) may
# point to more tapes in case of a higher order gradient.  It returns
# the gradient wrt the start_value.

function backward_pass(start_value, end_value, tape)
    @dbgcore((:back,:start,start_value,:end,end_value,:tape,tape,tape...))

# 4.2 If end_value is not a Value on the given tape, we return zero
# df/fx if x is a bits type, `nothing` otherwise.  end_value may not
# be a Value if the output of f does not depend on x.

    if !isa(end_value, Value) || 0==(tapeidx=findeq(end_value.tapes, tape))
        @dbgcore("Output seems independent of input. Returning zero gradient.")
        return (isa(start_value,Number) ? zero(start_value) : nothing)
    end

    if !isa(end_value.value, Number)
        error("grad requires a scalar-valued function, got $(end_value.value)")
    end

# 4.3 backward_pass resets all node gradients except for the scalar
# output Value whose gradient is set to 1.0.  Each node has an array
# of gradients which will get summed up.

    for node in tape
        node.outgrads = []
    end
    end_value.nodes[tapeidx].outgrads = [1.0]

# Why do we need complete!(tape)?  To prevent recording during backward_pass.

    complete!(tape)

# 4.4 the tape is read in reverse and for each node with a non-empty
# outgrad its ingrads are computed using the gradient methods.

    cur_outgrad = nothing
    for node in tape[end-1:-1:1]  # note the end-1 because we pushed an eot marker
        isempty(node.outgrads) && continue
        @dbgcore((:sum1,node,:args,node.outgrads...))
        cur_outgrad = sum_outgrads(node.outgrads)
        @dbgcore((:sum2,node,:out,cur_outgrad))
        for i=1:length(node.parents)
            @dbgcore((:back1,cur_outgrad))
            isassigned(node.parents,i) || continue
            parent = node.parents[i]
            v = node.value
            og = v.func(Grad{i},cur_outgrad,v.value,v.args...;v.kwargs...)
            push!(parent.outgrads, og)
            @dbgcore((:back2,og))
        end
    end

# 4.5 the last outgrad is returned.  How do we know this is the
# correct gradient df/dx?  Only x and its descendents are marked as
# Values and recorded on the tape. In the beginning the only non-empty
# outgrad is the one for the end_value.  Since the end_value is a
# boxed Value (otherwise we returned 0/nothing), it must depend on
# input x.  The input is the first thing recorded on tape by
# forward_pass, thus will be the last thing whose gradient is seen.
# If there are Values influenced by x but do not influence the
# end_value, their outgrads will remain empty, thus only the necessary
# gradients are computed.  But let's test for it anyway.

    isempty(tape[1].outgrads) && error("Output independent of input?")
    return cur_outgrad
end

# back deps: getval, complete!, sum_outgrads


# 5. How recording is done.

# 5.1 Value: g=grad(f) calls forward_pass which calls f with one
# argument boxed in a Value type.  The primitives inside f call their
# recorder methods when one of their arguments is a Value.  The results
# of these recorder methods are also boxed in Value types, which will
# cause downstream primitives to be recorded as well.  The final
# output of f, if not independent of the input, will thus be a Value.

# 5.2 Node: Each result Value created by a primitive keeps track of
# the function and the arguments that created the Value.  Because a
# Value may need to be recorded in multiple tapes for higher order
# derivatives (see Sec. 7) these dependencies are kept in a separate
# data structure called a Node.  The parents field of a Node is an
# array that points to the Nodes of the arguments.  The gradient wrt
# the result is kept in the outgrads field.  outgrads is an array
# because a node can have multiple descendents each of which will push
# a gradient to outgrads to be summed.

# 5.3 Tape: When forward_pass is done, we have the computation graph
# (dependency tree) of the result recorded in Nodes.  However we also
# need the time order in which these Nodes were created for the
# backward_pass.  The gradient functions of all the children of a node
# need to be called before its own gradient function.  For example if
# z depends on x and y, and y depends on x, we want to compute the
# gradients in z-y-x order.  If we do it in z-x-y order, the gradient
# function of x will be called before its descendent y.  Thus we keep
# a Tape which is an array of Nodes in the order they were created.

if !isdefined(:Node)
type Node
    value
    parents::Vector{Node}
    outgrads::Vector
    Node(v) = new(v, Array(Node,length(v.args)))
end #type

typealias Tape Vector{Node}

type Value{T}
    value::T
    func::Function
    args::Tuple
    kwargs::Vector
    tapes::Vector{Tape}
    nodes::Vector{Node}
end # type Value{T}

function Value(value, tape::Tape=Tape(); func=rand, args=(), kwargs=[])
    self = Value(value,func,args,kwargs,Tape[tape],Array(Node,1))
    node = Node(self)
    push!(tape,node)
    self.nodes[1] = node
    return self
end

# Primitives with Value arguments may be called during the
# backward_pass. We do not want those primitives being recorded any
# more (at least on the tape created by the corresponding
# forward_pass, see Sec 7 for details).  We stop the recording on a
# Tape by calling its complete! method.

let eot = Node(Value(nothing))
    global iscomplete, complete!
    iscomplete(a::Tape)=(!isempty(a) && a[end]===eot)
    complete!(a::Tape)=push!(a,eot)
end

end # if !isdefined(:Node)


# 6. How new primitives and their gradients are defined.

# 6.1 Primitives

# AutoGrad primitives record their actions when they are called with
# some arguments boxed in Values (However, see 6.3 for
# undifferentiable primitives). Julia supports multiple dispatch,
# i.e. a single function can have multiple methods with different arg
# types.  AutoGrad supports multiple dispatch for primitives and
# gradients, i.e. only some of the methods of a function can be
# defined as primitives and have gradients.  Calls to a particular
# method where some arguments are boxed in Values are directed to the
# recorder function. The following example makes `sin(x::Number)` a
# primitive, but says nothing about e.g. `sin(x::Array)`.

#     local sin_r = recorder(sin)
#     sin{T<:Number}(x::Value{T}) = sin_r(x)

# With multiple arguments, things get a bit more complicated.  There
# is no easy way to say "at least one argument is a Value" in Julia.
# So one must define methods for all 2^N-1 combinations for
# boxed/unboxed arguments to be safe.  This example makes
# hypot(x1::Array,x2::Array) a primitive:

#     local hypot_r = recorder(hypot)
#     hypot{T<:Array,S<:Array}(x1::Value{T},x2::Value{S})=hypot_r(x1,x2)
#     hypot{T<:Array,S<:Array}(x1::Value{T},x2::S)=hypot_r(x1,x2)
#     hypot{T<:Array,S<:Array}(x1::T,x2::Value{S})=hypot_r(x1,x2)

# I wrote the @primitive macro in util.jl to automate this process.
# One restriction is the inability to target parametric methods such
# as `f{T<:Number}(AbstractArray{T})`.  Julia does not support
# `f{T<:Number,A<:AbstractArray{T}}(Value{A})` yet.

# One could also choose to be lazy and just say:

#     hypot(x...) = hypot_r(x...)

# This would send any argument combination not covered by regular
# hypot methods to the recorder function, which presumably includes
# calls with boxed arguments.  This is dangerous for several reasons:
# (1) the Julia base may contain a typeless method (e.g. it does for
# `vcat`) we are overwriting. (2) this catches boxed calls to hypot
# methods we may not support yet.  So generally I would not recommend
# it.

# 6.2 Gradients

if !isdefined(:Grad)
"Grad{N} creates a type used by AutoGrad to represent the gradient wrt N'th arg."    
immutable Grad{N}; end
end

# In AutoGrad, gradients are defined using gradient methods that have
# the following signature:

#     f(Grad{i},dy,y,x...) => dx[i]

# Here `f` is the name of original function, Grad{i} is a Type
# constant that specifies the gradient wrt the i'th argument, `dy` is
# the gradient wrt the output `y`, and `x...` are the input arguments.
# In this case `f` was originally called with `f(x...)` and returned
# `y`.  Somebody handed us the gradient `dy` wrt the output and
# `f(Grad{i},...)` above is going to give us the gradient `dx[i]` wrt
# the i'th argument.

# Note that type declarations on the x's can be used to specialize
# this gradient to any method of the function `f`.  Here is the
# gradient for `sin`:

# `sin{T<:Number}(::Type{Grad{1}}, dy, y, x::Value{T})=dy*cos(x)

# For the second example a different gradient method is needed for
# each argument:

# `hypot{T<:Array,S<:Array}(::Type{Grad{1}},dy,y,x1::Value{T},x2::Value{S})=(dy.*x1./y)`
# `hypot{T<:Array,S<:Array}(::Type{Grad{2}},dy,y,x1::Value{T},x2::Value{S})=(dy.*x2./y)`

# And of course we need four more definitions for the other
# boxed/unboxed argument combinations, which the @primitive macro
# generates automatically.

# Finally, there are three cases of zero gradients that need to be
# handled:

# 6.3 Undifferentiable functions

# Piecewise constant functions such as `sign`, and non-numeric
# functions such as `size` are not differentiable wrt any of their
# arguments.  Unlike primitives, these functions do not need to record
# their action or return a boxed Value.  They can just unbox their
# arguments and return an unboxed value:

# `size(a::Value,i...)=size(a.value,i...)`

# The @zerograd macro defined in util.jl can be used to automate this.

# 6.4 Undifferentiable wrt unboxed arguments

# Methods such as `sum(a::Array,i::Int)` are only differentiable wrt
# some of their arguments (here `a` but not `i`).  These methods must
# record when their differentiable argument(s) are boxed and return
# boxed values.  If we are certain that their undifferentiable
# arguments are never going to be boxed, we can leave their gradients
# undefined:

#     local sum_r = recorder(sum)
#     sum{T<:Array}(a::Value{T},i::Int)=sum_r(a,i)
#     sum{T<:Array}(::Type{Grad{1}},dy,y,a::Value{T},i::Int)=dy.+zeros(a)

# 6.5 Undifferentiable wrt boxed arguments

# Finally, in the rare cases when an undifferentiable argument can be
# boxed, its gradient must be defined and must return 0.  The utility
# function `ungetindex` in intefaces.jl which uses its first
# argument's shape as a template is one example of this rare class.


# 7. How higher order gradients work.

# Say g=grad(f) and h=grad(g) and we call h(x).
# h(x) calls forward_pass(g,x), which wraps x in v1=Value(x,t1:n1) and calls g(v1).
# merge_tapes in forward_pass(g,x) is a noop because x is not a Value.
# g(v1) calls forward_pass(f,v1), which creates v2=Value(x,t2:n2)
# merge_tapes in forward_pass(f,v1) creates v3=Value(x,[t1:n31,t2:n32]) with pointers n31->n1, n32->n2.
# forward_pass(f,v1) calls f(v3)
# ops in f(v3) push their results on [t1,t2] and record gradfuns and parents on each tape separately.
# f(v3) returns v4=Value(y,[t1:n41,t2:n42]).
# g(v1) calls backward_pass(f)(v2,v4,t2).
# backward_pass(f) calls complete!(t2) and starts processing the nodes on t2 in reverse.
# the nodes on t2 only point to other nodes in t2, so backward_pass(f) fills outgrads on t2.
# backward_pass(f) calls gradfuns recorded by ops in f(v3).
# these gradfuns are defined generically like f, they can handle regular or Value input.
# a gradfun is a closure (dy->dx) with an environment (x,y).  dy may be a Value or value, (x,y) are typically Values recorded during the call.
# the operations of gradfuns are recorded only on t1, that is why we need iscomplete(t2) once we start backward_pass on t2.
# backward_pass(f) returns v5=Value(df/dx,t1:n5) which becomes the output of forward_pass(g,x)
# h(x) calls backward_pass(g)(v1,v5,t1).
# backward_pass(g) calls gradfuns recorded in t1.
# even though some inputs are Values again, nothing gets recorded and all primitives return values because t1 is complete.
# backward_pass(g) returns a regular value which becomes the output of h(x).


# 8. Support functions.

# These are helper functions used in forward_pass, backward_pass, and
# recorder.  We need to be careful about whether they take or return
# Values and record their gradients.  merge_tapes, sum_outgrads are defined as primitives.

# 8.1 Value, getval: these box, unbox, and float values.

"getval(x) unboxes x if it is a Value, otherwise returns x."
getval(x) = (if isa(x, Value); x.value; else; x; end)  # we never create Value(Value).

# 8.2 merge_tapes: Used by forward_pass to support higher order
# gradients. Records its operation if both its arguments are Values.
# Its first argument is a newly created Value.  Its second argument is
# the original input argument, which is only a Value if this is a
# higher order gradient, in which case it is a Value that belongs to
# another tape and merge_tapes in effect creates a third Value on both
# tapes that point to their respective parent Values.  If the second
# argument is not a Value, simply returns its first arg without
# recording anything.

merge_tapes(a,b)=a
merge_tapes_r = recorder(merge_tapes)
merge_tapes(a::Value,b::Value)=merge_tapes_r(a,b)
# The derivatives simply pass the gradients back.
merge_tapes(::Type{Grad{1}},d,c,a,b) = d
merge_tapes(::Type{Grad{2}},d,c,a,b) = d


# 8.3 gradient makers like merge_tapes(::D1,c,a,b) and gradfuns they return

# The gradmakers don't record even when their input is a Value, is that
# a problem?  Let's think about this.  gradmakers are only run during
# forward call of primitives to generate a gradfun.  They are always
# run with Value arguments.  However their output is a Function,
# i.e. does not have a gradient, so they do not need to be recorded
# even though they have Value arguments.  A gradfun is run by back to
# compute dx from dy.  It is a composite function with a single
# argument dy and closure variables (x,y).  These may be Values, in
# which case boxing and unboxing will be performed by the primitives
# used in gradfun.

# The gradfun operations will only be recorded for high order
# gradients where the higher order tape is not closed.  If the tapes
# are closed (in the final backward_pass), no recording will be done
# and a regular value will be returned even if some of the inputs are
# Values.


# 8.4 sum_outgrads: only used in backward_pass to produce the input to
# a gradient function df/dy.  Does it ever need to record its
# operation and give a Value output?  Gradient functions are closures
# that take df/dy, return df/dx and have the environment (x,y) which
# is the original input/output and almost certainly Values.  The input
# df/dy may or may not be a Value.  If we encounter a Value with an open
# tape, we need to record the sum operation.  This will happen in
# higher order derivatives.

# A: what if first outgrad is a Value and others aren't, or vice versa?  handled by @primitive.
# A: what should the output be if some of the inputs are Values?  Is sum_outgrads a primitive? No, its input is never a Value, maybe an array including Values.  Its helper is a primitive.
# A: for array and dict can we just modify the first element of outgrads?  This may be dangerous because the same outgrad may be passed back to more than one target e.g. by `+`.

# TODO: Instead of maintaining an array of outgrads then summing them, why not keep a sum to avoid allocation?
# (instead of pushing to parent.outgrads, we'd have to call sum directly, deal with Values etc.)
# However before we can do this we need to handle overwriting ops because sum_outgrads is a primitive.

function sum_outgrads(x)
    length(x) == 0 && return nothing
    length(x) == 1 && return x[1]
    a = remove_nothings(x)
    length(a) == 0 && return nothing
    length(a) == 1 && return a[1]
    sum_helper(a...)
end

sum_helper(a::Number, b::Number, c::Number...)=sum([a,b,c...])
sum_helper(a::Tuple, b::Tuple, c::Tuple...)=tuple([sum_outgrads(e) for e in zip(a,b,c...)]...)
sum_helper{T}(a::AbstractArray{T},b::AbstractArray{T},c::AbstractArray{T}...) =
    (isbits(T) ? broadcast(+,a,b,c...) : [sum_outgrads(e) for e in zip(a,b,c...)])
sum_helper(a::Associative, b::Associative, c::Associative...) =
    (z=similar(a); for d in (a,b,c...), (k,v) in d; z[k]=v+get(z,k,0); end; z)

sum_helper_r = recorder(sum_helper)
sum_helper(x...)=sum_helper_r(x...)
sum_helper{N}(::Type{Grad{N}}, dy, y, x...)=dy

function remove_nothings(x)
    a = []
    for xi in x
        isa(xi,Void) || push!(a,xi)
    end
    return a
end

# TODO: check if we really need tofloat.
# converts nested values to float.
# tofloat uses float for Number and AbstractArray (for isleaftype)
tofloat(x::Number)=float(x)
tofloat{T<:Number}(x::AbstractArray{T})=float(x)
# tofloat extends to Tuple, Associative, and arbitrary Arrays
tofloat(x::Tuple)=(all(isfloat,x) ? x : ntuple(i->tofloat(x[i]), length(x)))
tofloat(x::Associative)=(all(isfloat,values(x)) ? x : (a=similar(x); for (k,v) in x; a[k]=tofloat(v); end; a))
tofloat(x::AbstractArray)=(all(isfloat,x) ? x : map(tofloat,x))
isfloat(x)=isa(x,AbstractFloat)

# findfirst uses == which is inefficient for tapes, so we define findeq with ===
function findeq(A,v)
    for i=1:length(A)
        if A[i] === v
            return i
        end
    end
    return 0
end
