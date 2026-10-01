//// Incremental SSE framing retains bytes until a complete line is available.
//// UTF-8 code points and CRLF pairs may cross native HTTP body fragments. Each
//// event is bounded independently so subscriptions do not require unbounded
//// accumulation or a lifetime limit on the stream.
////
//// ## Flow
////
//// feed -> scan -> segment finds byte delimiters before line validates UTF-8.
//// line collects data fields, ignores comments and unknown fields, and emits an
//// event only at a blank line. add_data charges the multiline data and separators;
//// append_line charges the pending line against the same event limit. finish checks
//// for incomplete state. encode emits data lines without ids or replay support.
////
//// Decoder updates create new records; callers keep the returned Decoder for the
//// next fragment. Decoding UTF-8 after a complete line lets a code point straddle
//// native chunks without treating a truncated prefix as corrupt input.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

/// The bounded framing state of one response stream.
pub opaque type Decoder {
  /// The pending framing state for exactly one response stream.
  Decoder(
    /// Bytes held until a complete UTF-8 line can be validated.
    line: BitArray,
    /// Completed data fields in reverse order for one pending event.
    data: List(String),
    /// Bytes charged for pending data fields and their separators.
    size: Int,
    /// The positive per-line and per-event byte allowance.
    limit: Int,
    /// Whether a preceding CR may absorb the next LF.
    newline: Newline,
    /// Whether the optional initial UTF-8 BOM can still be stripped.
    start: Start,
  )
}

type Newline {
  Ordinary
  AfterCr
}

type Start {
  FirstLine
  Started
}

/// Constructs a decoder whose individual lines and events fit the byte limit.
///
/// ## Examples
///
/// ```gleam
/// assert sse.new(0) |> result.is_error
/// assert sse.new(1024) |> result.is_ok
/// ```
pub fn new(max_event_bytes: Int) -> Result(Decoder, String) {
  case max_event_bytes > 0 {
    True -> Ok(Decoder(<<>>, [], 0, max_event_bytes, Ordinary, FirstLine))
    False -> Error("SSE byte limit must be positive")
  }
}

/// Adds a native fragment and returns only complete data-bearing events.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoder) = sse.new(1024)
/// let assert Ok(#(decoder, events)) = sse.feed(decoder, <<"data: hello\n\n":utf8>>)
/// assert events == ["hello"]
/// assert sse.finish(decoder) == Ok(Nil)
/// ```
pub fn feed(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, List(String)), String) {
  use #(decoder, events) <- result.try(scan(decoder, bytes, []))
  Ok(#(decoder, list.reverse(events)))
}

fn scan(
  decoder: Decoder,
  bytes: BitArray,
  events: List(String),
) -> Result(#(Decoder, List(String)), String) {
  case bytes, decoder.newline {
    <<10, rest:bytes>>, AfterCr ->
      scan(Decoder(..decoder, newline: Ordinary), rest, events)
    <<>>, _ -> Ok(#(decoder, events))
    _, _ -> segment(decoder, bytes, bytes, 0, events)
  }
}

// Scan delimiters as bytes and retain a whole UTF-8 line before decoding.
// CR and LF are ASCII, so finding them cannot split a code point.
fn segment(
  decoder: Decoder,
  source: BitArray,
  rest: BitArray,
  count: Int,
  events: List(String),
) -> Result(#(Decoder, List(String)), String) {
  case rest {
    <<byte:8, tail:bytes>> if byte == 10 || byte == 13 -> {
      use prefix <- result.try(
        bit_array.slice(source, 0, count)
        |> result.map_error(fn(_) { "invalid SSE fragment" }),
      )
      use decoder <- result.try(append_line(decoder, prefix))
      use #(decoder, event) <- result.try(line(decoder))
      let decoder =
        Decoder(..decoder, newline: case byte {
          13 -> AfterCr
          _ -> Ordinary
        })
      scan(decoder, tail, list.append(event, events))
    }
    <<_:8, tail:bytes>> -> segment(decoder, source, tail, count + 1, events)
    <<>> -> {
      use decoder <- result.try(append_line(decoder, source))
      Ok(#(Decoder(..decoder, newline: Ordinary), events))
    }
    _ -> Error("SSE fragment is not byte aligned")
  }
}

fn append_line(decoder: Decoder, bytes: BitArray) -> Result(Decoder, String) {
  case
    bit_array.byte_size(decoder.line)
    + bit_array.byte_size(bytes)
    + decoder.size
    > decoder.limit
  {
    True -> Error("SSE event exceeds byte limit")
    False -> Ok(Decoder(..decoder, line: bit_array.append(decoder.line, bytes)))
  }
}

// A blank line commits the pending event and resets its allowance. Comments
// and unknown fields produce no event; only data fields enter the payload.
fn line(decoder: Decoder) -> Result(#(Decoder, List(String)), String) {
  use text <- result.try(
    bit_array.to_string(decoder.line)
    |> result.map_error(fn(_) { "invalid UTF-8 SSE line" }),
  )
  let text = case decoder.start {
    FirstLine ->
      case text {
        "\u{feff}" <> rest -> rest
        _ -> text
      }
    Started -> text
  }
  let decoder = Decoder(..decoder, line: <<>>, start: Started)
  case text {
    "" -> {
      let events = case decoder.data {
        [] -> []
        data -> [string.join(list.reverse(data), "\n")]
      }
      Ok(#(Decoder(..decoder, data: [], size: 0), events))
    }
    ":" <> _ -> Ok(#(decoder, []))
    "data" -> add_data(decoder, "")
    "data:" <> rest ->
      case rest {
        " " <> rest -> add_data(decoder, rest)
        _ -> add_data(decoder, rest)
      }
    _ -> Ok(#(decoder, []))
  }
}

fn add_data(
  decoder: Decoder,
  data: String,
) -> Result(#(Decoder, List(String)), String) {
  let size = decoder.size + bit_array.byte_size(<<data:utf8>>) + 1
  case size > decoder.limit {
    True -> Error("SSE event exceeds byte limit")
    False -> Ok(#(Decoder(..decoder, data: [data, ..decoder.data], size:), []))
  }
}

/// Detects an unfinished event when the native stream terminates.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoder) = sse.new(1024)
/// let assert Ok(#(decoder, _)) = sse.feed(decoder, <<"data: hello\n":utf8>>)
/// assert sse.finish(decoder) |> result.is_error
/// ```
pub fn finish(decoder: Decoder) -> Result(Nil, String) {
  case decoder.line, decoder.data {
    <<>>, [] -> Ok(Nil)
    _, _ -> Error("SSE stream ended during an event")
  }
}

/// Frames one complete JSON-RPC message without event identifiers or resume state.
///
/// ## Examples
///
/// ```gleam
/// assert sse.encode("{}") == "data: {}\n\n"
/// ```
pub fn encode(message: String) -> String {
  "data: " <> string.replace(message, "\n", "\ndata: ") <> "\n\n"
}
