using Documenter
using CapnProto

makedocs(
    sitename = "CapnProto.jl",
    authors = "David MacMahon",
    repo = Remotes.GitHub("david-macmahon", "CapnProto.jl"),
    modules = [CapnProto],
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
    repo = "github.com/david-macmahon/CapnProto.jl",
    branch = "gh-pages",
    devbranch = "main",
    push_preview = true,
)
