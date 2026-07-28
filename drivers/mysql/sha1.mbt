// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Rotate a 32-bit word left by `n` bits.
fn rotl32(x : UInt, n : Int) -> UInt {
  (x << n) | (x >> (32 - n))
}

///|
/// The byte at bit-position `shift` of a 32-bit word (big-endian extraction).
fn u32_byte(x : UInt, shift : Int) -> Byte {
  ((x >> shift) & 0xFF).reinterpret_as_int().to_byte()
}

///|
/// SHA-1 (FIPS 180-4) over `msg`, returning the 20-byte digest.
///
/// MoonBit's core ships no SHA-1, but mysql_native_password's challenge-response
/// is built entirely on it (`SHA1(password) XOR SHA1(salt + SHA1(SHA1(password)))`),
/// so the driver carries its own. Pure and allocation-simple; verified against
/// the FIPS/NIST test vectors in the suite.
pub fn sha1(msg : Bytes) -> Bytes {
  let ml = msg.length()
  // Padded length = message ++ 0x80 ++ zero-fill to 56 mod 64 ++ 8-byte bit count.
  let base = ml + 1 + 8
  let rem = base % 64
  let total = if rem == 0 { base } else { base + (64 - rem) }
  let buf = FixedArray::make(total, b'\x00')
  for i in 0..<ml {
    buf[i] = msg[i]
  }
  buf[ml] = b'\x80'
  let bitlen = ml.to_int64() * 8L
  for i in 0..<8 {
    buf[total - 1 - i] = ((bitlen >> (i * 8)) & 0xFFL).to_byte()
  }
  let mut h0 = (0x67452301 : UInt)
  let mut h1 = (0xEFCDAB89 : UInt)
  let mut h2 = (0x98BADCFE : UInt)
  let mut h3 = (0x10325476 : UInt)
  let mut h4 = (0xC3D2E1F0 : UInt)
  let w = FixedArray::make(80, 0U)
  let chunks = total / 64
  let all_ones = 0xFFFFFFFFU
  for c in 0..<chunks {
    let p = c * 64
    for i in 0..<16 {
      let j = p + i * 4
      w[i] = (buf[j].to_int().reinterpret_as_uint() << 24) |
        (buf[j + 1].to_int().reinterpret_as_uint() << 16) |
        (buf[j + 2].to_int().reinterpret_as_uint() << 8) |
        buf[j + 3].to_int().reinterpret_as_uint()
    }
    for i in 16..<80 {
      w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
    }
    let mut a = h0
    let mut b = h1
    let mut cc = h2
    let mut d = h3
    let mut e = h4
    for i in 0..<80 {
      let f = if i < 20 {
        (b & cc) | ((b ^ all_ones) & d)
      } else if i < 40 {
        b ^ cc ^ d
      } else if i < 60 {
        (b & cc) | (b & d) | (cc & d)
      } else {
        b ^ cc ^ d
      }
      let k = if i < 20 {
        0x5A827999U
      } else if i < 40 {
        0x6ED9EBA1U
      } else if i < 60 {
        0x8F1BBCDCU
      } else {
        0xCA62C1D6U
      }
      let tmp = rotl32(a, 5) + f + e + k + w[i]
      e = d
      d = cc
      cc = rotl32(b, 30)
      b = a
      a = tmp
    }
    h0 = h0 + a
    h1 = h1 + b
    h2 = h2 + cc
    h3 = h3 + d
    h4 = h4 + e
  }
  let out = Buffer()
  for h in [h0, h1, h2, h3, h4] {
    out.write_byte(u32_byte(h, 24))
    out.write_byte(u32_byte(h, 16))
    out.write_byte(u32_byte(h, 8))
    out.write_byte(u32_byte(h, 0))
  }
  out.to_bytes()
}
