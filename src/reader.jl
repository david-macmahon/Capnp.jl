# reader.jl - struct/list readers and getters.
#
# Mirrors builder.jl but read-only. Resolves struct/list/far pointers.

"""
    StructReader

A read-only view of a struct within a `MessageReader` (or
`MmapMessageReader`). Located by segment id and the word index of the start
of the struct's data section. Parameterized by the underlying message type
so a `StructReader` over an mmap-backed message retains a reference to the
mmap'd bytes.
"""
struct StructReader{M}
    msg::M
    seg::Int
    base::Int          # word index of the first data word
    data_words::Int
    ptr_count::Int
    StructReader(msg::M, seg::Integer, base::Integer, data_words::Integer, ptr_count::Integer) where M =
        new{M}(msg, Int(seg), Int(base), Int(data_words), Int(ptr_count))
end

"""
    ListReader

A read-only view of a list within a `MessageReader` (or `MmapMessageReader`).
For composite lists, `base` points at the tag word and elements start at
`base + 1`. Parameterized by the underlying message type so a `ListReader`
over an mmap-backed message retains a reference to the mmap'd bytes.
"""
struct ListReader{M}
    msg::M
    seg::Int
    base::Int          # word index of the first body word (for composite: the tag word)
    element_size::UInt64
    element_count::Int
    elem_data_words::Int
    elem_ptr_count::Int
    ListReader(msg::M, seg::Integer, base::Integer, element_size::Integer,
               element_count::Integer, elem_data_words::Integer, elem_ptr_count::Integer) where M =
        new{M}(msg, Int(seg), Int(base), UInt64(element_size), Int(element_count),
               Int(elem_data_words), Int(elem_ptr_count))
end

# ----- Root and pointer resolution ---------------------------------------------

"Resolve a pointer word located at `seg`,`word_idx`. Returns a resolved pointee.
The return is either a StructReader, ListReader, or `nothing` if the pointer is null."
function resolve_pointer(msg, seg::Int, word_idx::Int)
    p = get_word(msg, seg, word_idx)
    if p == 0
        return nothing
    end
    return resolve_pointer_value(msg, seg, word_idx, p)
end

function resolve_pointer_value(msg, seg::Int, word_idx::Int, p::UInt64)
    t = pointer_type(p)
    if t == STRUCT_POINTER
        off = pointer_offset(p)
        base = word_idx + 1 + off
        return StructReader(msg, seg, base, struct_data_words(p), struct_ptr_count(p))
    elseif t == LIST_POINTER
        off = pointer_offset(p)
        base = word_idx + 1 + off
        esize = list_element_size(p)
        if esize == COMPOSITE_LIST
            # The list pointer's D field is the body word count EXCLUDING the
            # tag word. The tag word is a struct pointer whose offset field
            # holds the element count.
            tag = get_word(msg, seg, base)
            elem_count = Int(pointer_offset(tag))
            data_words = struct_data_words(tag)
            ptr_count = struct_ptr_count(tag)
            return ListReader(msg, seg, base, COMPOSITE_LIST,
                              elem_count, data_words, ptr_count)
        end
        return ListReader(msg, seg, base, esize, list_element_count(p), 0, 0)
    elseif t == FAR_POINTER
        return resolve_far(msg, p)
    else
        error("unknown pointer type $t")
    end
end

function resolve_far(msg, p::UInt64)
    target_seg = Int(far_segment_id(p))  # 0-based
    target_off = Int(far_offset(p))      # 0-based word index
    if far_is_double(p)
        # Two-word landing pad: [far ptr][struct/list ptr]
        _seg_has_word(msg, target_seg, target_off + 1) || return nothing
        real_ptr = get_word(msg, target_seg, target_off + 1)
        return resolve_pointer_value(msg, target_seg, target_off + 1, real_ptr)
    else
        _seg_has_word(msg, target_seg, target_off) || return nothing
        landing = get_word(msg, target_seg, target_off)
        return resolve_pointer_value(msg, target_seg, target_off, landing)
    end
end

"Is word `i` (0-based) present in segment `seg` (0-based)? A segment that was
skipped during reading (see `parse_messages` with `skip=...`) is empty, so far
pointers into it are treated as null."
@inline _seg_has_word(msg, seg::Int, i::Int) =
    0 <= seg < nsegments(msg) && 0 <= i < segment_words(msg, seg)

"""
    get_root(mr)::StructReader

Get the root struct of a message. Works with any message type whose accessors
`get_word`, `nsegments`, and `segment_words` are defined (i.e. both
[`MessageReader`](@ref) and [`MmapMessageReader`](@ref)).
"""
function get_root(mr)::StructReader
    p = get_word(mr, 0, 0)
    if pointer_type(p) == STRUCT_POINTER
        off = pointer_offset(p)
        return StructReader(mr, 0, 1 + off, struct_data_words(p), struct_ptr_count(p))
    end
    # If the root is a list or far, resolve and adapt.
    r = resolve_pointer(mr, 0, 0)
    r isa StructReader && return r
    error("root is not a struct")
end

# ----- Primitive getters -------------------------------------------------------
#
# The data-word getters (`get_word_field`, `get_subword`, `get_bool`, and the
# typed `get_int*`/`get_uint*`/`get_float*` wrappers) read fields from the
# struct's data section. Per the Cap'n Proto wire spec, a data word beyond the
# struct's declared data section (an absent high-offset field, e.g. written by
# an older schema that lacked the field) reads as zero. The getters therefore
# return zero / `false` for out-of-range word indices rather than throwing.

function get_word_field(s::StructReader, word::Int)::UInt64
    0 <= word < s.data_words || return UInt64(0)
    return get_word(s.msg, s.seg, s.base + word)
end

"""
    get_int8(s::StructReader, word::Int, byte::Int)

Read an `Int8` field at byte `byte` (0-7) of data word `word` (0-based).
"""
get_int8(s::StructReader, word::Int, byte::Int) =
    Int8(reinterpret(Int8, UInt8(get_subword(s, word, byte, 8))))
"""
    get_uint8(s::StructReader, word::Int, byte::Int)

Read a `UInt8` field at byte `byte` (0-7) of data word `word` (0-based).
"""
get_uint8(s::StructReader, word::Int, byte::Int) =
    UInt8(get_subword(s, word, byte, 8))
"""
    get_int16(s::StructReader, word::Int)

Read an `Int16` field from the low 16 bits of data word `word` (0-based).
"""
get_int16(s::StructReader, word::Int) =
    Int16(reinterpret(Int16, UInt16(get_subword(s, word, 0, 16))))
"""
    get_uint16(s::StructReader, word::Int)

Read a `UInt16` field from the low 16 bits of data word `word` (0-based).
"""
get_uint16(s::StructReader, word::Int) =
    UInt16(get_subword(s, word, 0, 16))
"""
    get_int32(s::StructReader, word::Int)

Read an `Int32` field from the low 32 bits of data word `word` (0-based).
"""
get_int32(s::StructReader, word::Int) =
    Int32(reinterpret(Int32, UInt32(get_subword(s, word, 0, 32))))
"""
    get_uint32(s::StructReader, word::Int)

Read a `UInt32` field from the low 32 bits of data word `word` (0-based).
"""
get_uint32(s::StructReader, word::Int) =
    UInt32(get_subword(s, word, 0, 32))
"""
    get_int64(s::StructReader, word::Int)

Read an `Int64` field occupying all of data word `word` (0-based).
"""
get_int64(s::StructReader, word::Int) = Int64(reinterpret(Int64, get_word_field(s, word)))
"""
    get_uint64(s::StructReader, word::Int)

Read a `UInt64` field occupying all of data word `word` (0-based).
"""
get_uint64(s::StructReader, word::Int) = UInt64(get_word_field(s, word))
"""
    get_float32(s::StructReader, word::Int)

Read a `Float32` field from the low 32 bits of data word `word` (0-based).
"""
get_float32(s::StructReader, word::Int) =
    Float32(reinterpret(Float32, UInt32(get_subword(s, word, 0, 32))))
"""
    get_float64(s::StructReader, word::Int)

Read a `Float64` field occupying all of data word `word` (0-based).
"""
get_float64(s::StructReader, word::Int) =
    Float64(reinterpret(Float64, get_word_field(s, word)))

"""
    get_bool(s::StructReader, word::Int, bit::Int)::Bool

Read a boolean bit at `(word, bit)` (0-based) from the struct's data section.
"""
function get_bool(s::StructReader, word::Int, bit::Int)::Bool
    0 <= word < s.data_words || return false
    w = get_word(s.msg, s.seg, s.base + word)
    return (w >> bit) & 1 == 1
end

function get_subword(s::StructReader, word::Int, byte::Int, bits::Int)::UInt64
    0 <= word < s.data_words || return UInt64(0)
    w = get_word(s.msg, s.seg, s.base + word)
    shift = byte * 8
    mask = (UInt64(1) << bits) - 1
    return (w >> shift) & mask
end

# ----- Field accessors (pointer slots) -----------------------------------------

"""
    get_struct_field(parent::StructReader, p::Int)::Union{StructReader, Nothing}

Get the StructReader for pointer slot `p` of `parent`, or `nothing` if null.

Returns `nothing` if `p` is beyond `parent`'s declared pointer section (an
absent field, e.g. written by an older schema that lacked this field).
"""
function get_struct_field(parent::StructReader, p::Int)::Union{StructReader, Nothing}
    0 <= p < parent.ptr_count || return nothing
    idx = parent.base + parent.data_words + p
    r = resolve_pointer(parent.msg, parent.seg, idx)
    r isa StructReader ? r : nothing
end

"""
    get_list_field(parent::StructReader, p::Int)::Union{ListReader, Nothing}

Get the ListReader for pointer slot `p` of `parent`, or `nothing` if null.

Returns `nothing` if `p` is beyond `parent`'s declared pointer section (an
absent field, e.g. written by an older schema that lacked this field).
"""
function get_list_field(parent::StructReader, p::Int)::Union{ListReader, Nothing}
    0 <= p < parent.ptr_count || return nothing
    idx = parent.base + parent.data_words + p
    r = resolve_pointer(parent.msg, parent.seg, idx)
    r isa ListReader ? r : nothing
end

"""
    get_text(parent::StructReader, p::Int)::Union{String, Nothing}
    get_text(lr::ListReader)::String

Get the text at pointer slot `p`, or `nothing` if null.
"""
function get_text(parent::StructReader, p::Int)::Union{String, Nothing}
    lr = get_list_field(parent, p)
    lr === nothing && return nothing
    return get_text(lr)
end

"""
    get_data(parent::StructReader, p::Int)::Union{Vector{UInt8}, Nothing}
    get_data(lr::ListReader)::Vector{UInt8}

Get the data at pointer slot `p`, or `nothing` if null.
"""
function get_data(parent::StructReader, p::Int)::Union{Vector{UInt8}, Nothing}
    lr = get_list_field(parent, p)
    lr === nothing && return nothing
    return get_data(lr)
end

# ----- Text / data from a ListReader -------------------------------------------

"""
    get_text(lr::ListReader)::String

Read the text held by a `ListReader` (a `List(UInt8)` with a trailing NUL). The
NUL terminator is not included in the returned `String`.
"""
function get_text(lr::ListReader)::String
    @assert lr.element_size == INT8_LIST
    n = lr.element_count
    # The trailing NUL is not part of the string content.
    n > 0 && (n -= 1)
    bytes = Vector{UInt8}(undef, n)
    for i in 1:n
        bytes[i] = get_byte(lr, i - 1)
    end
    return String(bytes)
end

"""
    get_data(lr::ListReader)::Vector{UInt8}

Read the raw bytes held by a `ListReader` (a `List(UInt8)`).
"""
function get_data(lr::ListReader)::Vector{UInt8}
    @assert lr.element_size == INT8_LIST
    n = lr.element_count
    bytes = Vector{UInt8}(undef, n)
    for i in 1:n
        bytes[i] = get_byte(lr, i - 1)
    end
    return bytes
end

"""
    get_byte(lr::ListReader, k::Int)::UInt8

Get byte `k` (0-based) of a byte list.
"""
function get_byte(lr::ListReader, k::Int)::UInt8
    word = lr.base + k ÷ 8
    byte = k % 8
    w = get_word(lr.msg, lr.seg, word)
    return UInt8((w >> (byte * 8)) & 0xff)
end

# ----- List element getters ----------------------------------------------------

"""
    list_length(lr::ListReader)::Int

Number of elements in a list.
"""
list_length(lr::ListReader)::Int = lr.element_count

"""
    _segment_bytes(lr::ListReader)

Internal: the little-endian byte view of the segment containing the list body.
Delegates to the message's [`_segment_bytes`](@ref) trait. Used by the typed
layer's primitive-list fast path to return a zero-copy `reinterpret` view of
a primitive list body directly over the backing storage (mmap or otherwise).
"""
_segment_bytes(lr::ListReader) = _segment_bytes(lr.msg, lr.seg)

"""
    get_element(lr::ListReader, i::Int)::UInt64

Get element `i` (0-based) of a primitive list as a UInt64.
"""
function get_element(lr::ListReader, i::Int)::UInt64
    if lr.element_size == VOID_LIST
        return 0
    elseif lr.element_size == BOOL_LIST
        word = lr.base + i ÷ 64
        bit = i % 64
        return (get_word(lr.msg, lr.seg, word) >> bit) & 1
    elseif lr.element_size == INT8_LIST
        return UInt64(get_byte(lr, i))
    end
    bits = lr.element_size == INT16_LIST ? 16 :
           lr.element_size == INT32_LIST ? 32 :
           lr.element_size == FLOAT32_LIST ? 32 :
           lr.element_size == INT64_LIST ? 64 :
           lr.element_size == FLOAT64_LIST ? 64 : 64
    per = 64 ÷ bits
    word = lr.base + i ÷ per
    byte = (i % per) * (bits ÷ 8)
    w = get_word(lr.msg, lr.seg, word)
    return (w >> (byte * 8)) & ((UInt64(1) << bits) - 1)
end

"""
    get_text_element(lr::ListReader, i::Int)::Union{String, Nothing}

Get element `i` (0-based) of a list of text.
"""
function get_text_element(lr::ListReader, i::Int)::Union{String, Nothing}
    @assert lr.element_size == POINTER_LIST
    ptr_idx = lr.base + i
    r = resolve_pointer(lr.msg, lr.seg, ptr_idx)
    r isa ListReader ? get_text(r) : nothing
end

"""
    list_element_struct(lr::ListReader, i::Int)::StructReader

Get a StructReader for element `i` (0-based) of a composite list.
"""
function list_element_struct(lr::ListReader, i::Int)::StructReader
    @assert lr.element_size == COMPOSITE_LIST
    per = lr.elem_data_words + lr.elem_ptr_count
    base = lr.base + 1 + i * per   # +1 to skip the tag
    return StructReader(lr.msg, lr.seg, base, lr.elem_data_words, lr.elem_ptr_count)
end

"""
    list_element(lr::ListReader, i::Int)

Generic element accessor: returns element `i` of a list as a `UInt64` (for
primitive lists) or a `StructReader` (for composite lists).
"""
function list_element(lr::ListReader, i::Int)
    if lr.element_size == COMPOSITE_LIST
        return list_element_struct(lr, i)
    else
        return get_element(lr, i)
    end
end

"""
    is_null(s::StructReader, p::Int)::Bool

IsNull check on a pointer slot of a struct. Returns `true` for a slot beyond
the struct's declared pointer section (an absent field).
"""
function is_null(s::StructReader, p::Int)::Bool
    0 <= p < s.ptr_count || return true
    idx = s.base + s.data_words + p
    return get_word(s.msg, s.seg, idx) == 0
end
