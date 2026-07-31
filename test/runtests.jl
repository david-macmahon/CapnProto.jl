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

@testset "looks_unpacked and auto-detection" begin
    b = MessageBuilder()
    root = init_root_struct!(b, 2, 1)
    set_int64!(root, 0, 0x0102030405060708)
    set_text!(root, 0, "hello")
    unpacked = write_message(b)
    packed = write_packed(b)

    @test looks_unpacked(unpacked)
    @test !looks_unpacked(packed)

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

@testset "schema-driven roundtrip with auto-detection" begin
    sf = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; b @1 :Text; }
    """)
    val = (a=Int64(42), b="auto")
    # build_message defaults to packed; parse_message auto-detects.
    bytes_packed = build_message(sf, "S", val; packed=true)
    @test parse_message(sf, "S", bytes_packed).b == "auto"
    bytes_unpacked = build_message(sf, "S", val; packed=false)
    @test parse_message(sf, "S", bytes_unpacked).b == "auto"
    # Default (no packed kw) should also auto-detect both.
    @test parse_message(sf, "S", bytes_packed).a == 42
    @test parse_message(sf, "S", bytes_unpacked).a == 42
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
    bytes = Capnp.build_message(PERSON_SCHEMA, "Person", val)
    out = Capnp.parse_message(PERSON_SCHEMA, "Person", bytes)
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
    bytes = Capnp.build_message(sf, "Outer", val)
    out = Capnp.parse_message(sf, "Outer", bytes)
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
    bytes = Capnp.build_message(sf, "Polyline", val)
    out = Capnp.parse_message(sf, "Polyline", bytes)
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
    bytes = Capnp.build_message(sf, "Blob", val)
    out = Capnp.parse_message(sf, "Blob", bytes)
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
    bytes = Capnp.build_message(sf, "Nums", val)
    out = Capnp.parse_message(sf, "Nums", bytes)
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
    stream_unpacked = reduce(vcat, [build_message(sf, "Hit", v; packed=false) for v in vals])
    stream_packed = reduce(vcat, [build_message(sf, "Hit", v; packed=true) for v in vals])

    # Unpacked stream via byte vector.
    hits = collect(parse_messages(sf, "Hit", stream_unpacked))
    @test length(hits) == 3
    @test [h.n for h in hits] == [1, 2, 3]
    @test [h.tag for h in hits] == ["a", "bb", "ccc"]

    # Packed stream via byte vector (auto-detected).
    hits_p = collect(parse_messages(sf, "Hit", stream_packed))
    @test length(hits_p) == 3
    @test [h.n for h in hits_p] == [1, 2, 3]
    @test [h.tag for h in hits_p] == ["a", "bb", "ccc"]

    # Same streams via IOBuffer.
    hits_io = collect(parse_messages(sf, "Hit", IOBuffer(stream_unpacked)))
    @test [h.n for h in hits_io] == [1, 2, 3]

    # Empty input yields no messages.
    @test isempty(collect(parse_messages(sf, "Hit", UInt8[])))

    # Iteration state advances correctly: first value matches first message.
    it = parse_messages(sf, "Hit", stream_unpacked)
    first = iterate(it)
    @test first !== nothing
    @test first[1].n == 1
    second = iterate(it, first[2])
    @test second !== nothing
    @test second[1].n == 2
end
