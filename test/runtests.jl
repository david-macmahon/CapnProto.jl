using Capnp
using Test

# ---------------------------------------------------------------------------
# Wire-format primitives
# ---------------------------------------------------------------------------

@testset "wire pointers" begin
    # Struct pointer: offset 5, 3 data words, 7 pointers.
    p = struct_pointer(5, 3, 7)
    @test pointer_type(p) == STRUCT_POINTER
    @test pointer_offset(p) == 5
    @test struct_data_words(p) == 3
    @test struct_ptr_count(p) == 7

    # Negative offset.
    p = struct_pointer(-3, 1, 1)
    @test pointer_offset(p) == -3

    # List pointer.
    p = list_pointer(4, INT32_LIST, 12)
    @test pointer_type(p) == LIST_POINTER
    @test pointer_offset(p) == 4
    @test list_element_size(p) == INT32_LIST
    @test list_element_count(p) == 12

    # Far pointer.
    p = far_pointer(10, 2, false)
    @test pointer_type(p) == FAR_POINTER
    @test far_offset(p) == 10
    @test far_segment_id(p) == 2
    @test !far_is_double(p)
    p = far_pointer(10, 2, true)
    @test far_is_double(p)
end

@testset "element_words" begin
    @test element_words(INT8_LIST, 0) == 0
    @test element_words(INT8_LIST, 1) == 1
    @test element_words(INT8_LIST, 8) == 1
    @test element_words(INT8_LIST, 9) == 2
    @test element_words(INT16_LIST, 4) == 1
    @test element_words(INT32_LIST, 2) == 1
    @test element_words(INT64_LIST, 3) == 3
    @test element_words(BOOL_LIST, 64) == 1
    @test element_words(BOOL_LIST, 65) == 2
    @test element_words(VOID_LIST, 100) == 0
    @test element_words(POINTER_LIST, 3) == 3
end

# ---------------------------------------------------------------------------
# Low-level message roundtrip
# ---------------------------------------------------------------------------

@testset "root struct roundtrip" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 2, 2)
    set_int64!(root, 0, 0x0102030405060708)
    set_int32!(root, 1, 0x0a0b0c0d)
    set_text!(root, 0, "hello")
    bytes = write_message(b)
    @test length(bytes) % 8 == 0

    mr, _ = read_message(bytes)
    r = get_root(mr)
    @test get_int64(r, 0) == 0x0102030405060708
    @test get_uint32(r, 1) == 0x0a0b0c0d
    @test get_text(r, 0) == "hello"
end

@testset "nested struct + list" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 1, 2)
    set_int32!(root, 0, 42)
    sub = alloc_struct!(root, 0, 1, 1)
    set_int64!(sub, 0, 999)
    set_text!(sub, 0, "nested")
    lst = alloc_list!(root, 1, INT32_LIST, 4)
    for i in 0:3
        set_element!(lst, i, UInt64(UInt32(i * 10)))
    end

    bytes = write_message(b)
    mr, _ = read_message(bytes)
    r = get_root(mr)
    @test get_int32(r, 0) == 42
    sub_r = get_struct_field(r, 0)
    @test get_int64(sub_r, 0) == 999
    @test get_text(sub_r, 0) == "nested"
    lst_r = get_list_field(r, 1)
    @test list_length(lst_r) == 4
    @test [UInt32(get_element(lst_r, i)) for i in 0:3] == UInt32[0, 10, 20, 30]
end

@testset "composite list" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 0, 1)
    lb = alloc_composite_list!(root, 0, 3, 1, 1)  # 3 elements, each 1 data + 1 ptr
    for i in 0:2
        el = list_element_struct(lb, i)
        set_int64!(el, 0, Int64(i * 100))
        set_text!(el, 0, "el$i")
    end

    bytes = write_message(b)
    mr, _ = read_message(bytes)
    r = get_root(mr)
    lr = get_list_field(r, 0)
    @test list_length(lr) == 3
    for i in 0:2
        el = list_element_struct(lr, i)
        @test get_int64(el, 0) == Int64(i * 100)
        @test get_text(el, 0) == "el$i"
    end
end

@testset "bool and float fields" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 3, 0)
    set_bool!(root, 0, 0, true)
    set_bool!(root, 0, 1, false)
    set_bool!(root, 0, 7, true)
    set_float32!(root, 1, 1.5f0)
    set_float64!(root, 2, 2.5)
    bytes = write_message(b)
    mr, _ = read_message(bytes)
    r = get_root(mr)
    @test get_bool(r, 0, 0)
    @test !get_bool(r, 0, 1)
    @test get_bool(r, 0, 7)
    @test get_float32(r, 1) === 1.5f0
    @test get_float64(r, 2) === 2.5
end

# ---------------------------------------------------------------------------
# Packed encoding
# ---------------------------------------------------------------------------

@testset "packed roundtrip" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 4, 2)
    set_int64!(root, 0, 0)
    set_int64!(root, 1, 0)
    set_int64!(root, 2, 0x0102030405060708)
    set_int64!(root, 3, 0)
    set_text!(root, 0, "ab")
    bytes = write_packed(b)
    # Should be smaller than the unpacked version thanks to zero-word runs.
    unpacked = write_message(b)
    @test length(bytes) < length(unpacked)

    mr = read_packed(bytes)
    r = get_root(mr)
    @test get_int64(r, 2) == 0x0102030405060708
    @test get_text(r, 0) == "ab"
end

@testset "pack/unpack all-zeros" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 8, 0)  # 8 zero data words, no pointers
    # All zero -> the body is all zeros, and the segment table is not. So packed
    # should still compress the zero run.
    bytes = write_packed(b)
    mr = read_packed(bytes)
    r = get_root(mr)
    for i in 0:7
        @test get_int64(r, i) == 0
    end
end

@testset "packed 0xff verbatim run" begin
    # Words whose every byte is non-zero exercise the 0xff tag path.
    b = MessageBuilder()
    root = init_root_struct!(b, 4, 0)
    set_int64!(root, 0, 0x0102030405060708)
    set_int64!(root, 1, 0x0f0e0d0c0b0a0908)
    set_int64!(root, 2, 0x111015161718191a)
    set_int64!(root, 3, 0x1f1e1d1c1b1a1918)
    packed = write_packed(b)
    mr = read_packed(packed)
    r = get_root(mr)
    @test get_int64(r, 0) == 0x0102030405060708
    @test get_int64(r, 1) == 0x0f0e0d0c0b0a0908
    @test get_int64(r, 2) == 0x111015161718191a
    @test get_int64(r, 3) == 0x1f1e1d1c1b1a1918
end

@testset "looks_packed and auto-detection" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 2, 1)
    set_int64!(root, 0, 0x0102030405060708)
    set_text!(root, 0, "hello")
    unpacked = write_message(b)
    packed = write_packed(b)

    @test !looks_packed(unpacked)
    @test looks_packed(packed)

    # Auto-detection picks the right decoder for both formats.
    r_u = read_message_agnostic(unpacked)
    @test get_int64(get_root(r_u), 0) == 0x0102030405060708
    @test get_text(get_root(r_u), 0) == "hello"
    r_p = read_message_agnostic(packed)
    @test get_int64(get_root(r_p), 0) == 0x0102030405060708
    @test get_text(get_root(r_p), 0) == "hello"

    # Forcing the wrong format is possible but yields nonsense / errors; the
    # `packed` keyword overrides detection.
    @test read_message_agnostic(unpacked; packed=false) isa MessageReader
    @test read_message_agnostic(packed; packed=true) isa MessageReader
end

@testset "ispacked" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 2, 1)
    set_int64!(root, 0, 0x0102030405060708)
    set_text!(root, 0, "hello")
    unpacked = write_message(b)
    packed = write_packed(b)

    # Byte-vector form: the strong check (validates the full segment table).
    @test !ispacked(unpacked)
    @test ispacked(packed)
    # With a non-default start offset.
    @test !ispacked(unpacked; start=1)

    # IO form: peeks from the current position and restores it.
    io_u = IOBuffer(unpacked)
    @test !ispacked(io_u)
    @test position(io_u) == 0        # position restored
    io_p = IOBuffer(packed)
    @test ispacked(io_p)
    @test position(io_p) == 0

    # Detection from a non-zero offset leaves the position at that offset.
    io = IOBuffer(unpacked)
    seek(io, 5)
    @test !ispacked(io)
    @test position(io) == 5

    # parse_messages uses ispacked under the hood; verify both formats still
    # iterate correctly (regression check for the _detect_packed -> ispacked
    # rename).
    sf = parse_schema("@0x77;\nstruct S { a @0 :Int64; b @1 :Text; }")
    vals = [(a=1, b="x"), (a=2, b="yy")]
    su = reduce(vcat, [build_message(v, sf, "S"; packed=false) for v in vals])
    sp = reduce(vcat, [build_message(v, sf, "S"; packed=true) for v in vals])
    @test [m.a for m in parse_messages(su, sf, "S")] == [1, 2]
    @test [m.a for m in parse_messages(sp, sf, "S")] == [1, 2]
end

@testset "schema-driven roundtrip with auto-detection" begin
    sf = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; b @1 :Text; }
    """)
    val = (a=Int64(42), b="auto")
    # build_message defaults to packed; parse_message auto-detects.
    bytes_packed = build_message(val, sf, "S"; packed=true)
    @test parse_message(bytes_packed, sf, "S").b == "auto"
    bytes_unpacked = build_message(val, sf, "S"; packed=false)
    @test parse_message(bytes_unpacked, sf, "S").b == "auto"
    # Default (no packed kw) should also auto-detect both.
    @test parse_message(bytes_packed, sf, "S").a == 42
    @test parse_message(bytes_unpacked, sf, "S").a == 42
end

@testset "parse_message pos and parse_struct" begin
    sf = parse_schema("""
    @0x66;
    struct Hit { n @0 :Int32; tag @1 :Text; }
    """)
    vals = [(n=1, tag="a"), (n=2, tag="bb"), (n=3, tag="ccc")]
    # Stream of three concatenated unpacked messages.
    stream = reduce(vcat, [build_message(v, sf, "Hit"; packed=false) for v in vals])
    # Find the byte offset of the second message by reading the first.
    # read_message's start/next_start are 1-based; convert to 0-based for pos.
    _, next1 = read_message(stream; start=1)
    off2 = next1 - 1
    _, next2 = read_message(stream; start=next1)
    off3 = next2 - 1

    # parse_message with pos= (0-based) reads the message at that offset.
    @test parse_message(stream, sf, "Hit"; pos=off2).n == 2
    @test parse_message(stream, sf, "Hit"; pos=off2).tag == "bb"
    @test parse_message(stream, sf, "Hit"; pos=off3).n == 3
    @test parse_message(stream, sf, "Hit"; pos=off3).tag == "ccc"
    # pos defaults to 0 (the first message).
    @test parse_message(stream, sf, "Hit"; packed=false).n == 1

    # Same for a packed stream: pos=0 reads the first message.
    pstream = reduce(vcat, [build_message(v, sf, "Hit"; packed=true) for v in vals])
    @test parse_message(pstream, sf, "Hit"; pos=0).n == 1

    # parse_struct decodes a typed value from an already-read MessageReader.
    mr2, _ = read_message(stream; start=off2 + 1)
    m2 = parse_struct(mr2, sf, "Hit")
    @test m2.n == 2
    @test m2.tag == "bb"
    # From a reader obtained via the lazy IO reader. pos and IO positions are
    # both 0-based, so seek directly to off2.
    io = IOBuffer(stream)
    seek(io, off2)
    mr2b = Capnp.read_message_io(io)
    m2b = parse_struct(mr2b, sf, "Hit")
    @test m2b.n == 2
    @test m2b.tag == "bb"
    # From a reader obtained via read_message_agnostic at an offset (start is
    # 1-based, so pass off2 + 1).
    mr2c = read_message_agnostic(stream; packed=false, start=off2 + 1)
    @test parse_struct(mr2c, sf, "Hit").n == 2
end

@testset "parse_message from IO and filename" begin
    sf = parse_schema("""
    @0x66;
    struct Hit { n @0 :Int32; tag @1 :Text; }
    """)
    vals = [(n=1, tag="a"), (n=2, tag="bb"), (n=3, tag="ccc")]
    stream = reduce(vcat, [build_message(v, sf, "Hit"; packed=false) for v in vals])
    _, next1 = read_message(stream; start=1)
    off2 = next1 - 1
    tmp = tempname() * ".bin"
    write(tmp, stream)

    # IO method with pos= reads the message at that offset.
    io = IOBuffer(stream)
    @test parse_message(io, sf, "Hit"; pos=off2, packed=false).n == 2
    # IO method with pos=-1 (default) reads from the current position.
    io = IOBuffer(stream)
    seek(io, off2)
    @test parse_message(io, sf, "Hit"; packed=false).n == 2
    # IO method leaves the IO positioned just past the message.
    io = IOBuffer(stream)
    seek(io, off2)
    parse_message(io, sf, "Hit"; packed=false)
    _, next2 = read_message(stream; start=off2 + 1)
    @test position(io) == next2 - 1
    # IO method auto-detects packed vs unpacked.
    pstream = reduce(vcat, [build_message(v, sf, "Hit"; packed=true) for v in vals])
    @test parse_message(IOBuffer(pstream), sf, "Hit").n == 1

    # Filename method with pos= reads the message at that offset.
    @test parse_message(tmp, sf, "Hit"; pos=off2, packed=false).n == 2
    # Filename method with pos=0 (default) reads the first message.
    @test parse_message(tmp, sf, "Hit"; packed=false).n == 1
    # Filename method auto-detects.
    ptmp = tempname() * ".bin"
    write(ptmp, pstream)
    @test parse_message(ptmp, sf, "Hit").n == 1

    rm(tmp; force=true)
    rm(ptmp; force=true)
end

# ---------------------------------------------------------------------------
# Schema parser
# ---------------------------------------------------------------------------

const PERSON_SCHEMA = parse_schema("""
@0xab12cd34ef56ef78;

struct Person {
    name @0 :Text;
    age  @1 :Int32;
    emails @2 :List(Text);
}

enum Color {
    red @0;
    green @1;
    blue @2;
}
""")

@testset "schema parser basics" begin
    @test startswith(PERSON_SCHEMA.id, "0x")
    person = PERSON_SCHEMA[:Person]
    @test person isa StructNode
    @test person.name == "Person"
    # name -> ptr slot 0, age -> data word 0 (Int32), emails -> ptr slot 1.
    name_f = person.fields[1]
    age_f = person.fields[2]
    emails_f = person.fields[3]
    @test name_f.name == "name"
    @test name_f.type.kind == :primitive && name_f.type.primitive == PT_Text
    @test name_f.ptr_slot == 0
    @test age_f.type.primitive == PT_Int32
    @test age_f.data_word == 0
    @test emails_f.type.kind == :list
    @test emails_f.type.element[].primitive == PT_Text
    @test emails_f.ptr_slot == 1

    color = PERSON_SCHEMA[:Color]
    @test color isa EnumNode
    @test [v.name for v in color.values] == ["red", "green", "blue"]
end

@testset "schema-driven roundtrip" begin
    person = PERSON_SCHEMA[:Person]
    val = (name="Alice", age=30, emails=["a@x.com", "b@y.com"])
    bytes = Capnp.build_message(val, PERSON_SCHEMA, "Person")
    out = Capnp.parse_message(bytes, PERSON_SCHEMA, "Person")
    @test out.name == "Alice"
    @test out.age == 30
    @test out.emails == ["a@x.com", "b@y.com"]
end

@testset "nested struct schema" begin
    sf = parse_schema("""
@0x11;
struct Outer {
    a @0 :Int64;
    b @1 :Inner;
    struct Inner {
        x @0 :Int32;
        y @1 :Text;
    }
}
""")
    outer = sf[:Outer]
    @test outer.data_words == 1
    @test outer.ptr_count == 1
    inner = sf.flat["Outer.Inner"]
    @test inner.name == "Inner"
    @test inner.data_words == 1
    @test inner.ptr_count == 1

    val = (a=Int64(7), b=(x=5, y="hi"))
    bytes = Capnp.build_message(val, sf, "Outer")
    out = Capnp.parse_message(bytes, sf, "Outer")
    @test out.a == 7
    @test out.b.x == 5
    @test out.b.y == "hi"
end

@testset "list of structs schema" begin
    sf = parse_schema("""
@0x22;
struct Point {
    x @0 :Int32;
    y @1 :Int32;
}
struct Polyline {
    points @0 :List(Point);
}
""")
    val = (points=[(x=1, y=2), (x=3, y=4), (x=5, y=6)],)
    bytes = Capnp.build_message(val, sf, "Polyline")
    out = Capnp.parse_message(bytes, sf, "Polyline")
    @test length(out.points) == 3
    @test out.points[1] == (x=1, y=2)
    @test out.points[3] == (x=5, y=6)
end

@testset "enum and union parse" begin
    sf = parse_schema("""
@0x33;
struct Msg {
    union {
        a @0 :Int32;
        b @1 :Text;
    }
}
""")
    msg = sf[:Msg]
    # Two union members, discriminants 0 and 1.
    @test count(f -> f.discriminant >= 0, msg.fields) == 2
    @test msg.fields[1].discriminant == 0
    @test msg.fields[2].discriminant == 1
end

@testset "data field" begin
    sf = parse_schema("""
@0x44;
struct Blob {
    payload @0 :Data;
}
""")
    val = (payload=UInt8[0x01, 0x02, 0x03],)
    bytes = Capnp.build_message(val, sf, "Blob")
    out = Capnp.parse_message(bytes, sf, "Blob")
    @test out.payload == UInt8[0x01, 0x02, 0x03]
end

@testset "primitive list" begin
    sf = parse_schema("""
    @0x55;
    struct Nums {
        vals @0 :List(Int64);
    }
    """)
    val = (vals=Int64[10, 20, 30],)
    bytes = Capnp.build_message(val, sf, "Nums")
    out = Capnp.parse_message(bytes, sf, "Nums")
    @test out.vals == Int64[10, 20, 30]
end

@testset "parse_messages iterator" begin
    sf = parse_schema("""
    @0x66;
    struct Hit {
        n @0 :Int32;
        tag @1 :Text;
    }
    """)
    node = sf[:Hit]
    # Build three messages and concatenate (unpacked, the default for build_message
    # is packed, so use packed=false to get the streaming-friendly form).
    vals = [(n=1, tag="a"), (n=2, tag="bb"), (n=3, tag="ccc")]
    stream_unpacked = reduce(vcat, [build_message(v, sf, "Hit"; packed=false) for v in vals])
    stream_packed = reduce(vcat, [build_message(v, sf, "Hit"; packed=true) for v in vals])

    # Unpacked stream via byte vector.
    hits = collect(parse_messages(stream_unpacked, sf, "Hit"))
    @test length(hits) == 3
    @test [h.n for h in hits] == [1, 2, 3]
    @test [h.tag for h in hits] == ["a", "bb", "ccc"]

    # Packed stream via byte vector (auto-detected).
    hits_p = collect(parse_messages(stream_packed, sf, "Hit"))
    @test length(hits_p) == 3
    @test [h.n for h in hits_p] == [1, 2, 3]
    @test [h.tag for h in hits_p] == ["a", "bb", "ccc"]

    # Same streams via IOBuffer.
    hits_io = collect(parse_messages(IOBuffer(stream_unpacked), sf, "Hit"))
    @test [h.n for h in hits_io] == [1, 2, 3]

    # Packed stream via IOBuffer.
    hits_pio = collect(parse_messages(IOBuffer(stream_packed), sf, "Hit"))
    @test [h.n for h in hits_pio] == [1, 2, 3]
    @test [h.tag for h in hits_pio] == ["a", "bb", "ccc"]

    # Empty input yields no messages.
    @test isempty(collect(parse_messages(UInt8[], sf, "Hit")))

    # Iteration state advances correctly: first value matches first message.
    it = parse_messages(stream_unpacked, sf, "Hit")
    first = iterate(it)
    @test first !== nothing
    @test first[1].n == 1
    second = iterate(it, first[2])
    @test second !== nothing
    @test second[1].n == 2

    # Lazy: breaking after the first message leaves the IO positioned just past
    # it, so a fresh iterator over the *remaining* bytes yields the rest.
    bio = IOBuffer(stream_unpacked)
    itr = parse_messages(bio, sf, "Hit")
    res = iterate(itr)
    @test res !== nothing
    @test res[1].n == 1
    remaining = read(bio)  # bytes not yet consumed by the lazy iterator
    rest = collect(parse_messages(remaining, sf, "Hit"))
    @test [h.n for h in rest] == [2, 3]
end

# ---------------------------------------------------------------------------
# Field skipping (`skip=`)
# ---------------------------------------------------------------------------
#
# `skip` returns typed empty values for skipped fields. Two tiers:
#   Tier A (typed layer): the field's bytes are still read into the MessageReader
#     but the field decodes to an empty value. Works for all encodings and all
#     entry points.
#   Tier B (IO layer): when reading from an IO, segments holding only skipped
#     data are not read: unpacked streams seek past them; packed streams decode-
#     and-discard them (bytes read but not retained).

# Schema modeled on the seticore Hit/Filterbank layout: a small root struct
# pointing at an inner struct whose `data` list is the large field we skip.
const SKIP_SCHEMA = parse_schema("""
@0x77;
struct Inner { a @0 :Int32; b @1 :List(Float32); }
struct Outer { name @0 :Text; inner @1 :Inner; }
""")

"Build a two-segment message: seg0 holds Outer+Inner (with a far pointer to
seg1 for `inner.b`), seg1 holds a landing pad + a big `List(Float32)` body.
Returns the unpacked message bytes and the byte size of seg1 (the part that
should be skipped)."
function build_two_segment_hit(name::AbstractString, a::Integer, bvals::AbstractVector{Float32})
    outer = SKIP_SCHEMA.flat["Outer"]; inner = SKIP_SCHEMA.flat["Inner"]
    b = MessageBuilder()
    root = init_root_struct!(b, outer.data_words, outer.ptr_count)
    set_text!(root, 0, name)
    sub = alloc_struct!(root, 1, inner.data_words, inner.ptr_count)
    set_int32!(sub, 0, a)
    seg1 = Capnp.alloc_segment!(b)
    N = length(bvals)
    list_words = cld(N * 4, 8)
    landing_idx = Capnp.alloc_words!(b, seg1, 1)
    body_idx = Capnp.alloc_words!(b, seg1, list_words)
    lb = ListBuilder(b, seg1, body_idx, INT32_LIST, N, 0, 0)
    for (i, v) in enumerate(bvals)
        set_element!(lb, i - 1, UInt64(reinterpret(UInt32, Float32(v))))
    end
    Capnp.set_word!(b, seg1, landing_idx, list_pointer(0, INT32_LIST, N))
    Capnp.set_word!(b, 0, sub.base + sub.data_words + 0,
                    Capnp.far_pointer(landing_idx, seg1, false))
    seg1_bytes = (1 + list_words) * 8
    return write_message(b), seg1_bytes
end

# A counting IO wrapper to measure actual bytes read (independent of seeks).
struct CountIO <: IO
    io::IO
    bytes_read::Base.RefValue{Int}
end
Base.read(c::CountIO, ::Type{UInt8}) = (c.bytes_read[] += 1; read(c.io, UInt8))
Base.readbytes!(c::CountIO, b::AbstractVector{UInt8}, n::Int) =
    (g = readbytes!(c.io, b, n); c.bytes_read[] += g; g)
Base.eof(c::CountIO) = eof(c.io)
Base.position(c::CountIO) = position(c.io)
Base.seek(c::CountIO, p::Int) = seek(c.io, p)
Base.mark(c::CountIO) = mark(c.io)
Base.reset(c::CountIO) = reset(c.io)
Base.isreadable(c::CountIO) = isreadable(c.io)

@testset "Tier A: read_struct skip returns typed empty values" begin
    val = (name="hi", inner=(a=7, b=Float32[1, 2, 3, 4]))
    for packed in (true, false)
        bytes = build_message(val, SKIP_SCHEMA, "Outer"; packed=packed)
        out = parse_message(bytes, SKIP_SCHEMA, "Outer"; skip=["inner.b"])
        @test out.name == "hi"
        @test out.inner.a == 7
        @test out.inner.b == Float32[]
        # Without skip, the list is decoded normally.
        full = parse_message(bytes, SKIP_SCHEMA, "Outer")
        @test full.inner.b == Float32[1, 2, 3, 4]
    end
end

@testset "Tier A: skip Text and Data" begin
    sf = parse_schema("""
    @0x88;
    struct S { t @0 :Text; d @1 :Data; n @2 :Int32; }
    """)
    val = (t="hello", d=UInt8[1, 2, 3], n=42)
    bytes = build_message(val, sf, "S")
    out = parse_message(bytes, sf, "S"; skip=["t", "d"])
    @test out.t == ""
    @test out.d == UInt8[]
    @test out.n == 42
end

@testset "Tier A: skip with predicate" begin
    val = (name="hi", inner=(a=7, b=Float32[1, 2, 3, 4]))
    bytes = build_message(val, SKIP_SCHEMA, "Outer")
    # Predicate matching any path ending in ".b".
    out = parse_message(bytes, SKIP_SCHEMA, "Outer"; skip = p -> endswith(p, ".b"))
    @test out.inner.b == Float32[]
    @test out.inner.a == 7
    @test out.name == "hi"
    # Predicate that skips nothing.
    out2 = parse_message(bytes, SKIP_SCHEMA, "Outer"; skip = p -> false)
    @test out2.inner.b == Float32[1, 2, 3, 4]
end

@testset "Tier A: skip with single string" begin
    val = (name="hi", inner=(a=7, b=Float32[1, 2, 3, 4]))
    bytes = build_message(val, SKIP_SCHEMA, "Outer")
    # A single path string skips just that one field.
    out = parse_message(bytes, SKIP_SCHEMA, "Outer"; skip="inner.b")
    @test out.inner.b == Float32[]
    @test out.inner.a == 7
    @test out.name == "hi"
    # Single string at the top level.
    out2 = parse_message(bytes, SKIP_SCHEMA, "Outer"; skip="name")
    @test out2.name == ""
    @test out2.inner.b == Float32[1, 2, 3, 4]
    # Single string form works with parse_messages too.
    msgs = [(name="m$i", inner=(a=i, b=Float32[i])) for i in 1:3]
    stream = reduce(vcat, [build_message(m, SKIP_SCHEMA, "Outer"; packed=false) for m in msgs])
    results = collect(parse_messages(stream, SKIP_SCHEMA, "Outer"; skip="inner.b"))
    @test all(r -> r.inner.b == Float32[], results)
    @test [r.inner.a for r in results] == [1, 2, 3]
end

@testset "Tier A: parse_messages skip (single-segment, both encodings)" begin
    msgs = [(name="m$i", inner=(a=i, b=Float32[i, i * 10, i * 100])) for i in 1:3]
    for packed in (true, false)
        stream = reduce(vcat, [build_message(m, SKIP_SCHEMA, "Outer"; packed=packed) for m in msgs])
        results = collect(parse_messages(stream, SKIP_SCHEMA, "Outer"; skip=["inner.b"]))
        @test length(results) == 3
        for (i, r) in enumerate(results)
            @test r.name == "m$i"
            @test r.inner.a == i
            @test r.inner.b == Float32[]
        end
    end
end

@testset "Tier B: two-segment unpacked skips seg1 I/O" begin
    bytes, seg1_bytes = build_two_segment_hit("hi", 7, Float32[i for i in 0:999])
    total = length(bytes)
    # Full read consumes all bytes.
    ci = CountIO(IOBuffer(bytes), Ref(0))
    full = parse_message(ci, SKIP_SCHEMA, "Outer"; packed=false)
    @test full.inner.b == Float32[Float32(i) for i in 0:999]
    @test ci.bytes_read[] == total
    # Skip read: seg1 is seeked past, so only table + seg0 are read.
    ci = CountIO(IOBuffer(bytes), Ref(0))
    sk = parse_message(ci, SKIP_SCHEMA, "Outer"; packed=false, skip=["inner.b"])
    @test sk.name == "hi"
    @test sk.inner.a == 7
    @test sk.inner.b == Float32[]
    @test ci.bytes_read[] <= total - seg1_bytes + 16  # table+seg0 + small slack
    @test total - ci.bytes_read[] >= seg1_bytes - 16  # most of seg1 skipped
end

@testset "Tier B: two-segment packed discards seg1 words" begin
    bytes, seg1_bytes = build_two_segment_hit("hi", 7, Float32[i for i in 0:999])
    packed = pack(bytes)
    # Skip read: packed bytes are all read (variable-length), but seg1 words are
    # not retained -- the resulting MessageReader has seg1 empty.
    ci = CountIO(IOBuffer(packed), Ref(0))
    sk = parse_message(ci, SKIP_SCHEMA, "Outer"; packed=true, skip=["inner.b"])
    @test sk.name == "hi"
    @test sk.inner.a == 7
    @test sk.inner.b == Float32[]
    # All packed bytes are read (packed encoding is variable-length).
    @test ci.bytes_read[] == length(packed)
end

@testset "Tier B: parse_messages skip over multi-segment stream" begin
    # A stream of three 2-segment messages; skipping inner.b should skip seg1
    # of each message.
    msgs = [("hi$i", i, Float32[i * k for k in 1:100]) for i in 1:3]
    parts = [build_two_segment_hit(name, a, b) for (name, a, b) in msgs]
    stream = reduce(vcat, first.(parts))
    # Full read: all messages decoded with their lists.
    full = collect(parse_messages(stream, SKIP_SCHEMA, "Outer"; packed=false))
    @test length(full) == 3
    for (i, m) in enumerate(full)
        @test m.name == "hi$i"
        @test m.inner.a == i
        @test length(m.inner.b) == 100
    end
    # Skip read: lists are empty and seg1 of each message is seeked past.
    ci = CountIO(IOBuffer(stream), Ref(0))
    sk = collect(parse_messages(ci, SKIP_SCHEMA, "Outer"; packed=false, skip=["inner.b"]))
    @test length(sk) == 3
    for (i, m) in enumerate(sk)
        @test m.name == "hi$i"
        @test m.inner.a == i
        @test m.inner.b == Float32[]
    end
    # Substantial I/O savings (seg1 of each message skipped).
    @test ci.bytes_read[] < length(stream) / 2
end

@testset "skip leaves non-skipped sibling fields intact" begin
    # Add a second list field alongside the skipped one, both in seg1, to
    # confirm that skipping one field does not drop a sibling sharing the
    # segment. (When two fields share a segment and only one is skipped, the
    # segment is NEEDED and is read in full; only the typed layer trims the
    # skipped field.)
    sf = parse_schema("""
    @0x99;
    struct S { big @0 :List(Float32); small @1 :List(Int32); n @2 :Int32; }
    """)
    val = (big=Float32[1.0f0, 2.0f0, 3.0f0], small=Int32[10, 20, 30], n=42)
    bytes = build_message(val, sf, "S")
    out = parse_message(bytes, sf, "S"; skip=["big"])
    @test out.big == Float32[]
    @test out.small == Int32[10, 20, 30]
    @test out.n == 42
end

@testset "skip on test.hits (seticore-style multi-segment)" begin
    # test.hits is a small, checked-in fixture generated by test/generate_test_hits.jl
    # using test/hit.capnp. Each message is a two-segment Hit: seg0 holds the
    # root struct (Signal + Filterbank scalars + sourceName), seg1 holds the
    # filterbank.data List(Float32) body via a far pointer -- the layout that
    # Tier B segment-skipping optimizes.
    hits_file = joinpath(@__DIR__, "test.hits")
    schema_file = joinpath(@__DIR__, "hit.capnp")
    @test isfile(hits_file)
    @test isfile(schema_file)
    sf = parse_schema_file(schema_file)
    total = filesize(hits_file)

    # Full read: every message decodes with its filterbank.data populated.
    full = collect(parse_messages(hits_file, sf, "Hit"))
    @test length(full) == 4
    for (i, h) in enumerate(full)
        @test h.filterbank.sourceName == "test_source_$i"
        @test h.signal.frequency == 1000.0 + 0.5 * i
        @test h.signal.numTimesteps == 8
        @test h.filterbank.numTimesteps == 8
        @test h.filterbank.numChannels == 16
        @test length(h.filterbank.data) == 128
        @test h.filterbank.data == Float32[(t * 16 + c) * 0.1f0
                                          for t in 1:8 for c in 1:16]
    end

    # Skip filterbank.data: the field decodes to an empty list, other fields
    # remain intact, and seg1 of each message is seeked past (Tier B).
    sk = collect(parse_messages(hits_file, sf, "Hit"; skip=["filterbank.data"]))
    @test length(sk) == 4
    for (i, h) in enumerate(sk)
        @test h.filterbank.sourceName == "test_source_$i"
        @test h.signal.frequency == 1000.0 + 0.5 * i
        @test h.filterbank.numTimesteps == 8
        @test h.filterbank.numChannels == 16
        @test h.filterbank.data == Float32[]
    end

    # I/O savings: counting bytes read via a counting IO over the file. The
    # filterbank.data segments dominate, so skipping them reads well under
    # half the file.
    ci = CountIO(open(hits_file), Ref(0))
    collect(parse_messages(ci, sf, "Hit"; skip=["filterbank.data"]))
    close(ci.io)
    @test ci.bytes_read[] < total / 2

    # Predicate form also works end-to-end on the file.
    skp = collect(parse_messages(hits_file, sf, "Hit";
                                 skip = p -> p == "filterbank.data"))
    @test all(h -> h.filterbank.data == Float32[], skp)
end


