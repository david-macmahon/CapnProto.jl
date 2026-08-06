```@meta
CurrentModule = CapnProto
```

# Schema Language

CapnProto.jl includes a recursive-descent parser for a useful subset of the Cap'n
Proto [schema language](https://capnproto.org/language.html). Parsing a schema
returns a [`SchemaFile`](@ref) whose nodes can be looked up by name and used to
drive typed reading and writing.

## Supported subset

- File id (`@0x...;`), `import` declarations (recorded but not resolved).
- Top-level and nested `struct`, `enum`, `interface`, `const`, and `annotation`
  declarations.
- Struct fields with explicit ordinals (`name @N :Type;`).
- Field types: all primitives (`Void`, `Bool`, `Int8`..`Int64`, `UInt8`..`UInt64`,
  `Float32`, `Float64`), `Text`, `Data`, `List(T)`, and named struct/enum
  references.
- Default values (`= ...`) for primitive fields.
- Unnamed unions (`union { ... }`) inside a struct, with the discriminant
  value tracked per field.

Not yet supported: groups, generics, `using` aliases, annotation targets, and
resolution of imports across files.

## Parsing

```@docs
parse_schema
parse_schema_file
SchemaFile
Base.getindex(::SchemaFile, ::AbstractString)
```

## Schema AST nodes

```@docs
StructNode
EnumNode
InterfaceNode
ConstNode
StructField
EnumValue
InterfaceMethod
```

## Typed reading and writing

```@docs
write_struct!
read_struct
build_message
parse_message
parse_struct
parse_messages
MessageIterator
with_offsets
OffsetMessageIterator
```

## Primitive types

The primitive type enum used by the schema AST:

```@docs
PrimitiveType
PT_Void
PT_Bool
PT_Int8
PT_Int16
PT_Int32
PT_Int64
PT_UInt8
PT_UInt16
PT_UInt32
PT_UInt64
PT_Float32
PT_Float64
PT_Text
PT_Data
```

## Example

```julia
using CapnProto

schema = parse_schema(\"\"\"
@0xab12cd34ef56ef78;

struct Person {
    name   @0 :Text;
    age    @1 :Int32;
    emails @2 :List(Text);
}

enum Color {
    red   @0;
    green @1;
    blue  @2;
}
\"\"\")

person = schema[:Person]            # StructNode
person.data_words                   # 1
person.ptr_count                    # 2
person.fields[1].name               # "name"
person.fields[2].name               # "age"
person.fields[3].name               # "emails"

color = schema[:Color]              # EnumNode
[v.name for v in color.values]      # ["red", "green", "blue"]
```

### Nested structs

Nested struct nodes are reachable under both their dotted path
(`"Outer.Inner"`) and their bare name (`"Inner"`):

```julia
schema = parse_schema(\"\"\"
@0x11;
struct Outer {
    a @0 :Int64;
    b @1 :Inner;
    struct Inner {
        x @0 :Int32;
        y @1 :Text;
    }
}
\"\"\")
schema["Outer.Inner"].name          # "Inner"
schema["Inner"].name                # "Inner"  (bare name also works)
```
