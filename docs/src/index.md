```@meta
CurrentModule = Capnp
```

# Capnp.jl

A pure Julia package for reading and writing [Cap'n Proto](https://capnproto.org/)
messages.

Capnp.jl implements the Cap'n Proto binary wire format (both unpacked and
packed encodings), multi-segment message building and reading, and a parser for
the Cap'n Proto schema language. It lets you serialize and deserialize
structured data without a code-generation step, and optionally drive typed
reading and writing from a parsed `.capnp` schema.

## Features

- The [binary encoding](https://capnproto.org/encoding.html) (unpacked stream
  format) with multi-segment messages.
- The [packed encoding](https://capnproto.org/encoding.html#packing) for
  bandwidth-efficient transport.
- Structs, lists (primitive, pointer, and composite), text, data, and far
  pointers (single and double landing pads).
- A recursive-descent parser for a useful subset of the Cap'n Proto
  [schema language](https://capnproto.org/language.html): structs, enums,
  interfaces, constants, nested nodes, unions, and the common field types.
- Schema-driven typed reading and writing via `read_struct` / `write_struct!`.

## Documentation Outline

```@contents
Pages = [
    "getting-started.md",
    "wire-format.md",
    "schema.md",
]
Depth = 2
```

## License

BSD 2-Clause; see [LICENSE](https://github.com/david-macmahon/Capnp.jl/blob/main/LICENSE).
