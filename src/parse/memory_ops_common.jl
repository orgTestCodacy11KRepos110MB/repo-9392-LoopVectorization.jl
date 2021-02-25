dottosym(x) = x
dottosym(x::Expr) = Symbol(dottosym(x.args[1]), "###extractarray###", x.args[2].value)
function extract_array_symbol_from_ref!(ls::LoopSet, ex::Expr, offset1::Int)::Symbol
    ar = ex.args[1 + offset1]
    if isa(ar, Symbol)
        return ar
    elseif isa(ar, Expr) && ar.head === :(.)
        s = dottosym(ar)
        pushprepreamble!(ls, Expr(:(=), s, ar))
        return s
    else
        throw("Indexing into the following expression was not recognized: $ar")
    end
end


function ref_from_expr!(ls, ex, offset1::Int, offset2::Int)
    ar = extract_array_symbol_from_ref!(ls, ex, offset1)
    ar, @view(ex.args[2 + offset2:end])
end
ref_from_ref!(ls::LoopSet, ex::Expr) = ref_from_expr!(ls, ex, 0, 0)
ref_from_getindex!(ls::LoopSet, ex::Expr) = ref_from_expr!(ls, ex, 1, 1)
ref_from_setindex!(ls::LoopSet, ex::Expr) = ref_from_expr!(ls, ex, 1, 2)
function ref_from_expr!(ls::LoopSet, ex::Expr)
    if ex.head === :ref
        ref_from_ref!(ls, ex)
    else#if ex.head === :call
        f = first(ex.args)::Symbol
        f === :getindex ? ref_from_getindex!(ls, ex) : ref_from_setindex!(ls, ex)
    end
end

add_vptr!(ls::LoopSet, op::Operation) = add_vptr!(ls, op.ref)
add_vptr!(ls::LoopSet, mref::ArrayReferenceMeta) = add_vptr!(ls, mref.ref.array, vptr(mref))
# using VectorizationBase: noaliasstridedpointer
function add_vptr!(ls::LoopSet, array::Symbol, vptrarray::Symbol, actualarray::Bool = true, broadcast::Bool = false)
    if !includesarray(ls, array)
        push!(ls.includedarrays, array)
        actualarray && push!(ls.includedactualarrays, array)
        func = lv(broadcast ? :stridedpointer_for_broadcast : :stridedpointer)
        pushpreamble!(ls, Expr(:(=), vptrarray, Expr(:call, func, array)))
        # if broadcast
        #     pushpreamble!(ls, Expr(:(=), vptrarray, Expr(:call, lv(:stridedpointer_for_broadcast), array)))
        # else
        #     pushpreamble!(ls, Expr(:(=), vptrarray, Expr(:call, lv(:stridedpointer), array)))
        #     # pushpreamble!(ls, Expr(:(=), vptrarray, Expr(:call, lv(:noaliasstridedpointer), array)))
        # end
    end
    nothing
end

# @inline valsum() = Val{0}()
# @inline valsum(::Val{M}) where {M} = Val{M}()
# @generated valsum(::Val{M}, ::Val{N}) where {M,N} = Val{M+N}()
# @inline valsum(::Val{M}, ::Val{N}, ::Val{K}, args...) where {M,N,K} = valsum(valsum(Val{M}(), Val{N}()), Val{K}(), args...)
@inline staticdims(::Any) = One()
@inline staticdims(::CartesianIndices{N}) where {N} = StaticInt{N}()

function append_loop_staticdims!(valcall::Expr, loop::Loop)
    if isstaticloop(loop)
        push!(valcall.args, staticexpr(1))
    else
        push!(valcall.args, Expr(:call, lv(:staticdims), loop.rangesym))#loop_boundary(loop)))
    end
    nothing
end
function subset_vptr!(ls::LoopSet, vptr::Symbol, indnum::Int, ind, previndices, loopindex)
    subsetvptr = Symbol(vptr, "_subset_$(indnum)_with_$(ind)##")
    valcall = staticexpr(1)
    if indnum > 1
        offset = first(previndices) === DISCONTIGUOUS
        valcall = Expr(:call, :(+), valcall)
        for i ∈ 1:indnum-1
            loopdep = if loopindex[i]
                previndices[i+offset]
            else
                # assumes all staticdims will be of equal length once expanded...
                # A[I + J, constindex], I and J may be CartesianIndices. This requires they all be of same number of dims
                first(loopdependencies(ls.opdict[previndices[i+offset]]))
            end
            append_loop_staticdims!(valcall, getloop(ls, loopdep))
        end
    end
    # indm1 = ind isa Integer ? ind - 1 : Expr(:call, :-, ind, 1)
    pushpreamble!(ls, Expr(:(=), subsetvptr, Expr(:call, lv(:subsetview), vptr, valcall, ind)))
    subsetvptr
end
byterepresentable(x)::Bool = false
byterepresentable(x::Integer)::Bool = typemin(Int8) < x < typemax(Int8)
function _addoffset!(indices, offsets, strides, loopedindex, loopdependencies, ind, offset, stride)
    push!(indices, ind)
    push!(offsets, offset % Int8)
    push!(strides, stride)
    push!(loopedindex, true)
    push!(loopdependencies, ind)
    true
end

function addoffset_index!(
    indices::Vector{Symbol}, offsets::Vector{Int8}, strides::Vector{Int8}, loopedindex::Vector{Bool},
    loopdependencies::Vector{Symbol}, ind::Symbol, offset, stride
)::Bool
    byterepresentable(offset) || return false
    _addoffset!(indices, offsets, strides, loopedindex, loopdependencies, ind, offset, stride)
end

function addconstindex!(indices, offsets, strides, loopedindex, offset)
    push!(indices, CONSTANTZEROINDEX)
    push!(offsets, (offset-1) % Int8)
    push!(strides, zero(Int8))
    push!(loopedindex, true)
    true
end

# The search for multipliers is recursive
# TODO: make the search for increments recursive as well.
function addoffsetexpr!(
    ls::LoopSet, parents::Vector{Operation}, indices, offsets, strides, loopedindex,
    loopdependencies::Vector{Symbol}, reduceddeps::Vector{Symbol}, ind, offset, stride::Int, elementbytes
)::Bool
    byterepresentable(offset) || return false
    if isexpr(ind, :call, 3) && ind.args[1] === :(*)
        arg1 = ind.args[2]
        arg2 = ind.args[3]
        arg1int = arg1 isa Integer
        arg2int = arg2 isa Integer
        if arg1int
            arg1f::Int = convert(Int, arg1*stride)
            if arg2int
                newoff = convert(Int, arg1f * arg2 + offset)::Int
                if byterepresentable(newoff)
                    return addconstindex!(indices, offsets, strides, loopedindex, offset)
                end
            elseif byterepresentable(arg1f)
                if (arg2 isa Symbol) && (arg2 ∈ ls.loopsymbols)
                    return _addoffset!(indices, offsets, strides, loopedindex, loopdependencies, arg2, offset, arg1f)
                else
                    return addoffsetexpr!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, arg2, offset, arg1f, elementbytes)
                end
            end
        elseif arg2int
            arg2f::Int = convert(Int, arg2*stride)
            if byterepresentable(arg2f)
                if (arg1 isa Symbol) && (arg1 ∈ ls.loopsymbols)
                    return _addoffset!(indices, offsets, strides, loopedindex, loopdependencies, arg1, offset, arg2f)
                else
                    return addoffsetexpr!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, arg1, offset, arg2f, elementbytes)
                end
            end                        
        end
    end
    parent = if ind isa Expr
        add_operation!(ls, gensym!(ls, "indexpr"), ind, elementbytes, length(ls.loopsymbols))
    else
        getop(ls, ind, elementbytes)
    end
    pushparent!(parents, loopdependencies, reduceddeps, parent)
    push!(indices, name(parent));
    push!(offsets, offset % Int8)
    push!(strides, stride % Int8)
    push!(loopedindex, false)
    true
end

function checkforoffset!(
    ls::LoopSet, parents::Vector{Operation}, indices::Vector{Symbol}, offsets::Vector{Int8}, strides::Vector{Int8},
    loopedindex::Vector{Bool}, loopdependencies::Vector{Symbol}, reduceddeps::Vector{Symbol}, ind::Expr, elementbytes::Int
)
    ind.head === :call || return false
    f = first(ind.args)
    # if f === :add_fast
    # elseif f === :sub_fast
    # elseif f === :mul_fast
    # elseif f === :vfmadd_fast
    # elseif f === :vfnmadd_fast
    # elseif f === :vfmsub_fast
    # elseif f === :vfnmsub_fast
    # else
    #     return false
    # end
    factor = f === :+ ? 1 : -1
    if !(((f === :+) || (f === :-)) && (length(ind.args) == 3))
        if (f === :*)
            # offset 0, reuse that code
            return addoffsetexpr!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, ind, 0, 1, elementbytes)
        else
            return false
        end
    end
    arg1 = ind.args[2]
    arg2 = ind.args[3]
    if arg1 isa Integer
        # 3 + factor * i
        if arg2 isa Symbol
            if arg2 ∈ ls.loopsymbols
                addoffset_index!(indices, offsets, strides, loopedindex, loopdependencies, arg2, arg1, factor)
            else
                addoffsetexpr!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, arg2, arg1, factor, elementbytes)
            end
        elseif arg2 isa Expr
            addoffsetexpr!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, arg2, arg1, factor, elementbytes)
        else
            false
        end
    elseif arg2 isa Integer
        # i + factor * arg2
        if arg1 isa Symbol
            if arg1 ∈ ls.loopsymbols
                addoffset_index!(indices, offsets, strides, loopedindex, loopdependencies, arg1, arg2 * factor, 1)
            else
                addoffsetexpr!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, arg1, arg2 * factor, 1, elementbytes)
            end
        elseif arg1 isa Expr
            addoffsetexpr!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, arg1, arg2 * factor, 1, elementbytes)
        else
            false
        end
    else
        false
    end
end

function move_to_last!(x, i)
    i == length(x) && return
    xᵢ = x[i]
    deleteat!(x, i)
    push!(x, xᵢ)
    nothing
end
# TODO: Make this work with Cartesian Indices
function repeated_index!(ls::LoopSet, indices::Vector{Symbol}, vptr::Symbol, indnum::Int, firstind::Int)
    # Move ind to last position
    vptrrepremoved = Symbol(vptr, "##ind##", firstind, "##repeated##", indnum, "##")
    f = Expr(:(.), Expr(:(.), :LoopVectorization, QuoteNode(:VectorizationBase)), QuoteNode(:double_index))
    fiv = Expr(:call, Expr(:curly, :Val, firstind - 1))
    siv = Expr(:call, Expr(:curly, :Val, indnum - 1))
    pushpreamble!(ls, Expr(:(=), vptrrepremoved, Expr(:call, f, vptr, fiv, siv)))
    vptrrepremoved
end

function array_reference_meta!(ls::LoopSet, array::Symbol, rawindices, elementbytes::Int, var::Union{Nothing,Symbol} = nothing)
    vptrarray = vptr(array)
    add_vptr!(ls, array, vptrarray) # now, subset
    indices = Symbol[]
    offsets = Int8[]
    strides = Int8[]
    loopedindex = Bool[]
    parents = Operation[]
    loopdependencies = Symbol[]
    reduceddeps = Symbol[]
    loopset = ls.loopsymbols
    ninds = 1
    for ind ∈ rawindices
        if ind isa Integer # subset
            if byterepresentable(ind)
                addconstindex!(indices, offsets, strides, loopedindex, ind)
            else
                vptrarray = subset_vptr!(ls, vptrarray, ninds, ind, indices, loopedindex)
                length(indices) == 0 && push!(indices, DISCONTIGUOUS)
            end
        elseif ind isa Expr
            #FIXME: position (in loopnest) wont be length(ls.loopsymbols) in general
            if !checkforoffset!(ls, parents, indices, offsets, strides, loopedindex, loopdependencies, reduceddeps, ind, elementbytes)
                parent = add_operation!(ls, gensym!(ls, "indexpr"), ind, elementbytes, length(ls.loopsymbols))
                pushparent!(parents, loopdependencies, reduceddeps, parent)
                push!(indices, name(parent));
                push!(offsets, zero(Int8))
                push!(strides, one(Int8))
                push!(loopedindex, false)
            end
            ninds += 1
        elseif ind isa Symbol
            if ind ∈ loopset
                ind_prev_index = findfirst(isequal(ind), indices)
                if ind_prev_index === nothing
                    push!(indices, ind); ninds += 1
                    push!(offsets, zero(Int8))
                    push!(strides, one(Int8))
                    push!(loopedindex, true)
                    push!(loopdependencies, ind)
                else
                    move_to_last!(indices, ind_prev_index)
                    move_to_last!(offsets, ind_prev_index)
                    move_to_last!(strides, ind_prev_index)
                    move_to_last!(loopedindex, ind_prev_index)
                    move_to_last!(loopdependencies, ind_prev_index)
                    vptrarray = repeated_index!(ls, indices, vptrarray, ninds, ind_prev_index + (first(indices) === DISCONTIGUOUS))
                    makediscontiguous!(indices)
                end
            else
                indop = get(ls.opdict, ind, nothing)
                if indop !== nothing  && !isconstant(indop)
                    pushparent!(parents, loopdependencies, reduceddeps, indop)
                    push!(indices, name(indop)); ninds += 1
                    push!(offsets, zero(Int8))
                    push!(loopedindex, false)
                else
                    vptrarray = subset_vptr!(ls, vptrarray, ninds, ind, indices, loopedindex)
                    length(indices) == 0 && push!(indices, DISCONTIGUOUS)
                end
            end
        else
            throw("Unrecognized loop index: $ind.")
        end
    end
    mref = ArrayReferenceMeta(ArrayReference( array, indices, offsets, strides ), loopedindex, vptrarray)
    ArrayReferenceMetaPosition(mref, parents, loopdependencies, reduceddeps, var === nothing ? Symbol("") : var )
end
function tryrefconvert(ls::LoopSet, ex::Expr, elementbytes::Int, var::Union{Nothing,Symbol} = nothing)::Tuple{Bool,ArrayReferenceMetaPosition}
    ya, yinds = if ex.head === :ref
        ref_from_ref!(ls, ex)
    elseif ex.head === :call
        f = first(ex.args)
        if f === :getindex
            ref_from_getindex!(ls, ex)
        elseif f === :setindex!
            ref_from_setindex!(ls, ex)
        else
            return false, NOTAREFERENCEMP
        end
    else
        return false, NOTAREFERENCEMP
    end
    true, array_reference_meta!(ls, ya, yinds, elementbytes, var)
end