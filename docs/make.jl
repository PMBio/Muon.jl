using Documenter, Muon

makedocs(sitename="Muon Documentation", warnonly=:cross_references)

deploydocs(
    repo = "github.com/scverse/Muon.jl.git",
    devbranch = "main",
)
