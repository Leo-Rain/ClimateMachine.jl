using ClimateMachine
ClimateMachine.init()

using ClimateMachine.Atmos
using ClimateMachine.ConfigTypes
using ClimateMachine.Diagnostics
using ClimateMachine.GenericCallbacks
using ClimateMachine.ODESolvers
using ClimateMachine.Mesh.Filters
using ClimateMachine.MoistThermodynamics
using ClimateMachine.VariableTemplates
using ClimateMachine.VTK
using ClimateMachine.Atmos: vars_state_conservative, vars_state_auxiliary

using StaticArrays
using Test
using Printf
using MPI

using CLIMAParameters
using CLIMAParameters.Atmos.SubgridScale: C_smag
using CLIMAParameters.Planet: R_d, cp_d, cv_d, MSLP, grav
struct EarthParameterSet <: AbstractEarthParameterSet end
const param_set = EarthParameterSet()

# ------------------------ Description ------------------------- #
# 1) Dry Rising Bubble (circular potential temperature perturbation)
# 2) Boundaries - `All Walls` : Impenetrable(FreeSlip())
#                               Laterally periodic
# 3) Domain - 20000m[horizontal] x 10000m[vertical] (2-dimensional)
# 4) Timeend - 1000s
# 5) Mesh Aspect Ratio (Effective resolution) 2:1
# 7) Overrides defaults for
#               `init_on_cpu`
#               `solver_type`
#               `sources`
#               `C_smag`
# 8) Default settings can be found in `src/Driver/Configurations.jl`
# ------------------------ Description ------------------------- #
function init_risingbubble!(bl, state, aux, (x, y, z), t)
    FT = eltype(state)
    R_gas::FT = R_d(bl.param_set)
    c_p::FT = cp_d(bl.param_set)
    c_v::FT = cv_d(bl.param_set)
    γ::FT = c_p / c_v
    p0::FT = MSLP(bl.param_set)
    _grav::FT = grav(bl.param_set)

    xc::FT = 10000
    zc::FT = 2000
    r = sqrt((x - xc)^2 + (z - zc)^2)
    rc::FT = 2000
    θ_ref::FT = 300
    Δθ::FT = 0

    if r <= rc
        Δθ = FT(2) * cospi(0.5*r/rc)^2
    end

    #Perturbed state:
    θ = θ_ref + Δθ # potential temperature
    π_exner = FT(1) - _grav / (c_p * θ) * z # exner pressure
    ρ = p0 / (R_gas * θ) * (π_exner)^(c_v / R_gas) # density
    q_tot = FT(0)
    ts = LiquidIcePotTempSHumEquil(bl.param_set, θ, ρ, q_tot)
    q_pt = PhasePartition(ts)

    u = SVector(FT(20), FT(0), FT(0))

    #State (prognostic) variable assignment
    e_kin = FT(0.5*20*20)
    e_pot = gravitational_potential(bl.orientation, aux)
    ρe_tot = ρ * total_energy(e_kin, e_pot, ts)
    state.ρ = ρ
    state.ρu = ρ*u
    state.ρe = ρe_tot
    state.moisture.ρq_tot = ρ * q_pt.tot
end

function config_risingbubble(FT, N, resolution, xmax, ymax, zmax)

    # Choose explicit solver
    solver_type = MultirateInfinitesimalStep

    if solver_type==MultirateInfinitesimalStep
        ode_solver = ClimateMachine.MISSolverType(
            linear_model = AtmosAcousticGravityLinearModel,
            slow_method = MIS2,
            fast_method = (dg,Q) -> StormerVerlet(dg, [1,5], 2:4, Q),
            number_of_steps = (10,),
        )
        Δt=FT(0.4)
    elseif solver_type==MultirateRungeKutta
        ode_solver = ClimateMachine.MultirateSolverType(
            linear_model = AtmosAcousticGravityLinearModel,
            slow_method = LSRK144NiegemannDiehlBusch,
            #fast_method = LSRK144NiegemannDiehlBusch,
            fast_method = LSRK54CarpenterKennedy,
            timestep_ratio = 10,
        )
        Δt=nothing
    end

    # Set up the model
    C_smag = FT(0.23)
    ref_state = HydrostaticState(DryAdiabaticProfile(typemin(FT), FT(300)), FT(0))
        #HydrostaticState(IsothermalProfile(FT(T_0)),FT(0))
        #HydrostaticState(DryAdiabaticProfile(typemin(FT), FT(300)), FT(0))
    model = AtmosModel{FT}(
        AtmosLESConfigType,
        param_set;
        turbulence = SmagorinskyLilly{FT}(C_smag), #AnisoMinDiss{FT}(1),
        source = (Gravity(),),
        ref_state = ref_state,
        init_state_conservative = init_risingbubble!,
    )

    # Problem configuration
    config = ClimateMachine.AtmosLESConfiguration(
        "DryRisingBubble",
        N,
        resolution,
        xmax,
        ymax,
        zmax,
        param_set,
        init_risingbubble!,
        solver_type = ode_solver,
        model = model,
        #boundary = ((0, 0), (0, 0), (0, 0)),
        #periodicity = (false, true, false),
    )
    return config, Δt
end

function config_diagnostics(driver_config)
    interval = "10000steps"
    dgngrp = setup_atmos_default_diagnostics(interval, driver_config.name)
    return ClimateMachine.DiagnosticsConfiguration([dgngrp])
end

function main()
    ClimateMachine.init()

    # Working precision
    FT = Float64
    # DG polynomial order
    N = 4
    # Domain resolution and size
    Δx = FT(125)
    Δy = FT(125)
    Δz = FT(125)
    resolution = (Δx, Δy, Δz)
    # Domain extents
    xmax = FT(20000)
    ymax = FT(1000)
    zmax = FT(10000)
    # Simulation time
    t0 = FT(0)
    timeend = FT(1000)

    # Courant number
    CFL = FT(20)

    driver_config, Δt = config_risingbubble(FT, N, resolution, xmax, ymax, zmax)
    solver_config = ClimateMachine.SolverConfiguration(
        t0,
        timeend,
        driver_config,
        init_on_cpu = true,
        ode_dt = Δt,
        Courant_number = CFL,
    )
    dgn_config = config_diagnostics(driver_config)

    # User defined filter (TMAR positivity preserving filter)
    cbtmarfilter = GenericCallbacks.EveryXSimulationSteps(1) do (init = false)
        Filters.apply!(solver_config.Q, 6, solver_config.dg.grid, TMARFilter())
        nothing
    end

    nvtk=timeend/(Δt*100)
    vtk_step = 0
    cbvtk = GenericCallbacks.EveryXSimulationSteps(nvtk)  do (init=false)
        mkpath("./vtk-rtb/")
        outprefix = @sprintf("./vtk-rtb/risingBubbleBryanTranslationSplit_mpirank%04d_step%04d",
                         3, vtk_step)
                         #MPI.Comm_rank(driver_config.mpicomm), vtk_step)
        writevtk(outprefix, solver_config.Q, solver_config.dg,
            flattenednames(vars_state_conservative(driver_config.bl,FT)),
            solver_config.dg.state_auxiliary,
            flattenednames(vars_state_auxiliary(driver_config.bl,FT)))
        vtk_step += 1
        nothing
     end

    # Invoke solver (calls solve! function for time-integrator)
    result = ClimateMachine.invoke!(
        solver_config;
        diagnostics_config = dgn_config,
        user_callbacks = (cbvtk,),
        check_euclidean_distance = true,
    )

    @test isapprox(result, FT(1); atol = 1.5e-3)
end

main()