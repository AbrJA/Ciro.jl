using Documenter, Ciro

makedocs(modules = [Ciro],
         sitename = "Ciro.jl",
         format = Documenter.HTML(),
         )

deploydocs(repo = "github.com/AbrJA/Ciro.jl.git")
