# message.jl - segment-based message buffers for building and reading.
#
# A Cap'n Proto message is a sequence of segments, each a sequence of 64-bit
# words. The serialized stream begins with a segment table:
#
#   [u32 segment_count-1][u32 len(seg0)][u32 len(seg1)]...[pad][seg0 words][seg1 words]...
#
# The segment table is padded so the first segment starts on an 8-byte boundary.

# ----- Builder side ------------------------------------------------------------

"""
    MessageBuilder()

A mutable Cap'n Proto message under construction. Segments are stored as
`Vector{Vector{UInt64}}` in native byte order. The first segment is created
on construction; new segments can be allocated on demand by `alloc!`.
"""
mutable struct MessageBuilder
    segments::Vector{Vector{UInt64}}
    # Preallocated space (in words) per segment for far-pointer bookkeeping is
    # not needed; we allocate exactly when needed.
    function MessageBuilder()
        return new([UInt64[]])
    end
end

"Number of segments in the message."
nsegments(mb::MessageBuilder)::Int = length(mb.segments)

"Number of words currently used in segment `seg` (0-based segment id)."
function segment_words(mb::MessageBuilder, seg::Int)::Int
    return length(mb.segments[seg + 1])
end

"Allocate `n` words at the end of segment `seg` (0-based) and return the word index (0-based) of the first new word. The new words are zero-initialized."
function alloc_words!(mb::MessageBuilder, seg::Int, n::Int)::Int
    words = mb.segments[seg + 1]
    idx = length(words)
    old = idx
    resize!(words, idx + n)
    fill!(@view(words[old+1:end]), UInt64(0))
    return idx
end

"Append a word to segment `seg` (0-based) and return its 0-based index."
push_word!(mb::MessageBuilder, seg::Int, w::UInt64) = (push!(mb.segments[seg + 1], w); length(mb.segments[seg + 1]) - 1)

"Read a word from segment `seg` (0-based) at 0-based index `i`."
get_word(mb::MessageBuilder, seg::Int, i::Int)::UInt64 = mb.segments[seg + 1][i + 1]

"Set word `i` (0-based) in segment `seg` (0-based)."
function set_word!(mb::MessageBuilder, seg::Int, i::Int, w::UInt64)
    mb.segments[seg + 1][i + 1] = w
    return nothing
end

"Allocate a fresh segment and return its 0-based id."
function alloc_segment!(mb::MessageBuilder)::Int
    push!(mb.segments, UInt64[])
    return length(mb.segments) - 1
end

"""
    write_message(mb::MessageBuilder)::Vector{UInt8}

Serialize a MessageBuilder to a byte vector in standard (unpacked) form, including the segment table.
"""
function write_message(mb::MessageBuilder)::Vector{UInt8}
    nseg = length(mb.segments)
    table_words = cld(1 + nseg, 2) # (count word + nseg length words), padded to even
    total_table_bytes = table_words * 8
    body_bytes = sum(length(seg) * 8 for seg in mb.segments)
    out = Vector{UInt8}(undef, total_table_bytes + body_bytes)
    ii = 0
    # Segment count - 1 as UInt32 LE.
    ii = store_u32_le!(out, ii, UInt32(nseg - 1))
    for seg in mb.segments
        ii = store_u32_le!(out, ii, UInt32(length(seg)))
    end
    # Pad to 8-byte boundary.
    while ii % 8 != 0
        out[ii + 1] = 0
        ii += 1
    end
    # Body: words in native order, serialized little-endian.
    for seg in mb.segments
        for w in seg
            store_word_le!(out, ii + 1, w)
            ii += 8
        end
    end
    return out
end

function store_u32_le!(out::AbstractVector{UInt8}, i::Int, v::UInt32)::Int
    # `i` is 0-based byte offset; returns new 0-based offset.
    out[i + 1] = (v & 0xff) % UInt8
    out[i + 2] = ((v >>> 8) & 0xff) % UInt8
    out[i + 3] = ((v >>> 16) & 0xff) % UInt8
    out[i + 4] = ((v >>> 24) & 0xff) % UInt8
    return i + 4
end

# ----- Reader side -------------------------------------------------------------

"""
    MessageReader(segments)

A read-only view over a Cap'n Proto message given as a vector of segments,
each a `Vector{UInt64}` in native byte order.
"""
struct MessageReader
    segments::Vector{Vector{UInt64}}
end

nsegments(mr::MessageReader)::Int = length(mr.segments)
segment_words(mr::MessageReader, seg::Int)::Int = length(mr.segments[seg + 1])
get_word(mr::MessageReader, seg::Int, i::Int)::UInt64 = mr.segments[seg + 1][i + 1]

# Trait: the raw bytes backing a segment as a little-endian byte view. For a
# standard `MessageReader` this is `reinterpret(UInt8, segments[seg+1])` -- a
# view of the segment's `Vector{UInt64}` reinterpreted as bytes (no copy).
# For an `MmapMessageReader` it is a `SubArray` slice of the backing mmap'd
# bytes. In both cases the returned view is a contiguous, little-endian,
# word-aligned run of `segment_words(seg) * 8` bytes. The typed layer uses
# this to return zero-copy `reinterpret`-views of primitive list bodies
# directly over the backing storage (mmap or otherwise).
@inline _segment_bytes(mr::MessageReader, seg::Int) =
    reinterpret(UInt8, mr.segments[seg + 1])

"""
    MmapMessageReader

A read-only view over a Cap'n Proto message whose segment bodies are slices
of a single backing byte vector -- typically a `Vector{UInt8}` returned by
`Mmap.mmap`. Unlike [`MessageReader`](@ref), which copies each segment into
its own `Vector{UInt64}`, an `MmapMessageReader` keeps the segment data in
the backing bytes and reads words on demand via [`get_word`](@ref). The
backing bytes (and therefore the underlying mmap mapping) are kept alive for
the lifetime of the reader.

Exposes the same accessors as `MessageReader` (`nsegments`, `segment_words`,
`get_word`) so it is interchangeable with `MessageReader` in the reader and
typed layers. Construct via [`read_message_mmap`](@ref) (for a single
message) or indirectly via `parse_message(filename, ...)` /
`parse_messages(filename, ...)`.

On a little-endian host, primitive lists of 1-, 2-, 4-, or 8-byte elements
read from an `MmapMessageReader` are returned as zero-copy
`reinterpret`-views over the mmap'd bytes -- no per-element copy is made and
the OS pages the data in on demand.
"""
struct MmapMessageReader
    bytes::Vector{UInt8}        # the backing bytes (e.g. an Mmap.mmap result)
    # 1-based byte offset of each segment's first word within `bytes`, and
    # each segment's word count. `seg_offsets[k]` is the start of segment
    # `k-1`; the body occupies `seg_words[k] * 8` bytes from there.
    seg_offsets::Vector{Int}
    seg_words::Vector{Int}
end

nsegments(mr::MmapMessageReader)::Int = length(mr.seg_words)
segment_words(mr::MmapMessageReader, seg::Int)::Int = mr.seg_words[seg + 1]

# Read the `i`-th 0-based word of segment `seg` from the backing bytes. The
# wire is little-endian; on a little-endian host this is a single `unsafe_load`.
@inline function get_word(mr::MmapMessageReader, seg::Int, i::Int)::UInt64
    byte = mr.seg_offsets[seg + 1] + i * 8
    return load_word_le(mr.bytes, byte)
end

# Trait override: the segment body as a SubArray slice of the backing bytes.
# Used by the primitive-list fast path in typed.jl. The returned view is a
# contiguous, little-endian, word-aligned run of `segment_words(seg) * 8`
# bytes from the mmap'd region.
@inline function _segment_bytes(mr::MmapMessageReader, seg::Int)
    off = mr.seg_offsets[seg + 1]
    n = mr.seg_words[seg + 1] * 8
    return @view mr.bytes[off : off + n - 1]
end

"""
    read_message_mmap(bytes::Vector{UInt8}; start::Int=1)

Parse one unpacked Cap'n Proto message from `bytes` (typically an
`Mmap.mmap` result) starting at 1-based byte index `start`, returning an
[`MmapMessageReader`](@ref) whose segment bodies are zero-copy views of
`bytes` rather than copied `Vector{UInt64}` arrays. The backing `bytes`
vector is retained by the reader, so the underlying mmap mapping stays alive
for the lifetime of the reader.

Returns `(MmapMessageReader, next_start)` where `next_start` is the 1-based
byte index just past the message, suitable for iterating a stream of
concatenated messages from a memory-mapped file.

For packed-encoded input, use [`read_message`](@ref) or
[`read_packed`](@ref) instead -- the packed decoder must materialize the
decoded words and so cannot share the mmap-backed representation.
"""
function read_message_mmap(bytes::Vector{UInt8}; start::Int=1)
    seg_count = Int(load_u32_le(bytes, start)) + 1
    (seg_count == 0 || seg_count > 1 << 20) &&
        error("read_message_mmap: bad segment count $seg_count")
    ii = start + 4
    lengths = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        lengths[k] = Int(load_u32_le(bytes, ii))
        ii += 4
    end
    # Pad so the body starts on an 8-byte boundary relative to `start`.
    table_bytes = ii - start
    if table_bytes % 8 != 0
        ii += 8 - (table_bytes % 8)
    end
    seg_offsets = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        seg_offsets[k] = ii
        ii += lengths[k] * 8
    end
    return MmapMessageReader(bytes, seg_offsets, lengths), ii
end

"""
    read_message(bytes::AbstractVector{UInt8}; start::Int=1)

Parse a standard (unpacked) serialized message from `bytes` starting at byte index `start` (1-based).
Returns `(MessageReader, next_start)` where `next_start` is the byte index just past the message.
"""
function read_message(bytes::AbstractVector{UInt8}; start::Int=1)
    # Segment table: u32 (count-1), then count u32 lengths, padded to 8 bytes
    # relative to the start of the stream.
    seg_count = load_u32_le(bytes, start) + 1
    ii = start + 4
    lengths = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        lengths[k] = load_u32_le(bytes, ii)
        ii += 4
    end
    # Pad so the body starts on an 8-byte boundary relative to `start`.
    table_bytes = ii - start
    if table_bytes % 8 != 0
        ii += 8 - (table_bytes % 8)
    end
    segments = Vector{Vector{UInt64}}(undef, seg_count)
    for k in 1:seg_count
        n = lengths[k]
        seg = Vector{UInt64}(undef, n)
        for j in 1:n
            seg[j] = load_word_le(bytes, ii)
            ii += 8
        end
        segments[k] = seg
    end
    return MessageReader(segments), ii
end

"""
    looks_packed(bytes::AbstractVector{UInt8}; start::Int=1)::Bool

Return true iff `bytes` (from byte `start`) does NOT begin with a valid
unpacked Cap'n Proto segment table -- i.e. the data appears to be packed
rather than unpacked. A valid unpacked table is a sane segment count followed
by per-segment word lengths that fit within the input. Used to auto-detect
packed vs unpacked input. Note that a stream may contain multiple concatenated
messages, so the table need not consume the entire input.
"""
function looks_packed(bytes::AbstractVector{UInt8}; start::Int=1)::Bool
    n = length(bytes)
    # Need at least 4 bytes for the segment count.
    n - start + 1 < 4 && return true
    seg_count = try
        load_u32_le(bytes, start) + 1
    catch
        return true
    end
    # Sanity bound: a real message has at most a handful of segments.
    (seg_count == 0 || seg_count > 1 << 20) && return true
    table_u32s = 1 + seg_count
    table_bytes = table_u32s * 4
    # Pad to 8-byte boundary relative to start.
    table_bytes += table_bytes % 8 != 0 ? 8 - (table_bytes % 8) : 0
    body_start = start + table_bytes
    body_start > n + 1 && return true
    # Sum the declared segment lengths (in words) and check the body fits in the input.
    total_words = 0
    ii = start + 4
    for _ in 1:seg_count
        n - ii + 1 < 4 && return true
        total_words += load_u32_le(bytes, ii)
        ii += 4
    end
    return !(body_start + total_words * 8 - 1 <= n)
end

function load_u32_le(bytes::AbstractVector{UInt8}, i::Int)::UInt32
    return UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) |
           (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
end
