# reader.jl - struct/list readers and getters.
#
# Mirrors builder.jl but read-only. Resolves struct/list/far pointers.

struct StructReader
    msg::MessageReader
    seg::Int
    base::Int          # word index of the first data word
    data_words::Int
    ptr_count::Int
end

struct ListReader
    msg::MessageReader
    seg::Int
    base::Int          # word index of the first body word (for composite: the tag word)
    element_size::UInt64
    element_count::Int
    elem_data_words::Int
    elem_ptr_count::Int
end

# ----- Root and pointer resolution ---------------------------------------------

"Resolve a pointer word located at `seg`,`word_idx`. Returns a resolved pointee.
The return is either a StructReader, ListReader, or `nothing` if the pointer is null."
function resolve_pointer(msg::MessageReader, seg::Int, word_idx::Int)
    p = get_word(msg, seg, word_idx)
    if p == 0
        return nothing
    end
    return resolve_pointer_value(msg, seg, word_idx, p)
end

function resolve_pointer_value(msg::MessageReader, seg::Int, word_idx::Int, p::UInt64)
    t = pointer_type(p)
    if t == STRUCT_POINTER
        off = pointer_offset(p)
        base = word_idx + 1 + off
        return StructReader(msg, seg, base, struct_data_words(p), struct_ptr_count(p))
    elseif t == LIST_POINTER
        off = pointer_offset(p)
        base = word_idx + 1 + off
        esize = list_element_size(p)
        if esize == COMPOSITE_LIST
            # The list pointer's D field is the body word count EXCLUDING the
            # tag word. The tag word is a struct pointer whose offset field
            # holds the element count.
            tag = get_word(msg, seg, base)
            elem_count = Int(pointer_offset(tag))
            data_words = struct_data_words(tag)
            ptr_count = struct_ptr_count(tag)
            return ListReader(msg, seg, base, COMPOSITE_LIST,
                              elem_count, data_words, ptr_count)
        end
        return ListReader(msg, seg, base, esize, list_element_count(p), 0, 0)
    elseif t == FAR_POINTER
        return resolve_far(msg, p)
    else
        error("unknown pointer type $t")
    end
end

function resolve_far(msg::MessageReader, p::UInt64)
    target_seg = far_segment_id(p)  # 0-based
    target_off = far_offset(p)      # 0-based word index
    if far_is_double(p)
        # Two-word landing pad: [far ptr][struct/list ptr]
        real_ptr = get_word(msg, target_seg, target_off + 1)
        return resolve_pointer_value(msg, target_seg, target_off + 1, real_ptr)
    else
        landing = get_word(msg, target_seg, target_off)
        return resolve_pointer_value(msg, target_seg, target_off, landing)
    end
end

"Get the root struct of a message."
function get_root(mr::MessageReader)::StructReader
    p = get_word(mr, 0, 0)
    if pointer_type(p) == STRUCT_POINTER
        off = pointer_offset(p)
        return StructReader(mr, 0, 1 + off, struct_data_words(p), struct_ptr_count(p))
    end
    # If the root is a list or far, resolve and adapt.
    r = resolve_pointer(mr, 0, 0)
    r isa StructReader && return r
    error("root is not a struct")
end

# ----- Primitive getters -------------------------------------------------------

function get_word_field(s::StructReader, word::Int)::UInt64
    @assert 0 <= word < s.data_words
    return get_word(s.msg, s.seg, s.base + word)
end

get_int8(s::StructReader, word::Int, byte::Int) =
    Int8(reinterpret(Int8, UInt8(get_subword(s, word, byte, 8))))
get_uint8(s::StructReader, word::Int, byte::Int) =
    UInt8(get_subword(s, word, byte, 8))
get_int16(s::StructReader, word::Int) =
    Int16(reinterpret(Int16, UInt16(get_subword(s, word, 0, 16))))
get_uint16(s::StructReader, word::Int) =
    UInt16(get_subword(s, word, 0, 16))
get_int32(s::StructReader, word::Int) =
    Int32(reinterpret(Int32, UInt32(get_subword(s, word, 0, 32))))
get_uint32(s::StructReader, word::Int) =
    UInt32(get_subword(s, word, 0, 32))
get_int64(s::StructReader, word::Int) = Int64(reinterpret(Int64, get_word_field(s, word)))
get_uint64(s::StructReader, word::Int) = UInt64(get_word_field(s, word))
get_float32(s::StructReader, word::Int) =
    Float32(reinterpret(Float32, UInt32(get_subword(s, word, 0, 32))))
get_float64(s::StructReader, word::Int) =
    Float64(reinterpret(Float64, get_word_field(s, word)))

function get_bool(s::StructReader, word::Int, bit::Int)::Bool
    @assert 0 <= word < s.data_words
    w = get_word(s.msg, s.seg, s.base + word)
    return (w >> bit) & 1 == 1
end

function get_subword(s::StructReader, word::Int, byte::Int, bits::Int)::UInt64
    @assert 0 <= word < s.data_words
    w = get_word(s.msg, s.seg, s.base + word)
    shift = byte * 8
    mask = (UInt64(1) << bits) - 1
    return (w >> shift) & mask
end

# ----- Field accessors (pointer slots) -----------------------------------------

"Get the StructReader for pointer slot `p` of `parent`, or `nothing` if null."
function get_struct_field(parent::StructReader, p::Int)::Union{StructReader, Nothing}
    idx = parent.base + parent.data_words + p
    r = resolve_pointer(parent.msg, parent.seg, idx)
    r isa StructReader ? r : nothing
end

"Get the ListReader for pointer slot `p` of `parent`, or `nothing` if null."
function get_list_field(parent::StructReader, p::Int)::Union{ListReader, Nothing}
    idx = parent.base + parent.data_words + p
    r = resolve_pointer(parent.msg, parent.seg, idx)
    r isa ListReader ? r : nothing
end

"Get the text at pointer slot `p`, or `nothing` if null."
function get_text(parent::StructReader, p::Int)::Union{String, Nothing}
    lr = get_list_field(parent, p)
    lr === nothing && return nothing
    return get_text(lr)
end

"Get the data at pointer slot `p`, or `nothing` if null."
function get_data(parent::StructReader, p::Int)::Union{Vector{UInt8}, Nothing}
    lr = get_list_field(parent, p)
    lr === nothing && return nothing
    return get_data(lr)
end

# ----- Text / data from a ListReader -------------------------------------------

function get_text(lr::ListReader)::String
    @assert lr.element_size == INT8_LIST
    n = lr.element_count
    # The trailing NUL is not part of the string content.
    n > 0 && (n -= 1)
    bytes = Vector{UInt8}(undef, n)
    for i in 1:n
        bytes[i] = get_byte(lr, i - 1)
    end
    return String(bytes)
end

function get_data(lr::ListReader)::Vector{UInt8}
    @assert lr.element_size == INT8_LIST
    n = lr.element_count
    bytes = Vector{UInt8}(undef, n)
    for i in 1:n
        bytes[i] = get_byte(lr, i - 1)
    end
    return bytes
end

"Get byte `k` (0-based) of a byte list."
function get_byte(lr::ListReader, k::Int)::UInt8
    word = lr.base + k ÷ 8
    byte = k % 8
    w = get_word(lr.msg, lr.seg, word)
    return UInt8((w >> (byte * 8)) & 0xff)
end

# ----- List element getters ----------------------------------------------------

list_length(lr::ListReader)::Int = lr.element_count

"Get element `i` (0-based) of a primitive list as a UInt64."
function get_element(lr::ListReader, i::Int)::UInt64
    if lr.element_size == VOID_LIST
        return 0
    elseif lr.element_size == BOOL_LIST
        word = lr.base + i ÷ 64
        bit = i % 64
        return (get_word(lr.msg, lr.seg, word) >> bit) & 1
    elseif lr.element_size == INT8_LIST
        return UInt64(get_byte(lr, i))
    end
    bits = lr.element_size == INT16_LIST ? 16 :
           lr.element_size == INT32_LIST ? 32 :
           lr.element_size == FLOAT32_LIST ? 32 :
           lr.element_size == INT64_LIST ? 64 :
           lr.element_size == FLOAT64_LIST ? 64 : 64
    per = 64 ÷ bits
    word = lr.base + i ÷ per
    byte = (i % per) * (bits ÷ 8)
    w = get_word(lr.msg, lr.seg, word)
    return (w >> (byte * 8)) & ((UInt64(1) << bits) - 1)
end

"Get element `i` (0-based) of a list of text."
function get_text_element(lr::ListReader, i::Int)::Union{String, Nothing}
    @assert lr.element_size == POINTER_LIST
    ptr_idx = lr.base + i
    r = resolve_pointer(lr.msg, lr.seg, ptr_idx)
    r isa ListReader ? get_text(r) : nothing
end

"Get a StructReader for element `i` (0-based) of a composite list."
function list_element_struct(lr::ListReader, i::Int)::StructReader
    @assert lr.element_size == COMPOSITE_LIST
    per = lr.elem_data_words + lr.elem_ptr_count
    base = lr.base + 1 + i * per   # +1 to skip the tag
    return StructReader(lr.msg, lr.seg, base, lr.elem_data_words, lr.elem_ptr_count)
end

"IsNull check on a pointer slot of a struct."
function is_null(s::StructReader, p::Int)::Bool
    idx = s.base + s.data_words + p
    return get_word(s.msg, s.seg, idx) == 0
end
