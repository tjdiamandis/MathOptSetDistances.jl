
function FiniteDifferences.to_vec(s::S) where {S <: Union{MOI.EqualTo, MOI.LessThan, MOI.GreaterThan}}
    function set_from_vec(v)
        return S(v[1])
    end
    return [MOI.constant(s)], set_from_vec
end

function ChainRulesCore.rrule(::typeof(projection_on_set), d::DefaultDistance, v::T, s::MOI.EqualTo) where {T}
    vproj = projection_on_set(d, v, s)
    function pullback(Δvproj)
        return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), ChainRulesCore.Zero(), ChainRulesCore.Composite{typeof(s)}(value=Δvproj))
    end
    return (vproj, pullback)
end

function ChainRulesCore.rrule(::typeof(projection_on_set), d::DefaultDistance, v::T, s::MOI.LessThan) where {T}
    vproj = projection_on_set(d, v, s)
    function pullback(Δvproj)
        if vproj == v # if exactly equal, then constraint inactive
            return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), Δvproj, ChainRulesCore.Composite{typeof(s)}(upper=zero(Δvproj)))
        end
        return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), zero(Δvproj), ChainRulesCore.Composite{typeof(s)}(upper=Δvproj))
    end
    return (vproj, pullback)
end

function ChainRulesCore.rrule(::typeof(projection_on_set), d::DefaultDistance, v::T, s::MOI.GreaterThan) where {T}
    vproj = projection_on_set(d, v, s)
    function pullback(Δvproj)
        if vproj == v # if exactly equal, then constraint inactive
            return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), Δvproj, ChainRulesCore.Composite{typeof(s)}(lower=zero(Δvproj)))
        end
        return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), zero(Δvproj), ChainRulesCore.Composite{typeof(s)}(lower=Δvproj))
    end
    return (vproj, pullback)
end

function ChainRulesCore.rrule(::typeof(projection_on_set), d::DefaultDistance, v::AbstractVector{T}, s::MOI.Reals) where {T}
    vproj = projection_on_set(d, v, s)
    function pullback(Δvproj)
        return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), Δvproj, ChainRulesCore.DoesNotExist())
    end
    return (vproj, pullback)
end

function ChainRulesCore.rrule(::typeof(projection_on_set), d::DefaultDistance, v::AbstractVector{T}, s::MOI.Zeros) where {T}
    vproj = projection_on_set(d, v, s)
    function pullback(Δvproj)
        return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), FillArrays.Zeros(length(v)), ChainRulesCore.DoesNotExist())
    end
    return (vproj, pullback)
end

function ChainRulesCore.rrule(::typeof(projection_on_set), d::DefaultDistance, v::AbstractVector{T}, s::S) where {T, S <: Union{MOI.Nonnegatives, MOI.Nonpositives}}
    vproj = projection_on_set(d, v, s)
    function pullback(Δvproj)
        v̄ = zeros(eltype(Δvproj), length(Δvproj))
        for i in eachindex(Δvproj)
            if vproj[i] == v[i]
                v̄[i] = Δvproj[i]
            end
        end
        return (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), v̄, ChainRulesCore.DoesNotExist())
    end
    return (vproj, pullback)
end

function ChainRulesCore.rrule(::typeof(projection_on_set), d::Union{DefaultDistance, NormedEpigraphDistance}, v::AbstractVector{T}, s::MOI.SecondOrderCone) where {T}
    vproj = projection_on_set(d, v, s)
    t = v[1]
    x = v[2:end]
    norm_x = LinearAlgebra.norm2(x)
    function projection_on_set_pullback(Δv)
        Δt = Δv[1]
        Δx = Δv[2:end]
        v̄ = zeros(eltype(Δv), length(Δv))
        result_tuple = (ChainRulesCore.NO_FIELDS, ChainRulesCore.DoesNotExist(), v̄, ChainRulesCore.DoesNotExist())
        if norm_x ≤ t
            v̄ .= Δv
            return result_tuple
        elseif norm_x ≤ -t
            return result_tuple
        end
        inv_norm = inv(2norm_x)
        v̄[1] = inv_norm * sum(Δx[i] * x[i] for i in eachindex(x)) + Δt / 2
        dot_prod = LinearAlgebra.dot(x, Δx)
        inv_sq = inv(norm_x^2)
        cons_mul_last = inv_norm * inv_sq * t * x ⋅ Δx
        for i in eachindex(x)
            v̄[i+1] = inv_norm * Δt * x[i]
            v̄[i+1] += inv_norm * (t + norm_x) * Δx[i]
            v̄[i+1] -= cons_mul_last * x[i]
        end
        return result_tuple
    end
    return (vproj, projection_on_set_pullback)
end

function ChainRulesCore.frule((_, _, Δv, _), ::typeof(projection_on_set), d::DefaultDistance, v::AbstractVector{T}, s::MOI.PositiveSemidefiniteConeTriangle) where {T}
    dim = isqrt(2*length(v))
    X = unvec_symm(v, dim)
    (λ, U) = LinearAlgebra.eigen(X)
    λmin, λmax = extrema(λ)
    if λmin >= 0
        return (v, Δv)
    end
    if λmax <= 0
        # v zero vector
        return (0 * v, 0 * Δv)
    end
    λp = max.(0, λ)
    vproj = vec_symm(U * Diagonal(λp) * U')
    k = count(λi < 1e-4 for λi in λ)
    # TODO avoid full matrix materialize
    B = zeros(eltype(λ), dim, dim)
    for i in 1:dim, j in 1:dim
        if i > k && j > k
            B[i,j] = 1
        elseif i > k
            B[i,j] = λp[i] / (λp[i] - min(λ[j], 0))
        elseif j > k
            B[i,j] = λp[j] / (λp[j] - min(λ[i], 0))
        end
    end
    M = U * (B .* (U' * unvec_symm(Δv, dim) * U)) * U'
    Δvproj = vec_symm(M)
    return (vproj, Δvproj)
end
