# This is code that is associated to the article "Hybrid control of interconnected power converters using both expert-driven droop and data-driven reinforcement learning approaches", which is currently in the publication process.

# In this script we set up an experiment with two sources - one being controlled by a classical controller in Droop mode, the other by RL - each of which are connected to a load. The goal of the RL agent will be to control the input voltage of the source such that the corresponding current will match a reference signal which is a 3-phase sine signal.


using ElectricGrid

# create CM matrix and the parameters dict

CM = [ 0. 0. 1.
        0. 0. 2.
        -1. -2. 0.]

R_load, L_load, _, _ = ParallelLoadImpedance(50e3, 0.95, 230)

parameters =
Dict{Any, Any}(
    "source" => Any[
                    Dict{Any, Any}(
                        "pwr" => 200e3,
                        "control_type" => "RL",
                        "fltr" => "L",
                        #"L1" => 0.0008,
                        ),
                    Dict{Any, Any}(
                        "pwr" => 200e3,
                        "fltr" => "LC",
                        "control_type" => "classic",
                        "mode" => "Droop",),
                    ],
    "load"   => Any[
        Dict{Any, Any}(
            "impedance" => "RL",
            "R" => R_load,
            "L" => L_load,
            "v_limit" => 1e4,
            "i_limit" => 1e4)
        ],
    "grid" => Dict{Any, Any}(
        "phase" => 3,
        "ramp_end" => 0.04,)
)



# This function provides the reference signal. Note that we are outputting zeros in the first 0.04 seconds which is about the time the system needs to start up properly.

function reference(t)
    if t < 0.04
        return [0.0, 0.0, 0.0]
    end

    θ = 2*pi*50*t
    θph = [θ; θ - 120π/180; θ + 120π/180]
    return +10 * cos.(θph)
end


# The featurize function adds the reference signal to the state of the agent (normalized).

featurize_ddpg = function(state, env, name)
    if name == "ElectricGrid_ddpg_1"

        norm_ref = env.nc.parameters["source"][1]["i_limit"]
        state = vcat(state, reference(env.t)/norm_ref)

    end
end


# The reward function computes the error of all three phases, takes the square root and then sums them together.

function reward_function(env, name = nothing)
    if name == "classic"
        return 0

    else
        state_to_control_1 = env.state[findfirst(x -> x == "source1_i_L1_a", env.state_ids)]
        state_to_control_2 = env.state[findfirst(x -> x == "source1_i_L1_b", env.state_ids)]
        state_to_control_3 = env.state[findfirst(x -> x == "source1_i_L1_c", env.state_ids)]

        state_to_control = [state_to_control_1, state_to_control_2, state_to_control_3]

        if any(abs.(state_to_control).>1)
            return -1
        else

            refs = reference(env.t)
            norm_ref = env.nc.parameters["source"][1]["i_limit"]
            r = 1-1/3*(sum((abs.(refs/norm_ref - state_to_control)/2).^0.5))
            return r
        end
    end

end


# Now we can set up the env and the controllers and define a training functions.

env = ElectricGridEnv(
    CM =  CM,
    parameters = parameters,
    t_end = 1,
    reward_function = reward_function,
    featurize = featurize_ddpg,
    action_delay = 0,
    verbosity = 0)


controllers = SetupAgents(env)

learnhook = DataHook()


# We will train with the default action noise (0.032) for 1.5m steps and then proceed with a learning phase with an action noise scheduler equipped. Learning will not always be successful - a successful run usually gets a highscore per episode of about 9500 in the first learning phase.

function learn()
    num_steps = 50_000

    an_scheduler_loops = 20

    Learn(controllers, env, steps = num_steps, hook = learnhook)
    while true
        if length(controllers.hook.df[!,"reward"]) <= 1_500_000
            println("Steps so far: $(length(controllers.hook.df[!,"reward"]))")
            Learn(controllers, env, steps = num_steps, hook = learnhook)
        else
            for j in 1:10
                an = 0.01 * exp10.(collect(LinRange(0.0, -10, an_scheduler_loops)))
                for i in 1:an_scheduler_loops
                    controllers.agents["ElectricGrid_ddpg_1"]["policy"].policy.policy.act_noise = an[i]
                    println("Steps so far: $(length(controllers.hook.df[!,"reward"]))")
                    println("next action noise level: $(an[i])")
                    Learn(controllers, env, steps = num_steps, hook = learnhook)
                end
            end
        end
    end
end

function learn1()
    steps_total = 1_500_000

    steps_loop = 50_000

    Learn(controllers, env, steps = steps_loop, hook = learnhook)

    while length(controllers.hook.df[!,"reward"]) <= steps_total

        println("Steps so far: $(length(controllers.hook.df[!,"reward"]))")
        Learn(controllers, env, steps = steps_loop, hook = learnhook)

    end

end

# second training phase with action noise scheduler
function learn2()
    num_steps = 50_000

    an_scheduler_loops = 20


    for j in 1:10
        an = 0.01 * exp10.(collect(LinRange(0.0, -10, an_scheduler_loops)))
        for i in 1:an_scheduler_loops
            controllers.agents["ElectricGrid_ddpg_1"]["policy"].policy.policy.act_noise = an[i]
            println("Steps so far: $(length(controllers.hook.df[!,"reward"]))")
            println("next action noise level: $(an[i])")
            Learn(controllers, env, steps = num_steps, hook = learnhook)
        end
    end
end


# Start training!

learn()


# Now we start a simulation run with the fully trained agent and plot the results.

hook = DataHook(collect_state_ids = env.state_ids,
                collect_action_ids = env.action_ids);

Simulate(controllers, env, hook=hook);


RenderHookResults(hook = hook, states_to_plot  = env.state_ids, actions_to_plot = env.action_ids, plot_reward=true)
