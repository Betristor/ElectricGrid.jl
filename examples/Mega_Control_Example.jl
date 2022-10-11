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

include(srcdir("Classical_Control_Plots.jl"))

function reference(t)
    
    u = [sqrt(2)*230 * cos.(2*pi*50*t .- 2/3*pi*(i-1)) for i = 1:3]
    #return vcat(u,u)  # to control 2 sources
    return u
end

function reward(env, name = nothing)
    r = 0.0
    
    if !isnothing(name)
        if name == "agent"
            u_l1_index = findfirst(x -> x == "source1_v_C_a", env.state_ids)
            u_l2_index = findfirst(x -> x == "source1_v_C_b", env.state_ids)
            u_l3_index = findfirst(x -> x == "source1_v_C_c", env.state_ids)
        else
            u_l1_index = findfirst(x -> x == "source2_v_C_a", env.state_ids)
            u_l2_index = findfirst(x -> x == "source2_v_C_b", env.state_ids)
            u_l3_index = findfirst(x -> x == "source2_v_C_c", env.state_ids)
        end

        u_l1 = env.state[u_l1_index]
        u_l2 = env.state[u_l2_index]
        u_l3 = env.state[u_l3_index]

        u = [u_l1, u_l2, u_l3]
        refs = reference(env.t)

        r = -(sum(abs.(refs/600 - u)/3))
    end

    return r
end

function featurize(x0 = nothing, t0 = nothing; env = nothing, name = nothing)
    if !isnothing(name)
        state = env.state
        if name == agentname
            global state_ids_agent
            global state_ids
            state = state[findall(x -> x in state_ids_agent, state_ids)]
            state = vcat(state, reference(env.t)/600)
        else
            global state_ids_classic
            global state_ids
            state = env.x[findall(x -> x in state_ids_classic, state_ids)]
        end
    elseif isnothing(env)
        return x0
    else
        return env.state
    end
    return state
end

function RLBase.action_space(env::SimEnv, name::String)
    if name == "agent"
        return Space(fill(-1.0..1.0, size(action_ids_agent)))
    else
        return Space(fill(-1.0..1.0, size(action_ids_classic)))
    end
end

print("\n...........o0o----ooo0o0ooo~~~  START  ~~~ooo0o0ooo----o0o...........\n")

#_______________________________________________________________________________
# Parameters - Time simulation
Timestep = 100 #time step in μs ~ 100μs => 10kHz, 50μs => 20kHz, 20μs => 50kHz
t_final = 0.5 #time in seconds, total simulation run time

ts = Timestep*1e-6
t = 0:ts:t_final # time

fs = 1/ts # Hz, Sampling frequency of controller ~ 15 kHz < fs < 50kHz

#_______________________________________________________________________________
# State space representation

#-------------------------------------------------------------------------------
# Connectivity Matrix

CM = [ 0. 0. 0. 1.
        0. 0. 0. 2.
        0. 0. 0. 3.
        -1. -2. -3. 0.]

#= CM = [ 0. 0. 1.
        0. 0. 2
        -1. -2. 0.] =#

#= CM = [0. 1.
   -1. 0.] =#

#-------------------------------------------------------------------------------
# Cables

cable_list = []

# Network Cable Impedances
l = 2.5 # length in km
cable = Dict()
cable["R"] = 0.208*l # Ω, line resistance 0.722#
cable["L"] = 0.00025*l # H, line inductance 0.264e-3#
cable["C"] = 0.4e-6*l # 0.4e-6#

push!(cable_list, cable, cable, cable)

#-------------------------------------------------------------------------------
# Sources

source_list = []
source = Dict()

source["pwr"] = 200e3
source["vdc"] = 800
source["fltr"] = "LC"
Lf, Cf, _ = Filter_Design(source["pwr"], fs)
source["R1"] = 0.4
source["R_C"] = 0.0006
source["L1"] = Lf
source["C"] = Cf

push!(source_list, source)

source = Dict()

source["pwr"] = 200e3
source["vdc"] = 800
source["fltr"] = "LC"
Lf, Cf, _ = Filter_Design(source["pwr"], fs)
source["R1"] = 0.4
source["R_C"] = 0.0006
source["L1"] = Lf
source["C"] = Cf

push!(source_list, source)

source = Dict()

source["pwr"] = 200e3
source["vdc"] = 800
source["fltr"] = "LC"
Lf, Cf, _ = Filter_Design(source["pwr"], fs)
source["R1"] = 0.4
source["R_C"] = 0.0006
source["L1"] = Lf
source["C"] = Cf

push!(source_list, source)

#-------------------------------------------------------------------------------
# Loads

load_list = []
load = Dict()

R1_load, L_load, _, _ = Load_Impedance_2(50e3, 0.6, 230)
#R2_load, C_load, _, _ = Load_Impedance_2(150e3, -0.8, 230)

load["impedance"] = "RL"
load["R"] = R1_load# + R2_load # 
load["L"] = L_load
#load["C"] = C_load

push!(load_list, load)

#-------------------------------------------------------------------------------
# Amalgamation

parameters = Dict()

parameters["source"] = source_list
parameters["cable"] = cable_list
parameters["load"] = load_list
parameters["grid"] = Dict("fs" => fs, "phase" => 3, "v_rms" => 230)

# Define the environment

num_sources = length(source_list)
num_loads = length(load_list)

env = SimEnv(reward_function = reward, featurize = featurize, 
ts = ts, use_gpu = false, CM = CM, num_sources = num_sources, num_loads = num_loads, 
parameters = parameters, maxsteps = length(t), action_delay = 1)

state_ids = get_state_ids(env.nc)
action_ids = get_action_ids(env.nc)

#_______________________________________________________________________________
# Setting up the Reinforcement Learning Sources

agentname = "agent"

state_ids_agent = filter(x -> split(x, "_")[1] == "source1", state_ids)
action_ids_agent = filter(x -> split(x, "_")[1] == "source1", action_ids)

na = length(env.action_space)
agent = create_agent_ddpg(na = length(action_ids_agent), ns = length(state(env,agentname)), use_gpu = false)
agent = Agent(policy = NamedPolicy(agentname, agent.policy), trajectory = agent.trajectory)

#_______________________________________________________________________________
# Setting up the Classical Sources

# Animo = NamedPolicy("classic", Classical_Policy(env, Modes = [4, 6, 3], Source_Indices = [1 2 3]))
Animo = NamedPolicy("classic", Classical_Policy(env, Modes = [1, 1], Source_Indices = [2 3]))

#= Modes:
    1 -> "Swing" - voltage source without dynamics (i.e. an Infinite Bus)
    2 -> "Voltage Control" - voltage source with controller dynamics

    3 -> "PQ Control" - grid following controllable source/load

    4 -> "Droop Control" - simple grid forming with power balancing
    5 -> "Full-Synchronverter" - droop control on real and imaginary powers
    6 -> "Semi-Synchronverter" - droop characteristic on real power, and active control on voltage
=#

nm_src = 1 #2

Animo.policy.Source.τv[nm_src] = 0.002 # time constant of the voltage loop # 0.02
Animo.policy.Source.τf[nm_src] = 0.002 # time constant of the frequency loop # 0.002

Animo.policy.Source.pq0_set[nm_src, 1] = 50e3 # W, Real Power
Animo.policy.Source.pq0_set[nm_src, 2] = 10e3 # VAi, Imaginary Power

Animo.policy.Source.V_pu_set[nm_src, 1] = 0.95
Animo.policy.Source.V_δ_set[nm_src, 1] = -0*π/180

nm_src = 2 #3

Animo.policy.Source.pq0_set[nm_src, 1] = 65e3 # W, Real Power
Animo.policy.Source.pq0_set[nm_src, 2] = -25e3 # VAi, Imaginary Power

state_ids_classic = Animo.policy.state_ids
action_ids_classic = Animo.policy.action_ids

#= ma_agents = Dict(nameof(Animo) => Dict("policy" => Animo,
                            "state_ids" => state_ids_classic,
                            "action_ids" => action_ids_classic)) =#

ma_agents = Dict(nameof(agent) => Dict("policy" => agent,
                            "state_ids" => state_ids_agent,
                            "action_ids" => action_ids_agent),
                nameof(Animo) => Dict("policy" => Animo,
                            "state_ids" => state_ids_classic,
                            "action_ids" => action_ids_classic))
                            
ma = MultiAgentGridController(ma_agents, action_ids)

#_______________________________________________________________________________
#%% Starting time simulation

plt_state_ids = ["source1_v_C_a", "source1_i_L1_a"]
plt_action_ids = []#"u_v1_a", "u_v1_b", "u_v1_c"]
hook = DataHook(collect_state_ids = plt_state_ids, collect_action_ids = plt_action_ids, 
collect_vrms_idx = [3 2], collect_irms_idx = [3 2], collect_pq_idx = [3 2],
save_best_NNA = true, collect_reference = true, plot_rewards = true)

run(ma, env, StopAfterEpisode(100), hook);

#_______________________________________________________________________________
# Plotting

plot_hook_results(; hook = hook, actions_to_plot = [], episode = 200, 
pq_to_plot = [3 2], vrms_to_plot = [3 2], irms_to_plot = [3 2])

plot_best_results(;agent = ma, env = env, hook = hook, states_to_plot = plt_state_ids, 
plot_reward = false, plot_reference = true, use_best = false)

print("\n...........o0o----ooo0o0ooo~~~  END  ~~~ooo0o0ooo----o0o...........\n")