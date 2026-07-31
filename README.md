# Capnp.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://david-macmahon.github.io/Capnp.jl/dev/)
[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://david-macmahon.github.io/Capnp.jl/stable/)

A pure Julia package for reading and writing [Cap'n Proto](https://capnproto.org/) messages.

This package supports:
- The [Cap'n Proto binary encoding](https://capnproto.org/encoding.html) (unpacked and packed)
- Multi-segment message building and reading
- Structs, lists (including composite lists), text, data, and far pointers
- A parser for the Cap'n Proto schema language (`.capnp` files)
- Schema-driven typed reading and writing

## Status

Early development. The wire format and packed encoding are functional and
roundtrip-tested. The schema parser supports a useful subset of the schema
language: structs, enums, interfaces, constants, nested nodes, unions (with
discriminant), and common field types (primitive, text, data, struct, list).

## Installation

```julia
] dev /path/to/Capnp.jl
```

## Quick start

### Low-level message building

```julia
using Capnp

# Build a message with a root struct that has 2 data words and 2 pointer slots.
b = MessageBuilder()
root = init_root_struct!(b, 2, 2)
set_int64!(root, 0, 0x0102030405060708)
set_text!(root, 0, "hello")
bytes = write_packed(b)

# Read it back.
r = read_packed(bytes)
root_r = get_root(r)
get_int64(root_r, 0)        # -> 0x0102030405060708
get_text(root_r, 0)         # -> "hello"
```

### Schema-driven reading and writing

```julia
using Capnp

schema = parse_schema(\"\"\"
@0xab12cd34ef56ef78;
struct Person {
    name @0 :Text;
    age  @1 :Int32;
    emails @2 :List(Text);
}
\"\"\")

person = schema[:Person]
b = MessageBuilder()
root = init_root_struct!(b, person.data_words, person.ptr_count)
write_struct!(root, person, (name="Alice", age=30, emails=["a@x", "b@y"]))
bytes = write_packed(b)

r = read_packed(bytes)
read_struct(get_root(r), person)  # -> (name="Alice", age=30, emails=["a@x","b@y"])
```

## Layout

```
src/
  Capnp.jl         module + exports
  wire.jl          low-level pointer & bit utilities
  message.jl       segment-based message buffer (read & write views)
  builder.jl       StructBuilder / ListBuilder and setters
  reader.jl        StructReader / ListReader and getters
  packed.jl        packed encoding read/write
  schema.jl        schema AST types
  schema_parser.jl parser for the Cap'n Proto schema language
  typed.jl         schema-driven read_struct / write_struct!
test/
  runtests.jl
```

## Testing

```julia
] test Capnp
```

## Documentation

The docs are built with [Documenter.jl](https://documenter.juliadocs.org/) and
served at https://david-macmahon.github.io/Capnp.jl/. To build them locally:

```julia
julia --project=docs docs/make.jl
```

The build is automated via a GitHub Actions workflow
(`.github/workflows/Documentation.yml`) that deploys to the `gh-pages` branch on
push to `main` and on tags, with preview builds for pull requests.

## License

BSD 2-Clause; see [LICENSE](LICENSE).
