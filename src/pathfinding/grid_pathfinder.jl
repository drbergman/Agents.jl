export CostMetric, DirectDistanceMetric, ChebyshevMetric, HeightMapMetric, Pathfinder, Path, delta_cost, find_path, set_target!, move_agent!

"""
    Path{D}
An alias for `MutableLinkedList{Dims{D}}`. Used to represent the path to be
taken by an agent in a `D` dimensional [`GridSpace{D}`](@ref).
"""
const Path{D} = MutableLinkedList{Dims{D}}

"""
    CostMetric{D}
An abstract type representing a metric that measures the approximate cost of travelling
between two points in a `D` dimensional [`GridSpace{D}`](@ref). A struct with this as its
base type is used as the `cost_metric` for the [`Pathfinder`](@ref). To define a custom metric,
define a struct with this as its base type and a corresponding method for [`delta_cost`](@ref).
"""
abstract type CostMetric{D} end

struct DirectDistanceMetric{D} <: CostMetric{D}
    direction_costs::Vector{Int}
end

"""
    DirectDistanceMetric{D}(direction_costs::Vector{Int}=[floor(Int, 10.0*√x) for x in 1:D])
The default metric [`CostMetric{D}`](@ref). Distance is approximated as the shortest path between
the two points, where from any tile it is possible to step to any of its Moore neighbors.
`direction_costs` is an `Array{Int,1}` where `direction_costs[i]` represents the cost of
going from a tile to the neighbording tile on the `i` dimensional diagonal. The default value is 
`10√i` for the `i` dimensional diagonal, rounded down to the nearest integer.

If `moore_neighbors=false` in the [`Pathfinder`](@ref) struct, then it is only possible to step to
VonNeumann neighbors.
"""
DirectDistanceMetric{D}() where {D} = DirectDistanceMetric{D}([floor(Int, 10.0 * √x) for x in 1:D])

"""
    ChebyshevMetric{D}()
Distance between two tiles is approximated as the Chebyshev distance (maximum of absolute
difference in coordinates) between them.
"""
struct ChebyshevMetric{D} <: CostMetric{D}
end

struct HeightMapMetric{D} <: CostMetric{D}
    base_metric::CostMetric{D}
    hmap::Array{Int,D}
end

"""
    HeightMapMetric(hmap::Array{Int,D})
An alternative [`CostMetric{D}`](@ref). This allows for a `D` dimensional heightmap to be provided as a
`D` dimensional integer array, of the same size as the corresponding [`GridSpace{D}`](@ref). This metric
approximates the distance between two positions as the sum of the shortest distance between them and the absolute
difference in heights between the two positions. The shortest distance is calculated using the underlying
`base_metric` field, which defaults to [`MooreMetric{D}`](@ref)
"""
HeightMapMetric(hmap::Array{Int,D}) where {D} = HeightMapMetric{D}(DirectDistanceMetric{D}(), hmap)

mutable struct Pathfinder{D,P}
    agent_paths::Dict{Int,Path{D}}
    grid_dims::Dims{D}
    moore_neighbors::Bool
    admissibility::AbstractFloat
    walkable::Array{Bool,D}
    cost_metric::CostMetric{D}
end

"""
    Pathfinder(space::GridSpace{D,P}; kwargs...)
Stores path data of agents, and relevant pathfinding grid data. The dimensions are taken to be those of the space.

The keyword argument `moore_neighbors::Bool=true` specifies if movement can be to Moore neighbors of a tile, or only
Von Neumann neighbors.

The keyword argument `admissibility::AbstractFloat=0.0` specifies how much a path can deviate from optimality, in favour
of faster pathfinding. For an admissibility value of `ε`, a path with atmost `(1+ε)` times the optimal path length
will be calculated, exploring fewer nodes in the process. A value of `0` always finds the optimal path.

The keyword argument `walkable::Array{Bool,D}=fill(true, size(space.s))` is used to specify (un)walkable positions of
the space. Unwalkable positions are never part of any paths. By default, all positions are assumed to be walkable.

The keyword argument `cost_metric::CostMetric{D}=MooreMetric{D}()` specifies the metric used to approximate
the distance between any two walkable points on the grid. This must be a struct with base type [`CostMetric{D}`](@ref)
and having a corresponding method for [`delta_cost`](@ref). The default value is [`MooreMetric{D}`](@ref).
"""
Pathfinder(
    space::GridSpace{D,P};
    moore_neighbors::Bool=true,
    admissibility::AbstractFloat=0.0,
    walkable::Array{Bool,D}=fill(true, size(space.s)),
    cost_metric::CostMetric{D}=DirectDistanceMetric{D}()
) where {D,P} = Pathfinder{D,P}(Dict{Int,Path{D}}(), size(space.s), moore_neighbors, admissibility, walkable, cost_metric)

"""
    position_delta(pathfinder::Pathfinder{D,periodic}, from::NTuple{Int,D}, to::NTuple{Int,D})
Returns the absolute difference in coordinates between `from` and `to` taking into account periodicity of `pathfinder`.
"""
position_delta(
    pathfinder::Pathfinder{D,periodic},
    from::Dims{D},
    to::Dims{D}
) where {D, periodic} = periodic ? min.(abs.(to .- from), pathfinder.grid_dims .- abs.(to .- from)) : abs.(to .- from)

"""
    delta_cost(pathfinder::Pathfinder{D}, from::NTuple{D, Int}, to::NTuple{D, Int})
Calculates and returns an approximation for the cost of travelling from `from` to `to`. This calls the corresponding
`delta_cost(pathfinder, pathfinder.cost_metric, from, to)` function. In the case of a custom metric, define a method for
the latter function.
"""
function delta_cost(
    pathfinder::Pathfinder{D,periodic},
    metric::DirectDistanceMetric{D},
    from::Dims{D},
    to::Dims{D}
) where {D,periodic}    
    delta = collect(position_delta(pathfinder, from, to))

    pathfinder.moore_neighbors || return sum(delta)*metric.direction_costs[1]

    sort!(delta)
    carry = 0
    hdist = 0
    for i = D:-1:1
        hdist += metric.direction_costs[i] * (delta[D + 1 - i] - carry)
        carry = delta[D + 1 - i]
    end
    return hdist
end

delta_cost(
    pathfinder::Pathfinder{D,periodic},
    metric::ChebyshevMetric{D},
    from::Dims{D},
    to::Dims{D}
) where {D,periodic} = max(position_delta(pathfinder, from, to)...)


delta_cost(
    pathfinder::Pathfinder{D,periodic},
    metric::HeightMapMetric{D},
    from::Dims{D},
    to::Dims{D}
) where {D,periodic} = delta_cost(pathfinder, metric.base_metric, from, to) + abs(metric.hmap[from...] - metric.hmap[to...])

delta_cost(pathfinder::Pathfinder{D}, from::Dims{D}, to::Dims{D}) where {D} = delta_cost(pathfinder, pathfinder.cost_metric, from, to)

struct GridCell
    f::Int
    g::Int
    h::Int
end

GridCell(g::Int, h::Int, admissibility::AbstractFloat) = GridCell(round(Int, g + (1+admissibility)*h), g, h)

"""
    find_path(pathfinder::Pathfinder{D,periodic}, from::NTuple{D, Int}, to::NTuple{D,Int})
Using the specified [`Pathfinder`](@ref), calculates and returns the shortest path from `from` to `to` using the A* algorithm.
Paths are returned as a [`Path{D}`](@ref). If a path does not exist between the given positions, this returns an empty
[`Path{D}`](@ref). This function usually does not need to be called explicitly, instead the use the provided [`set_target!`](@ref)
and [`move_agent!`](@ref) functions.
"""
function find_path(
    pathfinder::Pathfinder{D,periodic},
    from::Dims{D},
    to::Dims{D},
) where {D,periodic}
    grid = DefaultDict{Dims{D},GridCell}(GridCell(typemax(Int), typemax(Int), typemax(Int)))
    parent = DefaultDict{Dims{D},Union{Nothing,Dims{D}}}(nothing)

    if pathfinder.moore_neighbors
        neighbor_offsets = [
            Tuple(a)
            for a in Iterators.product([(-1):1 for φ = 1:D]...) if a != Tuple(zeros(Int, D))
    ]
    else
        neighbor_offsets = [Tuple(i == j ? 1 : 0 for i in 1:D) for j in 1:D]
        neighbor_offsets = vcat(neighbor_offsets, [.-dir for dir in neighbor_offsets])
    end
    open_list = BinaryMinHeap{Tuple{Int,Dims{D}}}()
    closed_list = Set{Dims{D}}()

    grid[from] = GridCell(0, delta_cost(pathfinder, from, to), pathfinder.admissibility)
    push!(open_list, (grid[from].f, from))

    while !isempty(open_list)
        _, cur = pop!(open_list)
        push!(closed_list, cur)
        cur == to && break

        for offset in neighbor_offsets
            nbor = cur .+ offset
            periodic &&
                (nbor = (nbor .- 1 .+ pathfinder.grid_dims) .% pathfinder.grid_dims .+ 1)
            all(1 .<= nbor .<= pathfinder.grid_dims) || continue
            pathfinder.walkable[nbor...] || continue
            nbor in closed_list && continue
            new_g_cost = grid[cur].g + delta_cost(pathfinder, cur, nbor)
            if new_g_cost < grid[nbor].g
                parent[nbor] = cur
                grid[nbor] = GridCell(new_g_cost, delta_cost(pathfinder, nbor, to), pathfinder.admissibility)
                # open list will contain duplicates. Can this be avoided?
                push!(open_list, (grid[nbor].f, nbor))
            end
    end
end

    agent_path = Path{D}()
    cur = to
    while parent[cur] !== nothing
        pushfirst!(agent_path, cur)
cur = parent[cur]
    end
    return agent_path
end

"""
    set_target!(agent, pathfinder::Pathfinder{D}, target::NTuple{D,Int})
This calculates and stores the shortest path to move the agent from its current position to `target`
using [`find_path`](@ref).
"""
function set_target!(agent, pathfinder::Pathfinder{D}, target::Dims{D}) where {D}
    pathfinder.agent_paths[agent.id] = find_path(pathfinder, agent.pos, target)
end

"""
    move_agent!(agent, model::ABM{<:GridSpace{D}}, pathfinder::Pathfinder{D})
Moves the agent along the path to its target set by [`set_target!`](@ref). If the agent does
not have a precalculated path, or the path is empty, nothing happens.
"""
function move_agent!(agent, model::ABM{<:GridSpace{D}}, pathfinder::Pathfinder{D}) where {D}
    (get(pathfinder.agent_paths, agent.id, nothing) === nothing || isempty(pathfinder.agent_paths[agent.id])) && return

    move_agent!(agent, first(pathfinder.agent_paths[agent.id]), model)
    popfirst!(pathfinder.agent_paths[agent.id])
end
