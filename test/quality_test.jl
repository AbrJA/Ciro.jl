using Test
using Ciro

const HAS_AQUA = try using Aqua; true catch; false end
const HAS_JET = try using JET; true catch; false end

@testset "Code Quality" begin

    if HAS_AQUA
        @testset "Aqua.jl" begin
            Aqua.test_all(Ciro)
        end
    end

    if HAS_JET
        @testset "JET.jl" begin
            rep = JET.report_package(Ciro;
                target_modules=(Ciro, Ciro.Interface, Ciro.Backend, Ciro.HTTP,
                                Ciro.Core, Ciro.Router, Ciro.Runtime))
            reports = JET.get_reports(rep)
            foreach(println, reports)
            @test isempty(reports)
        end
    end
end
