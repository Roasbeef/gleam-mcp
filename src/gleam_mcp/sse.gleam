//// Incremental SSE framing retains bytes until a complete line is available.
//// UTF-8 code points and CRLF pairs may cross native HTTP body fragments. Each
//// event is bounded independently so subscriptions do not require unbounded
//// accumulation or a lifetime limit on the stream.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

/// The bounded framing state of one response stream.
pub opaque type Decoder {
  Decoder(
    line: BitArray,
    data: List(String),
    size: Int,
    limit: Int,
    newline: Newline,
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
/// `new(1_048_576)` admits events of up to one MiB.
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
/// `feed(decoder, <<"data: hello\n\n":utf8>>)` emits `"hello"`.
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
/// `finish(decoder)` refuses a trailing data line without a blank delimiter.
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
/// `encode("{}")` returns `"data: {}\n\n"`.
pub fn encode(message: String) -> String {
  "data: " <> string.replace(message, "\n", "\ndata: ") <> "\n\n"
}
