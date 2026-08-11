```@meta
CurrentModule = CapnProto
```

# Wire Format

Cap'n Proto messages are sequences of 64-bit words. Each message begins with a
*segment table* (the count of segments and each segment's word length), followed
by the segment bodies. The first word of the first segment is a pointer to the
root struct.

This page documents the low-level API exposed by CapnProto.jl. For most
applications the [schema-driven](@ref Schema-Language) API is more convenient,
but the low-level API is useful when you want full control over layout or when
you don't have a schema.

## Messages

```@docs
MessageBuilder
MessageReader
MmapMessageReader
write_message
read_message
read_message_mmap
nsegments
segment_words
alloc_segment!
```

## Builders

A [`StructBuilder`](@ref) locates a struct within a message by segment id and
the word index of its data section. The struct's `data_words` data words come
first, followed by its `ptr_count` pointer slots.

```@docs
StructBuilder
ListBuilder
init_root_struct!
init_root_list!
alloc_struct!
alloc_list!
alloc_composite_list!
```

### Primitive setters

Each setter takes the struct, a 0-based data-word index (and, for 8-bit fields,
a byte offset within the word), and the value. Booleans take a `(word, bit)`
pair.

```@docs
set_int8!
set_int16!
set_int32!
set_int64!
set_uint8!
set_uint16!
set_uint32!
set_uint64!
set_bool!
set_float32!
set_float64!
```

### Text, data, and list element setters

```@docs
set_text!
set_data!
set_element!
set_text_element!
```

## Readers

```@docs
StructReader
ListReader
get_root
get_struct_field
get_list_field
```

### Primitive getters

```@docs
get_int8
get_int16
get_int32
get_int64
get_uint8
get_uint16
get_uint32
get_uint64
get_bool
get_float32
get_float64
```

### Text, data, and list element getters

```@docs
get_text
get_data
get_element
get_text_element
get_byte
list_length
list_element
list_element_struct
```

## Packed encoding

```@docs
write_packed
read_packed
pack
unpack
```

### Auto-detection

[`looks_packed`](@ref) validates a stream's segment table without decoding,
and [`read_message_agnostic`](@ref) uses it to pick the right decoder
automatically for a byte vector. [`ispacked`](@ref) does the same for both
byte vectors and IO streams (peeking and restoring the IO position) and is
what [`parse_messages`](@ref) uses to detect the format of a message stream.
[`parse_message`](@ref) also auto-detects by default.

```@docs
looks_packed
read_message_agnostic
ispacked
```

## Pointer primitives

These are rarely needed directly but are exported for introspection and custom
encoders.

```@docs
struct_pointer
list_pointer
far_pointer
pointer_type
pointer_offset
struct_data_words
struct_ptr_count
list_element_count
list_element_size
far_is_double
far_offset
far_segment_id
element_words
```

## Constants

The list element-size tags used by list pointers and the pointer-type tags:

```@docs
STRUCT_POINTER
LIST_POINTER
FAR_POINTER
VOID_LIST
BOOL_LIST
INT8_LIST
INT16_LIST
INT32_LIST
INT64_LIST
FLOAT32_LIST
FLOAT64_LIST
POINTER_LIST
COMPOSITE_LIST
```

## Null checks

```@docs
is_null
```
