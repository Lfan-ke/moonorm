// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// SHA-512 (FIPS 180-4). MariaDB's client_ed25519 signs the challenge with
// Ed25519, whose PRF is SHA-512; the driver otherwise only had SHA-1/SHA-256.

///|
/// The 80 SHA-512 round constants (FIPS 180-4): the cube-root fractional parts of
/// the first 80 primes, generated not transcribed.
let sha512_k : Array[UInt64] = [
  0x428A2F98D728AE22UL, 0x7137449123EF65CDUL, 0xB5C0FBCFEC4D3B2FUL, 0xE9B5DBA58189DBBCUL,
  0x3956C25BF348B538UL, 0x59F111F1B605D019UL, 0x923F82A4AF194F9BUL, 0xAB1C5ED5DA6D8118UL,
  0xD807AA98A3030242UL, 0x12835B0145706FBEUL, 0x243185BE4EE4B28CUL, 0x550C7DC3D5FFB4E2UL,
  0x72BE5D74F27B896FUL, 0x80DEB1FE3B1696B1UL, 0x9BDC06A725C71235UL, 0xC19BF174CF692694UL,
  0xE49B69C19EF14AD2UL, 0xEFBE4786384F25E3UL, 0x0FC19DC68B8CD5B5UL, 0x240CA1CC77AC9C65UL,
  0x2DE92C6F592B0275UL, 0x4A7484AA6EA6E483UL, 0x5CB0A9DCBD41FBD4UL, 0x76F988DA831153B5UL,
  0x983E5152EE66DFABUL, 0xA831C66D2DB43210UL, 0xB00327C898FB213FUL, 0xBF597FC7BEEF0EE4UL,
  0xC6E00BF33DA88FC2UL, 0xD5A79147930AA725UL, 0x06CA6351E003826FUL, 0x142929670A0E6E70UL,
  0x27B70A8546D22FFCUL, 0x2E1B21385C26C926UL, 0x4D2C6DFC5AC42AEDUL, 0x53380D139D95B3DFUL,
  0x650A73548BAF63DEUL, 0x766A0ABB3C77B2A8UL, 0x81C2C92E47EDAEE6UL, 0x92722C851482353BUL,
  0xA2BFE8A14CF10364UL, 0xA81A664BBC423001UL, 0xC24B8B70D0F89791UL, 0xC76C51A30654BE30UL,
  0xD192E819D6EF5218UL, 0xD69906245565A910UL, 0xF40E35855771202AUL, 0x106AA07032BBD1B8UL,
  0x19A4C116B8D2D0C8UL, 0x1E376C085141AB53UL, 0x2748774CDF8EEB99UL, 0x34B0BCB5E19B48A8UL,
  0x391C0CB3C5C95A63UL, 0x4ED8AA4AE3418ACBUL, 0x5B9CCA4F7763E373UL, 0x682E6FF3D6B2B8A3UL,
  0x748F82EE5DEFB2FCUL, 0x78A5636F43172F60UL, 0x84C87814A1F0AB72UL, 0x8CC702081A6439ECUL,
  0x90BEFFFA23631E28UL, 0xA4506CEBDE82BDE9UL, 0xBEF9A3F7B2C67915UL, 0xC67178F2E372532BUL,
  0xCA273ECEEA26619CUL, 0xD186B8C721C0C207UL, 0xEADA7DD6CDE0EB1EUL, 0xF57D4F7FEE6ED178UL,
  0x06F067AA72176FBAUL, 0x0A637DC5A2C898A6UL, 0x113F9804BEF90DAEUL, 0x1B710B35131C471BUL,
  0x28DB77F523047D84UL, 0x32CAAB7B40C72493UL, 0x3C9EBE0A15C9BEBCUL, 0x431D67C49C100D4CUL,
  0x4CC5D4BECB3E42B6UL, 0x597F299CFC657E2AUL, 0x5FCB6FAB3AD6FAECUL, 0x6C44198C4A475817UL,
]

///|
fn rotr64(x : UInt64, n : Int) -> UInt64 {
  (x >> n) | (x << (64 - n))
}

///|
/// SHA-512 (FIPS 180-4), 64-bit words over 80 rounds. Messages here are far under
/// 2^64 bits, so the 128-bit length field's high half is always zero.
pub fn sha512(msg : Bytes) -> Bytes {
  let mut h0 : UInt64 = 0x6A09E667F3BCC908UL
  let mut h1 : UInt64 = 0xBB67AE8584CAA73BUL
  let mut h2 : UInt64 = 0x3C6EF372FE94F82BUL
  let mut h3 : UInt64 = 0xA54FF53A5F1D36F1UL
  let mut h4 : UInt64 = 0x510E527FADE682D1UL
  let mut h5 : UInt64 = 0x9B05688C2B3E6C1FUL
  let mut h6 : UInt64 = 0x1F83D9ABFB41BD6BUL
  let mut h7 : UInt64 = 0x5BE0CD19137E2179UL
  let bitlen = (msg.length() * 8).to_uint64()
  let buf = Buffer()
  buf.write_bytes(msg[:])
  buf.write_byte(b'\x80')
  while buf.length() % 128 != 112 {
    buf.write_byte(b'\x00')
  }
  for _high = 0; _high < 8; _high = _high + 1 {
    buf.write_byte(b'\x00')
  }
  for i = 7; i >= 0; i = i - 1 {
    buf.write_byte(((bitlen >> (i * 8)) & 0xFF).to_byte())
  }
  let data = buf.to_bytes()
  let w : Array[UInt64] = Array::make(80, 0UL)
  let nblocks = data.length() / 128
  for b = 0; b < nblocks; b = b + 1 {
    let off = b * 128
    for i = 0; i < 16; i = i + 1 {
      let j = off + i * 8
      w[i] = (data[j].to_int().to_uint64() << 56) |
        (data[j + 1].to_int().to_uint64() << 48) |
        (data[j + 2].to_int().to_uint64() << 40) |
        (data[j + 3].to_int().to_uint64() << 32) |
        (data[j + 4].to_int().to_uint64() << 24) |
        (data[j + 5].to_int().to_uint64() << 16) |
        (data[j + 6].to_int().to_uint64() << 8) |
        data[j + 7].to_int().to_uint64()
    }
    for i = 16; i < 80; i = i + 1 {
      let s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7)
      let s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    let mut a = h0
    let mut bb = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    let mut f = h5
    let mut g = h6
    let mut hh = h7
    for i = 0; i < 80; i = i + 1 {
      let s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
      let ch = (e & f) ^ (e.lnot() & g)
      let t1 = hh + s1 + ch + sha512_k[i] + w[i]
      let s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
      let maj = (a & bb) ^ (a & c) ^ (bb & c)
      let t2 = s0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = bb
      bb = a
      a = t1 + t2
    }
    h0 = h0 + a
    h1 = h1 + bb
    h2 = h2 + c
    h3 = h3 + d
    h4 = h4 + e
    h5 = h5 + f
    h6 = h6 + g
    h7 = h7 + hh
  }
  let out = Buffer()
  for hv in [h0, h1, h2, h3, h4, h5, h6, h7] {
    for k = 7; k >= 0; k = k - 1 {
      out.write_byte(((hv >> (k * 8)) & 0xFF).to_byte())
    }
  }
  out.to_bytes()
}
