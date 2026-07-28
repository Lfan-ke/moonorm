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
/// Open a connection to `host:port` and complete a mysql_native_password
/// handshake against `user`/`password`, selecting `database` (empty for none).
/// Works against both MySQL and MariaDB (the reported dialect is on
/// [`server_kind`]).
///
/// If the server's default plugin is not native but it offers pluggable auth, the
/// client advertises mysql_native_password and answers the server's
/// AuthSwitchRequest to it — the down-negotiation MariaDB may require. A switch to
/// any other plugin, or a caching_sha2_password full-auth (`0x01` AuthMoreData),
/// raises [`@moon_mysql.MysqlError::UnsupportedError`]: client_ed25519 and
/// caching_sha2_password are on the README roadmap, not stubbed.
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
  // AuthSwitchRequest (0xFE + body): honour it only for mysql_native_password —
  // the plugin MariaDB offers when its default differs but the account is native.
  if @moon_mysql.is_auth_switch_request(auth) {
    let (plugin, new_salt) = @moon_mysql.parse_auth_switch_request(auth)
    if plugin == "mysql_native_password" || plugin == "" {
      let reply = @moon_mysql.native_password_scramble(pw, new_salt)
      conn.write_packet(conn.seq + 1, reply)
      let final_pkt = conn.read_packet()
      if @moon_mysql.is_err_packet(final_pkt) {
        raise @moon_mysql.parse_err(final_pkt)
      }
      if @moon_mysql.is_ok_packet(final_pkt) {
        return conn
      }
      conn.tcp.close()
      raise @moon_mysql.UnsupportedError(
        "unexpected packet after mysql_native_password auth-switch (caching_sha2 full-auth is on the README roadmap)",
      )
    }
    conn.tcp.close()
    raise @moon_mysql.UnsupportedError(
      "server requested auth-switch to '" +
      plugin +
      "'; only mysql_native_password is implemented (client_ed25519 / caching_sha2_password are on the README roadmap)",
    )
  }
  // 0x01 = AuthMoreData (caching_sha2_password full auth) or anything unexpected.
  conn.tcp.close()
  raise @moon_mysql.UnsupportedError(
    "server drove a caching_sha2_password full-auth exchange; only mysql_native_password is implemented this round — see README roadmap",
  )
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
