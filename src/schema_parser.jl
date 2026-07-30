# schema_parser.jl - a recursive-descent parser for a useful subset of the
# Cap'n Proto schema language.
#
# Supported:
#   - file id (`@0x...;`)
#   - imports are recorded but not resolved
#   - top-level and nested `struct`, `enum`, `interface`, `const`, `annotation` decls
#   - struct fields with explicit ordinals (`name @N :Type;`)
#   - field types: all primitives, Text, Data, List(T), named structs/enums
#   - default values (`= ...`) for primitive fields
#   - unnamed unions (`union { ... }`) inside a struct, with discriminant pointer
#     slot chosen automatically (we use the first pointer slot reserved for it).
#   - groups (`group :Group { ... }`) are NOT supported yet
#   - annotations (`$Annotation(...)`) are skipped
#
# The parser computes data-section and pointer-section layout for struct fields
# matching the Cap'n Proto layout algorithm: primitive data fields are packed
# smallest-first into the data section (Void=0 bits, Bool=1 bit, Int8=8 bits,
# Int16=16, Int32=32, Float32=32, Int64=64, Float64=64). Pointer-type fields
# each take one pointer slot, in declaration order.

include("lexer.jl")

"Parse a Cap'n Proto schema string. Returns a SchemaFile."
function parse_schema(text::AbstractString)::SchemaFile
    return parse_schema_file(Lexer(text))
end

"Parse a Cap'n Proto schema file (already-read text). Returns a SchemaFile."
function parse_schema_file(text::AbstractString)::SchemaFile
    return parse_schema_file(Lexer(text))
end

function parse_schema_file(lex::Lexer)::SchemaFile
    nodes = Dict{String,Any}()
    flat = Dict{String,Any}()
    file_id = ""
    while !at_end(lex)
        skip_terminators(lex)
        if at_end(lex)
            break
        end
        tok = peek(lex)
        if tok.kind == :at
            # File id: @0x...;
            advance(lex)
            id_tok = expect(lex, :integer)
            file_id = id_tok.text
            expect_terminator(lex)
        elseif tok.kind == :keyword && tok.text == "import"
            advance(lex)
            # import "path";
            expect(lex, :string)
            expect_terminator(lex)
        elseif tok.kind == :keyword && tok.text in ("struct", "enum", "interface", "const", "annotation")
            push_node!(nodes, flat, parse_node(lex))
        else
            error("unexpected top-level token: $(tok)")
        end
    end
    return SchemaFile(file_id, nodes, flat)
end

function push_node!(nodes::Dict, flat::Dict, node::Any)
    name = node_name(node)
    nodes[name] = node
    flat[name] = node
    # If the node is a struct with nested nodes, register them under "Outer.Inner"
    # and also under the bare name (for convenient in-file references; later
    # definitions shadow earlier ones on collision).
    if node isa StructNode
        for (inner_name, inner) in node.nested
            flat["$name.$inner_name"] = inner
            flat[inner_name] = inner
        end
    end
end

node_name(n::StructNode) = n.name
node_name(n::EnumNode) = n.name
node_name(n::InterfaceNode) = n.name
node_name(n::ConstNode) = n.name

function parse_node(lex::Lexer)
    tok = expect(lex, :keyword)
    if tok.text == "struct"
        return parse_struct(lex, "")
    elseif tok.text == "enum"
        return parse_enum(lex)
    elseif tok.text == "interface"
        return parse_interface(lex)
    elseif tok.text == "const"
        return parse_const(lex)
    elseif tok.text == "annotation"
        return parse_annotation(lex)
    else
        error("not a node keyword: $(tok.text)")
    end
end

# ----- struct ------------------------------------------------------------------

function parse_struct(lex::Lexer, _prefix::AbstractString)::StructNode
    name_tok = expect(lex, :ident)
    name = name_tok.text
    # Optional discriminant pointer slot for an unnamed union: `struct Foo(N)`.
    disc_ptr = -1
    if peek(lex).kind == :lparen
        advance(lex)
        n_tok = expect(lex, :integer)
        disc_ptr = parse(Int, n_tok.text)
        expect(lex, :rparen)
    end
    expect(lex, :lbrace)
    fields = StructField[]
    nested = Dict{String,Any}()
    while peek(lex).kind != :rbrace
        skip_terminators(lex)
        if peek(lex).kind == :rbrace
            break
        end
        t = peek(lex)
        if t.kind == :keyword && t.text in ("struct", "enum", "interface", "const", "annotation")
            inner = parse_node(lex)
            nested[inner.name] = inner
        elseif t.kind == :keyword && t.text == "union"
            append!(fields, parse_union(lex))
        elseif t.kind == :ident
            push!(fields, parse_field(lex))
        else
            error("unexpected token in struct body: $(t)")
        end
    end
    expect(lex, :rbrace)
    # Compute layout.
    data_words, ptr_count = layout!(fields, disc_ptr)
    return StructNode(name, data_words, ptr_count, fields, disc_ptr,
                      count(f -> f.discriminant >= 0, fields), nested)
end

function parse_field(lex::Lexer)::StructField
    name = expect(lex, :ident).text
    expect(lex, :at)
    ordinal = parse(Int, expect(lex, :integer).text)
    expect(lex, :colon)
    ty = parse_type(lex)
    has_default = false
    default = UInt64(0)
    if peek(lex).kind == :eq
        advance(lex)
        has_default, default = parse_default(lex, ty)
    end
    # Skip annotations `$Foo(...)`.
    skip_annotations(lex)
    expect_terminator(lex)
    return StructField(name, ordinal, ty, -1, 0, 0, -1, -1, has_default, default)
end

function parse_union(lex::Lexer)::Vector{StructField}
    expect(lex, :keyword).text == "union" || error("expected union")
    expect(lex, :lbrace)
    fields = StructField[]
    disc = 0
    while peek(lex).kind != :rbrace
        skip_terminators(lex)
        if peek(lex).kind == :rbrace
            break
        end
        f = parse_field(lex)
        # Patch the discriminant value into the field.
        fields = push!(fields, StructField(f.name, f.ordinal, f.type, f.data_word,
                                           f.data_byte, f.data_bit, f.ptr_slot,
                                           disc, f.has_default, f.default_value))
        disc += 1
    end
    expect(lex, :rbrace)
    return fields
end

# ----- types -------------------------------------------------------------------

function parse_type(lex::Lexer)::Type
    t = peek(lex)
    if t.kind == :keyword
        prim = PRIMITIVE_KEYWORDS[t.text]
        advance(lex)
        return Type(:primitive, prim)
    elseif t.kind == :ident
        name = t.text
        advance(lex)
        if name == "List"
            expect(lex, :lparen)
            elem = parse_type(lex)
            expect(lex, :rparen)
            return Type(:list, PT_Void, "", elem)
        end
        # A struct/enum/interface reference. (Generics `Foo(T)` not supported.)
        return Type(:struct, PT_Void, name)
    elseif t.kind == :lparen
        # Parenthesized type (rare in schemas; treat as inner type).
        advance(lex)
        ty = parse_type(lex)
        expect(lex, :rparen)
        return ty
    else
        error("expected type, got $(t)")
    end
end

# ----- default values ----------------------------------------------------------

function parse_default(lex::Lexer, ty::Type)
    # We only record primitive defaults. Text/Data/struct/list defaults are ignored.
    if ty.kind != :primitive
        skip_value(lex)
        return (false, UInt64(0))
    end
    tok = peek(lex)
    has_default = true
    if tok.kind == :integer
        advance(lex)
        v = parse(Int128, tok.text)
        return (true, encode_default(ty.primitive, v))
    elseif tok.kind == :float
        advance(lex)
        v = parse(Float64, tok.text)
        return (true, encode_default_float(ty.primitive, v))
    elseif tok.kind == :keyword && tok.text == "void"
        advance(lex)
        return (true, UInt64(0))
    elseif tok.kind == :ident && tok.text in ("true", "false")
        advance(lex)
        return (true, tok.text == "true" ? UInt64(1) : UInt64(0))
    else
        skip_value(lex)
        return (false, UInt64(0))
    end
end

function encode_default(prim::PrimitiveType, v::Int128)::UInt64
    if prim in (PT_Int8, PT_Int16, PT_Int32, PT_Int64, PT_UInt8, PT_UInt16, PT_UInt32, PT_UInt64)
        return UInt64(v) & 0xffffffffffffffff
    elseif prim == PT_Bool
        return v != 0 ? UInt64(1) : UInt64(0)
    else
        return UInt64(0)
    end
end

function encode_default_float(prim::PrimitiveType, v::Float64)::UInt64
    if prim == PT_Float32
        return UInt64(reinterpret(UInt32, Float32(v)))
    elseif prim == PT_Float64
        return reinterpret(UInt64, Float64(v))
    else
        return UInt64(0)
    end
end

# ----- enum / interface / const ------------------------------------------------

function parse_enum(lex::Lexer)::EnumNode
    name = expect(lex, :ident).text
    expect(lex, :lbrace)
    values = EnumValue[]
    ord = 0
    while peek(lex).kind != :rbrace
        skip_terminators(lex)
        if peek(lex).kind == :rbrace
            break
        end
        vname = expect(lex, :ident).text
        if peek(lex).kind == :at
            advance(lex)
            ord = parse(Int, expect(lex, :integer).text)
        end
        skip_annotations(lex)
        expect_terminator(lex)
        push!(values, EnumValue(vname, ord))
        ord += 1
    end
    expect(lex, :rbrace)
    return EnumNode(name, values)
end

function parse_interface(lex::Lexer)::InterfaceNode
    name = expect(lex, :ident).text
    # Optional `(N)` for generic param count - skip.
    if peek(lex).kind == :lparen
        advance(lex)
        expect(lex, :integer)
        expect(lex, :rparen)
    end
    expect(lex, :lbrace)
    methods = InterfaceMethod[]
    while peek(lex).kind != :rbrace
        skip_terminators(lex)
        if peek(lex).kind == :rbrace
            break
        end
        mname = expect(lex, :ident).text
        expect(lex, :at)
        ordinal = parse(Int, expect(lex, :integer).text)
        expect(lex, :lparen)
        params = expect(lex, :ident).text
        expect(lex, :rparen)
        expect(lex, :colon)
        ret = expect(lex, :ident).text
        skip_annotations(lex)
        expect_terminator(lex)
        push!(methods, InterfaceMethod(mname, ordinal, params, ret))
    end
    expect(lex, :rbrace)
    return InterfaceNode(name, methods)
end

function parse_const(lex::Lexer)::ConstNode
    name = expect(lex, :ident).text
    expect(lex, :colon)
    ty = parse_type(lex)
    expect(lex, :eq)
    # Capture the value text up to the terminating ;.
    buf = IOBuffer()
    depth = 0
    while true
        t = peek(lex)
        if depth == 0 && t.kind in (:semicolon, :eof)
            break
        end
        if t.kind == :lparen
            depth += 1
        elseif t.kind == :rparen
            depth -= 1
        end
        write(buf, t.text)
        write(buf, " ")
        advance(lex)
    end
    expect_terminator(lex)
    return ConstNode(name, ty, strip(String(take!(buf))))
end

function parse_annotation(lex::Lexer)
    # `annotation foo(struct, enum): Text;` - we parse and discard.
    expect(lex, :ident)  # name
    if peek(lex).kind == :lparen
        advance(lex)
        while peek(lex).kind != :rparen
            advance(lex)
        end
        advance(lex)
    end
    if peek(lex).kind == :colon
        advance(lex)
        parse_type(lex)
    end
    skip_annotations(lex)
    expect_terminator(lex)
    return nothing
end

# ----- layout ------------------------------------------------------------------
#
# Cap'n Proto packs data fields smallest-first. We assign each primitive data
# field a (word, byte, bit) location. Pointer-type fields (Text, Data, struct,
# list, interface) consume pointer slots in declaration order.

primitive_bits(prim::PrimitiveType) =
    prim == PT_Void ? 0 :
    prim == PT_Bool ? 1 :
    prim in (PT_Int8, PT_UInt8) ? 8 :
    prim in (PT_Int16, PT_UInt16) ? 16 :
    prim in (PT_Int32, PT_UInt32, PT_Float32) ? 32 :
    prim in (PT_Int64, PT_UInt64, PT_Float64) ? 64 :
    64  # Text/Data are pointer-typed; shouldn't reach here for data layout.

function is_pointer_type(ty::Type)
    if ty.kind == :primitive
        return ty.primitive in (PT_Text, PT_Data)
    elseif ty.kind in (:struct, :interface, :list)
        return true
    else
        return false
    end
end

"Assign data/pointer layout to fields in place and return (data_words, ptr_count)."
function layout!(fields::Vector{StructField}, disc_ptr::Int)::Tuple{Int,Int}
    # Data fields are packed smallest-first into the data section. Pointer-type
    # fields each take one pointer slot in declaration order.
    # Build (orig_idx, field) pairs for data fields, then stable-sort by size.
    data_pairs = [(i, f) for (i, f) in enumerate(fields)
                  if !is_pointer_type(f.type) && f.type.primitive != PT_Void]
    ptr_pairs = [(i, f) for (i, f) in enumerate(fields) if is_pointer_type(f.type)]

    sort!(data_pairs; by=((_, f),) -> primitive_bits(f.type.primitive))

    new_fields = copy(fields)
    bit_cursor = 0  # bit offset within the data section
    for (orig_idx, f) in data_pairs
        bits = primitive_bits(f.type.primitive)
        word = bit_cursor ÷ 64
        bit_in_word = bit_cursor % 64
        byte = bit_in_word ÷ 8
        bit = bit_in_word % 8
        new_fields[orig_idx] = StructField(f.name, f.ordinal, f.type, word, byte, bit,
                                           f.ptr_slot, f.discriminant, f.has_default, f.default_value)
        bit_cursor += bits
    end
    data_words = cld(bit_cursor, 64)

    # Assign pointer slots. If the struct declares an unnamed union, reserve
    # its discriminant slot.
    ptr_count = 0
    if disc_ptr >= 0
        ptr_count = max(ptr_count, disc_ptr + 1)
    end
    for (orig_idx, f) in ptr_pairs
        slot = ptr_count
        ptr_count += 1
        cur = new_fields[orig_idx]
        new_fields[orig_idx] = StructField(f.name, f.ordinal, f.type,
                                           cur.data_word, cur.data_byte, cur.data_bit,
                                           slot, f.discriminant, f.has_default, f.default_value)
    end

    # Commit changes back into the input vector.
    for i in eachindex(fields)
        fields[i] = new_fields[i]
    end
    return (data_words, ptr_count)
end

# ----- lookup helpers ----------------------------------------------------------

"Look up a node by name within a SchemaFile, supporting dotted nested paths."
function Base.getindex(sf::SchemaFile, name::AbstractString)
    return sf.flat[name]
end
Base.getindex(sf::SchemaFile, name::Symbol) = sf.flat[String(name)]

"Resolve a Type referring to a named struct/enum to the actual node, given the
containing struct (for nested name resolution) and the file."
function resolve_type(ty::Type, _containing::Union{StructNode,Nothing}, sf::SchemaFile)
    if ty.kind == :struct
        return sf.flat[ty.type_name]
    end
    return nothing
end
