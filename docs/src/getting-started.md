```@meta
CurrentModule = Capnp
```

# Getting Started

## Installation

```julia
] dev /path/to/Capnp.jl
```

or, once registered:

```julia
] add Capnp
```

## A first message: low-level building

The low-level API exposes a [`MessageBuilder`](@ref) onto which you allocate a
root struct with [`init_root_struct!`](@ref). Fields are written with typed
setters such as [`set_int64!`](@ref) and [`set_text!`](@ref).

```julia
using Capnp

b = MessageBuilder()
root = init_root_struct!(b, 2, 2)        # 2 data words, 2 pointer slots
set_int64!(root, 0, 0x0102030405060708)
set_int32!(root, 1, 0x0a0b0c0d)
set_text!(root, 0, "hello")

bytes = write_packed(b)                  # serialize with the packed encoding
```

Reading flips the direction: parse the bytes into a [`MessageReader`](@ref)
with [`read_packed`](@ref), fetch the root with [`get_root`](@ref), and use the
typed getters.

```julia
r = read_packed(bytes)
root = get_root(r)
get_int64(root, 0)        # -> 0x0102030405060708
get_uint32(root, 1)       # -> 0x0a0b0c0d
get_text(root, 0)         # -> "hello"
```

## Nested structs and lists

Pointer-typed fields are allocated with [`alloc_struct!`](@ref),
[`alloc_list!`](@ref), and [`alloc_composite_list!`](@ref), which return a
builder for the new object and write the pointer into the parent's pointer
section.

```julia
b = MessageBuilder()
root = init_root_struct!(b, 1, 2)
set_int32!(root, 0, 42)

sub = alloc_struct!(root, 0, 1, 1)
set_int64!(sub, 0, 999)
set_text!(sub, 0, "nested")

lst = alloc_list!(root, 1, INT32_LIST, 4)
for i in 0:3
    set_element!(lst, i, UInt64(UInt32(i * 10)))
end

bytes = write_message(b)                 # unpacked this time
r, _ = read_message(bytes)
root = get_root(r)
get_int32(root, 0)                       # -> 42
sub_r = get_struct_field(root, 0)
get_int64(sub_r, 0)                      # -> 999
lst_r = get_list_field(root, 1)
[UInt32(get_element(lst_r, i)) for i in 0:3]   # -> UInt32[0, 10, 20, 30]
```

## Schema-driven reading and writing

When you have a schema, you can skip the manual layout and let the package
compute it. Parse a schema string with [`parse_schema`](@ref) and use
[`build_message`](@ref) / [`parse_message`](@ref) (or the lower-level
[`write_struct!`](@ref) / [`read_struct`](@ref)).

```julia
using Capnp

schema = parse_schema(\"\"\"
@0xab12cd34ef56ef78;
struct Person {
    name   @0 :Text;
    age    @1 :Int32;
    emails @2 :List(Text);
}
\"\"\")

val = (name="Alice", age=30, emails=["a@x.com", "b@y.com"])
bytes = build_message(schema, "Person", val)

out = parse_message(schema, "Person", bytes)
# -> (name = "Alice", age = 30, emails = ["a@x.com", "b@y.com"])
```

See the [Wire Format](@ref) and [Schema Language](@ref) pages for the full
low-level and schema-driven APIs.
