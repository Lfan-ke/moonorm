// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The 64 per-round additive constants `K[i] = floor(abs(sin(i+1)) * 2^32)`
/// (RFC 1321). Hand-tabulated so MD5 stays a self-contained pure-MoonBit
/// primitive with no dependency on a `sin` at build time.
let md5_k : FixedArray[UInt] = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
  0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
  0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
  0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
  0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
  0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
  0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
  0xeb86d391,
]

///|
/// Per-round left-rotation amounts (RFC 1321): four values cycled within each
/// of the four 16-operation rounds.
let md5_s : FixedArray[Int] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9,
  14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

///|
fn rotl32(x : UInt, s : Int) -> UInt {
  (x << s) | (x >> (32 - s))
}

///|
/// The MD5 digest of `msg` as 16 raw bytes (RFC 1321). Used only for
/// PostgreSQL's `AuthenticationMD5Password` handshake; not a general-purpose
/// hashing API. Runs the standard little-endian padding + four-round
/// compression over 64-byte blocks.
pub fn md5(msg : Bytes) -> Bytes {
  let msg_len = msg.length()
  // Padded length: message + 0x80 + zeros until ≡ 56 (mod 64) + 8-byte length.
  let total = ((msg_len + 8) / 64 + 1) * 64
  let buf = FixedArray::make(total, (0 : Byte))
  for i in 0..<msg_len {
    buf[i] = msg[i]
  }
  buf[msg_len] = 0x80
  let bit_len = (msg_len * 8).to_int64()
  for i in 0..<8 {
    buf[total - 8 + i] = (bit_len >> (i * 8)).to_byte()
  }
  let mut a0 : UInt = 0x67452301
  let mut b0 : UInt = 0xefcdab89
  let mut c0 : UInt = 0x98badcfe
  let mut d0 : UInt = 0x10325476
  let m = FixedArray::make(16, (0 : UInt))
  let mut off = 0
  while off < total {
    for j in 0..<16 {
      let p = off + j * 4
      m[j] = buf[p].to_uint() |
        (buf[p + 1].to_uint() << 8) |
        (buf[p + 2].to_uint() << 16) |
        (buf[p + 3].to_uint() << 24)
    }
    let mut a = a0
    let mut b = b0
    let mut c = c0
    let mut d = d0
    for i in 0..<64 {
      let mut f : UInt = 0
      let mut g = 0
      if i < 16 {
        f = (b & c) | (b.lnot() & d)
        g = i
      } else if i < 32 {
        f = (d & b) | (d.lnot() & c)
        g = (5 * i + 1) % 16
      } else if i < 48 {
        f = b ^ c ^ d
        g = (3 * i + 5) % 16
      } else {
        f = c ^ (b | d.lnot())
        g = 7 * i % 16
      }
      f = f + a + md5_k[i] + m[g]
      a = d
      d = c
      c = b
      b = b + rotl32(f, md5_s[i])
    }
    a0 = a0 + a
    b0 = b0 + b
    c0 = c0 + c
    d0 = d0 + d
    off = off + 64
  }
  let ob = Buffer()
  let words : FixedArray[UInt] = [a0, b0, c0, d0]
  for w in 0..<4 {
    for i in 0..<4 {
      ob.write_byte((words[w] >> (i * 8)).to_byte())
    }
  }
  ob.to_bytes()
}

///|
/// Lowercase hex of `data`, e.g. the 16-byte MD5 digest rendered as its 32-char
/// hex string — the form PostgreSQL's MD5 auth concatenates and re-hashes.
pub fn hex_lower(data : Bytes) -> String {
  let digits = "0123456789abcdef"
  let buf = StringBuilder::new()
  for i in 0..<data.length() {
    let b = data[i].to_int()
    buf.write_char(digits[b >> 4].unsafe_to_char())
    buf.write_char(digits[b & 0xf].unsafe_to_char())
  }
  buf.to_string()
}

///|
/// The `AuthenticationMD5Password` response token: `"md5" ++
/// hex(md5(hex(md5(password ++ user)) ++ salt))`, exactly per the PostgreSQL
/// frontend/backend protocol. `salt` is the four bytes the server sent.
pub fn pg_md5_password(
  user : String,
  password : String,
  salt : Bytes,
) -> String {
  let inner = md5(concat_bytes(@utf8.encode(password), @utf8.encode(user)))
  let inner_hex = hex_lower(inner)
  let outer = md5(concat_bytes(@utf8.encode(inner_hex), salt))
  "md5" + hex_lower(outer)
}
