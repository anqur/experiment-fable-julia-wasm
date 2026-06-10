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

"""Read an unsigned LEB128 of at most `maxbits` bits."""
function read_uleb(io::IO, maxbits::Integer=64)
    result = UInt64(0)
    shift = 0
    while true
        b = read(io, UInt8)
        result |= UInt64(b & 0x7f) << shift
        shift += 7
        if (b & 0x80) == 0
            shift > maxbits + 7 && throw(MalformedError("unsigned LEB128 too long"))
            result < (maxbits >= 64 ? typemax(UInt64) : UInt64(1) << maxbits) ||
                maxbits >= 64 || throw(MalformedError("unsigned LEB128 exceeds $maxbits bits"))
            return result
        end
        shift > 70 && throw(MalformedError("unsigned LEB128 too long"))
    end
end

"""Read a signed LEB128 of at most `maxbits` bits (e.g. 32, 33, 64)."""
function read_sleb(io::IO, maxbits::Integer=64)
    result = Int64(0)
    shift = 0
    local b::UInt8
    while true
        b = read(io, UInt8)
        result |= Int64(b & 0x7f) << shift
        shift += 7
        (b & 0x80) == 0 && break
        shift > 70 && throw(MalformedError("signed LEB128 too long"))
    end
    # Sign-extend from the final group.
    if shift < 64 && (b & 0x40) != 0
        result |= -(Int64(1) << shift)
    end
    return result
end

read_u32(io::IO) = UInt32(read_uleb(io, 32))
read_s33(io::IO) = read_sleb(io, 33)
