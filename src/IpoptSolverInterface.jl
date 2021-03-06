# Standard LP interface
importall MathProgBase.SolverInterface

###############################################################################
# Solver objects
export IpoptSolver
immutable IpoptSolver <: AbstractMathProgSolver
  options
end
IpoptSolver(;kwargs...) = IpoptSolver(kwargs)

type IpoptMathProgModel <: AbstractMathProgModel
  inner::Any
  options
end
function IpoptMathProgModel(;options...)
  return IpoptMathProgModel(nothing,options)
end
model(s::IpoptSolver) = IpoptMathProgModel(;s.options...)
export model

###############################################################################
# Begin interface implementation
function loadproblem!(model::IpoptMathProgModel, A, l, u, c, lb, ub, sense)
  Asparse = convert(SparseMatrixCSC{Float64,Int32}, A)
  n = int(Asparse.n)
  m = int(Asparse.m)
  nnz = int(length(Asparse.rowval))
  c_correct = float(c)
  if sense == :Max
    c_correct .*= -1.0
  end


  # Objective callback
  function eval_f(x)
    return dot(x,c_correct)
  end

  # Objective gradient callback
  function eval_grad_f(x, grad_f)
    for j = 1:n
      grad_f[j] = c_correct[j]
    end
  end

  # Constraint value callback
  function eval_g(x, g)
    g_val = A*x
    for i = 1:m
      g[i] = g_val[i]
    end
  end

  # Jacobian callback
  function eval_jac_g(x, mode, rows, cols, values)
    if mode == :Structure
      # Convert column wise sparse to triple format
      idx = 1
      for col = 1:n
        for pos = Asparse.colptr[col]:(Asparse.colptr[col+1]-1)
          rows[idx] = Asparse.rowval[pos]
          cols[idx] = col
          idx += 1
        end
      end
    else
      # Values
      idx = 1
      for col = 1:n
        for pos = Asparse.colptr[col]:(Asparse.colptr[col+1]-1)
          values[idx] = Asparse.nzval[pos]
          idx += 1
        end
      end
    end
  end

  x_L = float(l)
  x_U = float(u)
  g_L = float(lb)
  g_U = float(ub)
  model.inner = createProblem(n, x_L, x_U, m, g_L, g_U, nnz, 0,
                              eval_f, eval_g, eval_grad_f, eval_jac_g, nothing)
  model.inner.sense = sense
  addOption(model.inner, "jac_c_constant", "yes")
  addOption(model.inner, "jac_d_constant", "yes")
  addOption(model.inner, "hessian_constant", "yes")
  addOption(model.inner, "hessian_approximation", "limited-memory")
  addOption(model.inner, "mehrotra_algorithm", "yes")
  for (name,value) in model.options
    addOption(model.inner, string(name), value)
  end
end

# generic nonlinear interface
function loadnonlinearproblem!(m::IpoptMathProgModel, numVar::Integer, numConstr::Integer, x_l, x_u, g_lb, g_ub, sense::Symbol, d::AbstractNLPEvaluator)

    initialize(d, [:Grad, :Jac, :Hess])
    Ijac, Jjac = jac_structure(d)
    Ihess, Jhess = hesslag_structure(d)
    @assert length(Ijac) == length(Jjac)
    @assert length(Ihess) == length(Jhess)
    @assert sense == :Min || sense == :Max

    # Objective callback
    if sense == :Min
        eval_f_cb(x) = eval_f(d,x)
    else
        eval_f_cb(x) = -eval_f(d,x)
    end

    # Objective gradient callback
    if sense == :Min
        eval_grad_f_cb(x, grad_f) = eval_grad_f(d, grad_f, x)
    else
        eval_grad_f_cb(x, grad_f) = (eval_grad_f(d, grad_f, x); scale!(grad_f,-1))
    end


    # Constraint value callback
    eval_g_cb(x, g) = eval_g(d, g, x)

    # Jacobian callback
    function eval_jac_g_cb(x, mode, rows, cols, values)
        if mode == :Structure
            for i in 1:length(Ijac)
                rows[i] = Ijac[i]
                cols[i] = Jjac[i]
            end
        else
            eval_jac_g(d, values, x)
        end
    end

    # Hessian callback
    function eval_h_cb(x, mode, rows, cols, obj_factor,
        lambda, values)
        if mode == :Structure
            for i in 1:length(Ihess)
                rows[i] = Ihess[i]
                cols[i] = Jhess[i]
            end
        else
            if sense == :Max
                obj_factor *= -1
            end
            eval_hesslag(d, values, x, obj_factor, lambda)
        end
    end


    m.inner = createProblem(numVar, float(x_l), float(x_u), numConstr,
                                float(g_lb), float(g_ub), length(Ijac), length(Ihess),
                                eval_f_cb, eval_g_cb, eval_grad_f_cb, eval_jac_g_cb,
                                eval_h_cb)
    m.inner.sense = sense

    for (name,value) in m.options
        addOption(m.inner, string(name), value)
    end
end

getsense(m::IpoptMathProgModel) = m.inner.sense
numvar(m::IpoptMathProgModel) = m.inner.n
numconstr(m::IpoptMathProgModel) = m.inner.m
optimize!(m::IpoptMathProgModel) = solveProblem(m.inner)
function status(m::IpoptMathProgModel)
  if m.inner.status == 0 || m.inner.status == 1
    return :Optimal
  end
  return :Infeasible
end
getobjval(m::IpoptMathProgModel) = m.inner.obj_val * (m.inner.sense == :Max ? -1 : +1)
getsolution(m::IpoptMathProgModel) = m.inner.x
getconstrsolution(m::IpoptMathProgModel) = m.inner.g
getreducedcosts(m::IpoptMathProgModel) = zeros(m.inner.n)
getconstrduals(m::IpoptMathProgModel) = zeros(m.inner.m)
getrawsolver(m::IpoptMathProgModel) = m.inner
setwarmstart!(m::IpoptMathProgModel, x) = copy!(m.inner.x, x) # starting point
