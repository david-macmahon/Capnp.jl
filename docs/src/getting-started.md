```@meta
CurrentModule = CapnProto
```

# Getting Started

## Installation

```julia
] add https://github.com/david-macmahon/CapnProto.jl
```

## A first message: low-level building

The low-level API exposes a [`MessageBuilder`](@ref) onto which you allocate a
root struct with [`init_root_struct!`](@ref). Fields are written with typed
setters such as [`set_int64!`](@ref) and [`set_text!`](@ref).

```julia
using CapnProto

b = MessageBuilder()
root = init_root_struct!(b, 2, 2)        # 2 data words, 2 pointer slots
set_int64!(root, 0, 0x0102030405060708)
set_int32!(root, 1, 0x0a0b0c0d)
set_text!(root, 0, "hello")

bytes = write_packed(b)                  # serialize with the packed encoding
```

Reading flips the direction: parse the bytes into a [`MessageReader`](@ref)
with [`read_packed`](@ref), fetch the root with [`get_root`](@ref), and use the
typed getters.

```julia
r = read_packed(bytes)
root = get_root(r)
get_int64(root, 0)        # -> 0x0102030405060708
get_uint32(root, 1)       # -> 0x0a0b0c0d
get_text(root, 0)         # -> "hello"
```

## Nested structs and lists

Pointer-typed fields are allocated with [`alloc_struct!`](@ref),
[`alloc_list!`](@ref), and [`alloc_composite_list!`](@ref), which return a
builder for the new object and write the pointer into the parent's pointer
section.

```julia
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

bytes = write_message(b)                 # unpacked this time
r, _ = read_message(bytes)
root = get_root(r)
get_int32(root, 0)                       # -> 42
sub_r = get_struct_field(root, 0)
get_int64(sub_r, 0)                      # -> 999
lst_r = get_list_field(root, 1)
[UInt32(get_element(lst_r, i)) for i in 0:3]   # -> UInt32[0, 10, 20, 30]
```

## Schema-driven reading and writing

When you have a schema, you can skip the manual layout and let the package
compute it. Parse a schema string with [`parse_schema`](@ref) and use
[`build_message`](@ref) / [`parse_message`](@ref) (or the lower-level
[`write_struct!`](@ref) / [`read_struct`](@ref)).

```julia
using CapnProto

schema = parse_schema(\"\"\"
@0xab12cd34ef56ef78;
struct Person {
    name   @0 :Text;
    age    @1 :Int32;
    emails @2 :List(Text);
}
\"\"\")

val = (name="Alice", age=30, emails=["a@x.com", "b@y.com"])
bytes = build_message(val, schema, "Person")

out = parse_message(bytes, schema, "Person")
# -> (name = "Alice", age = 30, emails = ["a@x.com", "b@y.com"])
```

## Schema evolution and compatibility

CapnProto.jl follows the Cap'n Proto wire-format rules for forward and backward
compatibility, so a message written with one schema version reads correctly
with another (older or newer) version of the same schema.

**Backward** (old message, new reader): fields the writer did not know about
decode as their declared default (zero if no default was declared). `Text`
yields `""`, `Data` yields `UInt8[]`, list fields yield empty typed vectors,
and struct fields yield an empty struct (each nested field at its own
default/empty).

```julia
old = parse_schema("""
@0x99;
struct S { a @0 :Int64; }
""")
new = parse_schema("""
@0x99;
struct S { a @0 :Int64; b @1 :Int64 = 42; name @2 :Text; }
""")
bytes = build_message((a=Int64(7),), old, "S")
out = parse_message(bytes, new, "S")
# -> (a = 7, b = 42, name = "")
```

**Forward** (new message, old reader): fields the reader's schema does not
know about are silently ignored -- the old reader sees only its own fields.

```julia
bytes = build_message((a=Int64(7), b=Int64(8), name="hi"), new, "S")
out = parse_message(bytes, old, "S")
# -> (a = 7,)   # b and name are not surfaced
```

The same rules apply to nested structs and to the elements of composite
lists: the per-element data/pointer word counts come from the message's tag
word, so extra element words are ignored and missing element words yield
defaults.

## Files and streams

The schema-driven API also handles files containing many concatenated messages
of the same type. [`build_message`](@ref) produces one message's bytes; concatenate
them and write the result. [`parse_messages`](@ref) iterates a file or stream
lazily, one message at a time, and [`parse_message`](@ref) with `pos` reads a
single message at a known byte offset.

### Writing a vector of structs to a file

```julia
people = [
    (name="Alice", age=30, emails=["a@x.com", "b@y.com"]),
    (name="Bob",   age=25, emails=["bob@x.com"]),
    (name="Carol", age=41, emails=["carol@x.com", "c2@x.com", "c3@x.com"]),
]
# Serialize each as an unpacked message and concatenate them.
stream = reduce(vcat, [build_message(p, schema, "Person"; packed=false) for p in people])
write("people.bin", stream)
```

For large vectors, avoid building the whole concatenated byte vector in memory
by writing each message directly to the file:

```julia
open("people.bin", "w") do io
    for p in people
        write(io, build_message(p, schema, "Person"; packed=false))
    end
end
```

### Iterating through the structs in a file

[`parse_messages`](@ref) reads lazily from an `IO`, a byte vector, or a
filename. A filename is memory-mapped (via `Mmap.mmap`), so the file is paged in
on demand as the iterator reads rather than loaded up front; the whole file is
never held in memory:

```julia
for person in parse_messages("people.bin", schema, "Person"; packed=false)
    println(person.name, " is ", person.age, " (", length(person.emails), " emails)")
end
# Alice is 30 (2 emails)
# Bob is 25 (1 emails)
# Carol is 41 (3 emails)
```

The encoding is auto-detected from the first message; pass `packed=true` or
`packed=false` to force it. The decision is then applied to every message in
the stream.

### Zero-copy primitive lists from mmap'd files

When a stream is unpacked and the source is a byte vector or memory-mapped
file, [`parse_message`](@ref) and [`parse_messages`](@ref) read each message
into an [`MmapMessageReader`](@ref) whose segment bodies are zero-copy views
of the backing bytes. As a result, byte-strideable primitive lists
(`List(Int8)`/`UInt8`/`Int16`/`UInt16`/`Int32`/`UInt32`/`Int64`/`UInt64`/
`Float32`/`Float64`) are returned as `reinterpret`-views directly over the
mmap'd region -- no per-element copy is made and the OS pages the data in on
demand. The decoded value is an `AbstractVector{T}` (specifically a
`Base.ReinterpretArray`), not a `Vector{T}`:

```julia
schema = parse_schema(\"\"\"
@0x77;
struct Spectrum { data @0 :List(Float32); }
\"\"\")
bytes = build_message((data=Float32[1f0, 2f0, 3f0, 4f0],), schema, "Spectrum"; packed=false)

out = parse_message(bytes, schema, "Spectrum"; packed=false)
out.data isa AbstractVector{Float32}   # true
out.data isa Vector{Float32}           # false -- it is a zero-copy view
out.data == Float32[1, 2, 3, 4]        # true
```

This is the fastest way to read large primitive arrays from a Cap'n Proto
file: the array is not copied, and bytes the reader does not touch (e.g.
segments containing only skipped fields) are never paged in by the OS.

`Void` and `Bool` lists (not byte-strideable: `Void` carries no data, `Bool`
is bit-packed at 1 bit/elem) and `Text`/`Data`/struct lists (pointer lists)
are still materialized element-by-element. For packed input the message must
be unpacked (materialized) and so cannot share the mmap-backed
representation; the decoded primitive lists are still `AbstractVector{T}`
views over the materialized segment words, but the segment words themselves
are copied from the packed stream.

### Recording byte offsets while iterating

The default iterator yields only the decoded value. To also get the 0-based
byte offset at which each message began (e.g. to record seek positions for
later replay via [`parse_message`](@ref) with `pos=`), wrap the iterator with
[`with_offsets`](@ref):

```julia
offsets = Int[]
for (off, person) in with_offsets(parse_messages("people.bin", schema, "Person"))
    push!(offsets, off)
    println("message at byte ", off, ": ", person.name)
end
# message at byte 0: Alice
# message at byte 56: Bob
# message at byte 96: Carol

# Re-read just the second record by its recorded offset.
bob = parse_message("people.bin", schema, "Person"; pos=offsets[2])
```

The offset matches the `pos` keyword of [`parse_message`](@ref). The
underlying IO must support `position` (an `IOBuffer`, file stream, or the
memory-mapped wrapper used by `parse_messages` over a filename all do).

### Skipping fields

When iterating a stream, you can skip decoding one or more fields with the
`skip` keyword. Skipped fields yield typed empty values (`Float32[]`, `""`,
`UInt8[]`, etc.) instead of their full contents. For unpacked streams the
segments holding only skipped data are seeked past entirely -- their bytes are
never read from the file. For packed streams those segments are decoded-and-
discarded (the packed encoding is variable-length, so the bytes are read but
not retained).

`skip` accepts a collection of dotted, root-relative field paths or a
`path -> Bool` predicate:

```julia
# Skip the emails field of every person.
for person in parse_messages("people.bin", schema, "Person"; skip=["emails"])
    println(person.name, " has ", length(person.emails), " emails")
end
# Alice has 0 emails
# Bob has 0 emails
# Carol has 0 emails

# Equivalent predicate form.
for person in parse_messages("people.bin", schema, "Person";
                             skip = p -> p == "emails")
    println(person.name)
end
```

### Parsing a struct from the file at a given offset

Each `build_message` call produces one self-delimited message, so you can
record byte offsets as you write and later read individual records without
scanning the whole file. `pos` is a 0-based byte offset, matching the
convention of `position` and `seek`.

```julia
# Record the byte offset of each record as we write.
offsets = Int[]
buf = IOBuffer()
for p in people
    push!(offsets, position(buf))            # 0-based offset of this message
    write(buf, build_message(p, schema, "Person"; packed=false))
end
stream = take!(buf)
write("people.bin", stream)

# Read just the second record from the file, by its offset.
bob = parse_message("people.bin", schema, "Person"; pos=offsets[2], packed=false)
# -> (name = "Bob", age = 25, emails = ["bob@x.com"])
```

See the [Wire Format](@ref) and [Schema Language](@ref) pages for the full
low-level and schema-driven APIs.
