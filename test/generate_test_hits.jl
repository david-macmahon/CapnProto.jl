# Generates test/test.hits: a small, representative seticore-style hits file
# with multiple messages, each a two-segment Cap'n Proto message (root Hit
# struct in seg0, filterbank.data List(Float32) body in seg1 via a far pointer),
# matching the layout of real seticore .hits files so that segment-skipping
# tests exercise the same code path.
#
# Run:  julia --project=. test/generate_test_hits.jl

using Capnp

const HIT_SCHEMA = joinpath(@__DIR__, "hit.capnp")
const OUT_FILE = joinpath(@__DIR__, "test.hits")

# Small but representative filterbank dimensions: 8 timesteps x 16 channels.
# Real files use ~29 x ~86; we shrink to keep the test fixture tiny while still
# exercising the multi-segment layout and a non-trivial data array.
const NUM_TIMESTEPS = 8
const NUM_CHANNELS = 16
const NUM_HITS = 4

"Allocate the filterbank.data List(Float32) in a fresh segment and write a far
pointer to it at the filterbank struct's `data` pointer slot. Returns nothing."
function put_filterbank_data_in_seg1!(fb::StructBuilder, vals::Vector{Float32})
    seg1 = Capnp.alloc_segment!(fb.msg)
    n = length(vals)
    list_words = cld(n * 4, 8)            # Float32 = 4 bytes -> 2 per word
    landing_idx = Capnp.alloc_words!(fb.msg, seg1, 1)   # single-far landing pad
    body_idx = Capnp.alloc_words!(fb.msg, seg1, list_words)
    lb = ListBuilder(fb.msg, seg1, body_idx, INT32_LIST, n, 0, 0)
    for (i, v) in enumerate(vals)
        set_element!(lb, i - 1, UInt64(reinterpret(UInt32, Float32(v))))
    end
    # Landing pad: list pointer with offset 0 -> body at landing+1.
    Capnp.set_word!(fb.msg, seg1, landing_idx, list_pointer(0, INT32_LIST, n))
    # Far pointer at the filterbank's `data` pointer slot (slot 1).
    Capnp.set_word!(fb.msg, fb.seg, fb.base + fb.data_words + 1,
                    Capnp.far_pointer(landing_idx, seg1, false))
    return nothing
end

function main()
    sf = parse_schema_file(HIT_SCHEMA)
    hit = sf.flat["Hit"]
    signal = sf.flat["Signal"]
    filterbank = sf.flat["Filterbank"]
    bytes_stream = UInt8[]
    for k in 1:NUM_HITS
        b = MessageBuilder()
        root = init_root_struct!(b, hit.data_words, hit.ptr_count)
        # signal @0 :Signal (ptr slot 0)
        sig = alloc_struct!(root, 0, signal.data_words, signal.ptr_count)
        write_struct!(sig, signal, (
            frequency = 1000.0 + 0.5 * k,
            index = k - 1,
            driftSteps = k,
            driftRate = 0.01 * k,
            snr = 10.0f0 + k,
            coarseChannel = k - 1,
            beam = 0,
            numTimesteps = NUM_TIMESTEPS,
            power = 100.0f0 * k,
            incoherentPower = 50.0f0 * k,
        ))
        # filterbank @1 :Filterbank (ptr slot 1)
        fb = alloc_struct!(root, 1, filterbank.data_words, filterbank.ptr_count)
        # sourceName @0 :Text (ptr slot 0) -> write first so it lands in seg0.
        set_text!(fb, 0, "test_source_$k")
        # Fill the scalar fields.
        write_struct!(fb, filterbank, (
            sourceName = "test_source_$k",
            fch1 = 2000.0 + k,
            foff = -0.5,
            tstart = 60000.0,
            tsamp = 1.0,
            ra = 18.0,
            dec = -21.0,
            telescopeId = 64,
            numTimesteps = NUM_TIMESTEPS,
            numChannels = NUM_CHANNELS,
            coarseChannel = k - 1,
            startChannel = 100 * (k - 1),
            beam = 0,
        ))
        # data @10 :List(Float32) -- place in seg1 via far pointer.
        vals = Float32[(t * NUM_CHANNELS + c) * 0.1f0
                       for t in 1:NUM_TIMESTEPS for c in 1:NUM_CHANNELS]
        put_filterbank_data_in_seg1!(fb, vals)
        append!(bytes_stream, write_message(b))
    end
    write(OUT_FILE, bytes_stream)
    println("Wrote $(length(bytes_stream)) bytes ($NUM_HITS hits) to $OUT_FILE")
end

main()
