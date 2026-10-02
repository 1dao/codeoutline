-- Public-key arithmetic/parser adapted from xnet2lua xrsa.lua; see XNET2LUA-LICENSE.
-- Strict RSASSA-PKCS1-v1_5 / SHA-256 verification only.
local xutils = require('xutils')

local M = {}
local floor, schar, sbyte, ssub = math.floor, string.char, string.byte, string.sub
-- 24-bit limbs keep multiplication exact in a Lua double.
local LIMB_BITS = 24
local BASE = 16777216          -- 2^24
local HLEN = 20                -- SHA-1 digest length; MySQL's OAEP uses SHA-1

-- ---------------------------------------------------------------------------
-- Bignum primitives
-- ---------------------------------------------------------------------------

-- Big-endian byte string -> limb array of exactly k limbs (k inferred if nil).
local function bn_from_bytes(s, k)
    local n = #s
    local limbs = {}
    local i = n
    local idx = 1
    while i > 0 do
        local b0 = sbyte(s, i) or 0
        local b1 = (i - 1 >= 1) and sbyte(s, i - 1) or 0
        local b2 = (i - 2 >= 1) and sbyte(s, i - 2) or 0
        limbs[idx] = b0 + b1 * 256 + b2 * 65536
        idx = idx + 1
        i = i - 3
    end
    if #limbs == 0 then limbs[1] = 0 end
    k = k or #limbs
    for j = #limbs + 1, k do limbs[j] = 0 end
    return limbs, k
end

-- Limb array -> big-endian byte string of exactly `len` bytes.
local function bn_to_bytes(a, k, len)
    local bytes = {}
    for i = 1, k do
        local v = a[i]
        local base = (i - 1) * 3
        bytes[base + 1] = v % 256
        bytes[base + 2] = floor(v / 256) % 256
        bytes[base + 3] = floor(v / 65536) % 256
    end
    local out = {}
    for i = len, 1, -1 do
        out[#out + 1] = schar(bytes[i] or 0)
    end
    return table.concat(out)
end

local function bn_cmp(a, b, k)
    for i = k, 1, -1 do
        local av, bv = a[i] or 0, b[i] or 0
        if av ~= bv then
            if av > bv then return 1 end
            return -1
        end
    end
    return 0
end

-- a = a - b (requires a >= b when `borrow_in` is 0). Returns the final borrow,
-- which cancels an overflow limb the caller carried separately.
local function bn_sub(a, b, k)
    local borrow = 0
    for i = 1, k do
        local v = a[i] - (b[i] or 0) - borrow
        if v < 0 then
            a[i] = v + BASE
            borrow = 1
        else
            a[i] = v
            borrow = 0
        end
    end
    return borrow
end

-- x = 2x mod n, for x < n. n must have exactly k limbs.
local function bn_dbl_mod(x, n, k)
    local carry = 0
    for i = 1, k do
        local v = x[i] * 2 + carry
        if v >= BASE then
            x[i] = v - BASE
            carry = 1
        else
            x[i] = v
            carry = 0
        end
    end
    -- 2x < 2n, so at most one subtraction brings it back below n. When carry is
    -- set the true value is 2^(24k) + x, which is always >= n.
    if carry == 1 or bn_cmp(x, n, k) >= 0 then
        bn_sub(x, n, k)
    end
end

-- -n[1]^-1 mod 2^24, via Newton iteration on the low limb.
local function mont_n0inv(n0)
    local inv = 1
    for _ = 1, 5 do          -- doubles the correct bit count each round: 2^32 > 2^24
        inv = (inv * (2 - (n0 * inv) % BASE)) % BASE
    end
    return (BASE - inv) % BASE
end

-- Montgomery product: (a * b * R^-1) mod n, with R = 2^(24k). CIOS variant.
local function mont_mul(a, b, ctx)
    local k, n, n0inv = ctx.k, ctx.n, ctx.n0inv
    local t = ctx.scratch
    for i = 1, k + 2 do t[i] = 0 end

    for i = 1, k do
        local bi = b[i]
        local c = 0
        if bi ~= 0 then
            for j = 1, k do
                local v = t[j] + a[j] * bi + c
                c = floor(v / BASE)
                t[j] = v - c * BASE
            end
        end
        local v = t[k + 1] + c
        c = floor(v / BASE)
        t[k + 1] = v - c * BASE
        t[k + 2] = t[k + 2] + c

        local m = (t[1] * n0inv) % BASE
        v = t[1] + m * n[1]
        c = floor(v / BASE)
        for j = 2, k do
            v = t[j] + m * n[j] + c
            c = floor(v / BASE)
            t[j - 1] = v - c * BASE
        end
        v = t[k + 1] + c
        c = floor(v / BASE)
        t[k] = v - c * BASE
        t[k + 1] = t[k + 2] + c
        t[k + 2] = 0
    end

    local out = {}
    for i = 1, k do out[i] = t[i] end
    if t[k + 1] ~= 0 or bn_cmp(out, n, k) >= 0 then
        bn_sub(out, n, k)
    end
    return out
end

local function mont_ctx(n_bytes)
    local n, k = bn_from_bytes(n_bytes)
    if n[1] % 2 == 0 then
        return nil, 'rsa modulus must be odd'
    end
    local ctx = {
        n = n,
        k = k,
        n0inv = mont_n0inv(n[1]),
        scratch = {},
    }
    -- R^2 mod n by repeated doubling: 2 * 24k doublings from 1. Division-free,
    -- and this runs once per connection, not once per multiply.
    local rr = {}
    for i = 1, k do rr[i] = 0 end
    rr[1] = 1
    for _ = 1, 2 * LIMB_BITS * k do
        bn_dbl_mod(rr, n, k)
    end
    ctx.rr = rr
    return ctx
end

-- m^e mod n, all arguments big-endian byte strings; result is `#n_bytes` long.
local function mod_exp(m_bytes, e_bytes, n_bytes)
    local ctx, err = mont_ctx(n_bytes)
    if not ctx then return nil, err end
    local k = ctx.k

    local base = bn_from_bytes(m_bytes, k)
    if bn_cmp(base, ctx.n, k) >= 0 then
        return nil, 'message representative out of range'
    end

    local one = {}
    for i = 1, k do one[i] = 0 end
    one[1] = 1

    local base_m = mont_mul(base, ctx.rr, ctx)      -- base * R mod n
    local acc = mont_mul(one, ctx.rr, ctx)          -- 1 * R mod n

    -- Square-and-multiply over the bits of e, most significant first. e is the
    -- server's public exponent, so its bit pattern is not a secret.
    local started = false
    for i = 1, #e_bytes do
        local byte = sbyte(e_bytes, i)
        for bit = 7, 0, -1 do
            if started then
                acc = mont_mul(acc, acc, ctx)
            end
            if floor(byte / (2 ^ bit)) % 2 == 1 then
                if started then
                    acc = mont_mul(acc, base_m, ctx)
                else
                    acc = base_m
                    started = true
                end
            end
        end
    end
    if not started then
        return nil, 'rsa exponent is zero'
    end

    local result = mont_mul(acc, one, ctx)          -- out of Montgomery domain
    return bn_to_bytes(result, k, #n_bytes)
end

-- ---------------------------------------------------------------------------
-- DER / PEM public key parsing
-- ---------------------------------------------------------------------------

-- Reads one ASN.1 TLV at `pos`. Returns tag, contents, next position.
local function der_read(der, pos)
    local tag = sbyte(der, pos)
    if not tag then return nil, nil, nil, 'truncated DER' end
    pos = pos + 1
    local len = sbyte(der, pos)
    if not len then return nil, nil, nil, 'truncated DER length' end
    pos = pos + 1
    if len >= 128 then
        local count = len - 128
        if count == 0 or count > 4 then return nil, nil, nil, 'bad DER length' end
        len = 0
        for _ = 1, count do
            local b = sbyte(der, pos)
            if not b then return nil, nil, nil, 'truncated DER length' end
            len = len * 256 + b
            pos = pos + 1
        end
    end
    local contents = ssub(der, pos, pos + len - 1)
    if #contents ~= len then return nil, nil, nil, 'truncated DER contents' end
    return tag, contents, pos + len
end

local function der_uint(s)
    -- ASN.1 INTEGERs are signed, so a leading 0x00 guards the sign bit.
    local i = 1
    while i < #s and sbyte(s, i) == 0 do i = i + 1 end
    return ssub(s, i)
end

-- Accepts both "BEGIN PUBLIC KEY" (SubjectPublicKeyInfo, what MySQL sends) and
-- "BEGIN RSA PUBLIC KEY" (bare PKCS#1). Returns n, e as byte strings.
function M.parse_public_key(pem)
    if type(pem) ~= 'string' or pem == '' then
        return nil, nil, 'empty public key'
    end
    local body = pem:gsub('%-%-%-%-%-[^%-]*%-%-%-%-%-', ''):gsub('%s', '')
    if body == '' then return nil, nil, 'no base64 body in PEM' end
    local der = xutils.base64_decode(body)
    if not der or der == '' then return nil, nil, 'base64 decode failed' end

    local tag, contents, _, err = der_read(der, 1)
    if not tag then return nil, nil, err end
    if tag ~= 0x30 then return nil, nil, 'expected DER SEQUENCE' end

    local inner = contents
    local first_tag, first_contents, next_pos = der_read(inner, 1)
    if not first_tag then return nil, nil, 'malformed public key' end

    if first_tag == 0x30 then
        -- SubjectPublicKeyInfo: skip AlgorithmIdentifier, unwrap the BIT STRING.
        local bit_tag, bit_contents = der_read(inner, next_pos)
        if bit_tag ~= 0x03 then return nil, nil, 'expected DER BIT STRING' end
        if sbyte(bit_contents, 1) ~= 0 then return nil, nil, 'unexpected BIT STRING padding' end
        local seq_tag, seq_contents = der_read(ssub(bit_contents, 2), 1)
        if seq_tag ~= 0x30 then return nil, nil, 'expected RSAPublicKey SEQUENCE' end
        inner = seq_contents
        first_tag, first_contents, next_pos = der_read(inner, 1)
    end

    if first_tag ~= 0x02 then return nil, nil, 'expected modulus INTEGER' end
    local e_tag, e_contents = der_read(inner, next_pos)
    if e_tag ~= 0x02 then return nil, nil, 'expected exponent INTEGER' end

    local n = der_uint(first_contents)
    local e = der_uint(e_contents)
    if #n < 64 then return nil, nil, 'rsa modulus too small' end
    return n, e
end

-- ---------------------------------------------------------------------------

function M.verify(pem, message, signature)
    local n, e, err = M.parse_public_key(pem)
    if not n then return false, err end
    if #n < 256 or #n > 512 or e ~= '\1\0\1' then return false, 'RSA 2048-4096 / exponent 65537 required' end
    if type(signature) ~= 'string' or #signature ~= #n then return false, 'invalid signature length' end
    local encoded = mod_exp(signature, e, n)
    if not encoded then return false, 'invalid signature' end
    local prefix = xutils.hex_decode('3031300d060960864801650304020105000420')
    local digest = prefix .. xutils.sha256(message)
    local expected = '\0\1' .. string.rep('\255', #n - #digest - 3) .. '\0' .. digest
    return encoded == expected, encoded == expected and nil or 'signature mismatch'
end
return M
