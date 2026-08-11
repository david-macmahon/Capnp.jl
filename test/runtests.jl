using CapnProto
using Test
using Logging: with_logger, Warn

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
    mr2b = CapnProto.read_message_io(io)
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
    bytes = CapnProto.build_message(val, PERSON_SCHEMA, "Person")
    out = CapnProto.parse_message(bytes, PERSON_SCHEMA, "Person")
    @test out.name == "Alice"
    @test out.age == 30
    @test out.emails == ["a@x.com", "b@y.com"]
end

@testset "build_message default encoding is unpacked" begin
    sf = parse_schema("@0x1; struct S { a @0 :Int32; }")
    # default packed= produces unpacked bytes: parse_message with packed=false
    # succeeds, and with packed=true fails (the unpacked bytes are not a valid
    # packed stream).
    bytes = build_message((a=Int32(42),), sf, "S")
    @test parse_message(bytes, sf, "S"; packed=false).a == 42
    @test_throws Exception parse_message(bytes, sf, "S"; packed=true)
    # Explicit packed=true produces a different (packed) byte stream that
    # round-trips via packed=true.
    pbytes = build_message((a=Int32(42),), sf, "S"; packed=true)
    @test pbytes != bytes
    @test parse_message(pbytes, sf, "S"; packed=true).a == 42
    @test_throws Exception parse_message(pbytes, sf, "S"; packed=false)
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
    bytes = CapnProto.build_message(val, sf, "Outer")
    out = CapnProto.parse_message(bytes, sf, "Outer")
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
    bytes = CapnProto.build_message(val, sf, "Polyline")
    out = CapnProto.parse_message(bytes, sf, "Polyline")
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

@testset "fields declared out of ordinal order (issue #1)" begin
    # Fields declared in non-ordinal order must still be laid out and
    # read/written according to their ordinals, matching the Cap'n Proto wire
    # format. The schema below interleaves data and pointer fields and reverses
    # the natural ordinal order so that any code relying on declaration order
    # would produce a mismatched layout.
    sf = parse_schema("""
@0x50;
struct Reversed {
    # Pointer field declared first but with the highest ordinal.
    name @2 :Text;
    # A 64-bit data field declared next, ordinal 0.
    big @0 :Int64;
    # A 32-bit data field declared last, ordinal 1.
    small @1 :Int32;
}
""")
    node = sf[:Reversed]
    # Fields are sorted by ordinal after parsing.
    @test [f.ordinal for f in node.fields] == [0, 1, 2]
    @test [f.name for f in node.fields] == ["big", "small", "name"]
    # Layout: big (Int64) -> data word 0; small (Int32) -> data word 1, byte 0;
    # name (Text) -> pointer slot 0.
    big_f = node.fields[1]
    small_f = node.fields[2]
    name_f = node.fields[3]
    @test big_f.data_word == 0 && big_f.ptr_slot == -1
    @test small_f.data_word == 1 && small_f.data_byte == 0
    @test name_f.ptr_slot == 0

    # Round-trip: writing by field name and reading back must yield the same
    # values regardless of the declaration order in the schema.
    val = (name="hi", big=Int64(0x0102030405060708), small=Int32(7))
    bytes = CapnProto.build_message(val, sf, "Reversed")
    out = CapnProto.parse_message(bytes, sf, "Reversed")
    @test out.name == "hi"
    @test out.big == 0x0102030405060708
    @test out.small == 7

    # Cross-check against an equivalent schema with fields declared in ordinal
    # order: the wire bytes must be identical for the same values.
    sf_ordered = parse_schema("""
@0x50;
struct Reordered {
    big @0 :Int64;
    small @1 :Int32;
    name @2 :Text;
}
""")
    bytes_ordered = CapnProto.build_message(val, sf_ordered, "Reordered")
    @test bytes == bytes_ordered
    out_ordered = CapnProto.parse_message(bytes_ordered, sf_ordered, "Reordered")
    @test out_ordered.big == 0x0102030405060708
    @test out_ordered.small == 7
    @test out_ordered.name == "hi"
end

@testset "data field" begin
    sf = parse_schema("""
@0x44;
struct Blob {
    payload @0 :Data;
}
""")
    val = (payload=UInt8[0x01, 0x02, 0x03],)
    bytes = CapnProto.build_message(val, sf, "Blob")
    out = CapnProto.parse_message(bytes, sf, "Blob")
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
    bytes = CapnProto.build_message(val, sf, "Nums")
    out = CapnProto.parse_message(bytes, sf, "Nums")
    @test out.vals == Int64[10, 20, 30]
end

@testset "negative integers roundtrip (issue #2)" begin
    # write_primitive! and encode_primitive must accept negative signed values
    # (they previously called UInt64(Int8(val)) etc., which throw InexactError).
    sf = parse_schema("""
    @0x77;
    struct S {
        i8  @0 :Int8;
        i16 @1 :Int16;
        i32 @2 :Int32;
        i64 @3 :Int64;
        u8  @4 :UInt8;
        u16 @5 :UInt16;
        u32 @6 :UInt32;
        u64 @7 :UInt64;
    }
    """)
    val = (i8=Int8(-1), i16=Int16(-2), i32=Int32(-3), i64=Int64(-4),
           u8=UInt8(0xff), u16=UInt16(0xffff), u32=UInt32(0xffffffff), u64=UInt64(0xffffffffffffffff))
    bytes = CapnProto.build_message(val, sf, "S")
    out = CapnProto.parse_message(bytes, sf, "S")
    @test out.i8 === Int8(-1)
    @test out.i16 === Int16(-2)
    @test out.i32 === Int32(-3)
    @test out.i64 === Int64(-4)
    @test out.u8 === UInt8(0xff)
    @test out.u16 === UInt16(0xffff)
    @test out.u32 === UInt32(0xffffffff)
    @test out.u64 === UInt64(0xffffffffffffffff)

    # Each width's boundary values round-trip into a field of that width.
    for v in (typemin(Int8), typemax(Int8),
              typemin(Int16), typemax(Int16),
              typemin(Int32), typemax(Int32),
              typemin(Int64), typemax(Int64))
        T = typeof(v)
        field = v isa Int8 ? :i8 : v isa Int16 ? :i16 : v isa Int32 ? :i32 : :i64
        nt = (i8=Int8(0), i16=Int16(0), i32=Int32(0), i64=Int64(0),
              u8=UInt8(0), u16=UInt16(0), u32=UInt32(0), u64=UInt64(0))
        nt = merge(nt, NamedTuple{(field,)}((T(v),)))
        b = CapnProto.build_message(nt, sf, "S")
        o = CapnProto.parse_message(b, sf, "S")
        @test getfield(o, field) === T(v)
    end

    # Negative integers in primitive lists (encode_primitive path).
    sf_l = parse_schema("""
    @0x88;
    struct L {
        i8s  @0 :List(Int8);
        i16s @1 :List(Int16);
        i32s @2 :List(Int32);
        i64s @3 :List(Int64);
    }
    """)
    lval = (i8s=Int8[-1, 0, 1], i16s=Int16[-2, -1, 0, 1, 2],
            i32s=Int32[typemin(Int32), -1, 0, 1, typemax(Int32)],
            i64s=Int64[typemin(Int64), -1, 0, 1, typemax(Int64)])
    lbytes = CapnProto.build_message(lval, sf_l, "L")
    lout = CapnProto.parse_message(lbytes, sf_l, "L")
    @test lout.i8s == lval.i8s
    @test lout.i16s == lval.i16s
    @test lout.i32s == lval.i32s
    @test lout.i64s == lval.i64s

    # Negative default values must encode to the right bit pattern.
    sf_d = parse_schema("""
    @0xaa;
    struct D {
        i8  @0 :Int8 = -1;
        i16 @1 :Int16 = -1;
        i32 @2 :Int32 = -1;
        i64 @3 :Int64 = -1;
    }
    """)
    d = sf_d.flat["D"]
    @test d.fields[1].default_value === UInt64(0xff)
    @test d.fields[2].default_value === UInt64(0xffff)
    @test d.fields[3].default_value === UInt64(0xffffffff)
    @test d.fields[4].default_value === UInt64(0xffffffffffffffff)
end

@testset "forward compatibility: extra struct words ignored (spec)" begin
    # The Cap'n Proto encoding is forward-compatible: a reader whose schema
    # knows fewer fields than the writer's MUST silently ignore the extra
    # trailing data and pointer words rather than error. The struct pointer
    # carries the message's data_words/ptr_count; the reader only walks the
    # fields it knows, so unknown trailing words are never inspected.
    sf_small = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; }
    """)
    # Build with 2 data words and 2 pointer slots; the schema only knows 1
    # data field and no pointer fields.
    b = MessageBuilder()
    root = init_root_struct!(b, 2, 2)
    set_int64!(root, 0, 0x1111)
    set_int64!(root, 1, 0x2222)           # extra data word
    set_text!(root, 0, "first")           # extra pointer slot 0
    set_text!(root, 1, "second")          # extra pointer slot 1
    bytes = write_message(b)

    out = parse_message(bytes, sf_small, "S")
    @test out.a === Int64(0x1111)
    # The schema has no pointer fields, so the extra text pointers are simply
    # not surfaced -- no error, no spurious fields.
    @test propertynames(out) == (:a,)

    # Same rule for nested structs: a writer with extra nested-data words
    # is read fine by a schema that knows fewer.
    sf_outer = parse_schema("""
    @0x99;
    struct Outer { sub @0 :Inner; }
    struct Inner { x @0 :Int32; }
    """)
    sf_outer_big = parse_schema("""
    @0x99;
    struct Outer { sub @0 :Inner; }
    struct Inner { x @0 :Int32; y @1 :Int64; }
    """)
    val = (sub=(x=Int32(7), y=Int64(999)),)
    bytes_big = build_message(val, sf_outer_big, "Outer")
    # Reading with the smaller schema must succeed and see `x`.
    out_small = parse_message(bytes_big, sf_outer, "Outer")
    @test out_small.sub.x === Int32(7)
    @test propertynames(out_small.sub) == (:x,)
end

@testset "backward compatibility: missing struct words yield defaults (spec)" begin
    # The converse of forward compatibility: a reader whose schema knows
    # MORE fields than the writer's MUST read the absent high-offset fields
    # as their default values (zero when no default is declared), NOT error.
    # The message's struct pointer declares fewer data/pointer words than the
    # schema's highest field requires; the reader must treat the missing
    # words as zero-filled.
    sf_big = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; b @1 :Int64; }
    """)
    # Build a message whose struct has only 1 data word (field `a`); the
    # schema also declares `b` in data word 1, which the message lacks.
    b = MessageBuilder()
    root = init_root_struct!(b, 1, 0)
    set_int64!(root, 0, 0x1111)
    bytes = write_message(b)
    mr, _ = read_message(bytes)
    r = get_root(mr)

    # `a` is within the message's data section and reads correctly; the
    # absent `b` reads as its default (zero).
    @test get_int64(r, 0) === Int64(0x1111)
    @test get_int64(r, 1) === Int64(0)

    # Typed path: the absent field decodes as its default (zero).
    out = parse_message(bytes, sf_big, "S")
    @test out.a === Int64(0x1111)
    @test out.b === Int64(0)

    # Same for the pointer section: a struct whose schema declares pointer
    # fields but whose message has zero pointer words reads them as the
    # typed empty values, not throw.
    sf_ptr = parse_schema("""
    @0x99;
    struct S { name @0 :Text; xs @1 :List(Int32); sub @2 :Sub; }
    struct Sub { x @0 :Int32; }
    """)
    b = MessageBuilder()
    root = init_root_struct!(b, 0, 0)   # no pointer words at all
    bytes = write_message(b)
    out = parse_message(bytes, sf_ptr, "S")
    @test out.name === ""
    @test out.xs == Int32[]
    @test out.sub == (x = 0,)

    # A non-zero default must be honored for an absent field.
    sf_def = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; b @1 :Int64 = 42; }
    """)
    b = MessageBuilder()
    root = init_root_struct!(b, 1, 0)
    set_int64!(root, 0, 0x1111)
    bytes = write_message(b)
    mr, _ = read_message(bytes)
    r = get_root(mr)
    @test get_int64(r, 0) === Int64(0x1111)
    @test get_int64(r, 1) === Int64(0)   # low-level returns zero (no default knowledge)
    out = parse_message(bytes, sf_def, "S")
    @test out.a === Int64(0x1111)
    @test out.b === Int64(42)            # typed reader honors the declared default
end

@testset "list element word-count mismatch (spec)" begin
    # For composite lists the per-element data/pointer word counts come from
    # the list's tag word, not the reader's schema. Extra element words are
    # ignored; missing element words yield defaults (zero).
    sf_small = parse_schema("""
    @0x99;
    struct P { x @0 :Int32; }
    struct L { ps @0 :List(P); }
    """)
    sf_big = parse_schema("""
    @0x99;
    struct P { x @0 :Int32; y @1 :Int64; }
    struct L { ps @0 :List(P); }
    """)

    # Writer's elements have MORE data words than the small schema knows:
    # extra words are silently ignored (forward compatible).
    b = MessageBuilder()
    root = init_root_struct!(b, 0, 1)
    lb = alloc_composite_list!(root, 0, 2, 2, 0)   # tag: 2 data words/elem
    for i in 0:1
        el = list_element_struct(lb, i)
        set_int32!(el, 0, Int32(10 + i))
        set_int64!(el, 1, Int64(900 + i))          # extra word
    end
    bytes = write_message(b)
    out = parse_message(bytes, sf_small, "L")
    @test length(out.ps) == 2
    @test [p.x for p in out.ps] == Int32[10, 11]
    @test propertynames(out.ps[1]) == (:x,)

    # Writer's elements have FEWER data words than the big schema knows:
    # missing words yield defaults (zero).
    b = MessageBuilder()
    root = init_root_struct!(b, 0, 1)
    lb = alloc_composite_list!(root, 0, 2, 1, 0)   # tag: 1 data word/elem
    for i in 0:1
        el = list_element_struct(lb, i)
        set_int32!(el, 0, Int32(10 + i))
    end
    bytes = write_message(b)

    # Low-level: each element reader reports the tag's data_words (1); the
    # absent word 1 reads as zero.
    mr, _ = read_message(bytes)
    lr = get_list_field(get_root(mr), 0)
    el0 = list_element_struct(lr, 0)
    @test get_int32(el0, 0) === Int32(10)
    @test get_int64(el0, 1) === Int64(0)

    # Typed path: the absent `y` field of each element decodes as its
    # default (zero).
    out = parse_message(bytes, sf_big, "L")
    @test length(out.ps) == 2
    @test [p.x for p in out.ps] == Int32[10, 11]
    @test [p.y for p in out.ps] == Int64[0, 0]
end

@testset "schema-driven write/read compatibility across schema versions" begin
    # The forward/backward compatibility tests above use the low-level builder
    # to hand-craft messages with more or fewer words than the reader's schema
    # knows. The realistic scenario is schema-driven writing via build_message
    # with one schema version and reading via parse_message with another:
    #
    #   - Backward: an OLD writer (smaller schema) produces a message that a
    #     NEW reader (bigger schema) reads, with the new fields at their
    #     defaults.
    #   - Forward: a NEW writer (bigger schema) produces a message that an
    #     OLD reader (smaller schema) reads, ignoring the unknown fields.
    #
    # These tests cover the schema-driven write side for data fields, pointer
    # fields, nested structs, and composite-list elements.

    # ---- Data fields: root struct ----
    sf_small = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; }
    """)
    sf_big = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; b @1 :Int64; }
    """)
    # Backward: old writer writes only `a`; new reader sees `b` at its default.
    bytes = build_message((a=Int64(7),), sf_small, "S")
    out_big = parse_message(bytes, sf_big, "S")
    @test out_big.a === Int64(7)
    @test out_big.b === Int64(0)
    # Forward: new writer writes `a` and `b`; old reader sees only `a`.
    bytes = build_message((a=Int64(7), b=Int64(8)), sf_big, "S")
    out_small = parse_message(bytes, sf_small, "S")
    @test out_small.a === Int64(7)
    @test propertynames(out_small) == (:a,)

    # ---- Non-zero declared default: backward ----
    sf_def = parse_schema("""
    @0x99;
    struct S { a @0 :Int64; b @1 :Int64 = 42; }
    """)
    bytes = build_message((a=Int64(7),), sf_small, "S")  # old writer, no `b`
    out = parse_message(bytes, sf_def, "S")
    @test out.a === Int64(7)
    @test out.b === Int64(42)   # new reader honors the declared default

    # ---- Pointer fields: Text ----
    sf_ptr_small = parse_schema("""
    @0x99;
    struct S { a @0 :Int32; }
    """)
    sf_ptr_big = parse_schema("""
    @0x99;
    struct S { a @0 :Int32; name @1 :Text; }
    """)
    # Backward: old writer omits `name`; new reader sees it as the empty string.
    bytes = build_message((a=Int32(5),), sf_ptr_small, "S")
    out = parse_message(bytes, sf_ptr_big, "S")
    @test out.a === Int32(5)
    @test out.name === ""
    # Forward: new writer sets `name`; old reader ignores it.
    bytes = build_message((a=Int32(5), name="hi"), sf_ptr_big, "S")
    out = parse_message(bytes, sf_ptr_small, "S")
    @test out.a === Int32(5)
    @test propertynames(out) == (:a,)

    # ---- Nested struct: data field added in inner struct ----
    sf_inner_small = parse_schema("""
    @0x99;
    struct Outer { sub @0 :Inner; }
    struct Inner { x @0 :Int32; }
    """)
    sf_inner_big = parse_schema("""
    @0x99;
    struct Outer { sub @0 :Inner; }
    struct Inner { x @0 :Int32; y @1 :Int64; }
    """)
    # Backward: old writer's Inner has only `x`; new reader sees `y` as default.
    bytes = build_message((sub=(x=Int32(7),),), sf_inner_small, "Outer")
    out = parse_message(bytes, sf_inner_big, "Outer")
    @test out.sub.x === Int32(7)
    @test out.sub.y === Int64(0)
    # Forward: new writer sets `x` and `y`; old reader sees only `x`.
    bytes = build_message((sub=(x=Int32(7), y=Int64(8)),), sf_inner_big, "Outer")
    out = parse_message(bytes, sf_inner_small, "Outer")
    @test out.sub.x === Int32(7)
    @test propertynames(out.sub) == (:x,)

    # ---- Composite list: data field added in element struct ----
    sf_list_small = parse_schema("""
    @0x99;
    struct P { x @0 :Int32; }
    struct L { ps @0 :List(P); }
    """)
    sf_list_big = parse_schema("""
    @0x99;
    struct P { x @0 :Int32; y @1 :Int64; }
    struct L { ps @0 :List(P); }
    """)
    # Backward: old writer's elements have only `x`; new reader sees `y` as default.
    bytes = build_message((ps=[(x=Int32(1),), (x=Int32(2),)],), sf_list_small, "L")
    out = parse_message(bytes, sf_list_big, "L")
    @test [p.x for p in out.ps] == Int32[1, 2]
    @test [p.y for p in out.ps] == Int64[0, 0]
    # Forward: new writer's elements set `x` and `y`; old reader sees only `x`.
    bytes = build_message((ps=[(x=Int32(1), y=Int64(9)), (x=Int32(2), y=Int64(8))],),
                          sf_list_big, "L")
    out = parse_message(bytes, sf_list_small, "L")
    @test [p.x for p in out.ps] == Int32[1, 2]
    @test propertynames(out.ps[1]) == (:x,)

    # ---- Pointer fields added in inner struct of a composite list ----
    sf_lp_small = parse_schema("""
    @0x99;
    struct P { x @0 :Int32; }
    struct L { ps @0 :List(P); }
    """)
    sf_lp_big = parse_schema("""
    @0x99;
    struct P { x @0 :Int32; tag @1 :Text; }
    struct L { ps @0 :List(P); }
    """)
    # Backward: old writer's elements have no `tag`; new reader sees "".
    bytes = build_message((ps=[(x=Int32(1),), (x=Int32(2),)],), sf_lp_small, "L")
    out = parse_message(bytes, sf_lp_big, "L")
    @test [p.x for p in out.ps] == Int32[1, 2]
    @test [p.tag for p in out.ps] == ["", ""]
    # Forward: new writer's elements set `tag`; old reader ignores it.
    bytes = build_message((ps=[(x=Int32(1), tag="a"), (x=Int32(2), tag="b")],),
                          sf_lp_big, "L")
    out = parse_message(bytes, sf_lp_small, "L")
    @test [p.x for p in out.ps] == Int32[1, 2]
    @test propertynames(out.ps[1]) == (:x,)
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

@testset "parse_messages eltype and type stability" begin
    # The iterator's eltype is the NamedTuple type determined from the schema.
    # For byte-strideable primitive lists (xs::List(Int32), ys::List(UInt32))
    # the populated path returns a zero-copy `ReinterpretArray`-view of the
    # backing bytes while the null/empty path returns a `Vector{T}`, so the
    # field type widens to `AbstractVector{T}` and `outer_T` uses the
    # covariant `NamedTuple{names, <:Tuple{...}}` form so both concrete
    # NamedTuple types are subtypes. `collect` returns a `Vector{outer_T}`
    # whose elements are one of those concrete types. The type is stable
    # across messages regardless of whether fields are populated, empty, or
    # null, and regardless of the skip setting.
    sf = parse_schema("""
    @0x77;
    struct Outer {
        sub  @0 :Inner;
        vals @1 :List(Inner);
        xs   @2 :List(Int32);
        ys   @3 :List(UInt32);
        a    @4 :Int32;
        name @5 :Text;
    }
    struct Inner {
        x @0 :Int32;
        y @1 :Text;
    }
    """)
    node = sf["Outer"]
    outer_T = CapnProto._named_tuple_type(node, sf)
    @test outer_T == NamedTuple{(:sub, :vals, :xs, :ys, :a, :name),
                                <:Tuple{@NamedTuple{x::Int32, y::String},
                                        Vector{@NamedTuple{x::Int32, y::String}},
                                        AbstractVector{Int32}, AbstractVector{UInt32},
                                        Int32, String}}

    # Build messages with each list/struct field in turn left null (absent),
    # so every field takes its empty/default path. The decoded type must
    # be a subtype of outer_T in every case.
    function null_msg()
        b = MessageBuilder()
        init_root_struct!(b, 1, 6)  # no pointers set, `a` data word left zero
        return write_message(b)
    end
    function populated_msg()
        b = MessageBuilder()
        root = init_root_struct!(b, 1, 6)
        set_int32!(root, 0, Int32(42))
        set_text!(root, 5, "hi")
        sub = alloc_struct!(root, 0, 1, 1)
        set_int32!(sub, 0, 7); set_text!(sub, 0, "inner")
        lb = alloc_composite_list!(root, 1, 2, 1, 1)
        for i in 0:1
            el = list_element_struct(lb, i)
            set_int32!(el, 0, Int32(i))
        end
        lxs = alloc_list!(root, 2, INT32_LIST, 3)
        for i in 0:2; set_element!(lxs, i, UInt64(Int32(i))); end
        lys = alloc_list!(root, 3, INT32_LIST, 3)
        for i in 0:2; set_element!(lys, i, UInt64(UInt32(i))); end
        return write_message(b)
    end

    @test typeof(parse_message(null_msg(), sf, "Outer")) <: outer_T
    @test typeof(parse_message(populated_msg(), sf, "Outer")) <: outer_T

    # Skip settings targeting a list, a struct, and a scalar all preserve the
    # subtype relationship to outer_T.
    bytes = populated_msg()
    @test typeof(parse_message(bytes, sf, "Outer"; skip=["xs"])) <: outer_T
    @test typeof(parse_message(bytes, sf, "Outer"; skip=["sub"])) <: outer_T
    @test typeof(parse_message(bytes, sf, "Outer"; skip=["a"])) <: outer_T
    @test typeof(parse_message(bytes, sf, "Outer"; skip=["vals"])) <: outer_T

    # The populated path returns a zero-copy `ReinterpretArray`-view over the
    # backing segment bytes for byte-strideable primitive lists; the null path
    # returns a `Vector{T}`. Both are `AbstractVector{T}`.
    @test typeof(parse_message(populated_msg(), sf, "Outer").xs) <: AbstractVector{Int32}
    @test typeof(parse_message(populated_msg(), sf, "Outer").ys) <: AbstractVector{UInt32}
    @test typeof(parse_message(null_msg(),      sf, "Outer").xs) === Vector{Int32}
    @test typeof(parse_message(null_msg(),      sf, "Outer").ys) === Vector{UInt32}

    # The iterator's eltype matches outer_T, and collect returns a Vector of
    # that type.
    stream = vcat(populated_msg(), null_msg(), populated_msg())
    itr = parse_messages(stream, sf, "Outer")
    @test eltype(itr) === outer_T
    v = collect(itr)
    @test eltype(v) === outer_T
    @test length(v) == 3

    # OffsetMessageIterator's eltype is (Int, outer_T).
    oitr = with_offsets(parse_messages(IOBuffer(stream), sf, "Outer"))
    @test eltype(oitr) === Tuple{Int, outer_T}
    ov = collect(oitr)
    @test eltype(ov) === Tuple{Int, outer_T}
    @test length(ov) == 3
end

@testset "list read path inference (function barriers)" begin
    # Regression test for the function-barrier dispatch elimination in
    # `_read_list` / `_read_prim_list` / `_read_text_list` / `_read_data_list` /
    # `_read_struct_list`. Each inner barrier method must infer a concrete
    # `Vector{T}` return type from its declared argument types alone, so the
    # per-element decode loop is monomorphic (no per-element runtime dispatch).
    # The struct-list barrier's container is concrete at runtime even though
    # `return_type` (using declared arg types only) sees a NamedTuple UnionAll;
    # for that case we assert on `typeof(actual_call)` instead.
    sf = parse_schema("""
    @0x88;
    struct Outer {
        i8 @0 :List(Int8);  u8 @1 :List(UInt8);
        i16 @2 :List(Int16); u16 @3 :List(UInt16);
        i32 @4 :List(Int32); u32 @5 :List(UInt32);
        i64 @6 :List(Int64); u64 @7 :List(UInt64);
        f32 @8 :List(Float32); f64 @9 :List(Float64);
        b  @10 :List(Bool);
        t  @11 :List(Text);
        d  @12 :List(Data);
        s  @13 :List(Inner);
    }
    struct Inner { x @0 :Int32; }
    """)
    b = MessageBuilder()
    root = init_root_struct!(b, 0, 14)
    set_one_raw!(slot, esize, raw::UInt64) = set_element!(alloc_list!(root, slot, esize, 1), 0, raw)
    set_one_raw!(0,  INT8_LIST,  UInt64(1))
    set_one_raw!(1,  INT8_LIST,  UInt64(2))
    set_one_raw!(2,  INT16_LIST, UInt64(3))
    set_one_raw!(3,  INT16_LIST, UInt64(4))
    set_one_raw!(4,  INT32_LIST, UInt64(5))
    set_one_raw!(5,  INT32_LIST, UInt64(6))
    set_one_raw!(6,  INT64_LIST, UInt64(7))
    set_one_raw!(7,  INT64_LIST, UInt64(8))
    set_one_raw!(8,  INT32_LIST, UInt64(reinterpret(UInt32, Float32(1.0f0))))
    set_one_raw!(9,  INT64_LIST, reinterpret(UInt64, Float64(2.0)))
    set_one_raw!(10, BOOL_LIST,  UInt64(1))
    tlb = alloc_list!(root, 11, POINTER_LIST, 1); set_text_element!(tlb, 0, "hi")
    dlb = alloc_list!(root, 12, POINTER_LIST, 1); CapnProto.set_data_element!(dlb, 0, UInt8[0x01, 0x02])
    cl = alloc_composite_list!(root, 13, 1, 1, 0); set_int32!(list_element_struct(cl, 0), 0, Int32(42))
    bytes = write_message(b)
    mr, _ = read_message(bytes)
    rr = get_root(mr)

    # Void and Bool are NOT byte-strideable (Void carries no data; Bool is
    # bit-packed at 1 bit/elem) so their barriers still materialize a
    # concrete `Vector{T}`. Assert the strict type (which also excludes
    # Any / Vector{Any}, spelled out for symmetry with the byte-strideable
    # arm below).
    for (prim, T) in ((PT_Void, Vector{Nothing}), (PT_Bool, Vector{Bool}))
        rt = Core.Compiler.return_type(CapnProto._read_prim_list,
                                        Tuple{CapnProto.ListReader, Int, Val{prim}})
        @test rt === T
        @test rt !== Any
        @test rt !== Vector{Any}
    end

    # The byte-strideable primitives are returned as a zero-copy
    # `ReinterpretArray`-view over the backing segment bytes, whose
    # `return_type` is a Union over the possible backing types (mmap
    # Vector{UInt8} vs materialized Vector{UInt64}). Assert it is a
    # concrete-typed `AbstractVector{T}` (not Any / not Vector{Any}).
    for (prim, T) in (
        (PT_Int8,    Int8),    (PT_UInt8,   UInt8),
        (PT_Int16,   Int16),   (PT_UInt16,  UInt16),
        (PT_Int32,   Int32),   (PT_UInt32,  UInt32),
        (PT_Int64,   Int64),   (PT_UInt64,  UInt64),
        (PT_Float32, Float32), (PT_Float64, Float64),
    )
        rt = Core.Compiler.return_type(CapnProto._read_prim_list,
                                        Tuple{CapnProto.ListReader, Int, Val{prim}})
        @test rt <: AbstractVector{T}
        @test rt !== Any
        @test rt !== Vector{Any}
    end

    # Text / Data barriers infer concrete element types too.
    @test Core.Compiler.return_type(CapnProto._read_text_list,
                                    Tuple{CapnProto.ListReader, Int}) === Vector{String}
    @test Core.Compiler.return_type(CapnProto._read_data_list,
                                    Tuple{CapnProto.ListReader, Int}) === Vector{Vector{UInt8}}

    # Struct-list barrier: `return_type` (declared-arg inference) sees only a
    # NamedTuple UnionAll, so assert it is at least a Vector of NamedTuples
    # (not Any / not Vector{Any}) -- the per-element store is type-checked
    # against NamedTuple, eliminating the old Any-boxing.
    rt = Core.Compiler.return_type(CapnProto._read_struct_list,
                                   Tuple{CapnProto.ListReader, CapnProto.SchemaFile,
                                         String, Int, String, Nothing})
    @test rt <: Vector
    @test rt !== Any
    @test rt !== Vector{Any}

    # And at runtime -- where the concrete `sf` and `type_name` are in hand --
    # the container is fully concrete, so per-element stores into it are
    # monomorphic and dispatch-free.
    lr_s = get_list_field(rr, 13)
    inner_T = CapnProto._named_tuple_type(sf["Inner"], sf)
    @test typeof(CapnProto._read_struct_list(lr_s, sf, "Inner", 1, "", nothing)) === Vector{inner_T}

    # End-to-end: _read_list dispatches to the right barrier and returns a
    # concrete-typed `AbstractVector{T}` for each primitive kind. Bool is
    # materialized as `Vector{Bool}`; the byte-strideable primitives are
    # returned as a `ReinterpretArray`-view (for a materialized
    # `Vector{UInt64}`-backed `MessageReader` this is a
    # `ReinterpretArray{T,1,UInt8,SubArray{UInt8,1,
    # ReinterpretArray{UInt8,1,UInt64,Vector{UInt64}},...}}`).
    prim_type(prim) = CapnProto.SchemaType(:primitive, prim, "", nothing)
    # Bool: strict concrete Vector{Bool} (materialized, not byte-strideable).
    @test typeof(CapnProto._read_list(get_list_field(rr, 10), sf, prim_type(PT_Bool), "", nothing)) === Vector{Bool}
    # Byte-strideable primitives: zero-copy ReinterpretArray-view, asserted
    # as a concrete AbstractVector{T}.
    for (slot, prim, T) in (
        (0,  PT_Int8,    Int8),    (1,  PT_UInt8,   UInt8),
        (2,  PT_Int16,   Int16),   (3,  PT_UInt16,  UInt16),
        (4,  PT_Int32,   Int32),   (5,  PT_UInt32,  UInt32),
        (6,  PT_Int64,   Int64),   (7,  PT_UInt64,  UInt64),
        (8,  PT_Float32, Float32), (9,  PT_Float64, Float64),
    )
        out = CapnProto._read_list(get_list_field(rr, slot), sf, prim_type(prim), "", nothing)
        @test typeof(out) <: AbstractVector{T}
    end
    @test typeof(CapnProto._read_list(get_list_field(rr, 11), sf, prim_type(PT_Text), "", nothing)) === Vector{String}
    @test typeof(CapnProto._read_list(get_list_field(rr, 12), sf, prim_type(PT_Data), "", nothing)) === Vector{Vector{UInt8}}
    @test typeof(CapnProto._read_list(get_list_field(rr, 13), sf, CapnProto.SchemaType(:struct, PT_Void, "Inner", nothing), "", nothing)) === Vector{inner_T}
end

@testset "with_offsets yields (offset, value)" begin
    sf = parse_schema("""
    @0x66;
    struct Hit {
        n @0 :Int32;
        tag @1 :Text;
    }
    """)
    vals = [(n=1, tag="a"), (n=2, tag="bb"), (n=3, tag="ccc")]
    stream_unpacked = reduce(vcat, [build_message(v, sf, "Hit"; packed=false) for v in vals])
    stream_packed = reduce(vcat, [build_message(v, sf, "Hit"; packed=true) for v in vals])

    # Unpacked: offsets come from position(io) before each message is read.
    bio = IOBuffer(stream_unpacked)
    pairs = collect(with_offsets(parse_messages(bio, sf, "Hit")))
    @test length(pairs) == 3
    @test [p[2].n for p in pairs] == [1, 2, 3]
    # First message starts at offset 0; offsets strictly increase.
    @test pairs[1][1] == 0
    @test issorted([p[1] for p in pairs])
    # Each reported offset matches read_message's next_start-1 boundary.
    _, next1 = read_message(stream_unpacked; start=1)
    @test pairs[2][1] == next1 - 1
    _, next2 = read_message(stream_unpacked; start=next1)
    @test pairs[3][1] == next2 - 1

    # The reported offsets let us re-read individual messages via pos=.
    for (off, msg) in pairs
        r = parse_message(stream_unpacked, sf, "Hit"; pos=off, packed=false)
        @test r.n == msg.n
        @test r.tag == msg.tag
    end

    # Packed stream: offsets are still byte positions in the packed stream.
    bio_p = IOBuffer(stream_packed)
    pairs_p = collect(with_offsets(parse_messages(bio_p, sf, "Hit")))
    @test length(pairs_p) == 3
    @test [p[2].n for p in pairs_p] == [1, 2, 3]
    @test pairs_p[1][1] == 0
    @test issorted([p[1] for p in pairs_p])
    for (off, msg) in pairs_p
        r = parse_message(stream_packed, sf, "Hit"; pos=off, packed=true)
        @test r.n == msg.n
        @test r.tag == msg.tag
    end

    # Default iteration (without with_offsets) still yields values only.
    # The iterator's eltype is the concrete NamedTuple type determined from
    # the schema (so `collect` returns a Vector of that type, not Vector{Any}).
    bio0 = IOBuffer(stream_unpacked)
    Hit = typeof(first(collect(parse_messages(bio0, sf, "Hit"))))
    @test eltype(parse_messages(IOBuffer(stream_unpacked), sf, "Hit")) === Hit
    bio2 = IOBuffer(stream_unpacked)
    plain = collect(parse_messages(bio2, sf, "Hit"))
    @test eltype(plain) === Hit
    @test all(x -> x isa NamedTuple, plain)

    # Empty input yields no pairs.
    @test isempty(collect(with_offsets(parse_messages(UInt8[], sf, "Hit"))))

    # Works with skip=.
    sf2 = parse_schema("""
    @0x77;
    struct Inner { a @0 :Int32; b @1 :List(Float32); }
    struct Outer { name @0 :Text; inner @1 :Inner; }
    """)
    ovals = [(name="hi", inner=(a=7, b=Float32[1f0, 2f0, 3f0])),
             (name="yo", inner=(a=8, b=Float32[4f0, 5f0]))]
    s = reduce(vcat, [build_message(v, sf2, "Outer"; packed=false) for v in ovals])
    bio3 = IOBuffer(s)
    sk_pairs = collect(with_offsets(parse_messages(bio3, sf2, "Outer"; skip=["inner.b"])))
    @test length(sk_pairs) == 2
    @test [p[2].name for p in sk_pairs] == ["hi", "yo"]
    @test [p[2].inner.a for p in sk_pairs] == [7, 8]
    @test all(p -> p[2].inner.b == Float32[], sk_pairs)
    @test sk_pairs[1][1] == 0
    @test issorted([p[1] for p in sk_pairs])
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
    seg1 = CapnProto.alloc_segment!(b)
    N = length(bvals)
    list_words = cld(N * 4, 8)
    landing_idx = CapnProto.alloc_words!(b, seg1, 1)
    body_idx = CapnProto.alloc_words!(b, seg1, list_words)
    lb = ListBuilder(b, seg1, body_idx, INT32_LIST, N, 0, 0)
    for (i, v) in enumerate(bvals)
        set_element!(lb, i - 1, UInt64(reinterpret(UInt32, Float32(v))))
    end
    CapnProto.set_word!(b, seg1, landing_idx, list_pointer(0, INT32_LIST, N))
    CapnProto.set_word!(b, 0, sub.base + sub.data_words + 0,
                    CapnProto.far_pointer(landing_idx, seg1, false))
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

@testset "parse_messages bad tail" begin
    sf = parse_schema("""
    @0x77;
    struct S {
        a @0 :Int32;
    }
    """)
    ok = build_message((a=Int32(42),), sf, "S"; packed=false)
    ok_packed = build_message((a=Int32(42),), sf, "S"; packed=true)

    # Clean EOF (no trailing bytes): no warning, returns the complete messages.
    @test_logs min_level=Warn begin
        @test collect(parse_messages(ok, sf, "S"; packed=false)) |> length == 1
    end

    # --- Truncation ---

    # Default (throw_on_error=false): a truncated tail warns and ends iteration
    # cleanly. The warning carries the source name and the 0-based byte offset
    # of the truncated message.
    trunc = vcat(ok, ok[1:4])  # 1 good message + half a segment table
    @test_logs (:warn, "bad message in stream; ending iteration") match_mode=:any begin
        v = collect(parse_messages(trunc, sf, "S"; packed=false))
        @test length(v) == 1
        @test v[1].a == 42
    end

    # Packed truncation: same behavior, different inner error.
    trunc_p = vcat(ok_packed, ok_packed[1:end-2])
    @test_logs (:warn, "bad message in stream; ending iteration") match_mode=:any begin
        v = collect(parse_messages(trunc_p, sf, "S"; packed=true))
        @test length(v) == 1
        @test v[1].a == 42
    end

    # throw_on_error=true: raises TruncatedMessageError at the truncated message.
    @test_throws TruncatedMessageError begin
        collect(parse_messages(trunc, sf, "S"; packed=false, throw_on_error=true))
    end
    @test_throws TruncatedMessageError begin
        collect(parse_messages(trunc_p, sf, "S"; packed=true, throw_on_error=true))
    end

    # The skip path also honors throw_on_error.
    @test_throws TruncatedMessageError begin
        collect(parse_messages(trunc, sf, "S"; packed=false, skip=["a"],
                               throw_on_error=true))
    end

    # A clean EOF after a complete message, even with throw_on_error=true, does
    # not throw (no bad message exists).
    @test collect(parse_messages(ok, sf, "S"; packed=false,
                                  throw_on_error=true)) |> length == 1

    # --- Corruption ---

    # 0xFFFFFFFF seg count -> seg_count = 0 (a corrupt, not truncated, value).
    corrupt = vcat(ok, UInt8[0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00])

    # Default (throw_on_error=false): corruption also warns + ends iteration.
    @test_logs (:warn, "bad message in stream; ending iteration") match_mode=:any begin
        v = collect(parse_messages(corrupt, sf, "S"; packed=false))
        @test length(v) == 1
        @test v[1].a == 42
    end

    # throw_on_error=true: raises CorruptedMessageError at the corrupt message.
    @test_throws CorruptedMessageError begin
        collect(parse_messages(corrupt, sf, "S"; packed=false, throw_on_error=true))
    end

    # Corruption in the skip path is also caught as CorruptedMessageError.
    @test_throws CorruptedMessageError begin
        collect(parse_messages(corrupt, sf, "S"; packed=false, skip=["a"],
                               throw_on_error=true))
    end

    # --- throw_on_error=nothing: silent stop ---

    # Truncation: ends iteration silently (no warning), returns the good messages.
    @test_logs min_level=Warn begin
        v = collect(parse_messages(trunc, sf, "S"; packed=false, throw_on_error=nothing))
        @test length(v) == 1
        @test v[1].a == 42
    end

    # Packed truncation: same silent behavior.
    @test_logs min_level=Warn begin
        v = collect(parse_messages(trunc_p, sf, "S"; packed=true, throw_on_error=nothing))
        @test length(v) == 1
        @test v[1].a == 42
    end

    # Corruption: also silent with nothing.
    @test_logs min_level=Warn begin
        v = collect(parse_messages(corrupt, sf, "S"; packed=false, throw_on_error=nothing))
        @test length(v) == 1
        @test v[1].a == 42
    end

    # The skip path also honors throw_on_error=nothing silently.
    @test_logs min_level=Warn begin
        v = collect(parse_messages(trunc, sf, "S"; packed=false, skip=["a"],
                                   throw_on_error=nothing))
        @test length(v) == 1
    end

    # Clean EOF with throw_on_error=nothing still returns the good messages.
    @test_logs min_level=Warn begin
        @test collect(parse_messages(ok, sf, "S"; packed=false,
                                      throw_on_error=nothing)) |> length == 1
    end

    # --- Filename source in warning ---

    # The warning's `src` field is the filename, not "<byte vector>". Capture
    # the warning record via a TestLogger.
    tmp = tempname()
    open(tmp, "w") do io
        write(io, ok)
        write(io, ok[1:4])  # truncated second message
    end
    try
        tl = Test.TestLogger(min_level=Warn)
        v = with_logger(tl) do
            collect(parse_messages(tmp, sf, "S"; packed=false))
        end
        @test length(v) == 1
        warns = filter(r -> r.level == Warn, tl.logs)
        @test length(warns) == 1
        @test occursin(tmp, warns[1].kwargs[:src])
        @test warns[1].kwargs[:offset] >= 0
        @test warns[1].kwargs[:exception] isa TruncatedMessageError
    finally
        rm(tmp; force=true)
    end
end

# ---------------------------------------------------------------------------
# Mmap-backed reader and zero-copy primitive lists
# ---------------------------------------------------------------------------
#
# `MmapMessageReader` keeps segment bodies as zero-copy views of a backing
# byte vector (typically an `Mmap.mmap` result). The typed layer's
# primitive-list fast path returns a `reinterpret`-view of the list body
# directly over those bytes, so a `List(Float32)` (or any byte-strideable
# primitive list) decodes to an `AbstractVector{T}` whose elements are read
# on demand from the backing storage -- no per-element copy is made.

@testset "MmapMessageReader basics" begin
    # Build a simple message with an Int64 list and a Text field.
    sf = parse_schema("""
    @0x77;
    struct S { a @0 :Int64; xs @1 :List(Int64); name @2 :Text; }
    """)
    val = (a=Int64(42), xs=Int64[10, 20, 30], name="hi")
    bytes = build_message(val, sf, "S"; packed=false)

    # read_message_mmap produces an MmapMessageReader whose segment bytes are
    # zero-copy views of `bytes`. The message has a single segment whose body
    # follows the segment table; `next` is the 1-based byte index just past
    # the message (which for a single-message byte vector is `length+1`).
    mr, next = read_message_mmap(bytes)
    @test mr isa MmapMessageReader
    @test CapnProto.nsegments(mr) == 1
    @test next == length(bytes) + 1

    # The segment word count matches the materialized MessageReader's.
    mr_mat, _ = read_message(bytes)
    @test CapnProto.segment_words(mr, 0) == CapnProto.segment_words(mr_mat, 0)

    # get_word reads the same values as the materialized MessageReader.
    for seg in 0:CapnProto.nsegments(mr)-1
        for i in 0:CapnProto.segment_words(mr, seg)-1
            @test CapnProto.get_word(mr, seg, i) == CapnProto.get_word(mr_mat, seg, i)
        end
    end

    # _segment_bytes returns a byte view of the segment body (NOT the whole
    # message: the segment table prefix is excluded). Its length matches
    # segment_words * 8.
    sb = CapnProto._segment_bytes(mr, 0)
    @test sb isa AbstractVector{UInt8}
    @test length(sb) == CapnProto.segment_words(mr, 0) * 8
    # The segment body is a contiguous tail of `bytes` (the segment table
    # prefix has length `length(bytes) - length(sb)`).
    table_len = length(bytes) - length(sb)
    @test sb == bytes[table_len + 1 : end]

    # parse_struct decodes from an MmapMessageReader identically to a
    # materialized MessageReader.
    out = parse_struct(mr, sf, "S")
    @test out.a === Int64(42)
    @test out.xs == Int64[10, 20, 30]
    @test out.name == "hi"
end

@testset "read_message_mmap validates bounds" begin
    # Clean EOF: empty input returns nothing.
    @test read_message_mmap_checked(UInt8[]; start=1) === nothing
    # A single byte is truncated (need at least 4 for the segment count).
    @test_throws TruncatedMessageError read_message_mmap_checked(UInt8[0x00]; start=1)
    # A valid segment count but truncated segment-length table.
    truncated = UInt8[0x00, 0x00, 0x00, 0x00]  # seg_count=1, but no length word
    @test_throws TruncatedMessageError read_message_mmap_checked(truncated; start=1)
    # A corrupt segment count (too large).
    corrupt = UInt8[0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00]
    @test_throws CorruptedMessageError read_message_mmap_checked(corrupt; start=1)
    # A valid table but body runs past the end of the bytes.
    sf = parse_schema("@0x77; struct S { a @0 :Int64; }")
    bytes = build_message((a=Int64(42),), sf, "S"; packed=false)
    truncated_body = bytes[1:end-1]  # drop the last byte -> body truncated
    @test_throws TruncatedMessageError read_message_mmap_checked(truncated_body; start=1)
end

@testset "zero-copy primitive lists from byte vector" begin
    # parse_message(bytes) returns a zero-copy ReinterpretArray-view for each
    # byte-strideable primitive list, backed by the original bytes.
    sf = parse_schema("""
    @0x88;
    struct N {
        i8 @0 :List(Int8);  u8 @1 :List(UInt8);
        i16 @2 :List(Int16); u16 @3 :List(UInt16);
        i32 @4 :List(Int32); u32 @5 :List(UInt32);
        i64 @6 :List(Int64); u64 @7 :List(UInt64);
        f32 @8 :List(Float32); f64 @9 :List(Float64);
        b  @10 :List(Bool);
    }
    """)
    val = (
        i8=Int8[-1, 0, 1], u8=UInt8[0xff, 0x00, 0x01],
        i16=Int16[-2, -1, 0, 1, 2], u16=UInt16[0xffff, 0, 1, 2, 3],
        i32=Int32[typemin(Int32), -1, 0, 1, typemax(Int32)],
        u32=UInt32[0, 1, typemax(UInt32)],
        i64=Int64[typemin(Int64), -1, 0, 1, typemax(Int64)],
        u64=UInt64[0, 1, typemax(UInt64)],
        f32=Float32[1.0f0, -2.5f0, 3.14f0],
        f64=Float64[1.0, -2.5, 3.14],
        b=Bool[true, false, true],
    )
    bytes = build_message(val, sf, "N"; packed=false)
    out = parse_message(bytes, sf, "N"; packed=false)

    # Each byte-strideable primitive list is an AbstractVector{T}-view
    # (ReinterpretArray) over the backing bytes, not a materialized Vector{T}.
    @test typeof(out.i8)  <: AbstractVector{Int8}
    @test typeof(out.u8)  <: AbstractVector{UInt8}
    @test typeof(out.i16) <: AbstractVector{Int16}
    @test typeof(out.u16) <: AbstractVector{UInt16}
    @test typeof(out.i32) <: AbstractVector{Int32}
    @test typeof(out.u32) <: AbstractVector{UInt32}
    @test typeof(out.i64) <: AbstractVector{Int64}
    @test typeof(out.u64) <: AbstractVector{UInt64}
    @test typeof(out.f32) <: AbstractVector{Float32}
    @test typeof(out.f64) <: AbstractVector{Float64}
    # Bool is bit-packed (not byte-strideable) and stays a materialized Vector{Bool}.
    @test typeof(out.b) === Vector{Bool}

    # The view is not a Vector{T} (it's a ReinterpretArray).
    @test typeof(out.i32) !== Vector{Int32}
    @test typeof(out.f32) !== Vector{Float32}

    # Values are correct (the view decodes the same as a materialized read).
    @test out.i8 == val.i8
    @test out.u8 == val.u8
    @test out.i16 == val.i16
    @test out.u16 == val.u16
    @test out.i32 == val.i32
    @test out.u32 == val.u32
    @test out.i64 == val.i64
    @test out.u64 == val.u64
    @test out.f32 == val.f32
    @test out.f64 == val.f64
    @test out.b == val.b

    # The view shares memory with the backing bytes (proves zero-copy): the
    # view's data pointer lies within the backing bytes' memory range.
    out2 = parse_message(bytes, sf, "N"; packed=false)
    p_view = UInt(pointer(out2.u32))
    p_bytes_lo = UInt(pointer(bytes))
    p_bytes_hi = p_bytes_lo + length(bytes)
    @test p_view >= p_bytes_lo
    @test p_view < p_bytes_hi
    # Mutating the backing bytes at the list body changes the view's first
    # element. The u32 list body is at byte offset (p_view - p_bytes_lo)
    # within `bytes`.
    body_off = p_view - p_bytes_lo + 1  # 1-based
    @test body_off in 1:length(bytes)
    @test bytes[body_off] == 0x00  # first byte of u32[1] (which is 0)
    bytes[body_off] = 0xff
    @test out2.u32[1] === UInt32(0xff)
    bytes[body_off] = 0x00  # restore
    @test out2.u32[1] === UInt32(0)
end

@testset "zero-copy primitive lists from mmap'd file" begin
    # parse_message(filename) returns zero-copy ReinterpretArray-views backed
    # by the mmap'd bytes; the OS pages the data in on demand.
    sf = parse_schema("""
    @0x77;
    struct S { xs @0 :List(Float32); n @1 :Int32; }
    """)
    val = (xs=Float32[1.0f0, 2.0f0, 3.0f0, 4.0f0], n=Int32(42))
    bytes = build_message(val, sf, "S"; packed=false)
    tmp = tempname() * ".bin"
    write(tmp, bytes)
    try
        out = parse_message(tmp, sf, "S"; packed=false)
        @test typeof(out.xs) <: AbstractVector{Float32}
        @test typeof(out.xs) !== Vector{Float32}
        @test out.xs == val.xs
        @test out.n === Int32(42)

        # parse_messages(filename) also returns zero-copy views.
        stream = vcat(bytes, bytes)
        stmp = tempname() * ".bin"
        write(stmp, stream)
        try
            msgs = collect(parse_messages(stmp, sf, "S"; packed=false))
            @test length(msgs) == 2
            for m in msgs
                @test typeof(m.xs) <: AbstractVector{Float32}
                @test typeof(m.xs) !== Vector{Float32}
                @test m.xs == val.xs
                @test m.n === Int32(42)
            end
        finally
            rm(stmp; force=true)
        end
    finally
        rm(tmp; force=true)
    end
end

@testset "zero-copy primitive lists from byte vector stream" begin
    # parse_messages(bytes) on an unpacked stream returns zero-copy views
    # backed by the original bytes.
    sf = parse_schema("""
    @0x77;
    struct S { xs @0 :List(Float32); n @1 :Int32; }
    """)
    val = (xs=Float32[1.0f0, 2.0f0, 3.0f0], n=Int32(7))
    bytes = build_message(val, sf, "S"; packed=false)
    stream = vcat(bytes, bytes, bytes)
    msgs = collect(parse_messages(stream, sf, "S"; packed=false))
    @test length(msgs) == 3
    for m in msgs
        @test typeof(m.xs) <: AbstractVector{Float32}
        @test typeof(m.xs) !== Vector{Float32}
        @test m.xs == val.xs
        @test m.n === Int32(7)
    end

    # with_offsets works over the mmap-backed iterator.
    pairs = collect(with_offsets(parse_messages(stream, sf, "S"; packed=false)))
    @test length(pairs) == 3
    @test pairs[1][1] == 0
    @test issorted([p[1] for p in pairs])
    for (off, m) in pairs
        @test typeof(m.xs) <: AbstractVector{Float32}
        @test m.xs == val.xs
    end
end

@testset "packed input falls back to materialized AbstractVector{T}" begin
    # Packed input must be unpacked (materialized into Vector{UInt64} segments),
    # so primitive lists cannot be views over the original packed bytes. They
    # ARE still zero-copy views of the materialized segment words (a
    # ReinterpretArray over the segment's Vector{UInt64}), so the return type
    # is an AbstractVector{T}-view, not a Vector{T}. This is the best we can
    # do for packed input -- the per-element decode loop is avoided, but the
    # segment words are materialized by the unpacker.
    sf = parse_schema("@0x77; struct S { xs @0 :List(Float32); }")
    val = (xs=Float32[1.0f0, 2.0f0, 3.0f0],)
    pbytes = build_message(val, sf, "S"; packed=true)
    out = parse_message(pbytes, sf, "S"; packed=true)
    @test typeof(out.xs) <: AbstractVector{Float32}
    @test out.xs == val.xs

    # Packed stream via parse_messages.
    stream = vcat(pbytes, pbytes)
    msgs = collect(parse_messages(stream, sf, "S"; packed=true))
    @test length(msgs) == 2
    for m in msgs
        @test typeof(m.xs) <: AbstractVector{Float32}
        @test m.xs == val.xs
    end
end

@testset "MmapMessageReader handles multi-segment messages" begin
    # A multi-segment message (with a far pointer to seg1) decoded via the
    # mmap-backed reader: the far pointer resolves across segments, and the
    # primitive list in seg1 is a zero-copy view of the mmap'd seg1 bytes.
    sf = parse_schema("""
    @0x77;
    struct Inner { a @0 :Int32; b @1 :List(Float32); }
    struct Outer { name @0 :Text; inner @1 :Inner; }
    """)
    bytes, seg1_bytes = build_two_segment_hit("hi", 7, Float32[i for i in 0:99])
    out = parse_message(bytes, sf, "Outer"; packed=false)
    @test out.name == "hi"
    @test out.inner.a == 7
    @test typeof(out.inner.b) <: AbstractVector{Float32}
    @test out.inner.b == Float32[Float32(i) for i in 0:99]

    # nsegments of the MmapMessageReader is 2 (seg0 + seg1).
    mr, _ = read_message_mmap(bytes)
    @test CapnProto.nsegments(mr) == 2
    # The segment bodies do NOT sum to length(bytes) -- the segment table
    # (with padding) sits between the start of `bytes` and seg0, and there
    # is no inter-segment gap (seg1 immediately follows seg0). The total
    # segment body bytes plus the table bytes equals length(bytes).
    body_bytes = (CapnProto.segment_words(mr, 0) + CapnProto.segment_words(mr, 1)) * 8
    table_bytes = length(bytes) - body_bytes
    @test table_bytes > 0
    @test table_bytes % 8 == 0  # table is padded to a word boundary
    # _segment_bytes returns distinct views for each segment.
    sb0 = CapnProto._segment_bytes(mr, 0)
    sb1 = CapnProto._segment_bytes(mr, 1)
    @test length(sb0) == CapnProto.segment_words(mr, 0) * 8
    @test length(sb1) == CapnProto.segment_words(mr, 1) * 8
    @test length(sb0) + length(sb1) == body_bytes
end


