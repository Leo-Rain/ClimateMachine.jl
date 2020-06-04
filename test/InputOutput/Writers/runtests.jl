using NCDatasets
using OrderedCollections
using Test
using ClimateMachine.Writers

@testset "Writers" begin
    odims = OrderedDict(
        "x" => (collect(1:5), Dict()),
        "y" => (collect(1:5), Dict()),
        "z" => (collect(1010:10:1050), Dict()),
    )
    ovartypes = OrderedDict(
        "v1" => (("x", "y", "z"), Float64, Dict()),
        "v2" => (("x", "y", "z"), Float64, Dict()),
    )
    vals1 = rand(5, 5, 5)
    vals2 = rand(5, 5, 5)

    nc = NetCDFWriter()
    nfn, _ = mktemp()
    nfull = full_name(nc, nfn)

    init_data(nc, nfn, odims, ovartypes)
    append_data(nc, OrderedDict("v1" => vals1, "v2" => vals2), 0.5)

    NCDataset(nfull, "r") do nds
        @test nds["x"] == odims["x"][1]
        @test nds["y"] == odims["y"][1]
        @test nds["z"] == odims["z"][1]
        @test try
            nds["a"] == ones(5)
            false
        catch e
            true
        end
        @test length(nds["time"]) == 1
        @test nds["time"] == [0.5]
        @test nds["v1"] == vals1
        @test nds["v2"] == vals2
    end
end
