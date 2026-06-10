# LEB128 variable-length integer encoding.

function write_uleb(io::IO, x::Integer)
    x >= 0 || throw(ArgumentError("unsigned LEB encoding of negative value $x"))
    x = UInt64(x)
    n = 0
    while true
        b = UInt8(x & 0x7f)
        x >>= 7
        if x != 0
            n += write(io, b | 0x80)
        else
            n += write(io, b)
            return n
        end
    end
end

function write_sleb(io::IO, x::Integer)
    x = Int64(x)
    n = 0
    while true
        b = UInt8(x & 0x7f)
        x >>= 7   # arithmetic shift
        done = (x == 0 && (b & 0x40) == 0) || (x == -1 && (b & 0x40) != 0)
        n += write(io, done ? b : b | 0x80)
        done && return n
    end
end

"""
Read an unsigned LEB128 of at most `maxbits` bits. Per the spec, the encoding
may use at most `ceil(maxbits/7)` bytes and any unused bits of the final byte
must be zero.
"""
function read_uleb(io::IO, maxbits::Integer=64)
    result = UInt64(0)
    shift = 0
    nmax = 7 * cld(maxbits, 7)   # total payload bits in ceil(maxbits/7) bytes
    while true
        shift < nmax || throw(MalformedError("unsigned LEB128 too long"))
        b = read(io, UInt8)
        result |= UInt64(b & 0x7f) << shift
        shift += 7
        if (b & 0x80) == 0
            # Unused bits of the final byte must be zero.
            shift > maxbits && b >> (maxbits - shift + 7) != 0 &&
                throw(MalformedError("unsigned LEB128 exceeds $maxbits bits"))
            return result
        end
    end
end

"""
Read a signed LEB128 of at most `maxbits` bits whose first byte `b0` has
already been consumed. Enforces the spec limits: at most `ceil(maxbits/7)`
bytes, and the unused bits of the final byte must be a sign extension.
"""
function read_sleb_first(io::IO, b0::UInt8, maxbits::Integer)
    result = Int64(b0 & 0x7f)
    shift = 7
    nmax = 7 * cld(maxbits, 7)
    b = b0
    while (b & 0x80) != 0
        shift < nmax || throw(MalformedError("signed LEB128 too long"))
        b = read(io, UInt8)
        result |= Int64(b & 0x7f) << shift
        shift += 7
    end
    if shift > maxbits
        # The final byte carries `used` value bits; the bits above them must
        # all equal the sign bit (the topmost value bit).
        used = maxbits - shift + 7
        sign = (b >> (used - 1)) & 0x01
        (b & 0x7f) >> used == (sign == 0x01 ? 0x7f >> used : 0x00) ||
            throw(MalformedError("signed LEB128 exceeds $maxbits bits"))
    end
    # Sign-extend from the final group.
    if shift < 64 && (b & 0x40) != 0
        result |= -(Int64(1) << shift)
    end
    return result
end

"""Read a signed LEB128 of at most `maxbits` bits (e.g. 32, 33, 64)."""
read_sleb(io::IO, maxbits::Integer=64) = read_sleb_first(io, read(io, UInt8), maxbits)

read_u32(io::IO) = UInt32(read_uleb(io, 32))
read_s33(io::IO) = read_sleb(io, 33)
