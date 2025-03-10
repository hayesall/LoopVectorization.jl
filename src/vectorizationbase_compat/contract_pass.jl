
mulexprcost(::Number) = 0
mulexprcost(::Symbol) = 1
function mulexprcost(ex::Expr)
    base = ex.head === :call ? 10 : 1
    base + length(ex.args)
end
function mul_fast_expr(args)
    b = Expr(:call, :mul_fast)
    for i ∈ 2:length(args)
        push!(b.args, args[i])
    end
    b
end
function mulexpr(mulexargs)
    a = (mulexargs[1])::Union{Symbol,Expr,Number}
    if length(mulexargs) == 2
        return (a, mulexargs[2]::Union{Symbol,Expr,Number})
    elseif length(mulexargs) == 3
        # We'll calc the product between the guesstimated cheaper two args first, for better out of order execution
        b = (mulexargs[2])::Union{Symbol,Expr,Number}
        c = (mulexargs[3])::Union{Symbol,Expr,Number}
        ac = mulexprcost(a)
        bc = mulexprcost(b)
        cc = mulexprcost(c)
        maxc = max(ac, bc, cc)
        if ac == maxc
            return (a, Expr(:call, :mul_fast, b, c))
        elseif bc == maxc
            return (b, Expr(:call, :mul_fast, a, c))
        else
            return (c, Expr(:call, :mul_fast, a, b))
        end
    else
        return (a, mul_fast_expr(mulexargs))
    end
    a = (mulexargs[1])::Union{Symbol,Expr,Number}
    b = if length(mulexargs) == 2 # two arg mul
        (mulexargs[2])::Union{Symbol,Expr,Number}
    else
        mul_fast_expr(mulexargs)
    end
    a, b
end
function append_args_skip!(call, args, i, mod)
  for j ∈ eachindex(args)
    j == i && continue
    if length(call.args) < 3
      push!(call.args, args[j])
    else
      call = Expr(:call, :add_fast, call, args[j])
    end
  end
  call
end

function fastfunc(f)
  i = findfirst(Base.Fix2(===,f), (:sin,:cos,:sincos))
  if i === nothing
    get(VectorizationBase.FASTDICT, f, f)
  else
    (:sin_fast,:cos_fast,:sincos_fast)[i]
  end
end
function muladd_arguments!(argv, mod, f = first(argv))
    if f === :*
        argv[1] = :mul_fast
    else
        argv[1] = fastfunc(f)
    end
    for i ∈ 2:length(argv)
        a = argv[i]
        a isa Expr || continue
        argv[i] = capture_muladd(a::Expr, mod)
    end
end

function recursive_muladd_search!(call, argv, mod, cnmul::Bool = false, csub::Bool = false)
  if length(argv) < 3
    muladd_arguments!(argv, mod)
    return length(call.args) == 4, cnmul, csub
  end
  fun = first(argv)
  isadd = fun === :+ || fun === :add_fast || fun === :vadd || (fun == :(Base.FastMath.add_fast))::Bool
  issub = fun === :- || fun === :sub_fast || fun === :vsub || (fun == :(Base.FastMath.sub_fast))::Bool
  if isadd
    argv[1] = :add_fast
  elseif issub
    argv[1] = :sub_fast
  else
    muladd_arguments!(argv, mod, fun)
    return length(call.args) == 4, cnmul, csub
  end
  exargs = @view(argv[2:end])
  for i ∈ eachindex(exargs)
    if exargs[i] === :Inf
      exargs[i] === Inf
    end
  end
  issub && @assert length(exargs) == 2
  for (i,ex) ∈ enumerate(exargs)
    if ex isa Expr && ex.head === :call
      exa = ex.args
      f = first(exa)
      exav = @view(exa[2:end])
      if f === :* || f === :mul_fast || f === :vmul || (f == :(Base.FastMath.mul_fast))::Bool
        a, b = mulexpr(exav)
        call.args[2] = a
        call.args[3] = b
        if length(exargs) == 2
          push!(call.args, exargs[3 -  i])
        else
          push!(call.args, append_args_skip!(Expr(:call, :add_fast), exargs, i, mod))
        end
        if issub
          csub = i == 1
          cnmul = !csub
        end
        return true, cnmul, csub
      elseif isadd
        found, cnmul, csub = recursive_muladd_search!(call, exa, mod)
        if found
          if csub
            call.args[4] = if length(exargs) == 2
              Expr(:call, :sub_fast, exargs[3 - i], call.args[4])
            else
              Expr(:call, :sub_fast, append_args_skip!(Expr(:call, :add_fast), exargs, i, mod), call.args[4])
            end
          else
            call.args[4] = append_args_skip!(Expr(:call, :add_fast, call.args[4]), exargs, i, mod)
          end
          return true, cnmul, false
        end
      elseif issub
        found, cnmul, csub = recursive_muladd_search!(call, exa, mod)
        if found
          if i == 1
            if csub
              call.args[4] = Expr(:call, :add_fast, call.args[4], exargs[3 - i])
            else
              call.args[4] = Expr(:call, :sub_fast, call.args[4], exargs[3 - i])
            end
          else
            cnmul = !cnmul
            if csub
              call.args[4] = Expr(:call, :add_fast, exargs[3 - i], call.args[4])
            else
              call.args[4] = Expr(:call, :sub_fast, exargs[3 - i], call.args[4])
            end
            csub = false
          end
          return true, cnmul, csub
        end
      end
    end
  end
  length(call.args) == 4, cnmul, csub
end

function capture_a_muladd(ex::Expr, mod)
  call = Expr(:call, Symbol(""), Symbol(""), Symbol(""))
  found, nmul, sub = recursive_muladd_search!(call, ex.args, mod)
  if !found
    if length(ex.args) > 3
      f = ex.args[1]
      if (f === :add_fast) | (f === :mul_fast)
        newex = Expr(:call, f, ex.args[2], ex.args[3])
        for i ∈ 4:length(ex.args)
          newex = Expr(:call, f, newex, ex.args[i])
        end
        ex = newex
      end
    end
    return false, ex
  end
  # found || return ex
  # a, b, c = call.args[2], call.args[3], call.args[4]
  # call.args[2], call.args[3], call.args[4] = c, a, b
  f = if nmul && sub
    :vfnmsub_fast
  elseif nmul
    :vfnmadd_fast
  elseif sub
    :vfmsub_fast
  else
    :vfmadd_fast
  end
  if mod === nothing
    call.args[1] = f
  else
    call.args[1] = Expr(:(.), mod, QuoteNote(f))#_fast))
  end
  true, call
end
function capture_muladd(ex::Expr, mod)
  while true
    ex.head === :ref && return ex
    if Meta.isexpr(ex, :call, 2)
      if (ex.args[1] === :(-))
        if (ex.args[2] isa Number)
          return -ex.args[2]
        elseif ex.args[2] === :Inf
          return -Inf
        end
      end
    end
    found, ex = capture_a_muladd(ex, mod)
    found || return ex
  end
end
function append_update_args(f::Symbol, ex::Expr)
  call = Expr(:call, f)
  for i ∈ 2:length(ex.args)
    push!(call.args, ex.args[i])
  end
  push!(call.args, ex.args[1])
  call
end
contract_pass!(::Any, ::Any) = nothing
function contract!(expr::Expr, ex::Expr, i::Int, mod)
  # if ex.head === :call
  # expr.args[i] = capture_muladd(ex, mod)
  if ex.head === :(+=)
    call = append_update_args(:add_fast, ex)
    expr.args[i] = ex = Expr(:(=), first(ex.args), call)
  elseif ex.head === :(*=)
    call = append_update_args(:mul_fast, ex)
    expr.args[i] = ex = Expr(:(=), first(ex.args), call)
  elseif Meta.isexpr(ex, :(\=), 2)
    exa1 = ex.args[1]
    call = Expr(:call, :div_fast, ex.args[2], exa1)
    expr.args[i] = ex = Expr(:(=), exa1, call)
  else
    j = findfirst(Base.Fix2(===, ex.head), (:(-=),  :(/=),  :(÷=),  :(%=),  :(^=),  :(&=),  :(|=),  :(⊻=),  :(>>>=),  :(>>=),  :(<<=)))
    if j ≢ nothing
      f = (:sub_fast,  :div_fast,  :(÷),  :(%),  :(^),  :(&),  :(|),  :(⊻),  :(>>>),  :(>>),  :(<<))[j::Int]
      call = Expr(:call, f)
      append!(call.args, ex.args)
      expr.args[i] = ex = Expr(:(=), first(ex.args), call)
    end
  end
  if ex.head === :(=)
    RHS = ex.args[2]
    if RHS isa Expr && Base.sym_in(RHS.head, (:call,:if))
      ex.args[2] = capture_muladd(RHS, mod)
    end
  end
  contract_pass!(expr.args[i], mod)
end
# contract_pass(x) = x # x will probably be a symbol
function contract_pass!(expr::Expr, mod = nothing)
    i = Core.ifelse(expr.head === :for, 1, 0)
    Nexpr = length(expr.args)
    while i < Nexpr
        _ex = expr.args[(i+=1)]
        _ex isa Expr || continue
        ex::Expr = _ex
        contract!(expr, ex, i, mod)
    end
end

