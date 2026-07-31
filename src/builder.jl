# builder.jl - struct/list builders and setters.
#
# A `StructBuilder` locates a struct within a `MessageBuilder` by segment id and
# the word index of its data section. Its layout is:
#   [data_words * 8 bytes][ptr_count pointers]
# The pointers immediately follow the data words. The struct's "base" word index
# points at the first data word; a pointer at slot `p` lives at index
# `base + data_words + p`.
#
# A `ListBuilder` locates a list body. For primitive lists the body is just the
# packed elements. For pointer (TEXT/DATA/POINTER) lists the body is one word
# (a pointer) per element. For composite lists the body begins with a tag word
# (a struct pointer describing the element) followed by the elements.

"A builder for a struct within a `MessageBuilder`. Located by segment id and
the word index of the start of the struct's data section. The struct layout is
`data_words` data words followed by `ptr_count` pointer slots."
struct StructBuilder
    msg::MessageBuilder
    seg::Int          # segment id
    base::Int         # 0-based word index of the first data word
    data_words::Int   # size of the data section in words
    ptr_count::Int    # number of pointer slots
end

"A builder for a list within a `MessageBuilder`. Located by segment id and the
word index of the start of the list body. For composite lists the body begins
with a tag word; elements start at `base + 1`."
struct ListBuilder
    msg::MessageBuilder
    seg::Int
    base::Int         # 0-based word index of the first word of the list body
    element_size::UInt64
    element_count::Int
    # For composite lists only: the element struct's data_words and ptr_count.
    elem_data_words::Int
    elem_ptr_count::Int
    # For composite lists, `base` is the tag word; elements start at base+1.
end

# ----- Root allocation ---------------------------------------------------------

"Initialize and return the root struct of a fresh `MessageBuilder`."
function init_root_struct!(msg::MessageBuilder, data_words::Int, ptr_count::Int)::StructBuilder
    # Root struct lives at the start of segment 0; its pointer is conventionally
    # stored at word 0 of segment 0. We allocate the pointer word first, then
    # the struct body after it.
    ptr_idx = alloc_words!(msg, 0, 1)
    body_idx = alloc_words!(msg, 0, data_words + ptr_count)
    off = body_idx - ptr_idx - 1
    set_word!(msg, 0, ptr_idx, struct_pointer(off, data_words, ptr_count))
    return StructBuilder(msg, 0, body_idx, data_words, ptr_count)
end

"Initialize the root as a list (rare; mostly structs are roots). Returns a ListBuilder."
function init_root_list!(msg::MessageBuilder, element_size::UInt64, element_count::Int)::ListBuilder
    ptr_idx = alloc_words!(msg, 0, 1)
    nwords = element_words(element_size, element_count)
    body_idx = alloc_words!(msg, 0, nwords)
    off = body_idx - ptr_idx - 1
    set_word!(msg, 0, ptr_idx, list_pointer(off, element_size, element_count))
    return ListBuilder(msg, 0, body_idx, element_size, element_count, 0, 0)
end

# ----- Field allocation --------------------------------------------------------

"Allocate a struct field at pointer slot `p` of `parent`."
function alloc_struct!(parent::StructBuilder, p::Int, data_words::Int, ptr_count::Int)::StructBuilder
    msg = parent.msg
    seg = parent.seg
    ptr_word_idx = parent.base + parent.data_words + p
    body_idx = alloc_words!(msg, seg, data_words + ptr_count)
    off = body_idx - ptr_word_idx - 1
    set_word!(msg, seg, ptr_word_idx, struct_pointer(off, data_words, ptr_count))
    return StructBuilder(msg, seg, body_idx, data_words, ptr_count)
end

"Allocate a list field (primitive element size) at pointer slot `p` of `parent`."
function alloc_list!(parent::StructBuilder, p::Int, element_size::UInt64, element_count::Int)::ListBuilder
    msg = parent.msg
    seg = parent.seg
    ptr_word_idx = parent.base + parent.data_words + p
    nwords = element_words(element_size, element_count)
    body_idx = alloc_words!(msg, seg, nwords)
    off = body_idx - ptr_word_idx - 1
    set_word!(msg, seg, ptr_word_idx, list_pointer(off, element_size, element_count))
    return ListBuilder(msg, seg, body_idx, element_size, element_count, 0, 0)
end

"Allocate a composite list field at pointer slot `p` of `parent`.
The list has `element_count` elements, each a struct with `data_words` data
words and `ptr_count` pointer slots."
function alloc_composite_list!(parent::StructBuilder, p::Int, element_count::Int,
                               data_words::Int, ptr_count::Int)::ListBuilder
    msg = parent.msg
    seg = parent.seg
    ptr_word_idx = parent.base + parent.data_words + p
    per = data_words + ptr_count
    body_words = element_count * per          # excludes the tag word
    nwords = 1 + body_words                    # +1 for the tag word
    body_idx = alloc_words!(msg, seg, nwords)
    off = body_idx - ptr_word_idx - 1
    # For composite lists, the list pointer's size field (D) holds the word
    # count of the body EXCLUDING the tag word.
    set_word!(msg, seg, ptr_word_idx, list_pointer(off, COMPOSITE_LIST, body_words))
    # Tag word: a struct pointer whose offset field instead holds the element
    # count; data_words and ptr_count describe each element.
    set_word!(msg, seg, body_idx, struct_pointer(element_count, data_words, ptr_count))
    return ListBuilder(msg, seg, body_idx, COMPOSITE_LIST, element_count,
                       data_words, ptr_count)
end

# ----- Primitive setters on StructBuilder --------------------------------------
# Data fields are addressed by (word, bit) where `word` is the 0-based data word
# index and `bit` is the 0-based bit within that word (for booleans).

function set_word_field!(s::StructBuilder, word::Int, value::UInt64)
    @assert 0 <= word < s.data_words
    set_word!(s.msg, s.seg, s.base + word, value)
    return nothing
end

function get_word_field(s::StructBuilder, word::Int)::UInt64
    @assert 0 <= word < s.data_words
    return get_word(s.msg, s.seg, s.base + word)
end

"Set an `Int8` field at byte `byte` (0-7) of data word `word` (0-based)."
set_int8!(s::StructBuilder, word::Int, byte::Int, v::Integer) =
    set_subword!(s, word, byte, 8, UInt64(Int8(v) % UInt8))
"Set a `UInt8` field at byte `byte` (0-7) of data word `word` (0-based)."
set_uint8!(s::StructBuilder, word::Int, byte::Int, v::Integer) =
    set_subword!(s, word, byte, 8, UInt64(UInt8(v)))
"Set an `Int16` field at the low 16 bits of data word `word` (0-based)."
set_int16!(s::StructBuilder, word::Int, v::Integer) =
    set_subword!(s, word, 0, 16, UInt64(Int16(v) % UInt16))
"Set a `UInt16` field at the low 16 bits of data word `word` (0-based)."
set_uint16!(s::StructBuilder, word::Int, v::Integer) =
    set_subword!(s, word, 0, 16, UInt64(UInt16(v)))
"Set an `Int32` field at the low 32 bits of data word `word` (0-based)."
set_int32!(s::StructBuilder, word::Int, v::Integer) =
    set_subword!(s, word, 0, 32, UInt64(Int32(v) % UInt32))
"Set a `UInt32` field at the low 32 bits of data word `word` (0-based)."
set_uint32!(s::StructBuilder, word::Int, v::Integer) =
    set_subword!(s, word, 0, 32, UInt64(UInt32(v)))
"Set an `Int64` field occupying all of data word `word` (0-based)."
set_int64!(s::StructBuilder, word::Int, v::Integer) = set_word_field!(s, word, reinterpret(UInt64, Int64(v)))
"Set a `UInt64` field occupying all of data word `word` (0-based)."
set_uint64!(s::StructBuilder, word::Int, v::Integer) = set_word_field!(s, word, UInt64(v))
"Set a `Float32` field at the low 32 bits of data word `word` (0-based)."
set_float32!(s::StructBuilder, word::Int, v::AbstractFloat) =
    set_subword!(s, word, 0, 32, UInt64(reinterpret(UInt32, Float32(v))))
"Set a `Float64` field occupying all of data word `word` (0-based)."
set_float64!(s::StructBuilder, word::Int, v::AbstractFloat) =
    set_word_field!(s, word, reinterpret(UInt64, Float64(v)))

"Set a boolean bit at `(word, bit)`."
function set_bool!(s::StructBuilder, word::Int, bit::Int, v::Bool)
    @assert 0 <= word < s.data_words
    idx = s.base + word
    w = get_word(s.msg, s.seg, idx)
    mask = UInt64(1) << bit
    set_word!(s.msg, s.seg, idx, v ? (w | mask) : (w & ~mask))
    return nothing
end

"Helper to set a sub-word field of `bits` width starting at byte `byte` within `word`."
function set_subword!(s::StructBuilder, word::Int, byte::Int, bits::Int, v::UInt64)
    @assert 0 <= word < s.data_words
    @assert bits in (8, 16, 32, 64)
    idx = s.base + word
    w = get_word(s.msg, s.seg, idx)
    shift = byte * 8
    mask = (UInt64(1) << bits - 1) << shift
    w = (w & ~mask) | ((v << shift) & mask)
    set_word!(s.msg, s.seg, idx, w)
    return nothing
end

# ----- Text / data -------------------------------------------------------------
# Text and Data are List(UInt8) and are encoded as a list of bytes with a NUL
# terminator for text. We model both as a primitive byte list with element_size
# INT8_LIST. `set_text!` adds a trailing NUL.

"Allocate and fill a text field at pointer slot `p` of `parent`."
function set_text!(parent::StructBuilder, p::Int, s::AbstractString)
    bytes = codeunits(s)
    n = sizeof(bytes) + 1  # +1 for NUL terminator
    lb = alloc_list!(parent, p, INT8_LIST, n)
    # Write bytes into the body. Each word holds 8 bytes.
    body = lb.base
    for i in 1:n
        b = i <= sizeof(bytes) ? bytes[i] : 0x00
        set_byte_in_word!(parent.msg, parent.seg, body, i - 1, b)
    end
    return nothing
end

"Allocate and fill a Data field at pointer slot `p` of `parent`."
function set_data!(parent::StructBuilder, p::Int, data::AbstractVector{UInt8})
    n = length(data)
    lb = alloc_list!(parent, p, INT8_LIST, n)
    body = lb.base
    for (i, b) in enumerate(data)
        set_byte_in_word!(parent.msg, parent.seg, body, i - 1, b)
    end
    return nothing
end

"Set byte `k` (0-based) of a byte list whose body starts at word `body`."
function set_byte_in_word!(msg::MessageBuilder, seg::Int, body::Int, k::Int, b::UInt8)
    word = body + k ÷ 8
    byte = k % 8
    w = get_word(msg, seg, word)
    shift = byte * 8
    mask = UInt64(0xff) << shift
    w = (w & ~mask) | (UInt64(b) << shift)
    set_word!(msg, seg, word, w)
    return nothing
end

# ----- List element setters ----------------------------------------------------

"Set element `i` (0-based) of a primitive list to a 64-bit value."
function set_element!(lb::ListBuilder, i::Int, v::UInt64)
    @assert lb.element_size != COMPOSITE_LIST && lb.element_size != POINTER_LIST
    if lb.element_size == VOID_LIST
        return nothing
    elseif lb.element_size == BOOL_LIST
        word = lb.base + i ÷ 64
        bit = i % 64
        w = get_word(lb.msg, lb.seg, word)
        mask = UInt64(1) << bit
        set_word!(lb.msg, lb.seg, word, v != 0 ? (w | mask) : (w & ~mask))
        return nothing
    elseif lb.element_size == INT8_LIST
        return set_byte_in_word!(lb.msg, lb.seg, lb.base, i, UInt8(v))
    end
    # 16/32/64-bit: pack into words (64 bits per word).
    bits = lb.element_size == INT16_LIST ? 16 :
           lb.element_size == INT32_LIST ? 32 :
           lb.element_size == FLOAT32_LIST ? 32 :
           lb.element_size == INT64_LIST ? 64 :
           lb.element_size == FLOAT64_LIST ? 64 : 64
    per = 64 ÷ bits  # elements per word
    word = lb.base + i ÷ per
    byte = (i % per) * (bits ÷ 8)
    w = get_word(lb.msg, lb.seg, word)
    shift = byte * 8
    mask = (UInt64(1) << bits - 1) << shift
    w = (w & ~mask) | ((v << shift) & mask)
    set_word!(lb.msg, lb.seg, word, w)
    return nothing
end

"Set element `i` (0-based) of a list to a text value. The list must be List(Text)
i.e. a pointer list whose elements are text pointers."
function set_text_element!(lb::ListBuilder, i::Int, s::AbstractString)
    @assert lb.element_size == POINTER_LIST
    # The element pointer slot is at word `base + i`.
    ptr_idx = lb.base + i
    # Build a fake StructBuilder-like view to reuse alloc logic for the pointer slot.
    fake = StructBuilder(lb.msg, lb.seg, ptr_idx - 0, 0, 1)
    # `fake` has its pointer slot 0 at index `ptr_idx`.
    set_text!(fake, 0, s)
    return nothing
end

# ----- Composite-list element access -------------------------------------------

"Return a StructBuilder view of element `i` (0-based) of a composite list."
function list_element_struct(lb::ListBuilder, i::Int)::StructBuilder
    @assert lb.element_size == COMPOSITE_LIST
    per = lb.elem_data_words + lb.elem_ptr_count
    base = lb.base + 1 + i * per   # +1 to skip the tag word
    return StructBuilder(lb.msg, lb.seg, base, lb.elem_data_words, lb.elem_ptr_count)
end

"Number of elements in a list under construction."
list_length(lb::ListBuilder)::Int = lb.element_count

"IsNull check on a pointer slot of a struct."
function is_null(s::StructBuilder, p::Int)::Bool
    idx = s.base + s.data_words + p
    return get_word(s.msg, s.seg, idx) == 0
end

# ----- Convenience field setters ------------------------------------------------
# These wrap alloc_struct!/alloc_list! for the common case of writing a field
# whose value is a struct or list built inline. They return the new builder so
# the caller can fill it in.

"Allocate a struct at pointer slot `p` of `parent` with the given layout and
return the `StructBuilder` for it. Convenience alias for `alloc_struct!`."
set_struct_field!(parent::StructBuilder, p::Int, data_words::Int, ptr_count::Int) =
    alloc_struct!(parent, p, data_words, ptr_count)

"Allocate a primitive-element list at pointer slot `p` of `parent`. Convenience
alias for `alloc_list!`."
set_list_field!(parent::StructBuilder, p::Int, element_size::UInt64, element_count::Int) =
    alloc_list!(parent, p, element_size, element_count)

"Set a text field at pointer slot `p`. Convenience alias for `set_text!`."
set_text_field!(parent::StructBuilder, p::Int, s::AbstractString) = set_text!(parent, p, s)

"Set a Data field at pointer slot `p`. Convenience alias for `set_data!`."
set_data_field!(parent::StructBuilder, p::Int, data::AbstractVector{UInt8}) =
    set_data!(parent, p, data)
