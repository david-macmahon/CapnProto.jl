# wire.jl - low-level Cap'n Proto wire-format constants and pointer utilities.
#
# Cap'n Proto messages are sequences of 64-bit words. Pointers are one word:
#
#   bits 0..1  : pointer type tag (0=struct, 1=list, 2=far)
#   bits 2..31 : offset (struct/list) or far info
#   bits 32..63: type-specific payload
#
# See https://capnproto.org/encoding.html#pointers

const WirePointer = UInt64

# Pointer type tags (lowest 2 bits of the pointer word).
const STRUCT_POINTER = UInt64(0)
const LIST_POINTER = UInt64(1)
const FAR_POINTER = UInt64(2)

# Far pointer landing-pad kinds (bit 2 of a far pointer).
const SINGLE_FAR = UInt64(0)
const DOUBLE_FAR = UInt64(4)

# List element-size enumerations (3-bit field C of a list pointer, bits 32-34).
# Per the Cap'n Proto encoding spec, this encodes only the *size* of each
# element, not the type. Float32 and Int32 share size 4; Float64 and Int64
# share size 5. Text and Data are List(UInt8), i.e. element size 2.
const VOID_LIST = UInt64(0)       # 0 bits  (e.g. List(Void))
const BOOL_LIST = UInt64(1)       # 1 bit
const INT8_LIST = UInt64(2)       # 1 byte  (Int8, UInt8, Data, Text elements)
const INT16_LIST = UInt64(3)      # 2 bytes (Int16, UInt16)
const INT32_LIST = UInt64(4)      # 4 bytes (Int32, UInt32, Float32)
const INT64_LIST = UInt64(5)      # 8 bytes non-pointer (Int64, UInt64, Float64)
const FLOAT32_LIST = INT32_LIST   # alias: 4 bytes
const FLOAT64_LIST = INT64_LIST   # alias: 8 bytes
const POINTER_LIST = UInt64(6)    # 8 bytes pointer
const COMPOSITE_LIST = UInt64(7)  # composite (tag word prefix)

# Decode the tag of a pointer word.
pointer_type(p::WirePointer)::UInt64 = p & 0x3

"Offset (in words) from the pointer word to the pointee, for struct/list pointers."
function pointer_offset(p::WirePointer)::Int64
    # bits 2..31 are a signed two's-complement 30-bit integer.
    raw = (p >>> 2) & 0x3fffffff
    return reinterpret(Int64, raw << 34) >> 34
end

"For struct pointers: data section size in words (bits 32..47)."
struct_data_words(p::WirePointer)::UInt16 = ((p >>> 32) & 0xffff) % UInt16

"For struct pointers: pointer section size (bits 48..63)."
struct_ptr_count(p::WirePointer)::UInt16 = ((p >>> 48) & 0xffff) % UInt16

"For list pointers: element count (bits 35..63, 29 bits). For composite lists
this is the total word count of the body EXCLUDING the tag word."
list_element_count(p::WirePointer)::UInt32 = ((p >>> 35) & 0x1fffffff) % UInt32

"For list pointers: element size tag (bits 32..34, 3 bits)."
list_element_size(p::WirePointer)::UInt64 = (p >>> 32) & 0x7

"For far pointers: double-far flag (bit 2)."
far_is_double(p::WirePointer)::Bool = (p & 0x4) != 0

"For far pointers: offset in target segment (bits 3..31, 29 bits unsigned)."
far_offset(p::WirePointer)::UInt32 = ((p >>> 3) & 0x1fffffff) % UInt32

"For far pointers: target segment id (bits 32..63, 32 bits)."
far_segment_id(p::WirePointer)::UInt32 = ((p >>> 32) & 0xffffffff) % UInt32

# ----- Encoders ----------------------------------------------------------------

"Encode a struct pointer at value `p` pointing `offset` words forward/backward
from the pointer slot, with `data_words` data words and `ptr_count` pointer slots."
function struct_pointer(offset::Int64, data_words::Integer, ptr_count::Integer)::WirePointer
    @assert -(1 << 29) <= offset < (1 << 29) "struct pointer offset out of range"
    off = (UInt64(offset & 0x3fffffff) & 0x3fffffff) << 2
    return STRUCT_POINTER | off |
           (UInt64(UInt16(data_words) & 0xffff) << 32) |
           (UInt64(UInt16(ptr_count) & 0xffff) << 48)
end

"Encode a list pointer at value `p` pointing `offset` words from the pointer slot,
with `element_size` tag (3 bits) and `element_count` elements (or word count for
composite lists)."
function list_pointer(offset::Int64, element_size::WirePointer, element_count::Integer)::WirePointer
    @assert -(1 << 29) <= offset < (1 << 29) "list pointer offset out of range"
    @assert 0 <= element_size <= 7 "list element_size must fit in 3 bits"
    off = (UInt64(offset & 0x3fffffff) & 0x3fffffff) << 2
    return LIST_POINTER | off |
           ((element_size & 0x7) << 32) |
           (UInt64(element_count & 0x1fffffff) << 35)
end

"Encode a far pointer to `offset` words into `segment_id` (optionally double-far)."
function far_pointer(offset::Integer, segment_id::Integer, double::Bool=false)::WirePointer
    return FAR_POINTER |
           (double ? DOUBLE_FAR : UInt64(0)) |
           (UInt64(offset & 0x1fffffff) << 3) |
           (UInt64(segment_id & 0xffffffff) << 32)
end

# ----- Endianness --------------------------------------------------------------

# Cap'n Proto is little-endian on the wire. We store segments as Vector{UInt64}
# in native byte order and convert at serialization/parsing time.

@inline function load_word_le(bytes::AbstractVector{UInt8}, i::Int)::UInt64
    # `i` is a byte index (1-based) into `bytes`.
    w = UInt64(0)
    w |= UInt64(bytes[i])
    w |= UInt64(bytes[i+1]) << 8
    w |= UInt64(bytes[i+2]) << 16
    w |= UInt64(bytes[i+3]) << 24
    w |= UInt64(bytes[i+4]) << 32
    w |= UInt64(bytes[i+5]) << 40
    w |= UInt64(bytes[i+6]) << 48
    w |= UInt64(bytes[i+7]) << 56
    return w
end

@inline function store_word_le!(bytes::AbstractVector{UInt8}, i::Int, w::UInt64)
    bytes[i] = (w & 0xff) % UInt8
    bytes[i+1] = ((w >>> 8) & 0xff) % UInt8
    bytes[i+2] = ((w >>> 16) & 0xff) % UInt8
    bytes[i+3] = ((w >>> 24) & 0xff) % UInt8
    bytes[i+4] = ((w >>> 32) & 0xff) % UInt8
    bytes[i+5] = ((w >>> 40) & 0xff) % UInt8
    bytes[i+6] = ((w >>> 48) & 0xff) % UInt8
    bytes[i+7] = ((w >>> 56) & 0xff) % UInt8
    return nothing
end

# Number of 64-bit words occupied by a list of `count` elements of the given
# primitive element-size tag (NOT COMPOSITE_LIST). Text/Data are byte lists
# (INT8_LIST). Pointer lists take one word per element.
function element_words(element_size::WirePointer, count::Integer)::Int
    if count == 0
        return 0
    end
    @assert element_size != COMPOSITE_LIST "element_words: composite lists use a tag word; handle separately"
    bits_per = if element_size == VOID_LIST
        0
    elseif element_size == BOOL_LIST
        1
    elseif element_size == INT8_LIST
        8
    elseif element_size == INT16_LIST
        16
    elseif element_size == INT32_LIST
        32
    elseif element_size == INT64_LIST
        64
    elseif element_size == POINTER_LIST
        64
    else
        error("unknown element size tag $element_size")
    end
    return cld(count * bits_per, 64)
end
