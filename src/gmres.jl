export gmres, gmres!

#One Arnoldi iteration
#Optionally takes a truncation parameter l
function arnoldi!(K::KrylovSubspace, w; l=K.order)
    v = nextvec(K)
    w = copy(v)
    n = min(length(K.v), l)
    h = zeros(eltype(v), n+1)
    v, h[1:n] = orthogonalize(v, K, n)
    h[n+1] = norm(v)
    (h[n+1]==0) && error("Arnoldi iteration terminated")
    append!(K, v/h[n+1]) #save latest Arnoldi vector, i.e. newest column of Q in the AQ=QH factorization
    h #Return current Arnoldi coefficients, i.e. newest column of in the AQ=QH factorization
end

function apply_givens!(H, J, j)
    for k = 1:(j-1)
        temp     =       J[k,1]  * H[k,j] + J[k,2] * H[k+1,j]
        H[k+1,j] = -conj(J[k,2]) * H[k,j] + J[k,1] * H[k+1,j]
        H[k,j]   = temp
    end
end

function compute_givens(a, b, i, j)
    T = eltype(a)
    p = abs(a)
    q = abs(b)

    if q == zero(T)
        return [one(T), zero(T), a]
    elseif p == zero(T)
        return [zero(T), sign(conj(b)), q]
    else
        m      = hypot(p,q)
        temp   = sign(a)
        return [p / m, temp * conj(b) / m, temp * m]
    end
end

gmres(A, b, Pl=1, Pr=1;
      tol=sqrt(eps(typeof(real(b[1])))), maxiter::Int=1, restart::Int=min(20,length(b))) =
    gmres!(zerox(A,b), A, b, Pl, Pr; tol=tol, maxiter=maxiter, restart=restart)

function gmres!(x, A, b, Pl=1, Pr=1;
        tol=sqrt(eps(typeof(real(b[1])))), maxiter::Int=1, restart::Int=min(20,length(b)))
#Generalized Minimum RESidual
#Reference: http://www.netlib.org/templates/templates.pdf
#           2.3.4 Generalized Minimal Residual (GMRES)
#
#           http://www.netlib.org/lapack/lawnspdf/lawn148.pdf
#           Givens rotation based on Algorithm 1
#
#   Solve A*x=b using the Generalized Minimum RESidual Method with restarts
#
#   Effectively solves the equation inv(Pl)*A*inv(Pr)*y=b where x = inv(Pr)*y
#
#   Required Arguments:
#       A: Linear operator
#       b: Right hand side
#
#   Named Arguments:
#       Pl:      Left preconditioner
#       Pr:      Right preconditioner
#       restart: Number of iterations before restart (GMRES(restart))
#       maxiter:  Maximum number of outer iterations
#       tol:     Convergence Tolerance
#
#   The input A (resp. Pl, Pr) can be a matrix, a function returning A*x,
#   (resp. inv(Pl)*x, inv(Pr)*x), or any type representing a linear operator
#   which implements *(A,x) (resp. \(Pl,x), \(Pr,x)).
    n = length(b)
    T = eltype(b)
    H = zeros(T,n+1,restart)       #Hessenberg matrix
    s = zeros(T,restart+1)         #Residual history
    J = zeros(T,restart,3)         #Givens rotation values
    tol = tol * norm(Pl\b)         #Relative tolerance
    resnorms = zeros(typeof(real(b[1])), maxiter, restart)
    isconverged = false
    matvecs = 0
    K = KrylovSubspace(x->Pl\(A*(Pr\x)), n, restart+1, T)
    for iter = 1:maxiter
        w    = Pl\(b - A*x)
        s[1] = rho = norm(w)
        init!(K, w / rho)

        N = restart
        for j = 1:restart
            #Calculate next orthonormal basis vector in the Krylov subspace
            H[1:j+1, j] = arnoldi!(K, w)

            #Update QR factorization of H
            #The Q is stored as a series of Givens rotations in J
            #The R is stored in H
            #- Compute Givens rotation that zeros out bottom right entry of H
            apply_givens!(H, J, j)
            J[j,1:3] = compute_givens(H[j,j], H[j+1,j], j, j+1)
            #G = Base.LinAlg.Givens(restart+1, j, j+1, J[j,1], J[j,2], J[j,3])
            #- Zero out bottom right entry of H
            H[j,j]   = J[j,3]
            H[j+1,j] = zero(T)
            #- Apply Givens rotation j to s, given that s[j+1] = 0
            s[j+1] = -conj(J[j,2]) * s[j]
            #-conj(G.s) * s[j]
            s[j]  *= J[j,1] #G.c

            resnorms[iter, j] = rho = abs(s[j+1])
            if rho < tol
                N = j
                break
            end
        end

        @eval a = $(VERSION < v"0.4-" ? Triangular(H[1:N, 1:N], :U) \ s[1:N] : UpperTriangular(H[1:N, 1:N]) \ s[1:N])
        w = a[1:N] * K
        update!(x, 1, isa(Pr, Function) ? Pr(w) : Pr\w) #Right preconditioner

        if rho < tol
            resnorms = resnorms[1:iter, :]
            isconverged = true
            matvecs = (iter-1)*restart + N
            break
        end
    end

    return x, ConvergenceHistory(isconverged, tol, matvecs, resnorms)
end
