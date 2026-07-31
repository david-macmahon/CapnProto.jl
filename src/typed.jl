# typed.jl - schema-driven reading and writing.
#
# `write_struct!` and `read_struct` take a `StructNode` and a Julia value (either
# a NamedTuple or a Dict) and serialize/deserialize it. Field names in the Julia
# value are matched to schema field names case-sensitively.

# ----- Writing -----------------------------------------------------------------

"Write a Julia value `x` into the StructBuilder `s` according to schema `node`.
`x` may be a NamedTuple or an AbstractDict keyed by field name (as Symbol or String)."
function write_struct!(s::StructBuilder, node::StructNode, x)
    for f in node.fields
        name = f.name
        val = lookup_field(x, name)
        if val === nothing
            continue  # leave default / unset
        end
        write_field!(s, f, val)
    end
    return nothing
end

function lookup_field(x, name::AbstractString)
    if x isa NamedTuple
        sym = Symbol(name)
        return hasfield(typeof(x), sym) ? getfield(x, sym) : nothing
    elseif x isa AbstractDict
        return haskey(x, Symbol(name)) ? x[Symbol(name)] :
               haskey(x, name) ? x[name] : nothing
    else
        sym = Symbol(name)
        return hasproperty(x, sym) ? getproperty(x, sym) : nothing
    end
end

function write_field!(s::StructBuilder, f::StructField, val)
    ty = f.type
    if ty.kind == :primitive
        return write_primitive!(s, f, ty.primitive, val)
    elseif ty.kind == :list
        return write_list_field!(s, f, ty.element[], val)
    elseif ty.kind == :struct
        return write_struct_field!(s, f, ty.type_name, val)
    else
        error("unsupported field type kind $(ty.kind) for field $(f.name)")
    end
end

function write_primitive!(s::StructBuilder, f::StructField, prim::PrimitiveType, val)
    if prim == PT_Void
        return nothing
    elseif prim == PT_Bool
        return set_bool!(s, f.data_word, f.data_bit, Bool(val))
    elseif prim in (PT_Int8, PT_UInt8)
        return set_subword!(s, f.data_word, f.data_byte, 8, UInt64(UInt8(val)))
    elseif prim in (PT_Int16, PT_UInt16)
        w = f.data_word
        shift = f.data_byte * 8
        cur = get_word(s.msg, s.seg, s.base + w)
        mask = UInt64(0xffff) << shift
        v = UInt64(UInt16(val))
        set_word_field!(s, w, (cur & ~mask) | ((v << shift) & mask))
        return nothing
    elseif prim in (PT_Int32, PT_UInt32, PT_Float32)
        v = prim == PT_Float32 ? UInt64(reinterpret(UInt32, Float32(val))) : UInt64(UInt32(val))
        shift = f.data_byte * 8
        cur = get_word(s.msg, s.seg, s.base + f.data_word)
        mask = UInt64(0xffffffff) << shift
        set_word_field!(s, f.data_word, (cur & ~mask) | ((v << shift) & mask))
        return nothing
    elseif prim in (PT_Int64, PT_UInt64, PT_Float64)
        v = prim == PT_Float64 ? reinterpret(UInt64, Float64(val)) :
            prim == PT_Int64 ? reinterpret(UInt64, Int64(val)) : UInt64(val)
        return set_word_field!(s, f.data_word, v)
    elseif prim == PT_Text
        return set_text!(s, f.ptr_slot, String(val))
    elseif prim == PT_Data
        return set_data!(s, f.ptr_slot, Vector{UInt8}(val))
    end
    return nothing
end

function write_list_field!(s::StructBuilder, f::StructField, elem_type::Type, val)
    items = collect(val)
    n = length(items)
    if elem_type.kind == :primitive
        prim = elem_type.primitive
        if prim in (PT_Text, PT_Data)
            # List(Text) or List(Data): pointer list.
            lb = alloc_list!(s, f.ptr_slot, POINTER_LIST, n)
            for (i, item) in enumerate(items)
                if prim == PT_Text
                    set_text_element!(lb, i - 1, String(item))
                else
                    set_data_element!(lb, i - 1, Vector{UInt8}(item))
                end
            end
            return nothing
        end
        esize = PRIMITIVE_SIZES[prim]
        lb = alloc_list!(s, f.ptr_slot, esize, n)
        for (i, item) in enumerate(items)
            set_element!(lb, i - 1, encode_primitive(prim, item))
        end
        return nothing
    elseif elem_type.kind == :struct
        # Composite list.
        # Resolve the element struct node to get its layout.
        # We need the schema file - but the field's type only carries the name.
        # The caller is responsible for ensuring the element struct's layout
        # matches; here we infer data_words/ptr_count from the first item via a
        # recursive call would require the node. To keep this self-contained,
        # we require the caller to pass a schema via a thread-local.
        node = current_element_schema(elem_type.type_name)
        lb = alloc_composite_list!(s, f.ptr_slot, n, node.data_words, node.ptr_count)
        for (i, item) in enumerate(items)
            el = list_element_struct(lb, i - 1)
            write_struct!(el, node, item)
        end
        return nothing
    else
        error("unsupported list element kind $(elem_type.kind) for field $(f.name)")
    end
end

"Set element `i` (0-based) of a List(Data) (a pointer list) to raw bytes."
function set_data_element!(lb::ListBuilder, i::Int, data::Vector{UInt8})
    @assert lb.element_size == POINTER_LIST
    ptr_idx = lb.base + i
    fake = StructBuilder(lb.msg, lb.seg, ptr_idx, 0, 1)
    set_data!(fake, 0, data)
    return nothing
end

function write_struct_field!(s::StructBuilder, f::StructField, type_name::String, val)
    node = current_element_schema(type_name)
    sub = alloc_struct!(s, f.ptr_slot, node.data_words, node.ptr_count)
    write_struct!(sub, node, val)
    return nothing
end

# Thread-local schema stack so the typed writer can resolve named struct nodes
# without threading the SchemaFile through every call.
const _SCHEMA_STACK = SchemaFile[]
"Run `f()` with `sf` as the active schema for nested struct resolution by
`write_struct!`/`read_struct`. Schema-driven list/struct fields look up named
nodes from the active schema, so `with_schema` must wrap any code that uses
schema-driven reading or writing of nested struct types."
function with_schema(f, sf::SchemaFile)
    push!(_SCHEMA_STACK, sf)
    try
        return f()
    finally
        pop!(_SCHEMA_STACK)
    end
end
function current_element_schema(name::AbstractString)::StructNode
    isempty(_SCHEMA_STACK) && error("no schema available to resolve \"$name\"; call within `with_schema`")
    return _SCHEMA_STACK[end].flat[name]
end

"Encode a Julia value as a UInt64 for a primitive list element."
function encode_primitive(prim::PrimitiveType, val)::UInt64
    if prim == PT_Bool
        return Bool(val) ? UInt64(1) : UInt64(0)
    elseif prim in (PT_Int8, PT_UInt8)
        return UInt64(UInt8(val))
    elseif prim in (PT_Int16, PT_UInt16)
        return UInt64(UInt16(val))
    elseif prim in (PT_Int32, PT_UInt32)
        return UInt64(UInt32(val))
    elseif prim == PT_Float32
        return UInt64(reinterpret(UInt32, Float32(val)))
    elseif prim in (PT_Int64, PT_UInt64)
        return UInt64(val)
    elseif prim == PT_Float64
        return reinterpret(UInt64, Float64(val))
    else
        return UInt64(0)
    end
end

# ----- Reading -----------------------------------------------------------------

"Read a Julia NamedTuple from the StructReader `s` according to schema `node`."
function read_struct(s::StructReader, node::StructNode)
    names = Symbol[]
    values = Any[]
    for f in node.fields
        push!(names, Symbol(f.name))
        push!(values, read_field(s, f))
    end
    return NamedTuple{Tuple(names)}(values)
end

function read_field(s::StructReader, f::StructField)
    ty = f.type
    if ty.kind == :primitive
        return read_primitive(s, f, ty.primitive)
    elseif ty.kind == :list
        return read_list_field(s, f, ty.element[])
    elseif ty.kind == :struct
        return read_struct_field(s, f, ty.type_name)
    else
        error("unsupported field type kind $(ty.kind) for field $(f.name)")
    end
end

function read_primitive(s::StructReader, f::StructField, prim::PrimitiveType)
    if prim == PT_Void
        return nothing
    elseif prim == PT_Bool
        return get_bool(s, f.data_word, f.data_bit)
    elseif prim == PT_Int8
        return Int8(reinterpret(Int8, UInt8(get_subword(s, f.data_word, f.data_byte, 8))))
    elseif prim == PT_UInt8
        return UInt8(get_subword(s, f.data_word, f.data_byte, 8))
    elseif prim == PT_Int16
        w = get_word(s.msg, s.seg, s.base + f.data_word)
        shift = f.data_byte * 8
        return Int16(reinterpret(Int16, UInt16((w >> shift) & 0xffff)))
    elseif prim == PT_UInt16
        w = get_word(s.msg, s.seg, s.base + f.data_word)
        shift = f.data_byte * 8
        return UInt16((w >> shift) & 0xffff)
    elseif prim == PT_Int32
        w = get_word(s.msg, s.seg, s.base + f.data_word)
        shift = f.data_byte * 8
        return Int32(reinterpret(Int32, UInt32((w >> shift) & 0xffffffff)))
    elseif prim == PT_UInt32
        w = get_word(s.msg, s.seg, s.base + f.data_word)
        shift = f.data_byte * 8
        return UInt32((w >> shift) & 0xffffffff)
    elseif prim == PT_Float32
        w = get_word(s.msg, s.seg, s.base + f.data_word)
        shift = f.data_byte * 8
        return Float32(reinterpret(Float32, UInt32((w >> shift) & 0xffffffff)))
    elseif prim == PT_Int64
        return Int64(reinterpret(Int64, get_word(s.msg, s.seg, s.base + f.data_word)))
    elseif prim == PT_UInt64
        return UInt64(get_word(s.msg, s.seg, s.base + f.data_word))
    elseif prim == PT_Float64
        return Float64(reinterpret(Float64, get_word(s.msg, s.seg, s.base + f.data_word)))
    elseif prim == PT_Text
        return get_text(s, f.ptr_slot)
    elseif prim == PT_Data
        return get_data(s, f.ptr_slot)
    end
    return nothing
end

function read_list_field(s::StructReader, f::StructField, elem_type::Type)
    lr = get_list_field(s, f.ptr_slot)
    lr === nothing && return nothing
    return read_list(lr, elem_type)
end

function read_list(lr::ListReader, elem_type::Type)
    n = list_length(lr)
    if elem_type.kind == :primitive
        prim = elem_type.primitive
        if prim == PT_Text
            return [get_text_element(lr, i) for i in 0:(n - 1)]
        elseif prim == PT_Data
            return [get_data_element(lr, i) for i in 0:(n - 1)]
        end
        return [decode_primitive(prim, get_element(lr, i)) for i in 0:(n - 1)]
    elseif elem_type.kind == :struct
        node = current_element_schema(elem_type.type_name)
        return [read_struct(list_element_struct(lr, i), node) for i in 0:(n - 1)]
    else
        error("unsupported list element kind $(elem_type.kind)")
    end
end

function decode_primitive(prim::PrimitiveType, v::UInt64)
    if prim == PT_Bool
        return v != 0
    elseif prim in (PT_Int8, PT_UInt8)
        return prim == PT_Int8 ? Int8(reinterpret(Int8, UInt8(v))) : UInt8(v)
    elseif prim in (PT_Int16, PT_UInt16)
        return prim == PT_Int16 ? Int16(reinterpret(Int16, UInt16(v))) : UInt16(v)
    elseif prim in (PT_Int32, PT_UInt32)
        return prim == PT_Int32 ? Int32(reinterpret(Int32, UInt32(v))) : UInt32(v)
    elseif prim == PT_Float32
        return Float32(reinterpret(Float32, UInt32(v)))
    elseif prim in (PT_Int64, PT_UInt64)
        return prim == PT_Int64 ? Int64(reinterpret(Int64, v)) : UInt64(v)
    elseif prim == PT_Float64
        return Float64(reinterpret(Float64, v))
    else
        return nothing
    end
end

function get_data_element(lr::ListReader, i::Int)
    @assert lr.element_size == POINTER_LIST
    ptr_idx = lr.base + i
    r = resolve_pointer(lr.msg, lr.seg, ptr_idx)
    r isa ListReader ? get_data(r) : nothing
end

function read_struct_field(s::StructReader, f::StructField, type_name::String)
    sub = get_struct_field(s, f.ptr_slot)
    sub === nothing && return nothing
    node = current_element_schema(type_name)
    return read_struct(sub, node)
end

# ----- Convenience: build a whole message from a schema ------------------------

"Build a message whose root is the struct node `node_name` of `sf`, filled with
value `x`. Sets up the schema context internally. By default the output is
packed; pass `packed=false` for the unpacked stream format."
function build_message(sf::SchemaFile, node_name::AbstractString, x; packed::Bool=true)::Vector{UInt8}
    node = sf.flat[node_name]
    with_schema(sf) do
        b = MessageBuilder()
        root = init_root_struct!(b, node.data_words, node.ptr_count)
        write_struct!(root, node, x)
        return packed ? write_packed(b) : write_message(b)
    end
end

"Parse a message whose root is the struct node `node_name` of `sf` from a byte
vector. The encoding is auto-detected at `pos` via [`looks_packed`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins (default 0), matching the
convention of `position`/`seek`."
function parse_message(bytes::Vector{UInt8}, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=0)
    node = sf.flat[node_name]
    with_schema(sf) do
        r = read_message_agnostic(bytes; packed=packed, start=pos + 1)
        return read_struct(get_root(r), node)
    end
end

"Parse a message whose root is the struct node `node_name` of `sf` from an IO.
The encoding is auto-detected at the read position via [`ispacked`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins; the default `-1` means use the
IO's current position (no seek). The IO is left positioned just past the
message."
function parse_message(io::IO, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=-1)
    if pos >= 0
        seek(io, pos)
    end
    is_p = if packed === nothing
        ispacked(io)
    else
        packed
    end
    mr = is_p ? read_packed_message_io(io) : read_message_io(io)
    mr === nothing && error("parse_message: end of stream")
    node = sf.flat[node_name]
    with_schema(sf) do
        return read_struct(get_root(mr), node)
    end
end

"Parse a message whose root is the struct node `node_name` of `sf` from a file.
The encoding is auto-detected at `pos` via [`ispacked`](@ref); pass `packed=true`
or `packed=false` to force a specific interpretation. `pos` is the 0-based byte
offset at which the message begins (default 0). The file is opened, read, and
closed."
function parse_message(filename::AbstractString, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=0)
    open(filename, "r") do io
        return parse_message(io, sf, node_name; packed=packed, pos=pos)
    end
end

"Decode a typed value from an already-read `MessageReader` whose root is the
struct node `node_name` of `sf`. This is the typed layer over
`read_message`/`read_message_io`/`read_message_agnostic`: read the raw message
by any means, then call `parse_struct` to decode it."
function parse_struct(mr::MessageReader, sf::SchemaFile, node_name::AbstractString)
    node = sf.flat[node_name]
    with_schema(sf) do
        return read_struct(get_root(mr), node)
    end
end

# ----- Streaming iterator over multiple messages --------------------------------

"""
    parse_messages(io, schema, node_name; packed=nothing)

Return an iterator that yields one decoded message per iteration from `io`,
which is assumed to contain a stream of concatenated messages of the same
struct type `node_name`. Messages are read **lazily**: only one message at a
time is held in memory, so iterating a large stream does not load the whole
file.

The encoding is auto-detected from the first message via [`ispacked`](@ref)
and that decision is then applied to **every** message in the stream (Cap'n
Proto streams do not mix encodings). Pass `packed=true` or `false` to force a
specific interpretation and skip detection. Trailing bytes that do not form a
complete message cause an error.

`io` may be an `IO`, an `AbstractVector{UInt8}`, or a filename
(`AbstractString`). For byte vectors and filenames a buffered IO is opened over
them; for an `IO` it is used directly.
"""
function parse_messages(io, sf::SchemaFile, node_name::AbstractString; packed::Union{Bool,Nothing}=nothing)
    bio = _as_buffered_io(io)
    is_p = if packed === nothing
        ispacked(bio)
    else
        packed
    end
    return MessageIterator(sf, String(node_name), bio, is_p)
end

"Wrap `io` in a buffered IO suitable for lazy reading. Byte vectors and
filenames get an IOBuffer / file stream; an existing IO is wrapped in
BufferStream so we can read from it incrementally without consuming it all."
function _as_buffered_io(io)
    if io isa AbstractVector{UInt8}
        return IOBuffer(io; read=true, write=false)
    elseif io isa AbstractString
        return open(io, "r")
    elseif io isa IO
        return io
    else
        error("parse_messages: expected an IO, byte vector, or filename, got $(typeof(io))")
    end
end

"Iterator over the messages of a [`parse_messages`](@ref) stream. Reads one
message at a time from the underlying IO, so memory use is bounded by the
largest single message. Iterate with `for msg in itr` or use `collect`."
struct MessageIterator
    sf::SchemaFile
    node_name::String
    io::IO
    packed::Bool
end

Base.IteratorSize(::Base.Type{MessageIterator}) = Base.SizeUnknown()
Base.eltype(::Base.Type{MessageIterator}) = Any

function Base.iterate(it::MessageIterator, _state::Nothing=nothing)
    eof(it.io) && return nothing
    mr = it.packed ? read_packed_message_io(it.io) : read_message_io(it.io)
    mr === nothing && return nothing
    node = it.sf.flat[it.node_name]
    val = with_schema(it.sf) do
        return read_struct(get_root(mr), node)
    end
    return (val, nothing)
end
