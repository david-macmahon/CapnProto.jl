# packed.jl - Cap'n Proto packed encoding.
#
# The packed encoding compresses runs of zero words and repeats. See
# https://capnproto.org/encoding.html#packing for the full algorithm.
#
# Tags (one byte per group of 0..8 words):
#   0x00 : the next byte is a count, then that many additional all-zero words follow
#   0xff : 8 words follow verbatim
#   other: bit `b` of the tag is 1 if word `b` is non-zero; those words follow in order
#
# Packed text/data is packed as part of the word stream, so we operate on the
# raw serialized message bytes, interpreted as a sequence of 64-bit words.

"""
    write_packed(mb::MessageBuilder)::Vector{UInt8}

Serialize `mb` in packed form. Equivalent to `pack(write_message(mb))`.
"""
function write_packed(mb::MessageBuilder)::Vector{UInt8}
    return pack(write_message(mb))
end

"""
    pack(bytes::AbstractVector{UInt8})::Vector{UInt8}

Pack a byte vector (which must be a whole unpacked message including the
segment table) into packed form.
"""
function pack(bytes::AbstractVector{UInt8})::Vector{UInt8}
    @assert length(bytes) % 8 == 0 "pack: input must be a whole number of words"
    nwords = length(bytes) ÷ 8
    out = IOBuffer()
    i = 0  # 0-based word index
    while i < nwords
        # Look for a run of zero words.
        zrun = 0
        while i + zrun < nwords && is_zero_word(bytes, i + zrun)
            zrun += 1
        end
        if zrun > 0
            # Emit zero-run tags. Each tag handles 1 + N extra zero words where N is in 0..255.
            while zrun > 0
                extra = min(zrun - 1, 255)
                write(out, 0x00)
                write(out, UInt8(extra))
                zrun -= (extra + 1)
                i += (extra + 1)
            end
            continue
        end
        # Process the current word: compute its tag and emit its non-zero bytes.
        w = load_word_le(bytes, 8 * i + 1)
        tag = word_tag(w)
        write(out, tag)
        write_nonzero_bytes(out, w, tag)
        if tag == 0xff
            # Verbatim run: count N additional all-non-zero words, then copy them.
            # The run extends while the word's tag is 0xff (all 8 bytes non-zero).
            n = 0
            while i + 1 + n < nwords && word_tag(load_word_le(bytes, 8 * (i + 1 + n) + 1)) == 0xff
                n += 1
            end
            write(out, UInt8(min(n, 255)))
            for k in 1:n
                write_word_le(out, load_word_le(bytes, 8 * (i + k) + 1))
            end
            i += 1 + n
        else
            i += 1
        end
    end
    return take!(out)
end

"Compute the 8-bit packed tag for a word: bit `b` is set iff byte `b` is non-zero."
function word_tag(w::UInt64)::UInt8
    tag = 0x00
    for b in 0:7
        if ((w >>> (8 * b)) & 0xff) != 0
            tag |= (UInt8(1) << b)
        end
    end
    return tag
end

"Write the non-zero bytes of `w` (those whose tag bit is set) to `io`."
function write_nonzero_bytes(io::IO, w::UInt64, tag::UInt8)
    for b in 0:7
        if (tag >> b) & 1 == 1
            write(io, UInt8((w >>> (8 * b)) & 0xff))
        end
    end
    return nothing
end

function is_zero_word(bytes::AbstractVector{UInt8}, word_idx::Int)::Bool
    base = 8 * word_idx + 1
    return all(bytes[base + k] == 0x00 for k in 0:7)
end

function write_word_le(io::IO, w::UInt64)
    write(io, UInt8(w & 0xff))
    write(io, UInt8((w >>> 8) & 0xff))
    write(io, UInt8((w >>> 16) & 0xff))
    write(io, UInt8((w >>> 24) & 0xff))
    write(io, UInt8((w >>> 32) & 0xff))
    write(io, UInt8((w >>> 40) & 0xff))
    write(io, UInt8((w >>> 48) & 0xff))
    write(io, UInt8((w >>> 56) & 0xff))
    return nothing
end

"""
    read_packed(bytes::AbstractVector{UInt8}; start::Int=1)::MessageReader

Parse a packed message byte vector into a MessageReader. Throws if the input
ends mid-message. Returns only the MessageReader (unlike `read_message`).
"""
function read_packed(bytes::AbstractVector{UInt8}; start::Int=1)::MessageReader
    unpacked = unpack(bytes, start=start)
    mr, _ = read_message(unpacked)
    return mr
end

"""
    read_message_agnostic(bytes::AbstractVector{UInt8}; packed::Union{Bool,Nothing}=nothing, start::Int=1)::MessageReader

Auto-detect the encoding of `bytes` and return a `MessageReader`. If
[`looks_packed`](@ref) returns false, the input is treated as the standard
stream format; otherwise it is unpacked via the packed decoder. Pass
`packed=true` or `packed=false` to force a specific interpretation. `start`
gives the 1-based byte offset at which to begin (default 1).
"""
function read_message_agnostic(bytes::AbstractVector{UInt8}; packed::Union{Bool,Nothing}=nothing, start::Int=1)::MessageReader
    if packed === nothing
        packed = looks_packed(bytes; start=start)
    end
    return packed ? read_packed(bytes; start=start) : read_message(bytes; start=start)[1]
end

"""
    unpack(bytes::AbstractVector{UInt8}; start::Int=1)::Vector{UInt8}

Unpack a packed-encoded byte vector into a full unpacked message byte vector.
"""
function unpack(bytes::AbstractVector{UInt8}; start::Int=1)::Vector{UInt8}
    out = IOBuffer()
    i = start
    n = length(bytes)
    while i <= n
        tag = bytes[i]
        i += 1
        if tag == 0x00
            # Zero run: next byte is count of additional zero words.
            extra = bytes[i]
            i += 1
            for _ in 1:(extra + 1)
                write_word_le(out, UInt64(0))
            end
            continue
        end
        # Reconstruct one word from the tag + the non-zero bytes that follow.
        w = UInt64(0)
        for b in 0:7
            if (tag >> b) & 1 == 1
                w |= UInt64(bytes[i]) << (8 * b)
                i += 1
            end
        end
        write_word_le(out, w)
        if tag == 0xff
            # Verbatim run: next byte is N, then N additional words copied directly.
            extra = bytes[i]
            i += 1
            for _ in 1:extra
                w = read_word_le(bytes, i)
                write_word_le(out, w)
                i += 8
            end
        end
    end
    return take!(out)
end

function read_word_le(bytes::AbstractVector{UInt8}, i::Int)::UInt64
    # `i` is a 1-based byte index.
    return UInt64(bytes[i]) | (UInt64(bytes[i + 1]) << 8) |
           (UInt64(bytes[i + 2]) << 16) | (UInt64(bytes[i + 3]) << 24) |
           (UInt64(bytes[i + 4]) << 32) | (UInt64(bytes[i + 5]) << 40) |
           (UInt64(bytes[i + 6]) << 48) | (UInt64(bytes[i + 7]) << 56)
end
