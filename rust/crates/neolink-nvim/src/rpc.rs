//! msgpack-RPC framing: requests and notifications out, a stream of messages in.

use rmpv::Value;

/// A message from Neovim.
#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    /// Neovim asks us something (`[0, id, method, params]`).
    Request { id: u64, method: String, params: Vec<Value> },
    /// The answer to one of our requests (`[1, id, error, result]`).
    Response { id: u64, error: Option<Value>, result: Value },
    /// `[2, method, params]`: `redraw` and our own `neolink_*` notices arrive this way, in order.
    Notification { method: String, params: Vec<Value> },
}

pub fn request(id: u64, method: &str, params: Vec<Value>) -> Vec<u8> {
    encode(&Value::Array(vec![Value::from(0), Value::from(id), Value::from(method), Value::Array(params)]))
}

pub fn notification(method: &str, params: Vec<Value>) -> Vec<u8> {
    encode(&Value::Array(vec![Value::from(2), Value::from(method), Value::Array(params)]))
}

pub fn response(id: u64, error: Option<Value>, result: Value) -> Vec<u8> {
    encode(&Value::Array(vec![Value::from(1), Value::from(id), error.unwrap_or(Value::Nil), result]))
}

fn encode(value: &Value) -> Vec<u8> {
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, value).expect("writing to a Vec cannot fail");
    bytes
}

#[derive(Debug, PartialEq)]
pub enum DecodeError {
    /// The bytes are not msgpack, or not an RPC message. The stream cannot be resynchronised.
    Malformed(String),
    /// A single message larger than the bound: refused rather than buffered without limit.
    TooLarge,
}

/// Turns the bytes read from Neovim into messages, however they are split across reads.
pub struct Decoder {
    buffer: Vec<u8>,
    limit: usize,
}

impl Default for Decoder {
    fn default() -> Self {
        Decoder::new(64 * 1024 * 1024)
    }
}

impl Decoder {
    /// `limit`: the largest message accepted, in bytes.
    pub fn new(limit: usize) -> Decoder {
        Decoder { buffer: Vec::new(), limit }
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next complete message, `Ok(None)` if more bytes are needed.
    pub fn next(&mut self) -> Result<Option<Message>, DecodeError> {
        if self.buffer.is_empty() {
            return Ok(None);
        }
        let mut cursor = std::io::Cursor::new(&self.buffer[..]);
        let value = match rmpv::decode::read_value(&mut cursor) {
            Ok(value) => value,
            Err(error) => {
                let incomplete = match &error {
                    rmpv::decode::Error::InvalidMarkerRead(io) | rmpv::decode::Error::InvalidDataRead(io) => io.kind() == std::io::ErrorKind::UnexpectedEof,
                    _ => false,
                };
                if !incomplete {
                    return Err(DecodeError::Malformed(error.to_string()));
                }
                if self.buffer.len() > self.limit {
                    return Err(DecodeError::TooLarge);
                }
                return Ok(None);
            }
        };
        let consumed = cursor.position() as usize;
        self.buffer.drain(..consumed);
        parse(value).map(Some)
    }
}

fn parse(value: Value) -> Result<Message, DecodeError> {
    let malformed = |what: &str| DecodeError::Malformed(what.to_string());
    let Value::Array(mut items) = value else { return Err(malformed("a message is an array")) };
    let kind = items.first().and_then(Value::as_u64).ok_or_else(|| malformed("a message starts with its type"))?;
    match (kind, items.len()) {
        (0, 4) => {
            let params = take_array(items.pop().unwrap());
            let method = items.pop().unwrap().as_str().map(str::to_string).ok_or_else(|| malformed("a request names a method"))?;
            let id = items.pop().unwrap().as_u64().ok_or_else(|| malformed("a request has an id"))?;
            Ok(Message::Request { id, method, params })
        }
        (1, 4) => {
            let result = items.pop().unwrap();
            let error = items.pop().unwrap();
            let id = items.pop().unwrap().as_u64().ok_or_else(|| malformed("a response has an id"))?;
            Ok(Message::Response { id, error: if error.is_nil() { None } else { Some(error) }, result })
        }
        (2, 3) => {
            let params = take_array(items.pop().unwrap());
            let method = items.pop().unwrap().as_str().map(str::to_string).ok_or_else(|| malformed("a notification names a method"))?;
            Ok(Message::Notification { method, params })
        }
        _ => Err(malformed("unknown message type or length")),
    }
}

fn take_array(value: Value) -> Vec<Value> {
    match value {
        Value::Array(items) => items,
        Value::Nil => Vec::new(),
        other => vec![other],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_survive_every_split_point() {
        let mut stream = Vec::new();
        stream.extend(notification("redraw", vec![Value::Array(vec![Value::from("flush")])]));
        stream.extend(response(7, None, Value::from("ok")));
        stream.extend(request(3, "nvim_get_api_info", vec![]));
        stream.extend(response(8, Some(Value::from("E492")), Value::Nil));
        for split in 0..=stream.len() {
            let mut decoder = Decoder::default();
            let mut messages = Vec::new();
            for part in [&stream[..split], &stream[split..]] {
                decoder.push(part);
                while let Some(message) = decoder.next().unwrap() {
                    messages.push(message);
                }
            }
            assert_eq!(messages.len(), 4, "split at {split}");
            assert_eq!(messages[0], Message::Notification { method: "redraw".into(), params: vec![Value::Array(vec![Value::from("flush")])] });
            assert_eq!(messages[1], Message::Response { id: 7, error: None, result: Value::from("ok") });
            assert_eq!(messages[2], Message::Request { id: 3, method: "nvim_get_api_info".into(), params: vec![] });
            assert_eq!(messages[3], Message::Response { id: 8, error: Some(Value::from("E492")), result: Value::Nil });
        }
    }

    #[test]
    fn garbage_is_an_error_not_a_hang() {
        let mut decoder = Decoder::default();
        decoder.push(&[0xc1]); // a byte msgpack never uses
        assert!(matches!(decoder.next(), Err(DecodeError::Malformed(_))));
        let mut decoder = Decoder::default();
        decoder.push(&[0x93, 0x05, 0x00, 0x00]); // an array, but not an RPC message
        assert!(matches!(decoder.next(), Err(DecodeError::Malformed(_))));
    }

    #[test]
    fn an_endless_message_is_refused() {
        let mut decoder = Decoder::new(1024);
        // A string that claims 1 GiB.
        decoder.push(&[0xdb, 0x40, 0x00, 0x00, 0x00]);
        decoder.push(&vec![b'x'; 2048]);
        assert_eq!(decoder.next(), Err(DecodeError::TooLarge));
    }
}
