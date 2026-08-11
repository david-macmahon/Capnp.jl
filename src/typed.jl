# typed.jl - schema-driven reading and writing.
#
# `write_struct!` and `read_struct` take a `SchemaFile` and a `StructNode` (plus
# a Julia value, for writing) and serialize/deserialize it. The `SchemaFile` is
# threaded through every internal helper so nested struct nodes can be resolved
# by name without any shared/global state. Field names in the Julia value are
# matched to schema field names case-sensitively.

# ----- Writing -----------------------------------------------------------------

"""
    write_struct!(s::StructBuilder, sf::SchemaFile, node::StructNode, x)

Write a Julia value `x` into the StructBuilder `s` according to schema `node`,
resolving nested struct nodes through `sf`. `x` may be a NamedTuple or an
AbstractDict keyed by field name (as Symbol or String).
"""
function write_struct!(s::StructBuilder, sf::SchemaFile, node::StructNode, x)
    for f in node.fields
        name = f.name
        val = lookup_field(x, name)
        if val === nothing
            continue  # leave default / unset
        end
        write_field!(s, sf, f, val)
    end
    return nothing
end

function lookup_field(x, name::AbstractString)
    if x isa NamedTuple
        sym = Symbol(name)
        return hasfield(typeof(x), sym) ? getfield(x, sym) : nothing
    elseif x isa AbstractDict
        return haskey(x, Symbol(name)) ? x[Symbol(name)] :
               haskey(x, name) ? x[name] : nothing
    else
        sym = Symbol(name)
        return hasproperty(x, sym) ? getproperty(x, sym) : nothing
    end
end

function write_field!(s::StructBuilder, sf::SchemaFile, f::StructField, val)
    ty = f.type
    if ty.kind == :primitive
        return write_primitive!(s, f, ty.primitive, val)
    elseif ty.kind == :list
        return write_list_field!(s, sf, f, ty.element[], val)
    elseif ty.kind == :struct
        return write_struct_field!(s, sf, f, ty.type_name, val)
    else
        error("unsupported field type kind $(ty.kind) for field $(f.name)")
    end
end

function write_primitive!(s::StructBuilder, f::StructField, prim::PrimitiveType, val)
    if prim == PT_Void
        return nothing
    elseif prim == PT_Bool
        return set_bool!(s, f.data_word, f.data_bit, Bool(val))
    elseif prim in (PT_Int8, PT_UInt8)
        return set_subword!(s, f.data_word, f.data_byte, 8, val % UInt8 % UInt64)
    elseif prim in (PT_Int16, PT_UInt16)
        w = f.data_word
        shift = f.data_byte * 8
        cur = get_word(s.msg, s.seg, s.base + w)
        mask = UInt64(0xffff) << shift
        v = val % UInt16 % UInt64
        set_word_field!(s, w, (cur & ~mask) | ((v << shift) & mask))
        return nothing
    elseif prim in (PT_Int32, PT_UInt32, PT_Float32)
        v = prim == PT_Float32 ? UInt64(reinterpret(UInt32, Float32(val))) :
            val % UInt32 % UInt64
        shift = f.data_byte * 8
        cur = get_word(s.msg, s.seg, s.base + f.data_word)
        mask = UInt64(0xffffffff) << shift
        set_word_field!(s, f.data_word, (cur & ~mask) | ((v << shift) & mask))
        return nothing
    elseif prim in (PT_Int64, PT_UInt64, PT_Float64)
        v = prim == PT_Float64 ? reinterpret(UInt64, Float64(val)) :
            val % UInt64
        return set_word_field!(s, f.data_word, v)
    elseif prim == PT_Text
        return set_text!(s, f.ptr_slot, String(val))
    elseif prim == PT_Data
        return set_data!(s, f.ptr_slot, Vector{UInt8}(val))
    end
    return nothing
end

function write_list_field!(s::StructBuilder, sf::SchemaFile, f::StructField, elem_type::SchemaType, val)
    items = collect(val)
    n = length(items)
    if elem_type.kind == :primitive
        prim = elem_type.primitive
        if prim in (PT_Text, PT_Data)
            # List(Text) or List(Data): pointer list.
            lb = alloc_list!(s, f.ptr_slot, POINTER_LIST, n)
            for (i, item) in enumerate(items)
                if prim == PT_Text
                    set_text_element!(lb, i - 1, String(item))
                else
                    set_data_element!(lb, i - 1, Vector{UInt8}(item))
                end
            end
            return nothing
        end
        esize = PRIMITIVE_SIZES[prim]
        lb = alloc_list!(s, f.ptr_slot, esize, n)
        for (i, item) in enumerate(items)
            set_element!(lb, i - 1, encode_primitive(prim, item))
        end
        return nothing
    elseif elem_type.kind == :struct
        # Composite list. Resolve the element struct node through `sf` to get
        # its layout, then write each element via write_struct!.
        node = sf[elem_type.type_name]
        lb = alloc_composite_list!(s, f.ptr_slot, n, node.data_words, node.ptr_count)
        for (i, item) in enumerate(items)
            el = list_element_struct(lb, i - 1)
            write_struct!(el, sf, node, item)
        end
        return nothing
    else
        error("unsupported list element kind $(elem_type.kind) for field $(f.name)")
    end
end

"Set element `i` (0-based) of a List(Data) (a pointer list) to raw bytes."
function set_data_element!(lb::ListBuilder, i::Int, data::Vector{UInt8})
    @assert lb.element_size == POINTER_LIST
    ptr_idx = lb.base + i
    fake = StructBuilder(lb.msg, lb.seg, ptr_idx, 0, 1)
    set_data!(fake, 0, data)
    return nothing
end

function write_struct_field!(s::StructBuilder, sf::SchemaFile, f::StructField, type_name::String, val)
    node = sf[type_name]
    sub = alloc_struct!(s, f.ptr_slot, node.data_words, node.ptr_count)
    write_struct!(sub, sf, node, val)
    return nothing
end


"Encode a Julia value as a UInt64 for a primitive list element."
function encode_primitive(prim::PrimitiveType, val)::UInt64
    if prim == PT_Bool
        return Bool(val) ? UInt64(1) : UInt64(0)
    elseif prim in (PT_Int8, PT_UInt8)
        return val % UInt8 % UInt64
    elseif prim in (PT_Int16, PT_UInt16)
        return val % UInt16 % UInt64
    elseif prim in (PT_Int32, PT_UInt32)
        return val % UInt32 % UInt64
    elseif prim == PT_Float32
        return UInt64(reinterpret(UInt32, Float32(val)))
    elseif prim in (PT_Int64, PT_UInt64)
        return val % UInt64
    elseif prim == PT_Float64
        return reinterpret(UInt64, Float64(val))
    else
        return UInt64(0)
    end
end

# ----- Reading -----------------------------------------------------------------

# Field skipping.
#
# `skip` is either `nothing` (read everything), an AbstractSet / iterable of
# dotted path strings (e.g. ["filterbank.data"]), or a predicate `path -> Bool`.
# Paths are root-relative, dotted, and matched case-sensitively to schema field
# names. A skipped field is decoded as a typed empty value:
#   List(T) -> empty Vector{...}, Text -> "", Data -> UInt8[], primitive -> zero.
# At the typed layer (Tier A) the bytes are still read into the MessageReader;
# Tier B (parse_messages over an IO) additionally skips reading the segments that
# contain only skipped data, for both unpacked and packed streams.

"Return true iff `path` is to be skipped according to `skip`."
function _should_skip(skip, path::AbstractString)
    skip === nothing && return false
    if skip isa Function
        return skip(path)
    elseif skip isa AbstractString
        return path == skip
    else
        return path in skip
    end
end

"Build the child path `parent.child` (parent may be empty for the root's direct
fields)."
function _child_path(parent::AbstractString, child::AbstractString)
    isempty(parent) ? String(child) : string(parent, ".", child)
end

"Return true iff `prim` is a byte-strideable primitive whose list encoding
(INT8/INT16/INT32/INT64 list, of which FLOAT32/FLOAT64 are aliases) is a
contiguous little-endian run of `sizeof(T)` bytes per element. Such lists
can be returned as a zero-copy `reinterpret` view over the backing segment
bytes (mmap or otherwise). Void (0 bits/elem) and Bool (1 bit/elem) are NOT
byte-strideable and must be materialized element-by-element."
_byte_strideable(prim::PrimitiveType) =
    prim in (PT_Int8, PT_UInt8, PT_Int16, PT_UInt16,
             PT_Int32, PT_UInt32, PT_Int64, PT_UInt64,
             PT_Float32, PT_Float64)

"Return the container type used for a `List(prim)` field. Byte-strideable
primitives use `AbstractVector{T}` so the typed reader may return a zero-copy
`reinterpret`-view over the backing bytes; non-byte-strideable primitives
(Void, Bool) and pointer lists (Text, Data) use `Vector{T}` since they must
be materialized element-by-element."
_list_container_type(elem_type::SchemaType, sf::SchemaFile) =
    _byte_strideable(elem_type.primitive) ?
        AbstractVector{_julia_type(elem_type, sf)} :
        Vector{_julia_type(elem_type, sf)}

"Return the concrete Julia type a field of schema type `ty` decodes to.
This is the single source of truth shared by `_empty_primitive`,
`_empty_list_value`, `_read_list`, and `Base.eltype(::MessageIterator)`, so
the empty/populated/skipped/absent paths all produce values of the same type.

For a `List(T)` whose element `T` is a byte-strideable primitive
(Int8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Float32/Float64), the
container type is `AbstractVector{T}` -- the typed reader returns a
zero-copy `reinterpret`-view of the segment bytes (mmap-backed or otherwise)
rather than a materialized `Vector{T}`. For Void/Bool/Text/Data/struct
lists the container is the materialized `Vector{...}` as before."
function _julia_type(ty::SchemaType, sf::SchemaFile)
    if ty.kind == :primitive
        prim = ty.primitive
        if prim == PT_Void
            return Nothing
        elseif prim == PT_Bool
            return Bool
        elseif prim == PT_Int8
            return Int8
        elseif prim == PT_Int16
            return Int16
        elseif prim == PT_Int32
            return Int32
        elseif prim == PT_Int64
            return Int64
        elseif prim == PT_UInt8
            return UInt8
        elseif prim == PT_UInt16
            return UInt16
        elseif prim == PT_UInt32
            return UInt32
        elseif prim == PT_UInt64
            return UInt64
        elseif prim == PT_Float32
            return Float32
        elseif prim == PT_Float64
            return Float64
        elseif prim == PT_Text
            return String
        elseif prim == PT_Data
            return Vector{UInt8}
        else
            return Any
        end
    elseif ty.kind == :struct
        return _named_tuple_type(sf[ty.type_name], sf)
    elseif ty.kind == :list
        elem = ty.element[]
        if elem.kind == :primitive && _byte_strideable(elem.primitive)
            return AbstractVector{_julia_type(elem, sf)}
        else
            return Vector{_julia_type(elem, sf)}
        end
    else
        # :enum / :interface are not decoded by the typed layer yet.
        return Any
    end
end

"Build the concrete NamedTuple type for a struct node from its field list.
The element type of each field is `_julia_type` of its schema type.

When all field types are concrete, the result is a concrete
`NamedTuple{names, Tuple{...}}` and all decode paths (populated, null, skip)
produce values `isa` that type. When one or more fields have an abstract
container type (e.g. `AbstractVector{Int32}` for a byte-strideable primitive
list -- the populated path returns a `ReinterpretArray`-view, the null path
returns a `Vector{T}`), the result uses the covariant
`NamedTuple{names, <:Tuple{...}}` form so that both concrete NamedTuple
types are subtypes. `Vector{outer_T}` then stores either concrete type
uniformly, and `collect(parse_messages(...))` returns a `Vector{outer_T}`."
function _named_tuple_type(node::StructNode, sf::SchemaFile)
    nfields = length(node.fields)
    names = ntuple(i -> Symbol(node.fields[i].name), nfields)
    types = ntuple(i -> _julia_type(node.fields[i].type, sf), nfields)
    T = Tuple{types...}
    # If every field type is concrete, return the concrete NamedTuple.
    # Otherwise use the covariant upper-bounded form so different concrete
    # field types (e.g. Vector{T} vs ReinterpretArray{T,...}) are subtypes.
    return _isconcrete_all(types) ? NamedTuple{names, T} :
           NamedTuple{names, <:T}
end

"True iff every type in `types` is a concrete type (not a UnionAll or
abstract type like `AbstractVector{T}`). Used to decide whether
`_named_tuple_type` can return a concrete `NamedTuple{names, T}` or must use
the covariant `NamedTuple{names, <:T}` form so that different concrete field
types (e.g. `Vector{T}` vs `ReinterpretArray{T,...}`) are both subtypes."
_isconcrete_all(types::Tuple) = all(isconcretetype, types)

"Return a typed empty value for a skipped field of the given element SchemaType."
function _empty_value(ty::SchemaType, sf::SchemaFile)
    if ty.kind == :primitive
        return _empty_primitive(ty.primitive)
    elseif ty.kind == :list
        return _empty_list_value(ty.element[], sf)
    elseif ty.kind == :struct
        # A skipped struct field decodes to the same all-defaults NamedTuple
        # as a null/absent struct field, so the type matches the populated
        # case. (Previously this returned an empty `NamedTuple()`, which was
        # type-unstable relative to a populated or null struct field.)
        return _empty_struct_value(sf, ty.type_name)
    else
        return nothing
    end
end

function _empty_list_value(elem_type::SchemaType, sf::SchemaFile)
    return Vector{_julia_type(elem_type, sf)}()
end

function _empty_primitive(prim::PrimitiveType)
    if prim == PT_Void
        return nothing
    elseif prim == PT_Bool
        return false
    elseif prim == PT_Int8
        return Int8(0)
    elseif prim == PT_Int16
        return Int16(0)
    elseif prim == PT_Int32
        return Int32(0)
    elseif prim == PT_Int64
        return Int64(0)
    elseif prim == PT_UInt8
        return UInt8(0)
    elseif prim == PT_UInt16
        return UInt16(0)
    elseif prim == PT_UInt32
        return UInt32(0)
    elseif prim == PT_UInt64
        return UInt64(0)
    elseif prim == PT_Float32
        return 0.0f0
    elseif prim == PT_Float64
        return 0.0
    elseif prim == PT_Text
        return ""
    elseif prim == PT_Data
        return UInt8[]
    end
    return nothing
end

# ----- Tier B: segment-skipping reads ------------------------------------------
#
# When reading from an IO, we can avoid reading (and for unpacked streams even
# seeking past) the segments that hold only the bytes of skipped fields. The
# root struct always lives in segment 0 (the first segment), so we read seg 0
# fully and then classify the remaining segments by walking the root struct's
# pointer fields (and their inline struct descendants) to find:
#   - skip-segs:  segments reached ONLY via skipped field paths
#   - need-segs:  segments reached by some non-skipped field
# A segment is skipped iff it is a skip-seg and NOT a need-seg. If anything is
# uncertain (e.g. a skip path traverses a composite list, or the root pointer
# itself is a far/list pointer), we read everything and let Tier A trim the
# value. This keeps Tier B a pure optimization with a safe fallback.

"Return the segment id a pointer `p` (located in `seg`) ultimately lands in,
or `nothing` if it can't be determined locally (e.g. it points within `seg`).
`seg_used` accumulates segment ids that must be read; far pointers encountered
here are added to `seg_used`."
function _pointer_target_seg(msg::MessageReader, seg::Int, word_idx::Int, p::UInt64,
                             seg_used::Set{Int})
    t = pointer_type(p)
    if t == STRUCT_POINTER || t == LIST_POINTER
        return nothing  # inline in `seg`; no new segment to record
    elseif t == FAR_POINTER
        target_seg = Int(far_segment_id(p))
        push!(seg_used, target_seg)
        return target_seg
    else
        return nothing
    end
end

"Walk the struct `s` (and its inline struct descendants, NOT into composite-list
elements) recording segments reached by each pointer field. `skip` and the
current `path` determine whether a field's target segments are 'needed' or only
'skipped'. Adds needed segment ids to `need` and skipped-only segment ids to
`skip_segs`."
function _classify_segments(s::StructReader, sf::SchemaFile, node::StructNode,
                            path::AbstractString, skip,
                            need::Set{Int}, skip_segs::Set{Int})
    for f in node.fields
        fpath = _child_path(path, f.name)
        ty = f.type
        # Only pointer-bearing fields can reach other segments.
        if ty.kind == :primitive
            continue
        elseif ty.kind == :list
            _classify_list_field(s, sf, f, ty.element[], fpath, skip, need, skip_segs)
        elseif ty.kind == :struct
            _classify_struct_field(s, sf, f, ty.type_name, fpath, skip, need, skip_segs)
        end
    end
end

"Classify a List field's target segment(s). The whole list body lives in one
segment (the segment of its pointer's far target, or the parent's segment if
inline). If the field itself is skipped, that segment is skip-only; otherwise
it is needed (we don't descend into the elements' contents here -- a composite
list's element structs are inline within the list body, so they share the list's
segment classification)."
function _classify_list_field(s::StructReader, sf::SchemaFile, f::StructField, elem_type::SchemaType,
                              path::AbstractString, skip,
                              need::Set{Int}, skip_segs::Set{Int})
    # An absent pointer slot (beyond the struct's pointer section) is null.
    0 <= f.ptr_slot < s.ptr_count || return
    idx = s.base + s.data_words + f.ptr_slot
    p = get_word(s.msg, s.seg, idx)
    p == 0 && return  # null pointer, no segment
    if _should_skip(skip, path)
        union!(skip_segs, _far_target_segs(s.msg, s.seg, idx, p))
    else
        union!(need, _far_target_segs(s.msg, s.seg, idx, p))
    end
end

"Classify a nested struct field. If the field is skipped, its target segment
(if any) is skip-only; otherwise we recurse into the inline struct to classify
ITS fields' targets (and add the struct's own far target to `need`)."
function _classify_struct_field(s::StructReader, sf::SchemaFile, f::StructField, type_name::String,
                                path::AbstractString, skip,
                                need::Set{Int}, skip_segs::Set{Int})
    # An absent pointer slot (beyond the struct's pointer section) is null.
    0 <= f.ptr_slot < s.ptr_count || return
    idx = s.base + s.data_words + f.ptr_slot
    p = get_word(s.msg, s.seg, idx)
    p == 0 && return
    if _should_skip(skip, path)
        union!(skip_segs, _far_target_segs(s.msg, s.seg, idx, p))
        return
    end
    # The struct is needed: its far-target segment (if any) is needed, and we
    # recurse into it to classify its children.
    tsegs = _far_target_segs(s.msg, s.seg, idx, p)
    union!(need, tsegs)
    sub = get_struct_field(s, f.ptr_slot)
    sub === nothing && return
    node = sf[type_name]
    _classify_segments(sub, sf, node, path, skip, need, skip_segs)
end

"Return the set of segment ids reached (transitively through far landing pads)
by the pointer at `seg`,`word_idx` whose raw word is `p`. For an inline
struct/list pointer this is empty (the pointee shares the parent's segment).
For a far pointer it is `{target_seg}` plus whatever the landing pad points at
(if the landing pad itself is a far pointer)."
function _far_target_segs(msg::MessageReader, seg::Int, word_idx::Int, p::UInt64)::Set{Int}
    out = Set{Int}()
    _collect_far_targets!(out, msg, seg, word_idx, p)
    return out
end

function _collect_far_targets!(out::Set{Int}, msg::MessageReader, seg::Int, word_idx::Int, p::UInt64)
    t = pointer_type(p)
    if t == STRUCT_POINTER || t == LIST_POINTER
        return  # inline; no far target
    elseif t == FAR_POINTER
        target_seg = Int(far_segment_id(p))
        target_off = Int(far_offset(p))
        push!(out, target_seg)
        # Follow the landing pad in case IT is itself a far pointer (double-far
        # whose target is yet another segment). For a plain single-far the
        # landing pad is the real struct/list pointer and adds no new segment.
        if 0 <= target_seg < nsegments(msg) && 0 <= target_off < segment_words(msg, target_seg)
            if far_is_double(p)
                if 0 <= target_off + 1 < segment_words(msg, target_seg)
                    real_ptr = get_word(msg, target_seg, target_off + 1)
                    _collect_far_targets!(out, msg, target_seg, target_off + 1, real_ptr)
                end
            else
                landing = get_word(msg, target_seg, target_off)
                _collect_far_targets!(out, msg, target_seg, target_off, landing)
            end
        end
    end
end

"""
    _skip_segments_for(msg_segs::Vector{Int}, sf::SchemaFile, root_name, skip)

Given the per-segment word counts of a message, return a `Set{Int}` of segment
ids (0-based) that may be left empty (not read from the wire) because they are
reached only by skipped field paths. Segment 0 is NEVER skipped (it holds the
root pointer and root struct). Returns an empty set if classification is not
possible (e.g. the root pointer is not a struct pointer in segment 0).

`msg_segs` is the segment word counts of a partially-read message: index 1 is
segment 0, etc. The caller must have read segment 0 already (its words are
needed to walk pointers); the remaining entries may be the declared lengths
even though their bodies haven't been read.
"""
function _skip_segments_for(root_msg::MessageReader, sf::SchemaFile, root_name::AbstractString, skip)
    skip === nothing && return Set{Int}()
    need = Set{Int}([0])
    skip_segs = Set{Int}()
    node = sf.flat[root_name]
    root = get_root(root_msg)
    _classify_segments(root, sf, node, "", skip, need, skip_segs)
    return setdiff(skip_segs, need)
end

"Skip `n` bytes on `io`, seeking if possible, otherwise reading and discarding."
function _skip_bytes(io::IO, n::Int)
    n <= 0 && return
    target = position(io) + n
    try
        seek(io, target)
        return
    catch
        # Non-seekable: read and discard.
    end
    buf = Vector{UInt8}(undef, min(n, 65536))
    remaining = n
    while remaining > 0
        got = readbytes!(io, buf, min(remaining, length(buf)))
        got == 0 && error("_skip_bytes: unexpected EOF skipping $n bytes")
        remaining -= got
    end
end

# ----- Packed skipping reader --------------------------------------------------
#
# A packed message has no per-message length prefix and the body is a variable-
# length packed stream, so we cannot `seek` past a segment by word count. We
# therefore unpack the whole message (as `read_packed_message_io` does), then
# drop the words of skipped segments, retaining them as empty `UInt64[]`. This
# saves the memory of the skipped segments (and the CPU of copying them into
# the MessageReader) at the cost of still reading the packed bytes sequentially.
# The dropping is done inline in `_read_message_io_with_skip`'s packed branch.

# ----- Skip-aware message read (classify + read) -------------------------------
#
# Putting it together: read segment 0 of a message from `io`, classify which
# other segments may be skipped, then read the rest using the appropriate
# skipping reader. For a single message this requires peeking the table, reading
# seg 0, classifying, then reading the remaining segments -- which the streaming
# readers above do in one pass. We implement a unified reader that:
#   1. reads the segment table,
#   2. reads segment 0,
#   3. builds a partial MessageReader to walk pointers and classify,
#   4. reads the remaining segments (skipping some).
#
# For unpacked: we read the table once, then seg 0, then either seek past or
# read each remaining segment.
# For packed: we already have to unpack the whole message to know the segment
# boundaries, so we unpack all and then drop the skipped segments' words.

"""
    _read_message_io_with_skip(io, packed, sf, root_name, skip)

Read one message from `io`, skipping segments that hold only skipped fields.
Returns `(MessageReader, skip_segs)` where `skip_segs` is the set of segment ids
that were left empty, or `(nothing, Set{Int}())` at a clean EOF.
"""
function _read_message_io_with_skip(io::IO, packed::Bool, sf::SchemaFile,
                                    root_name::AbstractString, skip)
    skip === nothing && begin
        mr = packed ? read_packed_message_io(io) : read_message_io(io)
        return mr, Set{Int}()
    end
    if packed
        # Packed: we need the whole message unpacked to know segment boundaries,
        # so we can't avoid reading the bytes. We unpack everything, then drop
        # the skipped segments' words. To know which to drop we first need to
        # classify, which requires segment 0. Strategy: unpack retaining all
        # segments, classify, then build a new MessageReader with skipped segs
        # emptied.
        mr = read_packed_message_io(io)
        mr === nothing && return nothing, Set{Int}()
        skip_segs = _skip_segments_for(mr, sf, root_name, skip)
        if isempty(skip_segs)
            return mr, skip_segs
        end
        new_segs = Vector{Vector{UInt64}}(undef, nsegments(mr))
        for k in 1:nsegments(mr)
            seg_id = k - 1
            new_segs[k] = (seg_id in skip_segs && seg_id != 0) ? UInt64[] : mr.segments[k]
        end
        return MessageReader(new_segs), skip_segs
    else
        # Unpacked: read the table, then seg 0, classify, then read the rest
        # skipping classified segments.
        return _read_unpacked_io_with_skip(io, sf, root_name, skip)
    end
end

"Unpacked variant: reads the table and segment 0, classifies, then reads the
remaining segments (seeking past skipped ones). Throws a `TruncatedMessageError`
on a partial message at EOF; a `CorruptedMessageError` on a corrupt segment
count."
function _read_unpacked_io_with_skip(io::IO, sf::SchemaFile, root_name::AbstractString, skip)
    seg_count_m1 = _read_u32_le_io(io)
    seg_count_m1 === nothing && return nothing, Set{Int}()
    seg_count = Int(seg_count_m1) + 1
    (seg_count == 0 || seg_count > 1 << 20) && throw(CorruptedMessageError("_read_unpacked_io_with_skip: bad segment count $seg_count"))
    lengths = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        v = _read_u32_le_io(io)
        v === nothing && throw(TruncatedMessageError("_read_unpacked_io_with_skip: EOF reading segment lengths"))
        lengths[k] = Int(v)
    end
    table_u32s = 1 + seg_count
    if table_u32s % 2 != 0
        pad = _read_u32_le_io(io)
        pad === nothing && throw(TruncatedMessageError("_read_unpacked_io_with_skip: EOF reading table padding"))
    end
    # Read segment 0 first (always needed).
    seg0 = _read_words_io(io, lengths[1])
    partial = MessageReader([seg0])
    skip_segs = _skip_segments_for(partial, sf, root_name, skip)
    segments = Vector{Vector{UInt64}}(undef, seg_count)
    segments[1] = seg0
    for k in 2:seg_count
        seg_id = k - 1
        n = lengths[k]
        if seg_id in skip_segs
            _skip_bytes(io, n * 8)
            segments[k] = UInt64[]
        else
            segments[k] = _read_words_io(io, n)
        end
    end
    return MessageReader(segments), skip_segs
end

"""
    read_struct(s::StructReader, sf::SchemaFile, node::StructNode; skip=nothing)

Read a Julia NamedTuple from the StructReader `s` according to schema `node`,
resolving nested struct nodes through `sf`.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them instead. It may be:
  - a single dotted, root-relative path string (e.g. `"large_array"`) to skip
    one field;
  - a collection of such path strings (e.g. `["large_array", "other.field"]`)
    to skip multiple; or
  - a predicate `path::String -> Bool` returning `true` for paths to skip.

Paths are matched case-sensitively to schema field names.

Skipped `List(T)` fields yield empty typed vectors (`Float32[]`, etc.), `Text`
yields `""`, `Data` yields `UInt8[]`, and primitives yield zero. The skip
predicate sees the full dotted path from the root struct of this `read_struct`
call (use the `_rooted` variant or `parse_message` with `skip` to get paths
rooted at the message root).

Absent fields (written by an older schema that did not know them) decode the
same way as skipped fields: data primitives yield their declared default (zero
if none was declared), `Text` yields `""`, `Data` yields `UInt8[]`, list
fields yield empty typed vectors, and struct fields yield an empty struct
(all of the nested struct's fields at their own defaults/empty). This makes
`read_struct` backward-compatible: a message written with an older schema
reads correctly under a newer schema, with the newer fields at their
defaults. The converse (a newer message read with an older schema) is also
handled -- fields the older schema does not know are simply not surfaced.

At the typed layer the field's bytes are still present in the `MessageReader`;
`read_struct` merely avoids decoding them. Whether those bytes were actually
read from the wire depends on how the `MessageReader` was produced:
  - From an in-memory byte vector: all bytes are already in memory, so `skip`
    saves decode CPU and the resulting array allocations but not memory or I/O.
  - From a memory-mapped file: skipped segments are never paged in by the OS,
    so `skip` saves both memory and I/O (see [`parse_messages`](@ref)).
  - From an IO stream with a skip-aware reader: skipped segments are not read
    from the IO (see [`parse_messages`](@ref)).
"""
function read_struct(s::StructReader, sf::SchemaFile, node::StructNode; skip=nothing)
    return _read_struct(s, sf, node, "", skip)
end

"Internal: read_struct with an explicit path prefix (root-relative) and skip spec."
function _read_struct(s::StructReader, sf::SchemaFile, node::StructNode, path::AbstractString, skip)
    names = Symbol[]
    values = Any[]
    for f in node.fields
        push!(names, Symbol(f.name))
        push!(values, _read_field(s, sf, f, _child_path(path, f.name), skip))
    end
    return NamedTuple{Tuple(names)}(values)
end

function _read_field(s::StructReader, sf::SchemaFile, f::StructField, path::AbstractString, skip)
    if _should_skip(skip, path)
        return _empty_value(f.type, sf)
    end
    ty = f.type
    if ty.kind == :primitive
        return read_primitive(s, f, ty.primitive)
    elseif ty.kind == :list
        return _read_list_field(s, sf, f, ty.element[], path, skip)
    elseif ty.kind == :struct
        return _read_struct_field(s, sf, f, ty.type_name, path, skip)
    else
        error("unsupported field type kind $(ty.kind) for field $(f.name)")
    end
end

function read_primitive(s::StructReader, f::StructField, prim::PrimitiveType)
    if prim == PT_Void
        return nothing
    elseif prim == PT_Bool
        # Bool's "default" is a single bit; the encoded default word holds it
        # at the field's bit offset, so decode from f.default_value when the
        # data word is absent.
        if f.has_default && !(0 <= f.data_word < s.data_words)
            return ((f.default_value >> f.data_bit) & 1) == 1
        end
        return get_bool(s, f.data_word, f.data_bit)
    elseif prim in (PT_Int8, PT_UInt8, PT_Int16, PT_UInt16,
                    PT_Int32, PT_UInt32, PT_Float32,
                    PT_Int64, PT_UInt64, PT_Float64)
        # Data primitives live in data words. If the field's data word is
        # beyond the struct's declared data section (an older writer without
        # this field), the value reads as the field's declared default (zero
        # when no default was declared). Otherwise read the raw word and
        # decode the sub-word/bits.
        if !(0 <= f.data_word < s.data_words)
            return decode_primitive(prim, f.default_value)
        end
        w = get_word(s.msg, s.seg, s.base + f.data_word)
        shift = f.data_byte * 8
        if prim in (PT_Int8, PT_UInt8)
            v = (w >> shift) & 0xff
            return prim == PT_Int8 ? Int8(reinterpret(Int8, UInt8(v))) : UInt8(v)
        elseif prim in (PT_Int16, PT_UInt16)
            v = (w >> shift) & 0xffff
            return prim == PT_Int16 ? Int16(reinterpret(Int16, UInt16(v))) : UInt16(v)
        elseif prim in (PT_Int32, PT_UInt32, PT_Float32)
            v = (w >> shift) & 0xffffffff
            if prim == PT_Int32
                return Int32(reinterpret(Int32, UInt32(v)))
            elseif prim == PT_UInt32
                return UInt32(v)
            else
                return Float32(reinterpret(Float32, UInt32(v)))
            end
        else  # Int64 / UInt64 / Float64 (occupy the full word)
            if prim == PT_Int64
                return Int64(reinterpret(Int64, w))
            elseif prim == PT_UInt64
                return UInt64(w)
            else
                return Float64(reinterpret(Float64, w))
            end
        end
    elseif prim == PT_Text
        # A null/absent Text pointer reads as the empty string.
        return something(get_text(s, f.ptr_slot), "")
    elseif prim == PT_Data
        # A null/absent Data pointer reads as the empty byte vector.
        return something(get_data(s, f.ptr_slot), UInt8[])
    end
    return nothing
end

function read_list_field(s::StructReader, sf::SchemaFile, f::StructField, elem_type::SchemaType)
    lr = get_list_field(s, f.ptr_slot)
    lr === nothing && return nothing
    return read_list(lr, sf, elem_type)
end

"Internal: read_list_field honoring `skip` for nested struct elements."
function _read_list_field(s::StructReader, sf::SchemaFile, f::StructField, elem_type::SchemaType,
                          path::AbstractString, skip)
    lr = get_list_field(s, f.ptr_slot)
    # A null or absent pointer (slot beyond the struct's pointer section, or a
    # zero pointer) reads as the typed empty list value, per the Cap'n Proto
    # wire spec.
    lr === nothing && return _empty_list_value(elem_type, sf)
    return _read_list(lr, sf, elem_type, path, skip)
end

function read_list(lr::ListReader, sf::SchemaFile, elem_type::SchemaType)
    return _read_list(lr, sf, elem_type, "", nothing)
end

# List reading is split into a thin outer dispatcher (`_read_list`) and
# monomorphic inner methods keyed on the element type. The outer dispatcher
# branches on the runtime `elem_type.kind` / `elem_type.primitive` once per
# list and then delegates to an inner method specialized via `Val(prim)`
# (or directly for text/data/struct lists). Each inner method constructs a
# concrete `Vector{T}` and runs a tight loop with no per-element runtime
# dispatch -- the original polymorphic `out = Vector{T}(undef, n)` with
# `T::Type` produced an abstract container and a Union-typed decode call on
# every element.

function _read_list(lr::ListReader, sf::SchemaFile, elem_type::SchemaType,
                    path::AbstractString, skip)
    n = list_length(lr)
    if elem_type.kind == :primitive
        prim = elem_type.primitive
        prim === PT_Text && return _read_text_list(lr, n)
        prim === PT_Data && return _read_data_list(lr, n)
        return _read_prim_list(lr, n, Val(prim))
    elseif elem_type.kind == :struct
        return _read_struct_list(lr, sf, elem_type.type_name, n, path, skip)
    else
        error("unsupported list element kind $(elem_type.kind)")
    end
end

# ----- Primitive list readers (one method per PrimitiveType) -------------------
#
# Void and Bool lists are not byte-strideable (Void carries no data; Bool is
# bit-packed at 1 bit/elem) and are materialized element-by-element via
# `get_element`.
#
# The byte-strideable primitives (Int8/UInt8/Int16/UInt16/Int32/UInt32/Int64/
# UInt64/Float32/Float64) are returned as a zero-copy `reinterpret`-view of
# the segment's backing bytes (mmap-backed or otherwise). The list body lives
# at byte offset `lr.base * 8` within the segment and is a contiguous run of
# `n * sizeof(T)` little-endian bytes (with the trailing word's unused high
# bytes -- which lie beyond `n * sizeof(T)` -- ignored). `_segment_bytes`
# returns the segment body as an `AbstractVector{UInt8}` view, so the
# resulting `reinterpret(T, @view segbytes[range])` reads directly from the
# backing storage with no per-element copy. On a little-endian host this is
# also a no-op endianness-wise: the wire is little-endian and the host reads
# little-endian, so the reinterpreted values are correct. On a big-endian
# host we fall back to the materialized loop (the bytes would need swapping).

"The byte offset (0-based) of element `i` (0-based) of a primitive list body
within its segment's byte view. For byte-strideable primitives the body is a
contiguous run of `n * elem_bytes` bytes starting at `lr.base * 8`."
@inline _list_body_byte_offset(lr::ListReader, ::Int) = lr.base * 8

"Return a zero-copy `AbstractVector{T}` view of the body of a byte-strideable
primitive list, reinterpreted directly over the segment's backing bytes. `T`
is the concrete Julia element type and `elem_bytes` is `sizeof(T)`. The view
covers exactly `n` elements (NOT the full word-rounded body), so the trailing
word's unused high bytes are excluded."
@inline function _reinterpret_prim_view(lr::ListReader, ::Type{T}, n::Int) where T
    segbytes = _segment_bytes(lr)
    elem_bytes = sizeof(T)
    body_off = _list_body_byte_offset(lr, 0)  # 0-based byte offset within segbytes
    # `segbytes` is 1-based; the body occupies bytes [body_off+1 .. body_off+n*elem_bytes].
    body = @view segbytes[body_off + 1 : body_off + n * elem_bytes]
    return reinterpret(T, body)
end

function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Void})
    out = Vector{Nothing}(undef, n)
    for i in 1:n
        out[i] = nothing
    end
    return out
end

function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Bool})
    out = Vector{Bool}(undef, n)
    for i in 1:n
        out[i] = get_element(lr, i - 1) != 0
    end
    return out
end

# On a little-endian host, return a zero-copy `reinterpret`-view of the list
# body directly over the backing bytes (mmap or otherwise). On a big-endian
# host the wire bytes (little-endian) would need swapping per element, so we
# fall back to the materialized per-element loop using `get_element`.
if ENDIAN_BOM == 0x04030201  # little-endian host
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int8})    = _reinterpret_prim_view(lr, Int8, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt8})   = _reinterpret_prim_view(lr, UInt8, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int16})   = _reinterpret_prim_view(lr, Int16, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt16})  = _reinterpret_prim_view(lr, UInt16, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int32})   = _reinterpret_prim_view(lr, Int32, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt32})  = _reinterpret_prim_view(lr, UInt32, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int64})   = _reinterpret_prim_view(lr, Int64, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt64})  = _reinterpret_prim_view(lr, UInt64, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Float32}) = _reinterpret_prim_view(lr, Float32, n)
    _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Float64}) = _reinterpret_prim_view(lr, Float64, n)
else  # big-endian host: fall back to per-element decode (bytes need swapping)
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int8})
        out = Vector{Int8}(undef, n)
        for i in 1:n; out[i] = reinterpret(Int8, UInt8(get_element(lr, i - 1))); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt8})
        out = Vector{UInt8}(undef, n)
        for i in 1:n; out[i] = UInt8(get_element(lr, i - 1)); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int16})
        out = Vector{Int16}(undef, n)
        for i in 1:n; out[i] = reinterpret(Int16, UInt16(get_element(lr, i - 1))); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt16})
        out = Vector{UInt16}(undef, n)
        for i in 1:n; out[i] = UInt16(get_element(lr, i - 1)); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int32})
        out = Vector{Int32}(undef, n)
        for i in 1:n; out[i] = reinterpret(Int32, UInt32(get_element(lr, i - 1))); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt32})
        out = Vector{UInt32}(undef, n)
        for i in 1:n; out[i] = UInt32(get_element(lr, i - 1)); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Int64})
        out = Vector{Int64}(undef, n)
        for i in 1:n; out[i] = reinterpret(Int64, get_element(lr, i - 1)); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_UInt64})
        out = Vector{UInt64}(undef, n)
        for i in 1:n; out[i] = get_element(lr, i - 1); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Float32})
        out = Vector{Float32}(undef, n)
        for i in 1:n; out[i] = reinterpret(Float32, UInt32(get_element(lr, i - 1))); end
        return out
    end
    function _read_prim_list(lr::ListReader, n::Int, ::Val{PT_Float64})
        out = Vector{Float64}(undef, n)
        for i in 1:n; out[i] = reinterpret(Float64, get_element(lr, i - 1)); end
        return out
    end
end

# Fallback so a future-added primitive (or a Text/Data Val sneaking in) errors
# cleanly instead of no-method. (PrimitiveType is a Julia @enum, so its values
# are instances of PrimitiveType, not subtypes; `::Val` catches any Val.)
_read_prim_list(lr::ListReader, n::Int, ::Val) =
    error("unsupported primitive list element type")

# ----- Text / Data list readers ------------------------------------------------

function _read_text_list(lr::ListReader, n::Int)
    out = Vector{String}(undef, n)
    for i in 1:n
        out[i] = something(get_text_element(lr, i - 1), "")
    end
    return out
end

function _read_data_list(lr::ListReader, n::Int)
    out = Vector{Vector{UInt8}}(undef, n)
    for i in 1:n
        out[i] = something(get_data_element(lr, i - 1), UInt8[])
    end
    return out
end

# ----- Struct list reader ------------------------------------------------------

function _read_struct_list(lr::ListReader, sf::SchemaFile, type_name::AbstractString,
                           n::Int, path::AbstractString, skip)
    node = sf[type_name]::StructNode
    T = _named_tuple_type(node, sf)
    out = Vector{T}(undef, n)
    # For composite-list elements, the per-element path is `path.<index>`.
    # We don't expose indices in skip paths (they would be unwieldy and the
    # whole list is usually skipped); instead we recurse into each element
    # with the bare `path` so that fields *inside* each element can be
    # skipped uniformly across all elements (e.g. "myobjs.myfield" skips the
    # "myfield" field of every element of the list "myobjs").
    for i in 1:n
        out[i] = _read_struct(list_element_struct(lr, i - 1), sf, node, path, skip)
    end
    return out
end

function decode_primitive(prim::PrimitiveType, v::UInt64)
    if prim == PT_Bool
        return v != 0
    elseif prim in (PT_Int8, PT_UInt8)
        return prim == PT_Int8 ? Int8(reinterpret(Int8, UInt8(v))) : UInt8(v)
    elseif prim in (PT_Int16, PT_UInt16)
        return prim == PT_Int16 ? Int16(reinterpret(Int16, UInt16(v))) : UInt16(v)
    elseif prim in (PT_Int32, PT_UInt32)
        return prim == PT_Int32 ? Int32(reinterpret(Int32, UInt32(v))) : UInt32(v)
    elseif prim == PT_Float32
        return Float32(reinterpret(Float32, UInt32(v)))
    elseif prim in (PT_Int64, PT_UInt64)
        return prim == PT_Int64 ? Int64(reinterpret(Int64, v)) : UInt64(v)
    elseif prim == PT_Float64
        return Float64(reinterpret(Float64, v))
    else
        return nothing
    end
end

function get_data_element(lr::ListReader, i::Int)
    @assert lr.element_size == POINTER_LIST
    ptr_idx = lr.base + i
    r = resolve_pointer(lr.msg, lr.seg, ptr_idx)
    r isa ListReader ? get_data(r) : nothing
end

function read_struct_field(s::StructReader, sf::SchemaFile, f::StructField, type_name::String)
    sub = get_struct_field(s, f.ptr_slot)
    sub === nothing && return nothing
    node = sf[type_name]
    return read_struct(sub, sf, node)
end

"Internal: read_struct_field honoring `skip` for nested fields."
function _read_struct_field(s::StructReader, sf::SchemaFile, f::StructField, type_name::String,
                            path::AbstractString, skip)
    sub = get_struct_field(s, f.ptr_slot)
    # A null or absent pointer reads as an empty struct (all fields empty),
    # per the Cap'n Proto wire spec.
    sub === nothing && return _empty_struct_value(sf, type_name)
    node = sf[type_name]
    return _read_struct(sub, sf, node, path, skip)
end

"Return a typed empty value for an absent nested struct field. Decodes an
empty struct (all fields at their defaults/empty) by recursively reading an
empty StructReader of the right layout."
function _empty_struct_value(sf::SchemaFile, type_name::AbstractString)
    node = sf[type_name]
    # Build a zero-initialized segment of the right size and read it. This
    # yields each field's default/empty value uniformly without special-
    # casing primitive vs pointer fields.
    seg = zeros(UInt64, node.data_words + node.ptr_count)
    mr = MessageReader([seg])
    return _read_struct(StructReader(mr, 0, 0, node.data_words, node.ptr_count),
                        sf, node, "", nothing)
end

# ----- Convenience: build a whole message from a schema ------------------------

"""
    build_message(x, sf::SchemaFile, node_name::AbstractString; packed::Bool=false)::Vector{UInt8}

Build a message whose root is the struct node `node_name` of `sf`, filled with
value `x`. By default the output is in the unpacked stream format; pass
`packed=true` for the packed encoding.
"""
function build_message(x, sf::SchemaFile, node_name::AbstractString; packed::Bool=false)::Vector{UInt8}
    node = sf.flat[node_name]
    b = MessageBuilder()
    root = init_root_struct!(b, node.data_words, node.ptr_count)
    write_struct!(root, sf, node, x)
    return packed ? write_packed(b) : write_message(b)
end

"""
    parse_message(bytes::Vector{UInt8}, sf::SchemaFile, node_name::AbstractString; packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)

Parse a message whose root is the struct node `node_name` of `sf` from a byte
vector. The encoding is auto-detected at `pos` via [`looks_packed`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins (default 0), matching the
convention of `position`/`seek`.

For unpacked input the message is read into an [`MmapMessageReader`](@ref)
whose segment bodies are zero-copy views of `bytes`, so byte-strideable
primitive lists (`List(Int8)`/`UInt8`/`Int16`/`UInt16`/`Int32`/`UInt32`/
`Int64`/`UInt64`/`Float32`/`Float64`) are returned as `reinterpret`-views
directly over `bytes` -- no per-element copy is made. For packed input the
message must be unpacked (materialized) and so cannot share the mmap-backed
representation; the decoded primitive lists are `Vector{T}`.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them; see [`read_struct`](@ref). When reading from a byte vector the
field's bytes are already in memory, so `skip` saves decode CPU and the
resulting array allocations but not I/O or memory. For I/O and memory savings,
read from a filename (memory-mapped) via `parse_message(filename, ...)` or the
streaming [`parse_messages`](@ref) with `skip=`.
"""
function parse_message(bytes::Vector{UInt8}, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)
    if packed === nothing
        packed = looks_packed(bytes; start=pos + 1)
    end
    if packed
        mr = read_packed(bytes; start=pos + 1)
    else
        mr, _ = read_message_mmap(bytes; start=pos + 1)
    end
    node = sf.flat[node_name]
    return read_struct(get_root(mr), sf, node; skip=skip)
end

"""
    parse_message(io::IO, sf::SchemaFile, node_name::AbstractString; packed::Union{Bool,Nothing}=nothing, pos::Int=-1, skip=nothing)

Parse a message whose root is the struct node `node_name` of `sf` from an IO.
The encoding is auto-detected at the read position via [`ispacked`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins; the default `-1` means use the
IO's current position (no seek). The IO is left positioned just past the
message.

`skip` optionally skips decoding (and, where possible, reading) one or more
fields; see [`read_struct`](@ref). When `skip` is set, segments holding only
skipped data are not read from the IO: for unpacked streams their bytes are
seeked past (no I/O for those bytes); for packed streams they are decoded-and-
discarded (the packed encoding is variable-length, so the bytes are still read
but not retained).
"""
function parse_message(io::IO, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=-1, skip=nothing)
    if pos >= 0
        seek(io, pos)
    end
    is_p = if packed === nothing
        ispacked(io)
    else
        packed
    end
    mr, _ = _read_message_io_with_skip(io, is_p, sf, node_name, skip)
    mr === nothing && error("parse_message: end of stream")
    node = sf.flat[node_name]
    return read_struct(get_root(mr), sf, node; skip=skip)
end

"""
    parse_message(filename::AbstractString, sf::SchemaFile, node_name::AbstractString; packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)

Parse a message whose root is the struct node `node_name` of `sf` from a file.
The encoding is auto-detected at `pos` via [`looks_packed`](@ref); pass
`packed=true` or `packed=false` to force a specific interpretation. `pos` is the
0-based byte offset at which the message begins (default 0).

The file is memory-mapped (via `Mmap.mmap`) rather than read into memory, so
the OS pages it in on demand as the message is decoded.

For unpacked input the message is read into an [`MmapMessageReader`](@ref)
whose segment bodies are zero-copy views of the mmap'd bytes. As a result,
byte-strideable primitive lists (`List(Int8)`/`UInt8`/`Int16`/`UInt16`/
`Int32`/`UInt32`/`Int64`/`UInt64`/`Float32`/`Float64`) are returned as
`reinterpret`-views directly over the mmap'd region -- no per-element copy
is made and the OS pages the data in on demand. (Void and Bool lists, and
Text/Data/struct lists, are still materialized element-by-element.)

For packed input the message must be unpacked (materialized) and so cannot
share the mmap-backed representation; the decoded primitive lists are
`Vector{T}` as in the in-memory case.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them; see [`read_struct`](@ref). Because the file is memory-mapped,
skipped segments are never paged in by the OS, so `skip` saves both memory and
I/O. For unpacked streams the skipped segments are simply never touched; for
packed streams the message is unpacked from the mmap view but the skipped
segments' words are not retained.
"""
function parse_message(filename::AbstractString, sf::SchemaFile, node_name::AbstractString;
                       packed::Union{Bool,Nothing}=nothing, pos::Int=0, skip=nothing)
    bytes = open(Mmap.mmap, filename)
    if packed === nothing
        packed = looks_packed(bytes; start=pos + 1)
    end
    if packed
        # Packed: must materialize via the packed decoder; cannot share the
        # mmap-backed representation.
        mr = read_packed(bytes; start=pos + 1)
    else
        # Unpacked: build an MmapMessageReader whose segment bodies are
        # zero-copy views of the mmap'd bytes, so byte-strideable primitive
        # lists decode as `reinterpret`-views directly over the mmap region.
        mr, _ = read_message_mmap(bytes; start=pos + 1)
    end
    node = sf.flat[node_name]
    return read_struct(get_root(mr), sf, node; skip=skip)
end

"""
    parse_struct(mr, sf::SchemaFile, node_name::AbstractString; skip=nothing)

Decode a typed value from an already-read message reader whose root is the
struct node `node_name` of `sf`. `mr` may be a [`MessageReader`](@ref) or an
[`MmapMessageReader`](@ref). This is the typed layer over
`read_message`/`read_message_io`/`read_message_agnostic`/`read_message_mmap`:
read the raw message by any means, then call `parse_struct` to decode it.

`skip` optionally skips decoding one or more fields, returning typed empty
values for them; see [`read_struct`](@ref). If the message reader was produced
by a skip-aware reader (e.g. `parse_messages` with `skip=`), the skipped
segments are already empty and the typed layer returns the empty values
naturally.
"""
function parse_struct(mr, sf::SchemaFile, node_name::AbstractString; skip=nothing)
    node = sf.flat[node_name]
    return read_struct(get_root(mr), sf, node; skip=skip)
end

# ----- Streaming iterator over multiple messages --------------------------------

"""
    parse_messages(src, sf::SchemaFile, node_name; packed=nothing, skip=nothing, throw_on_error=false)

Return an iterator that yields one decoded message per iteration from `src`,
which is assumed to contain a stream of concatenated messages of the same
struct type `node_name`. Messages are read **lazily**: only one message at a
time is held in memory, so iterating a large stream does not load the whole
file.

The encoding is auto-detected from the first message via [`ispacked`](@ref)
and that decision is then applied to **every** message in the stream (Cap'n
Proto streams do not mix encodings). Pass `packed=true` or `false` to force a
specific interpretation and skip detection.

If a semantic error is encountered while reading a message (e.g. truncation or
corruption), `throw_on_error` controls the behavior:

  - `false` (the default): emit a warning and end iteration gracefully.
  - `true`: rethrow the error.
  - `nothing`: end iteration gracefully without a warning.

`src` may be an `IO`, an `AbstractVector{UInt8}`, or a filename
(`AbstractString`). A filename is memory-mapped (via `Mmap.mmap`) and wrapped
in a buffered IO, so the file is not fully loaded into memory up front -- the
OS pages it in on demand as the iterator reads. A byte vector is wrapped
directly in a buffered IO. An `IO` is used as-is.

`skip` optionally skips decoding (and, where possible, reading) one or more
fields for every message in the stream; see [`read_struct`](@ref). The savings
depend on the input type and encoding:

  - **Memory-mapped file** (filename): skipped segments are never paged in by
    the OS, so `skip` saves both memory and I/O. For unpacked streams the
    skipped segments are seeked past; for packed streams they are decoded-and-
    discarded (the packed encoding is variable-length, so the bytes are read
    but not retained).
  - **IO stream**: same as memory-mapped -- unpacked streams seek past skipped
    segments; packed streams decode-and-discard them.
  - **Byte vector** (`AbstractVector{UInt8}`): all bytes are already in memory,
    so `skip` saves decode CPU and the resulting array allocations but not I/O
    or memory.

This is the most efficient way to iterate a stream of messages while ignoring
a large field (e.g. a big `List(Float32)` array): only the small per-message
struct segments are retained.
"""
function parse_messages(src, sf::SchemaFile, node_name::AbstractString;
                        packed::Union{Bool,Nothing}=nothing, skip=nothing,
                        throw_on_error::Union{Bool,Nothing}=false)
    bio, src_name, bytes = _as_buffered_io(src)
    is_p = if packed === nothing
        ispacked(bio)
    else
        packed
    end
    return MessageIterator(sf, String(node_name), bio, bytes, is_p, skip, src_name, throw_on_error)
end

"Wrap `src` in a buffered IO suitable for lazy reading. Byte vectors and
filenames get an IOBuffer over their contents; an existing IO is used directly.
Filenames are memory-mapped (via `Mmap.mmap`) so the file is not fully loaded
into memory up front -- the OS pages it in on demand as the iterator reads.

Returns `(io, src_name, bytes)` where `src_name` is a human-readable identifier
for warnings (the filename / `<byte vector>` / `<IO>`) and `bytes` is the
underlying byte vector when the IO is backed by one (a byte vector or an
mmap'd file), or `nothing` for a raw IO. When `bytes` is non-`nothing` and the
stream is unpacked, `MessageIterator` uses `read_message_mmap` to produce
`MmapMessageReader`s whose segment bodies are zero-copy views of `bytes`, so
byte-strideable primitive lists decode as `reinterpret`-views directly over
the backing storage (mmap'd or otherwise) with no per-element copy."
function _as_buffered_io(src)
    if src isa AbstractVector{UInt8}
        return IOBuffer(src; read=true, write=false), "<byte vector>", src
    elseif src isa AbstractString
        # Memory-map the file so iteration reads it lazily via the OS page
        # cache rather than loading it all up front.
        bytes = open(Mmap.mmap, src)
        return IOBuffer(bytes; read=true, write=false), String(src), bytes
    elseif src isa IO
        return src, "<IO>", nothing
    else
        error("parse_messages: expected an IO, byte vector, or filename, got $(typeof(src))")
    end
end

"""
    MessageIterator

Iterator over the messages of a [`parse_messages`](@ref) stream. Reads one
message at a time from the underlying IO, so memory use is bounded by the
largest single message. Iterate with `for msg in itr` or use `collect`.

Construct a `MessageIterator` via [`parse_messages`](@ref); do not call the
constructor directly. Each iteration reads and decodes exactly one message,
honoring the `skip` setting (see [`parse_messages`](@ref)). Trailing bad
messages are handled per `throw_on_error` (see [`parse_messages`](@ref)).

When the source is a byte vector or memory-mapped file and the stream is
unpacked, the iterator reads each message into an [`MmapMessageReader`](@ref)
whose segment bodies are zero-copy views of the backing bytes, so
byte-strideable primitive lists decode as `reinterpret`-views directly over
the backing storage with no per-element copy. For packed input or a raw IO,
the iterator falls back to the materialized `MessageReader` path.
"""
struct MessageIterator
    sf::SchemaFile
    node_name::String
    io::IO
    # The backing byte vector when `io` is an IOBuffer over a byte vector or
    # an mmap'd file (`nothing` for a raw IO). When non-`nothing` and the
    # stream is unpacked, iteration uses `read_message_mmap` to produce
    # `MmapMessageReader`s with zero-copy segment views.
    bytes::Union{Nothing, Vector{UInt8}}
    packed::Bool
    skip   # nothing, a collection of path strings, or a path -> Bool predicate
    src_name::String         # filename / "<byte vector>" / "<IO>" for warnings
    throw_on_error::Union{Bool,Nothing}  # false (default): warn + stop; true: rethrow; nothing: silent stop
end

Base.IteratorSize(::Base.Type{MessageIterator}) = Base.SizeUnknown()
Base.eltype(it::MessageIterator) = _named_tuple_type(it.sf[it.node_name], it.sf)

"""
    Base.iterate(it::MessageIterator, [state]) -> Union{Nothing, Tuple{Any, Nothing}}

Advance the [`MessageIterator`](@ref) `it` to the next message and return
`(value, nothing)`, or `nothing` at the end of the stream. Each call reads and
decodes exactly one message from the underlying IO, so memory use is bounded
by the largest single message. When `it.skip` is set, skipped segments are
not retained (see [`parse_messages`](@ref)).

`throw_on_error` (set on the iterator via [`parse_messages`](@ref)) controls
the behavior if a semantic error is encountered while reading a message:
`false` (the default) emits a warning and ends iteration gracefully; `true`
rethrows the error; `nothing` ends iteration gracefully without a warning.
"""
function Base.iterate(it::MessageIterator, _state::Nothing=nothing)
    eof(it.io) && return nothing
    start_off = position(it.io)
    try
        mr = _read_next_message(it)
        mr === nothing && return nothing
        node = it.sf.flat[it.node_name]
        val = read_struct(get_root(mr), it.sf, node; skip=it.skip)
        return (val, nothing)
    catch e
        if e isa MessageStreamError
            it.throw_on_error === true && rethrow(e)
            it.throw_on_error === false &&
                @warn "bad message in stream; ending iteration" src=it.src_name offset=start_off exception=e
            return nothing
        end
        rethrow(e)
    end
end

"Read the next message from `it`'s source. For unpacked input with a backing
byte vector (byte vector or mmap'd file), use `read_message_mmap_checked` to
produce an `MmapMessageReader` with zero-copy segment views (and validate
bounds, raising `MessageStreamError`s on truncation/corruption consistent
with the IO reader). Otherwise (packed, or a raw IO without a backing byte
vector) fall back to the existing skip-aware IO reader (which materializes
the segment bodies as `Vector{UInt64}`)."
function _read_next_message(it::MessageIterator)
    if !it.packed && it.bytes !== nothing
        # Unpacked with a backing byte vector: build an MmapMessageReader
        # whose segment bodies are zero-copy views of `it.bytes`. The skip
        # optimization is handled naturally -- segments containing only
        # skipped fields are simply never paged in by the OS, since the
        # typed layer never reads them. The IO position is advanced past
        # the whole message so the next iteration starts at the next one.
        pos = position(it.io)  # 0-based byte offset
        res = read_message_mmap_checked(it.bytes; start=pos + 1)
        res === nothing && return nothing
        mr, next_pos = res
        # Advance the IO to just past the message (next_pos is 1-based).
        seek(it.io, next_pos - 1)
        return mr
    end
    # Packed, or a raw IO without a backing byte vector: use the existing
    # skip-aware IO reader (materializes segments as Vector{UInt64}).
    mr, _ = _read_message_io_with_skip(it.io, it.packed, it.sf, it.node_name, it.skip)
    return mr
end

# ----- Offset-tracking iterator ------------------------------------------------
#
 # The default `MessageIterator` yields only the decoded value, matching the
 # common case. `with_offsets` wraps it to also expose the 0-based byte
 # offset at which each message began in the underlying IO -- useful for
 # recording seek positions to replay individual messages later via
 # `parse_message(...; pos=off)`. It captures `position(io)` *before* each
 # inner `iterate` call advances the IO.

"""
    OffsetMessageIterator

Iterator wrapping a [`MessageIterator`](@ref) that yields `(offset, value)`
pairs instead of just `value`. The `offset` is the 0-based byte position of the
message within the underlying IO, compatible with the `pos` keyword of
[`parse_message`](@ref). Construct via [`with_offsets`](@ref); do not call the
constructor directly.
"""
struct OffsetMessageIterator
    inner::MessageIterator
end

Base.IteratorSize(::Type{OffsetMessageIterator}) = Base.SizeUnknown()
Base.eltype(it::OffsetMessageIterator) = Tuple{Int, eltype(it.inner)}

function Base.iterate(it::OffsetMessageIterator, state=nothing)
    off = position(it.inner.io)
    res = iterate(it.inner, state)
    res === nothing && return nothing
    val, inner_state = res
    return ((off, val), inner_state)
end

"""
    with_offsets(itr::MessageIterator) -> OffsetMessageIterator

Wrap the [`MessageIterator`](@ref) `itr` so that each iteration yields
`(offset, value)` instead of just `value`, where `offset` is the 0-based byte
offset at which the message began in the underlying IO. The default iteration
via [`parse_messages`](@ref) is unchanged and still yields only values.

The offset matches the `pos` keyword of [`parse_message`](@ref), so a message
read from the pair `(off, msg)` can be re-read directly:
`parse_message(src, schema, node; pos=off)`.

The underlying IO must support `position` (IOBuffer, file streams, and the
memory-mapped wrappers used by [`parse_messages`](@ref) all do). For a
non-seekable stream, buffer it first (e.g. wrap in an `IOBuffer`).

# Example
```julia
for (off, msg) in with_offsets(parse_messages("hits.bin", sf, "Hit"))
    @info "message at byte \$off" msg
end
```
"""
with_offsets(itr::MessageIterator) = OffsetMessageIterator(itr)
