using JuMP
import Ipopt

#using dare   warum geht das nicht?
using DrWatson
@quickactivate "dare"

using ReinforcementLearning
using PlotlyJS

include(srcdir("nodeconstructor.jl"))
include(srcdir("env.jl"))
include(srcdir("agent_ddpg.jl"))
include(srcdir("data_hook.jl"))
include(srcdir("Classical_Control.jl"))
include(srcdir("Power_System_Theory.jl"))
include(srcdir("MultiAgentGridController.jl"))


function set_bounds(variable, start_value, low_bound, up_bound)
    if !is_fixed(variable)
        set_lower_bound(variable, low_bound)
        set_upper_bound(variable, up_bound)
        set_start_value(variable, start_value)
    end
end



function get_degree(CM = CM) # how many cables are connected to a node? maybe remove function if not used
    result = zeros(Int, size(CM)[1])

    for i=1:size(CM)[1]
        result[i] = count(x -> x != 0, CM[i,:])
    end

    result
end

function get_cable_connections(CM = CM) # which cables are connected to which nodes

    result = Vector{Vector{Int64}}(undef, size(CM)[1])

    for i=1:size(CM)[1]
        result[i] = filter(x -> x != 0, abs.(CM[i,:]))
    end

    return result
end

function get_node_connections(CM = CM) # which nodes are connected to each other, including the self-connections

    result = Vector{Vector{Int64}}(undef, size(CM)[1])

    for i=1:size(CM)[1]
        result[i] = findall(x -> x != 0, CM[i,:])
        push!(result[i], i)
    end

    return result
end

function layout_cabels(CM, num_source, num_load, parameters)

    model = Model(Ipopt.Optimizer)
    #set_optimizer_attributes(model, "tol" => 1e-1)

    zero_expression = @NLexpression(model, 0.0)

    # Constant values
    omega = 2π*parameters["grid"]["fs"]

    # for every Source: v is fixed 230  #TODO: change depending on control mode?
    # for one Source: theta is fixed 0
    #TODO: user specified disctances
    #distances = [1.0 2.3 .323]  -> get from parameter dict

    num_nodes = num_source + num_load
    num_cables = maximum(CM)

    @variable(model, nodes[1 : num_nodes, ["v", "theta", "P", "Q"]])
    fix(nodes[1, "theta"], 0.0) # reference
    fix(nodes[1, "v"], 230.0) # reference should not be a load bus - ensure + change depending on control mode?, #TODO

    for i = 1:num_nodes
        if i <= num_source
            #fix(nodes[i, "v"], 230.0) # user may specify 1.05*230
            #TODO depending on the control mode! Check/change to not fixed?
            fix(nodes[i, "v"], parameters["source"][i]["v_pu_set"] * parameters["grid"]["v_rms"])

            set_bounds(nodes[i, "theta"], 0.0, -0.25*pi/2, 0.25*pi/2) # question, does this limit too much, should be more or less.
            set_bounds(nodes[i, "P"], (num_load * parameters["source"][i]["pwr"]) / num_source, -parameters["source"][i]["pwr"], parameters["source"][i]["pwr"]) # come from parameter dict/user?
            set_bounds(nodes[i, "Q"], (num_load * parameters["source"][i]["pwr"]) / num_source, -parameters["source"][i]["pwr"], parameters["source"][i]["pwr"]) # P and Q are the average from power, excluding cable losses
        else
            #TODO: what if we have an active load? -> would sit in sources
            fix(nodes[i, "P"], -parameters["load"][i-num_source]["pwr"])
            fix(nodes[i, "Q"], -parameters["load"][i-num_source]["pwr"])
    
            set_bounds(nodes[i, "theta"], 0.0, -0.25*pi/2, 0.25*pi/2) # same as above
            set_bounds(nodes[i, "v"], 230.0, 0.95*230, 1.05*230)
        end
    end

    cable_cons = get_cable_connections(CM)
    node_cons = get_node_connections(CM) 

    G = Array{NonlinearExpression, 2}(undef, num_nodes, num_nodes) # should be symmetric
    B = Array{NonlinearExpression, 2}(undef, num_nodes, num_nodes) # should be symmetric

    P_node = Array{NonlinearConstraintRef, 1}(undef, num_nodes)
    Q_node = Array{NonlinearConstraintRef, 1}(undef, num_nodes)

    
    cable_cons = get_cable_connections(CM)
    node_cons = get_node_connections(CM) 

    G = Array{NonlinearExpression, 2}(undef, num_nodes, num_nodes) # should be symmetric
    B = Array{NonlinearExpression, 2}(undef, num_nodes, num_nodes) # should be symmetric

    P_node = Array{NonlinearConstraintRef, 1}(undef, num_nodes)
    Q_node = Array{NonlinearConstraintRef, 1}(undef, num_nodes)

    # As radius goes down resistance goes up, inductance goes up, capacitance goes down. Put in formulas for this.
    @variable(model, cables[1 : num_cables, ["L", "X_R", "C_L"]]) # this is wrong - #TODO ["radius"] for futute : ["radius", "conductivity"] 
    cable_conductance = Array{NonlinearExpression, 1}(undef, num_cables)
    cable_susceptance_0 = Array{NonlinearExpression, 1}(undef, num_cables) # diagonals - where we add capacitances
    cable_susceptance_1 = Array{NonlinearExpression, 1}(undef, num_cables) # off diagonals

    for i=1:num_cables

        set_bounds(cables[i, "L"], 0.00025, 0.00023, 0.00026)
        set_bounds(cables[i, "X_R"], 0.38, 0.37, 0.4)
        set_bounds(cables[i, "C_L"], 0.0016, 0.0015, 0.0017)

        #set_bounds(cables[i, "radius"], 0.0016, 0.1, 0.25(?)) mm #TODO

        #R = (omega*L)/X_R
        #C = C_L*L
        cable_conductance[i] = @NLexpression(model, ((omega * cables[i, "L"]) / cables[i, "X_R"]) / (((omega*cables[i, "L"]) / cables[i, "X_R"])^2 + omega^2 * cables[i, "L"]^2))
        cable_susceptance_1[i] = @NLexpression(model, (-omega * cables[i, "L"] / (((omega*cables[i, "L"])/cables[i, "X_R"])^2 + omega^2 * cables[i, "L"]^2)))
        cable_susceptance_0[i] = @NLexpression(model, (-omega * cables[i, "L"] / (((omega*cables[i, "L"])/cables[i, "X_R"])^2 + omega^2 * cables[i, "L"]^2)) + omega*cables[i, "C_L"]*cables[i, "L"]/2)
    end

    for i in 1:num_nodes

        # diagonal terms
        G[i, i] = @NLexpression(model, sum( cable_conductance[cable_cons[i]][j] for j in 1:length(cable_cons[i])))
        B[i, i] = @NLexpression(model, sum( cable_susceptance_0[cable_cons[i]][j] for j in 1:length(cable_cons[i])))

        # off diagonal terms
        for k in (i+1):num_nodes # this is over the upper triangle

            if CM[i, k] != 0

                cable_num = abs(CM[i, k])

                G[i, k] = @NLexpression(model, -1*cable_conductance[cable_num])
                B[i, k] = @NLexpression(model, -1*cable_susceptance_1[cable_num])
                G[k, i] = G[i, k]
                B[k, i] = B[i, k]
                
            else

                G[i, k] = zero_expression # a formula which returns 0.0
                B[i, k] = zero_expression
                G[k, i] = zero_expression
                B[k, i] = zero_expression
            end
        end
    end

    # power flow constraints - this is perfect!!
    for i in 1:num_nodes

        P_node[i] = @NLconstraint(model,

        nodes[i, "P"] == nodes[i,"v"] * sum( nodes[j,"v"] * ((G[i, j] * cos(nodes[i,"theta"] - nodes[j,"theta"]) + B[i, j] * sin(nodes[i,"theta"] - nodes[j,"theta"]))) for j in node_cons[i])
        
        )

        Q_node[i] = @NLconstraint(model,

        nodes[i, "Q"] == nodes[i,"v"] * sum( nodes[j,"v"] * ((G[i, j] * sin(nodes[i,"theta"] - nodes[j,"theta"]) - B[i, j] * cos(nodes[i,"theta"] - nodes[j,"theta"]))) for j in node_cons[i])

        )

    end

    cable_constraints = Array{NonlinearConstraintRef, 1}(undef, num_cables)
    # maybe remove this? but add as check after optimisation has been completed.
    for i in 1:num_cables

        j, k = Tuple(findfirst(x -> x == i, CM))

        cable_constraints[i] = @NLconstraint(model,
            abs( nodes[j, "v"] * nodes[k, "v"] * (sin(nodes[j, "theta"] - nodes[k, "theta"]))/(omega*cables[i, "L"])) # this formula is not quite correct - missing resistances and capacitances
            <= 0.93 * nodes[j, "v"] * nodes[k, "v"] * sqrt(cables[i, "C_L"]) # check if there should be a 2 in the equation
        )

    end
    
    #0.93 * value(nodes[j, "v"] * nodes[k, "v"]) * sqrt(value(cables[i, "C_L"]))
    # non-linear objectives
    @NLexpression(model, P_source_mean, sum(nodes[j,"P"] for j in 1:num_source) / num_source)
    @NLexpression(model, Q_source_mean, sum(nodes[j,"Q"] for j in 1:num_source) / num_source)

    # TODO: normalisation, i.e. weighting between minimising P and Q, and minimising cable radius? Maybe use per unit system
    # normalisation : 1. max value
    #                 2. p.u. 0
    # Sbase_1_phase = sum(loads)
    # Vbase_rms = 230
    # Ibase_rms = f(Sbase_1_phase, Vbase_rms)
    # Zbase = f(Vbase_rms, Ibase_rms)
    @NLobjective(model, Min, abs(sum(nodes[i,"P"] for i in 1:num_source))/1000 # replace sum by mean or divide by 1000*num_source
                            + abs(sum(nodes[i,"Q"] for i in 1:num_source))/1000
                            + sum(nodes[i,"v"] for i in num_source+1:num_nodes)/230 # TODO: maybe wrong- minimise the deviation of voltage, excluding reference node (which does not neeed to be node 1)
                            + abs(sum(nodes[i,"theta"] for i in 2:num_nodes))/π
                            + sum(cables[i, "X_R"] for i in 1:num_cables) # replaced with radius, how do we normalise radius??? idea: upper bound of radius times by number of cables
                            + sum(1/cables[i, "L"] for i in 1:num_cables)
                            + sum(cables[i, "C_L"] for i in 1:num_cables)
                            + sum( (nodes[i,"P"] - P_source_mean)^2 for i in 1:num_source)/num_source 
                            + sum( (nodes[i,"Q"] - Q_source_mean)^2 for i in 1:num_source)/num_source ) # the variance - not exactly right (but good enough)

    optimize!(model)
    println("""
    termination_status = $(termination_status(model))
    primal_status      = $(primal_status(model))
    objective_value    = $(objective_value(model))
    """)


    println()
    println()
    println(value.(nodes))

    println()
    println(value.(cables))
    
    #R = (omega*L)/X_R 
    #C = C_L*L
    for (index, cable) in enumerate(parameters["cable"])

        cable["L"] = value.(cables).data[index,1]
        cable["Lb"] = cable["L"]/cable["len"]

        cable["R"] = (omega*cable["L"])/value.(cables).data[index,2]
        cable["Rb"] = cable["R"]/cable["len"]

        cable["C"] = cable["L"]*value.(cables).data[index,3]
        cable["Cb"] = cable["C"]/cable["len"]
    end

    return parameters
end


CM = [  0   0   0   1
        0   0   0   2
        0   0   0   3
        -1  -2  -3  0  ] # user specified



num_source = 3 # user
num_load = 1 # user

parameters = Dict{Any, Any}(
    "source" => Any[
                    Dict{Any, Any}("fltr"=>"LC", "pwr"=>1000, "v_pu_set" => 1.0),
                    Dict{Any, Any}("fltr"=>"LC", "pwr"=>1000, "v_pu_set" => 1.0),
                    Dict{Any, Any}("fltr"=>"LC", "pwr"=>1000, "v_pu_set" => 1.0),
                    ],
    "load"   => Any[
                    #Dict{Any, Any}("R"=>10, "L" => 0.16, "impedance"=>"RL")#, "pwr"=>1000)
                    Dict{Any, Any}("R"=>47.61, "L"=>0.0002336, "impedance"=>"RL")
                    ],
    "grid"   => Dict{Any, Any}("fs"=>50.0, "phase"=>3, "v_rms"=>230, "fg" => 50),
    "cable" => Any[
                    Dict{Any, Any}("len"=>1),
                    Dict{Any, Any}("len"=>1),
                    Dict{Any, Any}("len"=>1)
                    ]
)
#TODO: shift this for every load to the nodeconstructor
for (index, load) in enumerate(parameters["load"])
    # example for RL load
    print(load)
    if !haskey(load, "pwr")
        # parallel R||L
        Z = 1im*parameters["grid"]["fg"]*2*pi*load["R"]*load["L"]/(load["L"]+1im*parameters["grid"]["fg"]*2*pi*load["L"])
        load["pwr"] = parameters["grid"]["v_rms"]^2 / abs(Z)
    end
end

#TODO ensure that len is defined in nodeconstructor before this function is called!
#TODO Take len in PFE into acount! (currently assuming 1km)
parameters = layout_cabels(CM, num_source, num_load, parameters)








#=
##################################################
layout_cabels(CM, num_source, num_load, parameters)#distances, P_bounds, Q_bounds, powerfactor)
#_______________________________________________________________________________
# Parameters - Time simulation
Timestep = 100 #time step in μs ~ 100μs => 10kHz, 50μs => 20kHz, 20μs => 50kHz
t_final = 0.5 #time in seconds, total simulation run time

ts = Timestep*1e-6
t = 0:ts:t_final # time

fs = 1/ts # Hz, Sampling frequency of controller ~ 15 kHz < fs < 50kHz

#_______________________________________________________________________________
# State space representation
CM = [ 0. 0. 1.
        0. 0. 2
        -1. -2. 0.]

#-------------------------------------------------------------------------------
# Cables

cable_list = []

# Network Cable Impedances
l = 2.5 # length in km
cable = Dict()
cable["R"] = 0.208*l # Ω, line resistance 0.722#
cable["L"] = 0.00025*l # H, line inductance 0.264e-3#
cable["C"] = 0.4e-6*l # 0.4e-6#

#= push!(cable_list, cable, cable, cable) =#

push!(cable_list, cable, cable)

#-------------------------------------------------------------------------------
# Sources
source = Dict()

source_list = []

source["pwr"] = 200e3
source["vdc"] = 800
source["fltr"] = "LC"
source["p_set"] = 50e3
source["q_set"] = 10e3
source["v_pu_set"] = 1.05

push!(source_list, source)

source["pwr"] = 200e3
source["vdc"] = 800
source["fltr"] = "LC"
source["p_set"] = 50e3
source["q_set"] = 10e3
source["v_pu_set"] = 1.0

push!(source_list, source)

#-------------------------------------------------------------------------------
# Loads

load_list = []
load = Dict()

pwr_load = 50e3
pf_load = 0.6
R1_load, L_load, _, _ = Load_Impedance_2(pwr_load, pf_load, 230)
#R2_load, C_load, _, _ = Load_Impedance_2(150e3, -0.8, 230)

load["impedance"] = "RL"
load["R"] = R1_load# + R2_load # 
load["L"] = L_load
load["pwr"] = pwr_load
load["pf"] = pf_load
#load["C"] = C_load

push!(load_list, load)


#-------------------------------------------------------------------------------
# Amalgamation

parameters["source"] = source_list
parameters["cable"] = cable_list
parameters["load"] = load_list
parameters["grid"] = Dict("fs" => fs, "phase" => 3, "v_rms" => 230)

# Define the environment

num_sources = length(source_list)
num_loads = length(load_list)

env = SimEnv(ts = ts, use_gpu = false, CM = CM, num_sources = num_sources, num_loads = num_loads, 
parameters = parameters, maxsteps = length(t), action_delay = 1)
=#
