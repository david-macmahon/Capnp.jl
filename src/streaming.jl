# streaming.jl - lazy readers for Cap'n Proto messages from an IO stream.
#
# These read one message at a time directly from an IO, used by
# `parse_messages` to iterate a stream of concatenated messages without
# materializing the whole file.

"""
    MessageStreamError

Abstract supertype of the exceptions raised by [`parse_messages`](@ref) when a
stream cannot be read cleanly: [`TruncatedMessageError`](@ref) when the stream
ends mid-message, and [`CorruptedMessageError`](@ref) when the bytes are
present but impossible (e.g. an out-of-range segment count). `parse_messages`
catches both (as `MessageStreamError`) when `throw_on_error=false` (the
default) and ends iteration with a warning; pass `throw_on_error=true` to
rethrow, or `throw_on_error=nothing` to end iteration silently. A clean EOF
(no trailing bytes) always ends iteration without a warning.
"""
abstract type MessageStreamError <: Exception end

"""
    TruncatedMessageError(msg::AbstractString)

A `MessageStreamError` thrown when a stream ends in the middle of a message
(e.g. a file that was still being written when read).
"""
struct TruncatedMessageError <: MessageStreamError
    msg::String
end
Base.showerror(io::IO, e::TruncatedMessageError) = print(io, "TruncatedMessageError: ", e.msg)

"""
    CorruptedMessageError(msg::AbstractString)

A `MessageStreamError` thrown when a stream's bytes are present but impossible
to interpret as a valid Cap'n Proto message (e.g. an out-of-range segment
count). Distinct from [`TruncatedMessageError`](@ref): truncation means the
bytes ran out, corruption means the bytes are nonsensical.
"""
struct CorruptedMessageError <: MessageStreamError
    msg::String
end
Base.showerror(io::IO, e::CorruptedMessageError) = print(io, "CorruptedMessageError: ", e.msg)


# ----- Format detection -------------------------------------------------------

"""
    ispacked(io) -> Bool
    ispacked(bytes; start=1) -> Bool

Return `true` if the data at the current position of `io` (or at byte `start`
of `bytes`) appears to be a packed-encoded Cap'n Proto message, `false` if it
appears to be unpacked.

For a byte vector this delegates to [`looks_packed`](@ref), which validates
the full segment table against the available bytes -- the most reliable test.

For an IO, this peeks 4 bytes from the current position and checks whether they
form a plausible unpacked segment count (in `[1, 2^20]`). The IO position is
restored afterward (via `mark`/`reset`). This is a weaker check than the
byte-vector form because the total message length cannot be verified without
reading the whole table; a packed message whose first tag byte is small can be
misdetected as unpacked. When the format is known, pass `packed=true`/`false`
to `read_message_io`/`read_packed_message_io` or `parse_messages` to bypass
detection.
"""
function ispacked end

function ispacked(bytes::AbstractVector{UInt8}; start::Int=1)::Bool
    return looks_packed(bytes; start=start)
end

function ispacked(io::IO)::Bool
    # Peek 4 bytes from the current position, then restore it. mark/reset works
    # on IOBuffer, file streams, and pipes (the IO types this package handles).
    mark(io)
    b = Vector{UInt8}(undef, 4)
    got = readbytes!(io, b, 4)
    reset(io)   # restores the position to the mark and clears it
    if got < 4
        return false  # empty/tiny stream -> treat as unpacked (reader will hit EOF)
    end
    seg_count_m1 = UInt32(b[1]) | (UInt32(b[2]) << 8) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 24)
    seg_count = Int(seg_count_m1) + 1
    return !(1 <= seg_count <= 1 << 20)
end

# ----- Unpacked --------------------------------------------------------------

"Read one unpacked message from `io`. Returns a `MessageReader`, or `nothing`
at a clean end of stream. Throws a `TruncatedMessageError` on a partial message
at EOF; throws a `CorruptedMessageError` on a corrupt segment count."
function read_message_io(io::IO)::Union{MessageReader,Nothing}
    seg_count_m1 = _read_u32_le_io(io)
    seg_count_m1 === nothing && return nothing   # clean EOF
    seg_count = Int(seg_count_m1) + 1
    (seg_count == 0 || seg_count > 1 << 20) && throw(CorruptedMessageError("read_message_io: bad segment count $seg_count"))
    lengths = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        v = _read_u32_le_io(io)
        v === nothing && throw(TruncatedMessageError("read_message_io: EOF reading segment lengths"))
        lengths[k] = Int(v)
    end
    # The table is (1 + seg_count) u32s; if odd, one u32 of padding follows.
    table_u32s = 1 + seg_count
    if table_u32s % 2 != 0
        pad = _read_u32_le_io(io)
        pad === nothing && throw(TruncatedMessageError("read_message_io: EOF reading table padding"))
    end
    segments = Vector{Vector{UInt64}}(undef, seg_count)
    for k in 1:seg_count
        segments[k] = _read_words_io(io, lengths[k])
    end
    return MessageReader(segments)
end

"Read a little-endian UInt32 from `io`. Returns `nothing` at clean EOF; throws
a `TruncatedMessageError` if a partial 4 bytes remain."
function _read_u32_le_io(io::IO)::Union{UInt32,Nothing}
    b = Vector{UInt8}(undef, 4)
    got = readbytes!(io, b, 4)
    got == 0 && return nothing
    got < 4 && throw(TruncatedMessageError("read_message_io: unexpected EOF in u32"))
    return UInt32(b[1]) | (UInt32(b[2]) << 8) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 24)
end

"Read `n` 64-bit little-endian words from `io` into a `Vector{UInt64}`. Throws
a `TruncatedMessageError` on a partial word at EOF."
function _read_words_io(io::IO, n::Int)::Vector{UInt64}
    seg = Vector{UInt64}(undef, n)
    b = Vector{UInt8}(undef, 8)
    for j in 1:n
        got = readbytes!(io, b, 8)
        got < 8 && throw(TruncatedMessageError("read_message_io: unexpected EOF in segment body"))
        seg[j] = UInt64(b[1]) | (UInt64(b[2]) << 8) | (UInt64(b[3]) << 16) |
                 (UInt64(b[4]) << 24) | (UInt64(b[5]) << 32) | (UInt64(b[6]) << 40) |
                 (UInt64(b[7]) << 48) | (UInt64(b[8]) << 56)
    end
    return seg
end

# ----- Mmap-backed unpacked reader --------------------------------------------
#
# A checked wrapper around `read_message_mmap` (defined in message.jl) that
# validates the message's declared bounds against the available bytes and
# raises `MessageStreamError`s (TruncatedMessageError / CorruptedMessageError)
# consistent with the IO-based readers, so the streaming iterator's error
# handling can treat mmap and IO sources uniformly.

"Read one unpacked message from `bytes` (typically an `Mmap.mmap` result)
starting at 1-based byte index `start`, returning an `MmapMessageReader` and
the 1-based byte index just past the message. Returns `nothing` at a clean
end of stream. Throws a `TruncatedMessageError` on a partial message at EOF;
throws a `CorruptedMessageError` on a corrupt segment count or a declared
length that runs past the end of `bytes`."
function read_message_mmap_checked(bytes::Vector{UInt8}; start::Int=1)
    n = length(bytes)
    # Clean EOF: no bytes available from `start`.
    start > n && return nothing
    # Need at least 4 bytes for the segment count.
    n - start + 1 < 4 && throw(TruncatedMessageError("read_message_mmap: EOF reading segment count"))
    seg_count = Int(load_u32_le(bytes, start)) + 1
    (seg_count == 0 || seg_count > 1 << 20) &&
        throw(CorruptedMessageError("read_message_mmap: bad segment count $seg_count"))
    ii = start + 4
    table_u32s = 1 + seg_count
    # Validate the segment-length words are available.
    n - ii + 1 < 4 * seg_count &&
        throw(TruncatedMessageError("read_message_mmap: EOF reading segment lengths"))
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
    # Validate the segment bodies are available; sum their lengths for the
    # total body byte count.
    total_body = 0
    for k in 1:seg_count
        total_body += lengths[k] * 8
    end
    n - ii + 1 < total_body &&
        throw(TruncatedMessageError("read_message_mmap: EOF in segment bodies"))
    seg_offsets = Vector{Int}(undef, seg_count)
    for k in 1:seg_count
        seg_offsets[k] = ii
        ii += lengths[k] * 8
    end
    return MmapMessageReader(bytes, seg_offsets, lengths), ii
end

# ----- Packed -----------------------------------------------------------------
#
# A packed stream has no per-message length prefix, so to read one message we
# unpack tag-by-tag into a per-message word buffer until that buffer holds a
# complete unpacked message (segment table + declared body). The unpacker
# carries a small amount of state across calls for in-progress zero-runs and
# verbatim-runs.

"""
    PackedUnpacker(io::IO)

Stateful unpacker reading from an IO. Produces one unpacked word per
[`unpack_one!`](@ref). Used internally by [`read_packed_message_io`](@ref) to
decode a packed stream one word at a time without materializing the whole
message up front.
"""
mutable struct PackedUnpacker
    io::IO
    pending::Vector{UInt64}   # words already read but not yet consumed (verbatim run)
    zero_remaining::Int      # zero words still to emit from an in-progress zero run
end
PackedUnpacker(io::IO) = PackedUnpacker(io, UInt64[], 0)

"Produce one unpacked word from `pu`. Returns `(word, more)` where `more` is
false at a clean end of stream (word is 0 in that case). Throws a
`TruncatedMessageError` on a partial encoded unit at EOF."
function unpack_one!(pu::PackedUnpacker)::Tuple{UInt64,Bool}
    # First drain any buffered words (from a verbatim run).
    if !isempty(pu.pending)
        return (popfirst!(pu.pending), true)
    end
    # Then drain an in-progress zero run.
    if pu.zero_remaining > 0
        pu.zero_remaining -= 1
        return (UInt64(0), true)
    end
    eof(pu.io) && return (UInt64(0), false)
    tag = read(pu.io, UInt8)
    if tag == 0x00
        eof(pu.io) && throw(TruncatedMessageError("unpack: EOF after 0x00 tag"))
        extra = read(pu.io, UInt8)
        total = extra + 1
        pu.zero_remaining = total - 1
        return (UInt64(0), true)
    end
    # Reconstruct one word from the tag + its non-zero bytes.
    w = UInt64(0)
    for b in 0:7
        if (tag >> b) & 1 == 1
            eof(pu.io) && throw(TruncatedMessageError("unpack: EOF in tagged word"))
            w |= UInt64(read(pu.io, UInt8)) << (8 * b)
        end
    end
    if tag == 0xff
        # Verbatim run: next byte is N, then N more words follow verbatim.
        eof(pu.io) && throw(TruncatedMessageError("unpack: EOF after 0xff tag"))
        n = read(pu.io, UInt8)
        for _ in 1:n
            b = Vector{UInt8}(undef, 8)
            got = readbytes!(pu.io, b, 8)
            got < 8 && throw(TruncatedMessageError("unpack: EOF in verbatim run"))
            push!(pu.pending,
                  UInt64(b[1]) | (UInt64(b[2]) << 8) | (UInt64(b[3]) << 16) |
                  (UInt64(b[4]) << 24) | (UInt64(b[5]) << 32) | (UInt64(b[6]) << 40) |
                  (UInt64(b[7]) << 48) | (UInt64(b[8]) << 56))
        end
        # Return the tagged word now; the N verbatim words come from `pending`.
        return (w, true)
    end
    return (w, true)
end

"Read one packed message from `io`. Returns a `MessageReader`, or `nothing` at
a clean end of stream. Throws a `TruncatedMessageError` on a partial message
at EOF."
function read_packed_message_io(io::IO)::Union{MessageReader,Nothing}
    eof(io) && return nothing
    pu = PackedUnpacker(io)
    words = UInt64[]
    needed = -1   # total words the message needs, once the table is parsed
    while true
        w, more = unpack_one!(pu)
        more || break
        push!(words, w)
        if needed < 0
            needed = _try_compute_message_words(words)
        end
        if needed >= 0 && length(words) >= needed
            break
        end
    end
    if needed < 0
        needed = _try_compute_message_words(words)
    end
    if needed < 0 || length(words) < needed
        # A partial message at EOF: if we read nothing it's a clean end, else error.
        isempty(words) && return nothing
        throw(TruncatedMessageError("read_packed_message_io: partial message at EOF"))
    end
    # The message occupies `needed` words; any extras belong to the next message.
    # Parse the segment table out of the first `needed` words and split into
    # per-segment vectors, mirroring read_message.
    msg_words = words[1:needed]
    seg_count = Int(_u32_from_words(msg_words, 0)) + 1
    lengths = [Int(_u32_from_words(msg_words, 4 * k)) for k in 1:seg_count]
    table_u32s = 1 + seg_count
    table_words = cld(table_u32s * 4, 8)
    segments = Vector{Vector{UInt64}}(undef, seg_count)
    pos = table_words + 1   # 1-based word index into msg_words
    for k in 1:seg_count
        n = lengths[k]
        segments[k] = msg_words[pos:pos + n - 1]
        pos += n
    end
    return MessageReader(segments)
end

"Attempt to compute the total number of words (table + body) that the message
whose prefix is in `words` occupies. Returns -1 if the table is not yet fully
available."
function _try_compute_message_words(words::Vector{UInt64})::Int
    length(words) == 0 && return -1
    seg_count_m1 = _u32_from_words_maybe(words, 0)
    seg_count_m1 === nothing && return -1
    seg_count = Int(seg_count_m1) + 1
    (seg_count == 0 || seg_count > 1 << 20) && return -1
    table_u32s = 1 + seg_count
    total_body = 0
    for k in 1:seg_count
        v = _u32_from_words_maybe(words, 4 * k)
        v === nothing && return -1
        total_body += Int(v)
    end
    table_words = cld(table_u32s * 4, 8)
    return table_words + total_body
end

"Read a little-endian u32 from the bytes of `words` at 0-based `byte_idx`, or
`nothing` if fewer than 4 bytes are available from that offset."
function _u32_from_words_maybe(words::Vector{UInt64}, byte_idx::Int)::Union{UInt32,Nothing}
    if byte_idx + 4 > length(words) * 8
        return nothing
    end
    return _u32_from_words(words, byte_idx)
end

"Read a little-endian u32 from the bytes of `words` at 0-based `byte_idx`.
Assumes 4 bytes are available."
function _u32_from_words(words::Vector{UInt64}, byte_idx::Int)::UInt32
    w = words[byte_idx ÷ 8 + 1]
    b = byte_idx % 8
    return UInt32((w >> (8 * b)) & 0xffffffff)
end
