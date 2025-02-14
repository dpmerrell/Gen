#############################
# probability distributions #
#############################

import Distributions
using SpecialFunctions: lgamma, lbeta, digamma

abstract type Distribution{T} end

"""
    val::T = random(dist::Distribution{T}, args...)

Sample a random choice from the given distribution with the given arguments.
"""
function random end

"""
    lpdf = logpdf(dist::Distribution{T}, value::T, args...)

Evaluate the log probability (density) of the value.
"""
function logpdf end

"""
    has::Bool = has_output_grad(dist::Distribution)

Return true of the gradient if the distribution computes the gradient of the logpdf with respect to the value of the random choice.
"""
function has_output_grad end

"""
    grads::Tuple = logpdf_grad(dist::Distribution{T}, value::T, args...)

Compute the gradient of the logpdf with respect to the value, and each of the arguments.

If `has_output_grad` returns false, then the first element of the returned tuple is `nothing`.
Otherwise, the first element of the tuple is the gradient with respect to the value.
If the return value of `has_argument_grads` has a false value for at position `i`, then the `i+1`th element of the returned tuple has value `nothing`.
Otherwise, this element contains the gradient with respect to the `i`th argument.
"""
function logpdf_grad end

# NOTE: has_argument_grad is documented and exported in gen_fn_interface.jl

get_return_type(::Distribution{T}) where {T} = T

export Distribution
export random
export logpdf
export logpdf_grad
export has_output_grad

include("bernoulli.jl")
include("normal.jl")
include("mvnormal.jl")
include("gamma.jl")
include("inv_gamma.jl")
include("beta.jl")
include("categorical.jl")
include("uniform_discrete.jl")
include("uniform_continuous.jl")
include("poisson.jl")
include("piecewise_uniform.jl")
include("beta_uniform.jl")
include("geometric.jl")
include("exponential.jl")

###############
# combinators #
###############

# code shared by vector-shaped combinators
include("vector.jl")

# built-in generative function combinators
include("choice_at/choice_at.jl")
include("call_at/call_at.jl")
include("map/map.jl")
include("unfold/unfold.jl")
include("recurse/recurse.jl")

#############################################################
# abstractions for constructing custom generative functions #
#############################################################

include("custom_determ.jl")
