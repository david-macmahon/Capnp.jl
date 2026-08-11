# CapnProto.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://david-macmahon.github.io/CapnProto.jl/dev/)
[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://david-macmahon.github.io/CapnProto.jl/stable/)

A pure Julia package for reading and writing [Cap'n Proto](https://capnproto.org/) messages.

This package supports:
- The [Cap'n Proto binary encoding](https://capnproto.org/encoding.html) (unpacked and packed)
- Multi-segment message building and reading
- Structs, lists (including composite lists), text, data, and far pointers
- A parser for the Cap'n Proto schema language (`.capnp` files)
- Schema-driven typed reading and writing
- Streaming iteration over concatenated messages, with optional field skipping
  (avoid decoding -- and for unpacked streams, avoid reading -- large fields)
- Zero-copy primitive-list reading from memory-mapped files: byte-strideable
  primitive lists (`List(Int8)`/`UInt8`/`Int16`/`UInt16`/`Int32`/`UInt32`/
  `Int64`/`UInt64`/`Float32`/`Float64`) are returned as `reinterpret`-views
  directly over the mmap'd bytes, with no per-element copy

## Status

Early development. The wire format and packed encoding are functional and
roundtrip-tested. The schema parser supports a useful subset of the schema
language: structs, enums, interfaces, constants, nested nodes, unions (with
discriminant), and common field types (primitive, text, data, struct, list).

## Installation

```julia
] add https://github.com/david-macmahon/CapnProto.jl
```

## Quick start

### Schema-driven reading and writing

```julia
using CapnProto

schema = parse_schema("""
@0xab12cd34ef56ef78;
struct Person {
    name @0 :Text;
    age  @1 :Int32;
    emails @2 :List(Text);
}
""")

val = (name="Alice", age=30, emails=["a@x", "b@y"])

# Build and read back a single message.
bytes = build_message(val, schema, "Person")
parse_message(bytes, schema, "Person")
# -> (name="Alice", age=30, emails=["a@x","b@y"])

# Iterate a stream of concatenated messages from a file (memory-mapped).
# `src` may be a filename, a byte vector, or an IO.
for person in parse_messages("people.bin", schema, "Person")
    println(person.name)
end

# Skip a large field while iterating: its bytes are not decoded (and for
# unpacked streams, not read from the file at all).
for person in parse_messages("people.bin", schema, "Person"; skip=["emails"])
    println(person.name)
end
```

The `skip` keyword accepts a collection of dotted, root-relative field paths
(e.g. `["large_array"]`) or a `path -> Bool` predicate, and returns typed
empty values (`Float32[]`, `""`, `UInt8[]`, etc.) for skipped fields.

### Low-level message building

```julia
using CapnProto

# Build a message with a root struct that has 2 data words and 2 pointer slots.
b = MessageBuilder()
root = init_root_struct!(b, 2, 2)
set_int64!(root, 0, 0x0102030405060708)
set_text!(root, 0, "hello")
bytes = write_packed(b)

# Read it back.
r = read_packed(bytes)
root_r = get_root(r)
get_int64(root_r, 0)        # -> 0x0102030405060708
get_text(root_r, 0)         # -> "hello"
```

## License

BSD 2-Clause; see [LICENSE](LICENSE).
