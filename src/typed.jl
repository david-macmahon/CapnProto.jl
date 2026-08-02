# typed.jl - schema-driven reading and writing.
#
# `write_struct!` and `read_struct` take a `StructNode` and a Julia value (either
# a NamedTuple or a Dict) and serialize/deserialize it. Field names in the Julia
# value are matched to schema field names case-sensitively.

# ----- Writing -----------------------------------------------------------------

"""
    write_struct!(s::StructBuilder, node::StructNode, x)

Write a Julia value `x` into the StructBuilder `s` according to schema `node`.
`x` may be a NamedTuple or an AbstractDict keyed by field name (as Symbol or String).
"""
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

function write_list_field!(s::StructBuilder, f::StructField, elem_type::SchemaType, val)
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
"""
    with_schema(f, sf::SchemaFile)

Run `f()` with `sf` as the active schema for nested struct resolution by
`write_struct!`/`read_struct`. Schema-driven list/struct fields look up named
nodes from the active schema, so `with_schema` must wrap any code that uses
schema-driven reading or writing of nested struct types.
"""
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

# Field skipping.
#
# `skip` is either `nothing` (read everything), an AbstractSet / iterable of
# dotted path strings (e.g. ["filterbank.data"]), or a predicate `path -> Bool`.
# Paths are root-relative, dotted, and matched case-sensitively to schema field
# names. A skipped field is decoded as a typed empty value:
#   List(T) -> empty Vector{...}, Text -> "", Data -> UInt8[], primitive -> zero.
# At the typed layer (Tier A) the bytes are still read into the MessageReader;
# Tier B (parse_messages over an IO) additionally skips reading the segments that
# contain only skipped data, for both unpacked and packed streams.

"Return true iff `path` is to be skipped according to `skip`."
function _should_skip(skip, path::AbstractString)
    skip === nothing && return false
    if skip isa Function
        return skip(path)
    else
        return path in skip
    end
end

"Build the child path `parent.child` (parent may be empty for the root's direct
fields)."
function _child_path(parent::AbstractString, child::AbstractString)
    isempty(parent) ? String(child) : string(parent, ".", child)
end

"Return a typed empty value for a skipped field of the given element SchemaType."
function _empty_value(ty::SchemaType)
    if ty.kind == :primitive
        return _empty_primitive(ty.primitive)
    elseif ty.kind == :list
        return _empty_list_value(ty.element[])
    elseif ty.kind == :struct
        # An empty struct decodes to a NamedTuple of empty children. We need
        # the schema node to know the field names, but a skipped struct whose
        # contents are all empty can be approximated as an empty NamedTuple.
        # In practice skip targets are List/Text/Data fields; structs are
        # recursed into so their individual fields can be skipped.
        return NamedTuple()
    else
        return nothing
    end
end

function _empty_list_value(elem_type::SchemaType)
    if elem_type.kind == :primitive
        prim = elem_type.primitive
        if prim == PT_Text
            return String[]
        elseif prim == PT_Data
            return Vector{UInt8}[]
        elseif prim == PT_Bool
            return Bool[]
        elseif prim in (PT_Int8, PT_Int16, PT_Int32, PT_Int64)
            return Int[]
        elseif prim in (PT_UInt8, PT_UInt16, PT_UInt32, PT_UInt64)
            return UInt[]
        elseif prim == PT_Float32
            return Float32[]
        elseif prim == PT_Float64
            return Float64[]
        else
            return Any[]
        end
    elseif elem_type.kind == :struct
        return NamedTuple[]
    else
        return Any[]
    end
end

function _empty_primitive(prim::PrimitiveType)
    if prim == PT_Void
        return nothing
    elseif prim == PT_Bool
        return false
    elseif prim in (PT_Int8, PT_Int16, PT_Int32, PT_Int64)
        return 0
    elseif prim in (PT_UInt8, PT_UInt16, PT_UInt32, PT_UInt64)
        return 0x0
    elseif prim == PT_Float32
        return 0.0f0
    elseif prim == PT_Float64
        return 0.0
    elseif prim == PT_Text
        return ""
    elseif prim == PT_Data
        return UInt8[]
    end
    return nothing
end

# ----- Tier B: segment-skipping reads ------------------------------------------
#
# When reading from an IO, we can avoid reading (and for unpacked streams even
# seeking past) the segments that hold only the bytes of skipped fields. The
# root struct always lives in segment 0 (the first segment), so we read seg 0
# fully and then classify the remaining segments by walking the root struct's
# pointer fields (and their inline struct descendants) to find:
#   - skip-segs:  segments reached ONLY via skipped field paths
#   - need-segs:  segments reached by some non-skipped field
# A segment is skipped iff it is a skip-seg and NOT a need-seg. If anything is
# uncertain (e.g. a skip path traverses a composite list, or the root pointer
# itself is a far/list pointer), we read everything and let Tier A trim the
# value. This keeps Tier B a pure optimization with a safe fallback.

"Return the segment id a pointer `p` (located in `seg`) ultimately lands in,
or `nothing` if it can't be determined locally (e.g. it points within `seg`).
`seg_used` accumulates segment ids that must be read; far pointers encountered
here are added to `seg_used`."
function _pointer_target_seg(msg::MessageReader, seg::Int, word_idx::Int, p::UInt64,
                             seg_used::Set{Int})
    t = pointer_type(p)
    if t == STRUCT_POINTER || t == LIST_POINTER
        return nothing  # inline in `seg`; no new segment to record
    elseif t == FAR_POINTER
        target_seg = Int(far_segment_id(p))
        push!(seg_used, target_seg)
        return target_seg
    else
        return nothing
    end
end

"Walk the struct `s` (and its inline struct descendants, NOT into composite-list
elements) recording segments reached by each pointer field. `skip` and the
current `path` determine whether a field's target segments are 'needed' or only
'skipped'. Adds needed segment ids to `need` and skipped-only segment ids to
`skip_segs`."
function _classify_segments(s::StructReader, node::StructNode,
                            path::AbstractString, skip,
                            need::Set{Int}, skip_segs::Set{Int})
    for f in node.fields
        fpath = _child_path(path, f.name)
        ty = f.type
        # Only pointer-bearing fields can reach other segments.
        if ty.kind == :primitive
            continue
        elseif ty.kind == :list
            _classify_list_field(s, f, ty.element[], fpath, skip, need, skip_segs)
        elseif ty.kind == :struct
            _classify_struct_field(s, f, ty.type_name, fpath, skip, need, skip_segs)
        end
    end
end

"Classify a List field's target segment(s). The whole list body lives in one
segment (the segment of its pointer's far target, or the parent's segment if
inline). If the field itself is skipped, that segment is skip-only; otherwise
it is needed (we don't descend into the elements' contents here -- a composite
list's element structs are inline within the list body, so they share the list's
segment classification)."
function _classify_list_field(s::StructReader, f::StructField, elem_type::SchemaType,
                              path::AbstractString, skip,
                              need::Set{Int}, skip_segs::Set{Int})
    idx = s.base + s.data_words + f.ptr_slot
    p = get_word(s.msg, s.seg, idx)
    p == 0 && return  # null pointer, no segment
    if _should_skip(skip, path)
        union!(skip_segs, _far_target_segs(s.msg, s.seg, idx, p))
    else
        union!(need, _far_target_segs(s.msg, s.seg, idx, p))
    end
end

"Classify a nested struct field. If the field is skipped, its target segment
(if any) is skip-only; otherwise we recurse into the inline struct to classify
ITS fields' targets (and add the struct's own far target to `need`)."
function _classify_struct_field(s::StructReader, f::StructField, type_name::String,
                                path::AbstractString, skip,
                                need::Set{Int}, skip_segs::Set{Int})
    idx = s.base + s.data_words + f.ptr_slot
    p = get_word(s.msg, s.seg, idx)
    p == 0 && return
    if _should_skip(skip, path)
        union!(skip_segs, _far_target_segs(s.msg, s.seg, idx, p))
        return
    end
    # The struct is needed: its far-target segment (if any) is needed, and we
    # recurse into it to classify its children.
    tsegs = _far_target_segs(s.msg, s.seg, idx, p)
    union!(need, tsegs)
    sub = get_struct_field(s, f.ptr_slot)
    sub === nothing && return
    node = current_element_schema(type_name)
    _classify_segments(sub, node, path, skip, need, skip_segs)
end

"Return the set of segment ids reached (transitively through far landing pads)
by the pointer at `seg`,`word_idx` whose raw word is `p`. For an inline
struct/list pointer this is empty (the pointee shares the parent's segment).
For a far pointer it is `{target_seg}` plus whatever the landing pad points at
(if the landing pad itself is a far pointer)."
function _far_target_segs(msg::MessageReader, seg::Int, word_idx::Int, p::UInt64)::Set{Int}
    out = Set{Int}()
    _collect_far_targets!(out, msg, seg, word_idx, p)
    return out
end

function _collect_far_targets!(out::Set{Int}, msg::MessageReader, seg::Int, word_idx::Int, p::UInt64)
    t = pointer_type(p)
    if t == STRUCT_POINTER || t == LIST_POINTER
        return  # inline; no far target
    elseif t == FAR_POINTER
        target_seg = Int(far_segment_id(p))
        target_off = Int(far_offset(p))
        push!(out, target_seg)
        # Follow the landing pad in case IT is itself a far pointer (double-far
        # whose target is yet another segment). For a plain single-far the
        # landing pad is the real struct/list pointer and adds no new segment.
        if 0 <= target_seg < nsegments(msg) && 0 <= target_off < segment_words(msg, target_seg)
            if far_is_double(p)
                if 0 <= target_off + 1 < segment_words(msg, target_seg)
                    real_ptr = get_word(msg, target_seg, target_off + 1)
                    _collect_far_targets!(out, msg, target_seg, target_off + 1, real_ptr)
                end
            else
                landing = get_word(msg, target_seg, target_off)
                _collect_far_targets!(out, msg, target_seg, target_off, landing)
            end
        end
    end
end

"""
    _skip_segments_for(msg_segs::Vector{Int}, sf::SchemaFile, root_name, skip)

Given the per-segment word counts of a message, return a `Set{Int}` of segment
ids (0-based) that may be left empty (not read from the wire) because they are
reached only by skipped field paths. Segment 0 is NEVER skipped (it holds the
root pointer and root struct). Returns an empty set if classification is not
possible (e.g. the root pointer is not a struct pointer in segment 0).

`msg_segs` is the segment word counts of a partially-read message: index 1 is
segment 0, etc. The caller must have read segment 0 already (its words are
needed to walk pointers); the remaining entries may be the declared lengths
even though their bodies haven't been read.
"""
function _skip_segments_for(root_msg::MessageReader, sf::SchemaFile, root_name::AbstractString, skip)
    skip === nothing && return Set{Int}()
    need = Set{Int}([0])
    skip_segs = Set{Int}()
    node = sf.flat[root_name]
    root = get_root(root_msg)
    _classify_segments(root, node, "", skip, need, skip_segs)
    return setdiff(skip_segs, need)
end

"Skip `n` bytes on `io`, seeking if possible, otherwise reading and discarding."
function _skip_bytes(io::IO, n::Int)
    n <= 0 && return
    target = position(io) + n
    try
        seek(io, target)
        return
    catch
        # Non-seekable: read and discard.
    end
    buf = Vector{UInt8}(undef, min(n, 65536))
    remaining = n
    while remaining > 0
        got = readbytes!(io, buf, min(remaining, length(buf)))
        got == 0 && error("_skip_bytes: unexpected EOF skipping $n bytes")
        remaining -= got
    end
end

# ----- Packed skipping reader --------------------------------------------------
#
# A packed message has no per-message length prefix and the body is a variable-
# length packed stream, so we cannot `seek` past a segment by word count. We
# therefore unpack the whole message (as `read_packed_message_io` does), then
# drop the words of skipped segments, retaining them as empty `UInt64[]`. This
# saves the memory of the skipped segments (and the CPU of copying them into
# the MessageReader) at the cost of still reading the packed bytes sequentially.
# The dropping is done inline in `_read_message_io_with_skip`'s packed branch.

# ----- Skip-aware message read (classify + read) -------------------------------
#
# Putting it together: read segment 0 of a message from `io`, classify which
# other segments may be skipped, then read the rest using the appropriate
# skipping reader. For a single message this requires peeking the table, reading
# seg 0, classifying, then reading the remaining segments -- which the streaming
# readers above do in one pass. We implement a unified reader that:
#   1. reads the segment table,
#   2. reads segment 0,
#   3. builds a partial MessageReader to walk pointers and classify,
#   4. reads the remaining segments (skipping some).
#
# For unpacked: we read the table once, then seg 0, then either seek past or
# read each remaining segment.
# For packed: we already have to unpack the whole message to know the segment
# boundaries, so we unpack all and then drop the skipped segments' words.

"""
    _read_message_io_with_skip(io, packed, sf, root_name, skip)

Read one message from `io`, skipping segments that hold only skipped fields.
Returns `(MessageReader, skip_segs)` where `skip_segs` is the set of segment ids
that were left empty, or `(nothing, Set{Int}())` at a clean EOF.
"""
function _read_message_io_with_skip(io::IO, packed::Bool, sf::SchemaFile,
                                    root_name::AbstractString, skip)
    skip === nothing && begin
        mr = packed ? read_packed_message_io(io) : read_message_io(io)
        return mr, Set{Int}()
    end
    if packed
        # Packed: we need the whole message unpacked to know segment boundaries,
        # so we can't avoid reading the bytes. We unpack everything, then drop
        # the skipped segments' words. To know which to drop we first need to
        # classify, which requires segment 0. Strategy: unpack retaining all
        # segments, classify, then build a new MessageReader with skipped segs
        # emptied.
        mr = read_packed_message_io(io)
        mr === nothing && return nothing, Set{Int}()
        skip_segs = with_schema(sf) do
            return _skip_segments_for(mr, sf, root_name, skip)
        end
        if isempty(skip_segs)
            return mr, skip_segs
        end
        new_segs = Vector{Vector{UInt64}}(undef, nsegments(mr))
        for k in 1:nsegments(mr)
            seg_id = k - 1
            new_segs[k] = (seg_id in skip_segs && seg_id != 0) ? UInt64[] : mr.segments[k]
        end
        return MessageReader(new_segs), skip_segs
    else
        # Unpacked: read the table, then seg 0, classify, then read the rest
        # skipping classified segments.
        return _read_unpacked_io_with_skip(io, sf, root_name, skip)
    end
end

"Unpacked variant: reads the table and segment 0, classifies, then reads the
remaining segments (seeking past skipped ones)."
function _read_unpacked_io_with_skip(io::IO, sf::SchemaFile, root_name::AbstractString, skip)
    seg_count_m1 = _read_u32_le_io(io)
    seg_count_m1 === nothing && return nothing, Set{Int}()
    seg_count = Int(seg_count_m1) + 1
    (seg_count == 0 || seg_count > 1 << 20) && error("_read_unpacked_io_with_skip: bad segment count $seg_count")
    lengths = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        v = _read_u32_le_io(io)
        v === nothing && error("_read_unpacked_io_with_skip: EOF reading segment lengths")
        lengths[k] = Int(v)
    end
    table_u32s = 1 + seg_count
    if table_u32s % 2 != 0
        pad = _read_u32_le_io(io)
        pad === nothing && error("_read_unpacked_io_with_skip: EOF reading table padding")
    end
    # Read segment 0 first (always needed).
    seg0 = _read_words_io(io, lengths[1])
    partial = MessageReader([seg0])
    skip_segs = with_schema(sf) do
        return _skip_segments_for(partial, sf, root_name, skip)
    end
    segments = Vector{Vector{UInt64}}(undef, seg_count)
    segments[1] = seg0
    for k in 2:seg_count
        seg_id = k - 1
        n = lengths[k]
        if seg_id in skip_segs
            _skip_bytes(io, n * 8)
            segments[k] = UInt64[]
        else
            segments[k] = _read_words_io(io, n)
        end
    end
    return MessageReader(segments), skip_segs
end

"""
    read_struct(s::StructReader, node::StructNode; skip=nothing)

Read a Julia NamedTuple from the StructReader `s` according to schema `node`.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them instead. It may be:
  - a collection of dotted, root-relative path strings (e.g. `["filterbank.data"]`),
    matched case-sensitively to schema field names; or
  - a predicate `path::String -> Bool` returning `true` for paths to skip.

Skipped `List(T)` fields yield empty typed vectors (`Float32[]`, etc.), `Text`
yields `""`, `Data` yields `UInt8[]`, and primitives yield zero. The skip
predicate sees the full dotted path from the root struct of this `read_struct`
call (use the `_rooted` variant or `parse_message` with `skip` to get paths
rooted at the message root).

At the typed layer the field's bytes are still read into the `MessageReader`;
to also skip reading the containing segment(s) from the wire, use
[`parse_messages`](@ref) with `skip=` over an IO.
"""
function read_struct(s::StructReader, node::StructNode; skip=nothing)
    return _read_struct(s, node, "", skip)
end

"Internal: read_struct with an explicit path prefix (root-relative) and skip spec."
function _read_struct(s::StructReader, node::StructNode, path::AbstractString, skip)
    names = Symbol[]
    values = Any[]
    for f in node.fields
        push!(names, Symbol(f.name))
        push!(values, _read_field(s, f, _child_path(path, f.name), skip))
    end
    return NamedTuple{Tuple(names)}(values)
end

function _read_field(s::StructReader, f::StructField, path::AbstractString, skip)
    if _should_skip(skip, path)
        return _empty_value(f.type)
    end
    ty = f.type
    if ty.kind == :primitive
        return read_primitive(s, f, ty.primitive)
    elseif ty.kind == :list
        return _read_list_field(s, f, ty.element[], path, skip)
    elseif ty.kind == :struct
        return _read_struct_field(s, f, ty.type_name, path, skip)
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

function read_list_field(s::StructReader, f::StructField, elem_type::SchemaType)
    lr = get_list_field(s, f.ptr_slot)
    lr === nothing && return nothing
    return read_list(lr, elem_type)
end

"Internal: read_list_field honoring `skip` for nested struct elements."
function _read_list_field(s::StructReader, f::StructField, elem_type::SchemaType,
                          path::AbstractString, skip)
    lr = get_list_field(s, f.ptr_slot)
    lr === nothing && return nothing
    return _read_list(lr, elem_type, path, skip)
end

function read_list(lr::ListReader, elem_type::SchemaType)
    return _read_list(lr, elem_type, "", nothing)
end

function _read_list(lr::ListReader, elem_type::SchemaType, path::AbstractString, skip)
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
        # For composite-list elements, the per-element path is `path.<index>`.
        # We don't expose indices in skip paths (they would be unwieldy and the
        # whole list is usually skipped); instead we recurse into each element
        # with the bare `path` so that fields *inside* each element can be
        # skipped uniformly across all elements (e.g. "myobjs.myfield" skips the
        # "myfield" field of every elemeent of the list "myobjs").
        return [_read_struct(list_element_struct(lr, i), node, path, skip)
                for i in 0:(n - 1)]
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

"Internal: read_struct_field honoring `skip` for nested fields."
function _read_struct_field(s::StructReader, f::StructField, type_name::String,
                            path::AbstractString, skip)
    sub = get_struct_field(s, f.ptr_slot)
    sub === nothing && return nothing
    node = current_element_schema(type_name)
    return _read_struct(sub, node, path, skip)
end

# ----- Convenience: build a whole message from a schema ------------------------

"""
    build_message(x, sf::SchemaFile, node_name::AbstractString; packed::Bool=true)::Vector{UInt8}

Build a message whose root is the struct node `node_name` of `sf`, filled with
value `x`. Sets up the schema context internally. By default the output is
packed; pass `packed=false` for the unpacked stream format.
"""
function build_message(x, sf::SchemaFile, node_name::AbstractString; packed::Bool=true)::Vector{UInt8}
    node = sf.flat[node_name]
    with_schema(sf) do
        b = MessageBuilder()
        root = init_root_struct!(b, node.data_words, node.ptr_count)
        write_struct!(root, node, x)
        return packed ? write_packed(b) : write_message(b)
    end
end

"""
    parse_message(bytes::Vector{UInt8}, sf::SchemaFile, node_name::AbstractString; packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)

Parse a message whose root is the struct node `node_name` of `sf` from a byte
vector. The encoding is auto-detected at `pos` via [`looks_packed`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins (default 0), matching the
convention of `position`/`seek`.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them; see [`read_struct`](@ref). When reading from a byte vector the
field's bytes are still in memory, so `skip` saves decode CPU and the resulting
array allocations but not I/O. For I/O and memory savings, read from an IO via
the streaming [`parse_messages`](@ref) with `skip=`.
"""
function parse_message(bytes::Vector{UInt8}, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)
    node = sf.flat[node_name]
    with_schema(sf) do
        r = read_message_agnostic(bytes; packed=packed, start=pos + 1)
        return read_struct(get_root(r), node; skip=skip)
    end
end

"""
    parse_message(io::IO, sf::SchemaFile, node_name::AbstractString; packed::Union{Bool,Nothing}=nothing, pos::Int=-1, skip=nothing)

Parse a message whose root is the struct node `node_name` of `sf` from an IO.
The encoding is auto-detected at the read position via [`ispacked`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins; the default `-1` means use the
IO's current position (no seek). The IO is left positioned just past the
message.

`skip` optionally skips decoding (and, where possible, reading) one or more
fields; see [`read_struct`](@ref). When `skip` is set, segments holding only
skipped data are not read from the IO: for unpacked streams their bytes are
seeked past; for packed streams they are decoded-and-discarded (the packed
encoding is variable-length, so the bytes are still read but not retained).
"""
function parse_message(io::IO, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=-1, skip=nothing)
    if pos >= 0
        seek(io, pos)
    end
    is_p = if packed === nothing
        ispacked(io)
    else
        packed
    end
    mr, _ = _read_message_io_with_skip(io, is_p, sf, node_name, skip)
    mr === nothing && error("parse_message: end of stream")
    node = sf.flat[node_name]
    with_schema(sf) do
        return read_struct(get_root(mr), node; skip=skip)
    end
end

"""
    parse_message(filename::AbstractString, sf::SchemaFile, node_name::AbstractString; packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)

Parse a message whose root is the struct node `node_name` of `sf` from a file.
The encoding is auto-detected at `pos` via [`looks_packed`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins (default 0).

The file is memory-mapped (via `Mmap.mmap`) rather than read into memory, so
the OS pages it in on demand as the message is decoded.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them; see [`read_struct`](@ref). Because the file is memory-mapped,
skipped segments are never paged in by the OS, so `skip` saves both memory and
I/O. For unpacked streams the skipped segments are simply never touched; for
packed streams the message is unpacked from the mmap view but the skipped
segments' words are not retained.
"""
function parse_message(filename::AbstractString, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)
    bytes = open(Mmap.mmap, filename)
    return parse_message(bytes, sf, node_name; packed=packed, pos=pos, skip=skip)
end

"""
    parse_struct(mr::MessageReader, sf::SchemaFile, node_name::AbstractString; skip=nothing)

Decode a typed value from an already-read `MessageReader` whose root is the
struct node `node_name` of `sf`. This is the typed layer over
`read_message`/`read_message_io`/`read_message_agnostic`: read the raw message
by any means, then call `parse_struct` to decode it.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them; see [`read_struct`](@ref). If the `MessageReader` was produced
by a skip-aware reader (e.g. `parse_messages` with `skip=`), the skipped
segments are already empty and the typed layer returns the empty values
naturally.
"""
function parse_struct(mr::MessageReader, sf::SchemaFile, node_name::AbstractString; skip=nothing)
    node = sf.flat[node_name]
    with_schema(sf) do
        return read_struct(get_root(mr), node; skip=skip)
    end
end

# ----- Streaming iterator over multiple messages --------------------------------

"""
    parse_messages(src, schema, node_name; packed=nothing, skip=nothing)

Return an iterator that yields one decoded message per iteration from `src`,
which is assumed to contain a stream of concatenated messages of the same
struct type `node_name`. Messages are read **lazily**: only one message at a
time is held in memory, so iterating a large stream does not load the whole
file.

The encoding is auto-detected from the first message via [`ispacked`](@ref)
and that decision is then applied to **every** message in the stream (Cap'n
Proto streams do not mix encodings). Pass `packed=true` or `false` to force a
specific interpretation and skip detection. Trailing bytes that do not form a
complete message cause an error.

`src` may be an `IO`, an `AbstractVector{UInt8}`, or a filename
(`AbstractString`). A filename is memory-mapped (via `Mmap.mmap`) and wrapped
in a buffered IO, so the file is not fully loaded into memory up front -- the
OS pages it in on demand as the iterator reads. A byte vector is wrapped
directly in a buffered IO. An `IO` is used as-is.

`skip` optionally skips decoding (and, where possible, reading) one or more
fields for every message in the stream; see [`read_struct`](@ref). For
unpacked streams the segments holding only skipped data are seeked past (no
I/O for those bytes); for packed streams those segments are decoded-and-
discarded (bytes read but not retained). This is the most efficient way to
iterate a stream of messages while ignoring a large field (e.g. a filterbank's
`data` array): only the small per-message struct segments are retained.
"""
function parse_messages(src, sf::SchemaFile, node_name::AbstractString;
                        packed::Union{Bool,Nothing}=nothing, skip=nothing)
    bio = _as_buffered_io(src)
    is_p = if packed === nothing
        ispacked(bio)
    else
        packed
    end
    return MessageIterator(sf, String(node_name), bio, is_p, skip)
end

"Wrap `src` in a buffered IO suitable for lazy reading. Byte vectors and
filenames get an IOBuffer over their contents; an existing IO is used directly.
Filenames are memory-mapped (via `Mmap.mmap`) so the file is not fully loaded
into memory up front -- the OS pages it in on demand as the iterator reads."
function _as_buffered_io(src)
    if src isa AbstractVector{UInt8}
        return IOBuffer(src; read=true, write=false)
    elseif src isa AbstractString
        # Memory-map the file so iteration reads it lazily via the OS page
        # cache rather than loading it all up front.
        bytes = open(Mmap.mmap, src)
        return IOBuffer(bytes; read=true, write=false)
    elseif src isa IO
        return src
    else
        error("parse_messages: expected an IO, byte vector, or filename, got $(typeof(src))")
    end
end

"""
    MessageIterator

Iterator over the messages of a [`parse_messages`](@ref) stream. Reads one
message at a time from the underlying IO, so memory use is bounded by the
largest single message. Iterate with `for msg in itr` or use `collect`.

Construct a `MessageIterator` via [`parse_messages`](@ref); do not call the
constructor directly. Each iteration reads and decodes exactly one message,
honoring the `skip` setting (see [`parse_messages`](@ref)).
"""
struct MessageIterator
    sf::SchemaFile
    node_name::String
    io::IO
    packed::Bool
    skip   # nothing, a collection of path strings, or a path -> Bool predicate
end

Base.IteratorSize(::Base.Type{MessageIterator}) = Base.SizeUnknown()
Base.eltype(::Base.Type{MessageIterator}) = Any

"""
    Base.iterate(it::MessageIterator, [state]) -> Union{Nothing, Tuple{Any, Nothing}}

Advance the [`MessageIterator`](@ref) `it` to the next message and return
`(value, nothing)`, or `nothing` at the end of the stream. Each call reads and
decodes exactly one message from the underlying IO, so memory use is bounded
by the largest single message. When `it.skip` is set, skipped segments are
not retained (see [`parse_messages`](@ref)).
"""
function Base.iterate(it::MessageIterator, _state::Nothing=nothing)
    eof(it.io) && return nothing
    mr, _ = _read_message_io_with_skip(it.io, it.packed, it.sf, it.node_name, it.skip)
    mr === nothing && return nothing
    node = it.sf.flat[it.node_name]
    val = with_schema(it.sf) do
        return read_struct(get_root(mr), node; skip=it.skip)
    end
    return (val, nothing)
end
