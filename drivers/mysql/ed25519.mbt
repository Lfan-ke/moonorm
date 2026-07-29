// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Ed25519 signing (RFC 8032) for MariaDB's client_ed25519 auth. The client proves
// the password by signing the server's 32-byte challenge; MariaDB derives the
// signing key by treating SHA-512(password) as the expanded secret (where stock
// Ed25519 would expand a 32-byte seed), the rest is deterministic RFC 8032 §5.1.6.
// Only the signing half is needed here — the server verifies — so point
// decompression and the verify equation are deliberately absent.
//
// Curve constants (RFC 8032) as big integers on the builtin BigInt: `p = 2^255-19`
// the field prime, `d` the curve coefficient, `l` the group order, `(bx, by)` the
// base point. Values are computed from the definition, not transcribed.

///|
let ed_p : BigInt = BigInt::from_string(
  "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED",
  radix=16,
)

///|
let ed_d : BigInt = BigInt::from_string(
  "52036CEE2B6FFE738CC740797779E89800700A4D4141D8AB75EB4DCA135978A3",
  radix=16,
)

///|
let ed_l : BigInt = BigInt::from_string(
  "1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED",
  radix=16,
)

///|
let ed_bx : BigInt = BigInt::from_string(
  "216936D3CD6E53FEC0A4E231FDD6DC5C692CC7609525A7B2C9562D608F25D51A",
  radix=16,
)

///|
let ed_by : BigInt = BigInt::from_string(
  "6666666666666666666666666666666666666666666666666666666666666658",
  radix=16,
)

///|
/// A point on Edwards25519 in affine coordinates. The twisted-Edwards addition law
/// (a = -1) is complete, identity `(0, 1)`, so no infinity flag is needed.
priv struct EdPoint {
  x : BigInt
  y : BigInt
}

///|
fn edmod(a : BigInt) -> BigInt {
  let m = a % ed_p
  if m < (0 : BigInt) {
    m + ed_p
  } else {
    m
  }
}

///|
fn edmod_l(a : BigInt) -> BigInt {
  let m = a % ed_l
  if m < (0 : BigInt) {
    m + ed_l
  } else {
    m
  }
}

///|
fn edinv(a : BigInt) -> BigInt {
  edmod(a).pow(ed_p - 2, modulus=ed_p)
}

///|
fn ed_add(pp : EdPoint, qq : EdPoint) -> EdPoint {
  let x1 = pp.x
  let y1 = pp.y
  let x2 = qq.x
  let y2 = qq.y
  let dxy = edmod(ed_d * x1 * x2 * y1 * y2)
  let x3 = edmod((x1 * y2 + x2 * y1) * edinv(edmod(1 + dxy)))
  let y3 = edmod((y1 * y2 + x1 * x2) * edinv(edmod(1 - dxy)))
  { x: x3, y: y3 }
}

///|
/// Scalar multiplication `e · pt` by double-and-add.
fn ed_mul(e : BigInt, pt : EdPoint) -> EdPoint {
  let mut result : EdPoint = { x: 0, y: 1 }
  let mut addend = pt
  let mut k = e
  while k > (0 : BigInt) {
    if k % 2 == (1 : BigInt) {
      result = ed_add(result, addend)
    }
    addend = ed_add(addend, addend)
    k = k / 2
  }
  result
}

///|
/// Interpret `b` as a little-endian unsigned integer (Ed25519's byte order).
fn ed_le_int(b : Bytes) -> BigInt {
  let buf = Buffer()
  for i = b.length() - 1; i >= 0; i = i - 1 {
    buf.write_byte(b[i])
  }
  BigInt::from_octets(buf.to_bytes()[:])
}

///|
/// Encode a point as its 32-byte little-endian compressed form (RFC 8032 §5.1.2):
/// `y` in the low 255 bits, the parity of `x` in the top bit.
fn ed_encode_point(pt : EdPoint) -> Bytes {
  let be = edmod(pt.y).to_octets(length=32)
  let buf = Buffer()
  for i = 31; i >= 1; i = i - 1 {
    buf.write_byte(be[i])
  }
  let parity = if edmod(pt.x) % 2 == (1 : BigInt) { 0x80 } else { 0 }
  buf.write_byte((be[0].to_int() | parity).to_byte())
  buf.to_bytes()
}

///|
/// A big integer as `length` little-endian bytes (Ed25519's byte order for `S`).
fn ed_int_to_le(n : BigInt, length : Int) -> Bytes {
  let be = n.to_octets(length~)
  let buf = Buffer()
  for i = length - 1; i >= 0; i = i - 1 {
    buf.write_byte(be[i])
  }
  buf.to_bytes()
}

///|
/// Expand an Ed25519 secret (RFC 8032 §5.1.5): `SHA-512(secret)`, the low 32 bytes
/// clamped (`&= 0xF8`, top two bits forced) as the little-endian scalar, the high
/// 32 bytes as the PRF prefix. MariaDB feeds the password as the secret directly.
fn ed_expand(secret : Bytes) -> (BigInt, Bytes) {
  let h = sha512(secret)
  let abuf = Buffer()
  abuf.write_byte((h[0].to_int() & 0xF8).to_byte())
  for i = 1; i < 31; i = i + 1 {
    abuf.write_byte(h[i])
  }
  abuf.write_byte(((h[31].to_int() & 0x7F) | 0x40).to_byte())
  let s = ed_le_int(abuf.to_bytes())
  let pbuf = Buffer()
  for i = 32; i < 64; i = i + 1 {
    pbuf.write_byte(h[i])
  }
  (s, pbuf.to_bytes())
}

///|
/// Ed25519 signing (RFC 8032 §5.1.6), deterministic, keyed by `secret` (expanded
/// via [`ed_expand`]). Returns the 64-byte `R || S`: `r = SHA-512(prefix || M) mod
/// l`, `R = [r]B`, `k = SHA-512(R || A || M) mod l`, `S = (r + k·s) mod l`.
pub fn ed25519_sign(secret : Bytes, msg : Bytes) -> Bytes {
  let base : EdPoint = { x: ed_bx, y: ed_by }
  let (s, prefix) = ed_expand(secret)
  let big_a = ed_encode_point(ed_mul(s, base))
  let rbuf = Buffer()
  rbuf.write_bytes(prefix[:])
  rbuf.write_bytes(msg[:])
  let r = edmod_l(ed_le_int(sha512(rbuf.to_bytes())))
  let big_r = ed_encode_point(ed_mul(r, base))
  let kbuf = Buffer()
  kbuf.write_bytes(big_r[:])
  kbuf.write_bytes(big_a[:])
  kbuf.write_bytes(msg[:])
  let k = edmod_l(ed_le_int(sha512(kbuf.to_bytes())))
  let s_scalar = edmod_l(r + k * s)
  let out = Buffer()
  out.write_bytes(big_r[:])
  out.write_bytes(ed_int_to_le(s_scalar, 32)[:])
  out.to_bytes()
}

///|
/// The MariaDB client_ed25519 response: the 64-byte Ed25519 signature of the
/// server's 32-byte challenge, keyed by the password. An empty password yields an
/// empty response (matching the native-plugin convention).
pub fn mariadb_ed25519_response(password : Bytes, scramble : Bytes) -> Bytes {
  if password.length() == 0 {
    return b""
  }
  ed25519_sign(password, scramble)
}
