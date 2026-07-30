# message.jl - segment-based message buffers for building and reading.
#
# A Cap'n Proto message is a sequence of segments, each a sequence of 64-bit
# words. The serialized stream begins with a segment table:
#
#   [u32 segment_count-1][u32 len(seg0)][u32 len(seg1)]...[pad][seg0 words][seg1 words]...
#
# The segment table is padded so the first segment starts on an 8-byte boundary.

# ----- Builder side ------------------------------------------------------------

"""
    MessageBuilder()

A mutable Cap'n Proto message under construction. Segments are stored as
`Vector{Vector{UInt64}}` in native byte order. The first segment is created
on construction; new segments can be allocated on demand by `alloc!`.
"""
mutable struct MessageBuilder
    segments::Vector{Vector{UInt64}}
    # Preallocated space (in words) per segment for far-pointer bookkeeping is
    # not needed; we allocate exactly when needed.
    function MessageBuilder()
        return new([UInt64[]])
    end
end

"Number of segments in the message."
nsegments(mb::MessageBuilder)::Int = length(mb.segments)

"Number of words currently used in segment `seg` (0-based segment id)."
function segment_words(mb::MessageBuilder, seg::Int)::Int
    return length(mb.segments[seg + 1])
end

"Allocate `n` words at the end of segment `seg` (0-based) and return the word index (0-based) of the first new word. The new words are zero-initialized."
function alloc_words!(mb::MessageBuilder, seg::Int, n::Int)::Int
    words = mb.segments[seg + 1]
    idx = length(words)
    old = idx
    resize!(words, idx + n)
    fill!(@view(words[old+1:end]), UInt64(0))
    return idx
end

"Append a word to segment `seg` (0-based) and return its 0-based index."
push_word!(mb::MessageBuilder, seg::Int, w::UInt64) = (push!(mb.segments[seg + 1], w); length(mb.segments[seg + 1]) - 1)

"Read a word from segment `seg` (0-based) at 0-based index `i`."
get_word(mb::MessageBuilder, seg::Int, i::Int)::UInt64 = mb.segments[seg + 1][i + 1]

"Set word `i` (0-based) in segment `seg` (0-based)."
function set_word!(mb::MessageBuilder, seg::Int, i::Int, w::UInt64)
    mb.segments[seg + 1][i + 1] = w
    return nothing
end

"Allocate a fresh segment and return its 0-based id."
function alloc_segment!(mb::MessageBuilder)::Int
    push!(mb.segments, UInt64[])
    return length(mb.segments) - 1
end

"Serialize a MessageBuilder to a byte vector in standard (unpacked) form, including the segment table."
function write_message(mb::MessageBuilder)::Vector{UInt8}
    nseg = length(mb.segments)
    table_words = cld(1 + nseg, 2) # (count word + nseg length words), padded to even
    total_table_bytes = table_words * 8
    body_bytes = sum(length(seg) * 8 for seg in mb.segments)
    out = Vector{UInt8}(undef, total_table_bytes + body_bytes)
    ii = 0
    # Segment count - 1 as UInt32 LE.
    ii = store_u32_le!(out, ii, UInt32(nseg - 1))
    for seg in mb.segments
        ii = store_u32_le!(out, ii, UInt32(length(seg)))
    end
    # Pad to 8-byte boundary.
    while ii % 8 != 0
        out[ii + 1] = 0
        ii += 1
    end
    # Body: words in native order, serialized little-endian.
    for seg in mb.segments
        for w in seg
            store_word_le!(out, ii + 1, w)
            ii += 8
        end
    end
    return out
end

function store_u32_le!(out::AbstractVector{UInt8}, i::Int, v::UInt32)::Int
    # `i` is 0-based byte offset; returns new 0-based offset.
    out[i + 1] = (v & 0xff) % UInt8
    out[i + 2] = ((v >>> 8) & 0xff) % UInt8
    out[i + 3] = ((v >>> 16) & 0xff) % UInt8
    out[i + 4] = ((v >>> 24) & 0xff) % UInt8
    return i + 4
end

# ----- Reader side -------------------------------------------------------------

"""
    MessageReader(segments)

A read-only view over a Cap'n Proto message given as a vector of segments,
each a `Vector{UInt64}` in native byte order.
"""
struct MessageReader
    segments::Vector{Vector{UInt64}}
end

nsegments(mr::MessageReader)::Int = length(mr.segments)
segment_words(mr::MessageReader, seg::Int)::Int = length(mr.segments[seg + 1])
get_word(mr::MessageReader, seg::Int, i::Int)::UInt64 = mr.segments[seg + 1][i + 1]

"Parse a standard (unpacked) serialized message from `bytes` starting at byte index `start` (1-based).
Returns `(MessageReader, next_start)` where `next_start` is the byte index just past the message."
function read_message(bytes::AbstractVector{UInt8}; start::Int=1)
    # Segment table: u32 (count-1), then count u32 lengths, padded to 8 bytes
    # relative to the start of the stream.
    seg_count = load_u32_le(bytes, start) + 1
    ii = start + 4
    lengths = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        lengths[k] = load_u32_le(bytes, ii)
        ii += 4
    end
    # Pad so the body starts on an 8-byte boundary relative to `start`.
    table_bytes = ii - start
    if table_bytes % 8 != 0
        ii += 8 - (table_bytes % 8)
    end
    segments = Vector{Vector{UInt64}}(undef, seg_count)
    for k in 1:seg_count
        n = lengths[k]
        seg = Vector{UInt64}(undef, n)
        for j in 1:n
            seg[j] = load_word_le(bytes, ii)
            ii += 8
        end
        segments[k] = seg
    end
    return MessageReader(segments), ii
end

function load_u32_le(bytes::AbstractVector{UInt8}, i::Int)::UInt32
    return UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) |
           (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
end
