using Documenter
using Capnp

makedocs(
    sitename = "Capnp.jl",
    authors = "David MacMahon",
    repo = Remotes.GitHub("david-macmahon", "Capnp.jl"),
    modules = [Capnp],
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Wire Format" => "wire-format.md",
        "Schema Language" => "schema.md",
    ],
    warnonly = [:missing_docs],
    remotes = nothing,
)

deploydocs(
    repo = "github.com/david-macmahon/Capnp.jl",
    branch = "gh-pages",
    devbranch = "main",
    push_preview = true,
)
