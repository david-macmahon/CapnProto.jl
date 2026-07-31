# schema.jl - AST types describing a parsed Cap'n Proto schema.
#
# We model the subset of the schema language needed to drive typed reading and
# writing. See https://capnproto.org/language.html for the language reference.

"""
    PrimitiveType

Enumeration of the primitive Cap'n Proto types used by the schema AST.
"""
@enum PrimitiveType begin
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
end

"""
    PT_Void

The `Void` type (carries no data).
"""
PT_Void
"""
    PT_Bool

A single bit.
"""
PT_Bool
"""
    PT_Int8

Signed 8-bit integer.
"""
PT_Int8
"""
    PT_Int16

Signed 16-bit integer.
"""
PT_Int16
"""
    PT_Int32

Signed 32-bit integer.
"""
PT_Int32
"""
    PT_Int64

Signed 64-bit integer.
"""
PT_Int64
"""
    PT_UInt8

Unsigned 8-bit integer.
"""
PT_UInt8
"""
    PT_UInt16

Unsigned 16-bit integer.
"""
PT_UInt16
"""
    PT_UInt32

Unsigned 32-bit integer.
"""
PT_UInt32
"""
    PT_UInt64

Unsigned 64-bit integer.
"""
PT_UInt64
"""
    PT_Float32

32-bit IEEE-754 float.
"""
PT_Float32
"""
    PT_Float64

64-bit IEEE-754 float.
"""
PT_Float64
"""
    PT_Text

A NUL-terminated UTF-8 string (`List(UInt8)`).
"""
PT_Text
"""
    PT_Data

A raw byte array (`List(UInt8)`).
"""
PT_Data

const PRIMITIVE_SIZES = Dict{PrimitiveType,UInt64}(
    PT_Void => VOID_LIST, PT_Bool => BOOL_LIST,
    PT_Int8 => INT8_LIST, PT_Int16 => INT16_LIST,
    PT_Int32 => INT32_LIST, PT_Int64 => INT64_LIST,
    PT_UInt8 => INT8_LIST, PT_UInt16 => INT16_LIST,
    PT_UInt32 => INT32_LIST, PT_UInt64 => INT64_LIST,
    PT_Float32 => INT32_LIST, PT_Float64 => INT64_LIST,
)

# A field's value type. `type_name` refers to a user-defined struct/enum by name
# (resolved within the file) for STRUCT and ENUM kinds. For LIST, `element` is
# the element Type.
struct Type
    kind::Symbol          # :primitive, :struct, :enum, :list, :interface
    primitive::PrimitiveType
    type_name::String     # for :struct / :enum / :interface
    element::Ref{Type}    # for :list (a Ref so we can build recursive types)
end
# A stable void Type reused as the list element placeholder for non-list Types.
const VOID_TYPE = Type(:primitive, PT_Void, "", Ref{Type}())
VOID_TYPE.element[] = VOID_TYPE
Type(kind::Symbol, prim::PrimitiveType=PT_Void, name::AbstractString="", elem::Union{Type,Nothing}=nothing) =
    Type(kind, prim, String(name), Ref{Type}(elem === nothing ? VOID_TYPE : elem))

# Field kinds.
@enum FieldKind begin
    FK_NORMAL    # regular data or pointer field
    FK_UNION     # the synthesized group field for an unnamed union
end

"""
    StructField

A field of a struct. For data fields, `data_word`, `data_byte`, and `data_bit`
locate the field within the struct's data section. For pointer fields, `ptr_slot`
is the 0-based pointer index. `discriminant` is the union discriminant value for
this field, or -1 if the field is not part of a union.
"""
struct StructField
    name::String
    ordinal::Int          # the @N number, also used for default-positioning
    type::Type
    # Data-section layout (only valid when type is a primitive data type).
    data_word::Int
    data_byte::Int        # byte offset within the word (0..7)
    data_bit::Int         # bit offset within the byte (0..7) for Bool
    # Pointer-section layout (valid when type is Text, Data, struct, list, interface).
    ptr_slot::Int
    # For union members: the discriminant value this field corresponds to, or -1
    # if the field is not part of a union.
    discriminant::Int
    has_default::Bool
    default_value::UInt64 # for primitive defaults (encoded as a raw word)
end

"""
    EnumValue

A named value of an enum (`name @ordinal;`).
"""
struct EnumValue
    name::String
    ordinal::Int
end

"""
    EnumNode

A parsed `enum` node: a list of `EnumValue`s.
"""
struct EnumNode
    name::String
    values::Vector{EnumValue}
end

"""
    InterfaceMethod

A method of an interface (`name @N (Params) :Result;`).
"""
struct InterfaceMethod
    name::String
    ordinal::Int
    param_type::String     # name of the params struct (we don't model params in detail)
    return_type::String
end

"""
    InterfaceNode

A parsed `interface` node: a list of `InterfaceMethod`s.
"""
struct InterfaceNode
    name::String
    methods::Vector{InterfaceMethod}
end

"""
    StructNode

A parsed `struct` node. `data_words` and `ptr_count` give the struct's wire
layout; `fields` holds the parsed fields with their computed positions. Nested
nodes are kept in `nested` by name.
"""
struct StructNode
    name::String
    data_words::Int
    ptr_count::Int
    fields::Vector{StructField}
    # Union bookkeeping: discriminant pointer slot (-1 for no union), and the
    # number of union members.
    discriminant_ptr::Int
    discriminant_count::Int
    # Nested nodes by name.
    nested::Dict{String,Any}  # values are StructNode, EnumNode, InterfaceNode
end

"""
    ConstNode

A parsed `const` declaration. The value is stored as raw text; interpretation
is left to callers.
"""
struct ConstNode
    name::String
    type::Type
    # We store the raw textual default; interpretation is left to callers.
    value_text::String
end

"""
    SchemaFile

A parsed Cap'n Proto schema file. `nodes` holds top-level nodes by name; `flat`
includes nested nodes keyed by dotted path (`\"Outer.Inner\"`) and also by bare
name.
"""
struct SchemaFile
    id::String             # the @0x... file id
    nodes::Dict{String,Any} # top-level nodes by name
    # A flat lookup including nested nodes, keyed by dotted path "Outer.Inner".
    flat::Dict{String,Any}
end

function Base.show(io::IO, s::StructNode)
    print(io, "struct ", s.name, " { data=", s.data_words, " ptrs=", s.ptr_count,
          ", fields=", length(s.fields), " }")
end
Base.show(io::IO, e::EnumNode) = print(io, "enum ", e.name, " { ", length(e.values), " values }")
