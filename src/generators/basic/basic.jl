abstract type BasicGenFunction{T,U} <: Generator{T,U} end

# a method that is executed, at code-generation time on the type
function get_ir end

include("ir.jl")


########################
# arg change data type #
########################

"""
Example: MaskedArgChange{Tuple{Val{:true},Val{:false}},Something}(something)
"""
struct MaskedArgChange{T <: Tuple,U}
    info::U
end

get_change_type(::BasicGenFunction) = MaskedArgChange # TODO make the type parameter U part of the BasicGenFunction type parameter?
# or, users can overload it..

function mask(bits...)
    parameters = map((bit) -> Val{bit}, bits)
    MaskedArgChange{Tuple{parameters...},Void}(nothing)
end

#######################
# basic block parsing #
#######################

struct BasicBlockParseError <: Exception
    expr::Any
end

function parse_read(expr::Expr)
    @assert expr.head == :macrocall && expr.args[1] == Symbol("@read")
    if length(expr.args) != 2
        throw(BasicBlockParseError(expr))
    end
    addr_expr = expr.args[2]
    addr_expr
end

function parse_addr(expr::Expr)
    @assert expr.head == :macrocall && expr.args[1] == Symbol("@addr")
    if length(expr.args) == 3
        change_expr = nothing
    elseif length(expr.args) == 4
        change_expr = expr.args[4]
    else
        throw(BasicBlockParseError(expr))
    end
    call = expr.args[2]
    if !isa(call, Expr) || call.head != :call
        throw(BasicBlockParseError(call))
    end
    generator_or_dist = Main.eval(call.args[1]) # TODO use of eval...
    if isa(generator_or_dist, Distribution) && change_expr != nothing
        error("Cannot pass change values to @addr for distributions")
    end
    args = call.args[2:end]
    addr = expr.args[3]
    if isa(addr, Symbol)
    elseif isa(addr, Expr) && length(addr.args) == 1 && isa(addr.args[1], Symbol)
        addr = addr.args[1]
    end
    (addr::Symbol, generator_or_dist, args, change_expr)
end

function parse_change(expr::Expr)
    @assert expr.head == :macrocall && expr.args[1] == Symbol("@change")
    if length(expr.args) != 2
        throw(BasicBlockParseError(statement))
    end
    addr = expr.args[2]
    if isa(addr, Symbol)
        pass
    elseif isa(addr, Expr) && length(addr.args) == 1 && isa(addr.args[1], Symbol)
        addr = addr.args[1]
    end
    addr::Symbol
end

function parse_lhs(lhs::Expr)
    if lhs.head == :(::)
        name = lhs.args[1]
        typ = lhs.args[2]
        return (name, typ)
    else
        throw(BasicBlockParseError(lhs))
    end
end

function parse_lhs(lhs::Symbol)
    name = lhs
    (name, :Any)
end

function generate_ir(args, body)
    ir = BasicBlockIR()
    if !isa(body, Expr) || body.head != :block
        throw(BasicBlockParseError(body))
    end
    for arg in args
        if isa(arg, Symbol)
            name = arg
            typ = :Any
        elseif isa(arg, Expr) && arg.head == :(::)
            name = arg.args[1]
            typ = arg.args[2]
        else
            throw(BasicBlockParseError(body))
        end
        add_argument!(ir, name, typ)
    end
    for statement in body.args
        if !isa(statement, Expr)
            throw(BasicBlockParseError(statement))
        end
        if statement.head == :line
            continue
        elseif statement.head == :macrocall && statement.args[1] == Symbol("@addr")
            # an @addr statement without a left-hand-side
            (addr, dist_or_gen, args, change_expr) = parse_addr(statement)
            if isa(dist_or_gen, Distribution)
                @assert change_expr == nothing
                add_addr!(ir, addr, dist_or_gen, args)
            else
                # change_expr may be nothing, indicating nothing is known
                add_addr!(ir, addr, dist_or_gen, args, change_expr)
            end
        elseif statement.head == :(=)
            lhs = statement.args[1]
            rhs = statement.args[2]
            (name, typ) = parse_lhs(lhs)
            if rhs.head == :macrocall && rhs.args[1] == Symbol("@read")
                addr_expr = parse_read(rhs)
                add_read!(ir, addr_expr, typ, name)
            elseif rhs.head == :macrocall && rhs.args[1] == Symbol("@addr")
                (addr, dist_or_gen, args, change_expr) = parse_addr(rhs)
                if isa(dist_or_gen, Distribution)
                    @assert change_expr == nothing
                    add_addr!(ir, addr, dist_or_gen, args, typ, name)
                else
                    # change_expr may be nothing, indicating nothing is known
                    add_addr!(ir, addr, dist_or_gen, args, typ, name, change_expr)
                end
            elseif rhs.head == :macrocall && rhs.args[1] == Symbol("@argschange")
                if length(rhs.args) != 1
                    throw(BasicBlockParseError(statement))
                end
                add_argschange!(ir, typ, name)
            elseif rhs.head == :macrocall && rhs.args[1] == Symbol("@change")
                addr = parse_change(rhs)
                add_change!(ir, addr, typ, name)
            else
                add_julia!(ir, rhs, typ, name)
            end
        elseif statement.head == :return
            if length(statement.args) != 1
                throw(BasicBlockParseError(statement))
            end
            return_expr = statement.args[1]
            set_return!(ir, return_expr)
        elseif statement.head == :macrocall && statement.args[1] == Symbol("@retchange")
            if length(statement.args) != 2
                throw(BasicBlockParseError(statement))
            end
            retchange_expr = statement.args[2]
            set_retchange!(ir, retchange_expr)
        else
            throw(BasicBlockParseError(statement))
            # TODO make LHS optional for @addr..
        end
    end
    finish!(ir)
    ir
end

function basic_gen_parse(ast)
    dsl = Symbol("@compiled")
    if ast.head != :macrocall || ast.args[1] != Symbol("@gen") || length(ast.args) != 2
        error("syntax error in $dsl, expected $dsl @gen function .. end")
    end
    ast = ast.args[2]
    if ast.head != :function
        error("syntax error in $dsl at $(ast) in $(ast.head)")
    end
    if length(ast.args) != 2
        error("syntax error in $dsl at $(ast) in $(ast.args)")
    end
    signature = ast.args[1]
    body = ast.args[2]
    if signature.head != :call
        error("syntax error in $dsl at $(ast) in $(signature)")
    end
    name = signature.args[1]
    args = signature.args[2:end]
    (name, args, body)
end

###########################
# basic block trace types #
###########################

#
# the trace has fields:
# - a field for each value node (prefixed with a gensym)
# - a field for each addr statement (either a subtrace nor a value)
# - note: there is redundancy between the value nodes and the distribution addr fields

const value_node_prefix = gensym("value")

function value_field(name::Symbol)
    Symbol("$(value_node_prefix)_$name")
end

function value_field(node::ValueNode)
    value_field(node.name)
end

function value_trace_ref(trace, node::ValueNode)
    fieldname = value_field(node)
    Expr(:(.), trace, QuoteNode(fieldname))
end

struct BasicBlockChoices{T}
    trace::T
end

get_address_schema(::Type{BasicBlockChoices{T}}) where {T} = get_address_schema(T)

has_leaf_node(trie::BasicBlockChoices, addr) = false

has_internal_node(trie::BasicBlockChoices, addr) = false

Base.getindex(trie::BasicBlockChoices, addr) = get_leaf_node(trie, addr)

Base.haskey(trie::BasicBlockChoices, addr) = has_leaf_node(trie, addr)

function make_choice_trie_methods(trace_type, addr_dist_nodes, addr_gen_nodes)
    methods = Expr[]

    push!(methods, quote
        Base.isempty(trie::GenLite.BasicBlockChoices{$trace_type}) = trie.trace.$is_empty_field
    end)

    # get_leaf_nodes
    leaf_addrs = map((node) -> node.address, addr_dist_nodes)
    push!(methods, quote
        function GenLite.get_leaf_nodes(trie::GenLite.BasicBlockChoices{$trace_type})
            $(Expr(:tuple,
                [quote (Val($(QuoteNode(addr))), trie.trace.$addr) end for addr in leaf_addrs]...))
        end
    end)

    # get_internal_nodes
    internal_addrs = map((node) -> node.address, addr_gen_nodes)
    push!(methods, quote
        function GenLite.get_internal_nodes(trie::GenLite.BasicBlockChoices{$trace_type})
            $(Expr(:tuple,
                [quote (Val($(QuoteNode(addr))), trie.trace.$addr) end for addr in leaf_addrs]...))
        end
    end)


    for node::AddrDistNode in addr_dist_nodes
        addr = node.address

        push!(methods, quote
            function GenLite.has_leaf_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           ::Val{$(QuoteNode(addr))})
                true
            end
        end)

        push!(methods, quote
            function GenLite.get_leaf_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           ::Val{$(QuoteNode(addr))})
                trie.trace.$addr
            end
        end)

    end

    for node::AddrGeneratorNode in addr_gen_nodes
        addr = node.address

        push!(methods, quote
            function GenLite.has_leaf_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           addr::Pair{Val{$(QuoteNode(addr))},T}) where {T}
                (_, rest) = addr
                has_leaf_node(trie.trace.$addr, rest)
            end
        end)

        push!(methods, quote
            function GenLite.get_leaf_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           addr::Pair{Val{$(QuoteNode(addr))},T}) where {T}
                (_, rest) = addr
                get_leaf_node(get_choices(trie.trace.$addr), rest)
            end
        end)

        push!(methods, quote
            function GenLite.has_internal_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           ::Val{$(QuoteNode(addr))})
                true
            end
        end)

        push!(methods, quote
            function GenLite.has_internal_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           addr::Pair{Val{$(QuoteNode(addr))},T}) where {T}
                (_, rest) = addr
                has_internal_node(trie.trace.$addr, rest)
            end
        end)

        push!(methods, quote
            function GenLite.get_internal_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           ::Val{$(QuoteNode(addr))})
                get_choices(trie.trace.$addr)
            end
        end)

        push!(methods, quote
            function GenLite.get_internal_node(trie::GenLite.BasicBlockChoices{$trace_type},
                                           addr::Pair{Val{$(QuoteNode(addr))},T}) where {T}
                (_, rest) = addr
                get_internal_node(trie.trace.$addr, rest)
            end
        end)
    end

    methods
end

const is_empty_field = gensym("is_empty")
const call_record_field = gensym("call_record")

function generate_trace_type(ir::BasicBlockIR, name)
    trace_type_name = gensym("BasicBlockTrace_$name")
    fields = Expr[]
    for (name, node) in ir.value_nodes
        # NOTE: for now record the incremental computations
        # (ir.incremental_nodes) in the trace, but these can be removed for
        # performance optimization
        typ = get_type(node)
        push!(fields, Expr(:(::), value_field(node), typ))
    end
    for (addr, node) in ir.addr_dist_nodes
        typ_value::Type = get_return_type(node.dist)
        push!(fields, Expr(:(::), node.address, QuoteNode(typ_value)))
    end
    for (addr, node) in ir.addr_gen_nodes
        typ_value::Type = get_trace_type(node.gen)
        push!(fields, Expr(:(::), node.address, QuoteNode(typ_value)))
    end
    addresses = union(keys(ir.addr_dist_nodes), keys(ir.addr_gen_nodes))
    choice_trie_methods = make_choice_trie_methods(
        trace_type_name, values(ir.addr_dist_nodes), values(ir.addr_gen_nodes))
    retval_type = isnull(ir.output_node) ? :Void : get(ir.output_node).typ
    defn = esc(quote

        # specialized trace implementation
        mutable struct $trace_type_name
            $is_empty_field::Bool
            $call_record_field::CallRecord{$retval_type}
            $(Expr(:block, fields...))
            $trace_type_name() = new()
        end

        function Base.copy(other::$trace_type_name)
            trace = $trace_type_name()
            $(Expr(:block, [
                let fieldname = field.args[1] 
                    quote trace.$fieldname = other.$fieldname end
                end for field in fields]...))
            trace
        end

        GenLite.get_call_record(trace::$trace_type_name) = trace.$call_record_field
        GenLite.has_choices(trace::$trace_type_name) = !trace.$is_empty_field

        # choice trie view of the trace
        GenLite.get_choices(trace::$trace_type_name) = GenLite.BasicBlockChoices(trace)
        function GenLite.get_address_schema(::Type{$trace_type_name})
            GenLite.StaticAddressSchema(merge(
                Dict{Symbol, GenLite.StaticAddressInfo}([$([QuoteNode(addr => GenLite.StaticAddressInfo(true)) for addr in keys(ir.addr_dist_nodes)]...)]),
                Dict{Symbol, GenLite.StaticAddressInfo}([$([QuoteNode(addr => GenLite.StaticAddressInfo(false)) for addr in keys(ir.addr_gen_nodes)]...)])))
        end
        $(Expr(:block, choice_trie_methods...))
    end)
    (defn, trace_type_name)
end

#########################
# basic block generator #
#########################

function generate_generator_type(ir::BasicBlockIR, trace_type::Symbol, name::Symbol)
    generator_type = Symbol("BasicBlockGenerator_$name")
    retval_type = isnull(ir.output_node) ? :Void : get(ir.output_node).typ
    defn = esc(quote
        struct $generator_type <: GenLite.BasicGenFunction{$retval_type, $trace_type}
        end
        GenLite.get_ir(::Type{$generator_type}) = $(QuoteNode(ir))
        GenLite.render_graph(::$generator_type, fname) = GenLite.render_graph(GenLite.get_ir($generator_type), fname)
        GenLite.get_trace_type(::Type{$generator_type}) = $trace_type
        function GenLite.get_static_argument_types(::$generator_type)
            [node.typ for node in GenLite.get_ir($generator_type).arg_nodes]
        end
    end)
    (defn, generator_type)
end

macro compiled(ast)

    # parse the AST
    (name, args, body) = basic_gen_parse(ast)

    # geneate intermediate data-flow representation
    ir = generate_ir(args, body)

    # generate trace type definition
    (trace_type_defn, trace_type) = generate_trace_type(ir, name)

    # generate generator type definition
    (generator_type_defn, generator_type) = generate_generator_type(
        ir, trace_type, name)


    Expr(:block,
        trace_type_defn,
        generator_type_defn,
        quote global const $(esc(name)) = $(esc(generator_type))() end)
end

# helper functions for code generation

has_output(node::ExprNode) = true
has_output(node::Union{AddrDistNode,AddrGeneratorNode}) = !isnull(node.output)

function get_value_info(node::Union{AddrDistNode,AddrGeneratorNode})
    value_node::ValueNode = get(node.output)
    (value_node.typ, value_field(value_node))
end

function get_value_info(node::ExprNode)
    value_node::ValueNode = node.output
    (value_node.typ, value_field(value_node))
end

function get_args(trace::Symbol, node::ExprNode)
    map(input_node -> Expr(:(.), trace, QuoteNode(value_field(input_node))), node.input_nodes)
end

include("simulate.jl")
include("assess.jl")
include("generate.jl")
include("update.jl")

export @compiled
export MaskedArgChange
export mask