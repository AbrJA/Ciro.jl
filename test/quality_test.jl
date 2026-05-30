using Test
using Ciro

const HAS_AQUA = try using Aqua; true catch; false end
const HAS_JET = try using JET; true catch; false end

@testset "Code Quality" begin

    if HAS_AQUA
        @testset "Aqua.jl" begin
            Aqua.test_all(Ciro;
                ambiguities=false,
                piracies=false,
                deps_compat=(check_extras=false,),
            )
        end
    end

    if HAS_JET
        @testset "JET.jl" begin
            rep = JET.report_package(Ciro; target_modules=(Ciro,))
            @test length(JET.get_reports(rep)) == 0
        end
    end
end
