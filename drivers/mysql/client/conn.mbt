// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A live MySQL connection over a raw TCP socket, speaking the wire protocol in
/// pure MoonBit. This is the asynchronous, full-fidelity driver: it owns the
/// socket for its whole lifetime, so `begin`/`commit`/`rollback` bracket a real
/// server-side transaction. The synchronous `@moondb.Driver` adapter
/// ([`MysqlDriver`]) is layered on top for the moondb contract.
///
/// Framing is the classic 3-byte little-endian length + 1-byte sequence id
/// header; the transport transparently reassembles the `0xFFFFFF` continuation
/// frames a large payload is split into.
pub struct MysqlConn {
  tcp : @socket.Tcp
  mut seq : Int
  mut closed : Bool
  mut server_kind : @moon_mysql.ServerKind
}

///|
/// The dialect (MySQL or MariaDB) reported by the server's handshake.
pub fn MysqlConn::server_kind(self : MysqlConn) -> @moon_mysql.ServerKind {
  self.server_kind
}

///|
/// Read one logical packet payload, reassembling `0xFFFFFF`-length continuation
/// frames. Updates the connection's last-seen sequence id.
async fn MysqlConn::read_packet(self : MysqlConn) -> Bytes {
  let out = Buffer()
  for ;; {
    let hdr = self.tcp.read_exactly(4)
    let len = hdr[0].to_int() | (hdr[1].to_int() << 8) | (hdr[2].to_int() << 16)
    self.seq = hdr[3].to_int()
    if len > 0 {
      out.write_bytes(self.tcp.read_exactly(len)[:])
    }
    if len < 0xFFFFFF {
      break
    }
  }
  out.to_bytes()
}

///|
/// Write one packet: the header (payload length + `seq`) then the payload.
async fn MysqlConn::write_packet(
  self : MysqlConn,
  seq : Int,
  payload : Bytes,
) -> Unit {
  let buf = Buffer()
  let n = payload.length()
  buf.write_byte((n & 0xFF).to_byte())
  buf.write_byte(((n >> 8) & 0xFF).to_byte())
  buf.write_byte(((n >> 16) & 0xFF).to_byte())
  buf.write_byte((seq & 0xFF).to_byte())
  buf.write_bytes(payload[:])
  self.tcp.write(buf.to_bytes())
}

///|
/// Open a connection to `host:port` and complete the auth handshake against
/// `user`/`password`, selecting `database` (empty for none). Works against both
/// MySQL and MariaDB (the reported dialect is on [`server_kind`]).
///
/// mysql_native_password and caching_sha2_password (MySQL 8's default, including
/// the RSA full-auth path on a cache miss) are handled directly, whether the
/// server drives them from its default or via an AuthSwitchRequest. A switch to any
/// other plugin (e.g. client_ed25519, on the README roadmap) raises
/// [`@moon_mysql.MysqlError::UnsupportedError`].
pub async fn MysqlConn::connect(
  host : String,
  port : Int,
  user : String,
  password : String,
  database : String,
) -> MysqlConn {
  let addr = @socket.Addr::resolve(host, port~)
  let tcp = @socket.Tcp::connect(addr)
  let conn = MysqlConn::{
    tcp,
    seq: 0,
    closed: false,
    server_kind: @moon_mysql.ServerKind::MySQL,
  }
  let pw = @utf8.encode(password[:])
  let handshake = @moon_mysql.parse_handshake(conn.read_packet())
  conn.server_kind = handshake.server_kind
  let response = @moon_mysql.build_handshake_response(
    handshake, user, pw, database,
  )
  // The handshake response is sequence id 1 (the server's handshake was 0).
  conn.write_packet(conn.seq + 1, response)
  let auth = conn.read_packet()
  if @moon_mysql.is_err_packet(auth) {
    raise @moon_mysql.parse_err(auth)
  }
  if @moon_mysql.is_ok_packet(auth) {
    return conn
  }
  // AuthSwitchRequest (0xFE + body): the server offers a different plugin — answer
  // mysql_native_password directly, or caching_sha2_password via its scramble +
  // AuthMoreData exchange.
  if @moon_mysql.is_auth_switch_request(auth) {
    let (plugin, new_salt) = @moon_mysql.parse_auth_switch_request(auth)
    if plugin == "mysql_native_password" || plugin == "" {
      conn.write_packet(
        conn.seq + 1,
        @moon_mysql.native_password_scramble(pw, new_salt),
      )
      let final_pkt = conn.read_packet()
      if @moon_mysql.is_err_packet(final_pkt) {
        raise @moon_mysql.parse_err(final_pkt)
      }
      if @moon_mysql.is_ok_packet(final_pkt) {
        return conn
      }
      conn.tcp.close()
      raise @moon_mysql.UnsupportedError(
        "unexpected packet after mysql_native_password auth-switch",
      )
    }
    if plugin == "caching_sha2_password" {
      conn.write_packet(
        conn.seq + 1,
        @moon_mysql.caching_sha2_scramble(pw, new_salt),
      )
      conn.finish_caching_sha2(pw, new_salt, conn.read_packet())
      return conn
    }
    conn.tcp.close()
    raise @moon_mysql.UnsupportedError(
      "server requested auth-switch to '" +
      plugin +
      "'; only mysql_native_password and caching_sha2_password are implemented (client_ed25519 is on the README roadmap)",
    )
  }
  // AuthMoreData (lead byte 0x01): the caching_sha2 reply to the fast scramble we
  // already sent in the handshake response.
  if auth.length() >= 1 && auth[0].to_int() == 0x01 {
    conn.finish_caching_sha2(pw, handshake.salt, auth)
    return conn
  }
  conn.tcp.close()
  raise @moon_mysql.UnsupportedError("unexpected packet during authentication")
}

///|
/// Drive the caching_sha2_password exchange to completion given the server's
/// AuthMoreData reply to the fast scramble. `0x03` is fast-auth success (a cached
/// digest); `0x04` needs full auth — without TLS the client fetches the server's
/// RSA public key and returns the nonce-obfuscated password RSA-OAEP encrypted
/// under it. `nonce` is the same salt the fast scramble used.
async fn MysqlConn::finish_caching_sha2(
  self : MysqlConn,
  pw : Bytes,
  nonce : Bytes,
  more_data : Bytes,
) -> Unit {
  guard more_data.length() >= 2 && more_data[0].to_int() == 0x01 else {
    self.tcp.close()
    raise @moon_mysql.ProtocolError("caching_sha2: expected AuthMoreData")
  }
  match more_data[1].to_int() {
    0x03 => self.expect_ok_or_err(self.read_packet()) // fast auth success
    0x04 => {
      // Request the server's RSA public key (no TLS ⇒ full auth over RSA).
      self.write_packet(self.seq + 1, b"\x02")
      let key_pkt = self.read_packet()
      guard key_pkt.length() >= 1 && key_pkt[0].to_int() == 0x01 else {
        self.tcp.close()
        raise @moon_mysql.ProtocolError("caching_sha2: expected public key")
      }
      let pem = @moon_mysql.bytes_to_string(key_pkt[1:].to_owned())
      let seed = match @env.rand(20) {
        Some(b) => b
        None => {
          self.tcp.close()
          raise @moon_mysql.ProtocolError("no CSPRNG for the OAEP seed")
        }
      }
      let token = @moon_mysql.caching_sha2_full_auth_token(pw, nonce, pem, seed)
      self.write_packet(self.seq + 1, token)
      self.expect_ok_or_err(self.read_packet())
    }
    other => {
      self.tcp.close()
      raise @moon_mysql.ProtocolError(
        "caching_sha2: unexpected status " + other.to_string(),
      )
    }
  }
}

///|
/// A terminal auth packet must be OK (success) or ERR (raise); anything else is a
/// protocol violation.
fn MysqlConn::expect_ok_or_err(
  self : MysqlConn,
  pkt : Bytes,
) -> Unit raise @moon_mysql.MysqlError {
  if @moon_mysql.is_err_packet(pkt) {
    raise @moon_mysql.parse_err(pkt)
  }
  if @moon_mysql.is_ok_packet(pkt) {
    return
  }
  self.tcp.close()
  raise @moon_mysql.ProtocolError("unexpected packet after caching_sha2 auth")
}

///|
/// The outcome of one command: either an OK (no result set) or a materialised
/// text result set (column definitions plus raw row packets).
priv enum Outcome {
  Exec(@moon_mysql.OkPacket)
  Rows(Array[@moon_mysql.ColumnDef], Array[Bytes])
}

///|
/// Send a `COM_QUERY` carrying `query_bytes` and drive the text-protocol
/// response state machine to completion.
async fn MysqlConn::command(self : MysqlConn, query_bytes : Bytes) -> Outcome {
  if self.closed {
    raise @moondb.Closed
  }
  let payload = Buffer()
  payload.write_byte(b'\x03') // COM_QUERY
  payload.write_bytes(query_bytes[:])
  // A fresh command always starts at sequence id 0.
  self.write_packet(0, payload.to_bytes())
  let first = self.read_packet()
  if @moon_mysql.is_err_packet(first) {
    raise @moon_mysql.parse_err(first)
  }
  if @moon_mysql.is_ok_packet(first) {
    return Exec(@moon_mysql.parse_ok(first))
  }
  if first.length() > 0 && first[0].to_int() == 0xFB {
    raise @moon_mysql.UnsupportedError("LOCAL INFILE is not supported")
  }
  let reader = @moon_mysql.PacketReader::new(first)
  let column_count = reader.lenenc_uint().to_int()
  let columns : Array[@moon_mysql.ColumnDef] = []
  for _ in 0..<column_count {
    columns.push(@moon_mysql.parse_column_def(self.read_packet()))
  }
  // CLIENT_DEPRECATE_EOF is not negotiated, so an EOF closes the column block.
  let after_columns = self.read_packet()
  if @moon_mysql.is_err_packet(after_columns) {
    raise @moon_mysql.parse_err(after_columns)
  }
  let rows : Array[Bytes] = []
  // If the column-terminator was itself a row (defensive), keep it.
  if !@moon_mysql.is_eof_packet(after_columns) {
    rows.push(after_columns)
  }
  for ;; {
    let p = self.read_packet()
    if @moon_mysql.is_err_packet(p) {
      raise @moon_mysql.parse_err(p)
    }
    if @moon_mysql.is_eof_packet(p) {
      break
    }
    rows.push(p)
  }
  Rows(columns, rows)
}

///|
/// Run a non-row statement (`params` bound as escaped literals) and report the
/// rows affected and last insert id.
pub async fn MysqlConn::execute(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult {
  match self.command(@moon_mysql.bind_params(sql, params)) {
    Exec(ok) =>
      @moondb.ExecResult::{
        rows_affected: ok.affected_rows,
        last_insert_id: ok.last_insert_id,
      }
    Rows(_, _) =>
      raise @moon_mysql.ProtocolError(
        "execute() was given a row-returning statement; use query()",
      )
  }
}

///|
/// Run a row-returning statement and materialise every [`@moondb.Row`].
pub async fn MysqlConn::query(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] {
  match self.command(@moon_mysql.bind_params(sql, params)) {
    Rows(columns, row_payloads) =>
      @moon_mysql.build_text_rows(columns, row_payloads)
    Exec(_) => []
  }
}

///|
/// Begin a server-side transaction.
pub async fn MysqlConn::begin(self : MysqlConn) -> Unit {
  let _ = self.command(b"START TRANSACTION")
}

///|
/// Commit the current transaction.
pub async fn MysqlConn::commit(self : MysqlConn) -> Unit {
  let _ = self.command(b"COMMIT")
}

///|
/// Roll back the current transaction.
pub async fn MysqlConn::rollback(self : MysqlConn) -> Unit {
  let _ = self.command(b"ROLLBACK")
}

///|
/// Close the socket (best-effort, idempotent).
pub fn MysqlConn::close(self : MysqlConn) -> Unit {
  if !self.closed {
    self.closed = true
    self.tcp.close()
  }
}
