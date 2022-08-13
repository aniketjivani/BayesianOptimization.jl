abstract type AbstractAcquisition end

setparams!(a, model) = nothing
function acquisitionfunction(a, model)
    x -> begin
        μ, σ² = mean_var(model, x)
        a.(μ, σ²)
    end
end

"""
The probability of improvement measures the probability that a point `x` leads
to an improvement upon an incumbent target `τ`. For Gaussian distributions it is
given by

    Φ[(μ(x) - τ)/σ(x)]

where `Φ` is the standard normal cumulative distribution function and `μ(x)`, `σ(x)`
are mean and standard deviation of the distribution at point `x`.
"""
mutable struct ProbabilityOfImprovement <: AbstractAcquisition
    τ::Float64
end
@inline function (a::ProbabilityOfImprovement)(μ, σ²)
    σ² == 0 && return float(μ > a.τ)
    normal_cdf(μ - a.τ, σ²)
end
ProbabilityOfImprovement(; τ = -Inf) = ProbabilityOfImprovement(τ)

"""
The expected improvement measures the expected improvement `x - τ` of a point `x`
upon an incumbent target `τ`. For Gaussian distributions it is given by

    (μ(x) - τ) * ϕ[(μ(x) - τ)/σ(x)] + σ(x) * Φ[(μ(x) - τ)/σ(x)]

where `ϕ` is the standard normal distribution function and `Φ` is the standard
normal cumulative function, and `μ(x)`, `σ(x)` are mean and standard deviation
of the distribution at point `x`.

We can also introduce a new hyperparameter `ξ` that controls the tradeoff between exploration and exploitation.
Then, the expected improvement is given by:

    (μ(x) - τ - ξ) * ϕ[(μ(x) - τ - ξ)/σ(x)] + σ(x) * Φ[(μ(x) - τ)/σ(x)]

For ξ = 0, we just end up with the previous formula. But for large values of ξ, the algorithm will actually favour more exploration since we are inflating
the best value in the first term.
"""
mutable struct ExpectedImprovement <: AbstractAcquisition
    τ::Float64
    ξ::Float64
end
ExpectedImprovement(; τ = -Inf, ξ = 0) = ExpectedImprovement(τ, ξ)
function setparams!(a::Union{ExpectedImprovement,ProbabilityOfImprovement}, model)
    a.τ = max(maxy(model), a.τ)
end
@inline function (a::ExpectedImprovement)(μ, σ²)
    σ² == 0 && return μ > a.τ ? μ - a.τ : 0.
    (μ - a.τ - a.ξ) * normal_cdf(μ - a.τ - a.ξ, σ²) + √σ² * normal_pdf(μ - a.τ - ξ, σ²)
end

abstract type BetaScaling end
"""
Scales `βt` of `UpperConfidenceBound` as

    βt = √(2 * log(t^(D/2 + 2) * π^2/(3δ)))

where `t` is the number of observations, `D` is the dimensionality of the input
data points and δ is a small constant (default δ = 0.1).

See Brochu E., Cora V. M., de Freitas N. (2010), "A Tutorial on Bayesian
Optimization of Expensive Cost Functions, with Application to Active User
Modeling and Hierarchical Reinforcement Learning", https://arxiv.org/abs/1012.2599v1
page 16.
"""
struct BrochuBetaScaling <: BetaScaling
    δ::Float64
end
"""
Applies no scaling to `βt` of `UpperConfidenceBound`.
"""
struct NoBetaScaling <: BetaScaling end
"""
For Gaussian distributions the upper confidence bound at `x` is given by
    μ(x) + βt * σ(x)

where `βt` is a fixed parameter in the case of `NoBetaScaling` or an observation
size dependent parameter in the case of e.g. `BrochuBetaScaling`.
"""
mutable struct UpperConfidenceBound{S} <: AbstractAcquisition
    scaling::S
    βt::Float64
end
"""
    UpperConfidenceBound(; scaling = BrochuBetaScaling(.1), βt = 1)
"""
UpperConfidenceBound(; scaling = BrochuBetaScaling(.1), βt = 1.) = UpperConfidenceBound(scaling, βt)
function setparams!(a::UpperConfidenceBound{BrochuBetaScaling}, model)
    D, nobs = dims(model)
    nobs == 0 && (nobs = 1)
    a.βt = sqrt(2*log(nobs^(D/2 + 2)*π^2/(3*a.scaling.δ)))
end
(a::UpperConfidenceBound)(μ, σ²) = μ + a.βt * √σ²

"""
The acquisition function associated with `ThompsonSamplingSimple` draws
independent samples for each input `x` a function value from the model. Together
with a gradient-free optimization method this leads to proposal points that
might be similarly distributed as the maxima of true Thompson samples from GPs.
True Thompson samples from a GP are simply functions from a GP. Maximizing these
samples can be tricky, see e.g. http://hildobijl.com/Downloads/GPRT.pdf
chapter 6.
"""
struct ThompsonSamplingSimple <: AbstractAcquisition end
acquisitionfunction(a::ThompsonSamplingSimple, model) = x -> myrand(model, x)

struct MaxMean <: AbstractAcquisition end
acquisitionfunction(a::MaxMean, model) = x -> mean_var(model, x)[1]

"""
The mutual information measures the amount of information gained by querying at
x. The parameter γ̂ gives a lower bound for the information on f from the queries
{x}. For a Gaussian this is
    γ̂ = ∑σ²(x)
and the mutual information at x is
    μ(x) + √(α)*(√(σ²(x)+γ̂) - √(γ̂))

where `μ(x)`, `σ(x)` are mean and standard deviation
of the distribution at point `x`.

See Contal E., Perchet V., Vayatis N. (2014), "Gaussian Process Optimization
with Mutual Information" http://proceedings.mlr.press/v32/contal14.pdf
"""
mutable struct MutualInformation <: AbstractAcquisition
    sqrtα::Float64
    γ̂::Float64
end
MutualInformation(; α = 1.0, γ̂ = 0.0) = MutualInformation(sqrt(α), γ̂)
function setparams!(a::MutualInformation, model)
    D, nobs = dims(model)
    if iszero(nobs)
        a.γ̂ = 0.0
    else
        last_x = @view model.x[:, end]
        μ, σ2 = mean_var(model, last_x)
        a.γ̂ += σ2
    end
end
(a::MutualInformation)(μ, σ²) = μ + a.sqrtα * (sqrt(σ² + a.γ̂) - sqrt(a.γ̂))

# TODO see
# https://github.com/HildoBijl/GPRT/blob/7166548b8587201fabc671a0647aac2ff96f3555/Chapter6/Chapter6.m#L723
# and corresponding thesis page 173
# mutable struct ThompsonSampling{K} <: AbstractAcquisition
# end

# TODO
# mutable struct EntropySearch <: AbstractAcquisition
# end

# TODO
# mutable struct PredictiveEntropySearch <: AbstractAcquisition
# end

