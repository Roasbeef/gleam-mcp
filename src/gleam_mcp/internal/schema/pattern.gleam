//// JSON Schema recommends ECMAScript regular expressions. The maintained OTP
//// backend uses PCRE2, whose shorthand classes and line boundaries differ. This
//// adapter translates an explicit shared subset before compilation and refuses
//// backend extensions or escapes whose meaning it cannot preserve.
////
//// Character classes, quantifiers, alternation, groups, and lookarounds retain
//// their shared syntax. ASCII digit/word shorthands, Unicode whitespace, dot,
//// and end-of-input assertions receive explicit equivalents. Unicode escapes
//// become literal codepoints, and general-category properties use shared aliases.

import gleam/int
import gleam/list
import gleam/regexp.{type CompileError, type Regexp}
import gleam/result
import gleam/string

type Position {
  OutsideClass
  InsideClass
}

const whitespace = "\u{0009}-\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"

/// Compiles a pattern only when the shared subset preserves its assertion.
/// Unsupported forms produce a construction error before a tool is admitted.
///
/// ## Examples
///
/// ```gleam
/// // pattern.compile("\\p{Letter}+") recognizes Unicode general-category letters.
/// // pattern.compile("(?i)secret") rejects a backend-specific inline flag.
/// ```
pub fn compile(source: String) -> Result(Regexp, CompileError) {
  use translated <- result.try(
    translate(string.to_graphemes(source), OutsideClass, []),
  )
  regexp.from_string(translated)
}

fn translate(
  chars: List(String),
  position: Position,
  output: List(String),
) -> Result(String, CompileError) {
  case chars {
    [] -> Ok(output |> list.reverse |> string.concat)
    ["\\", escape, ..rest] -> {
      use #(replacement, rest) <- result.try(escaped(escape, rest, position))
      translate(rest, position, [replacement, ..output])
    }
    ["\\"] -> unsupported("trailing escape")
    ["[", ..rest] ->
      case position {
        OutsideClass -> translate(rest, InsideClass, ["[", ..output])
        InsideClass -> unsupported("nested or POSIX character class")
      }
    ["]", ..rest] -> translate(rest, OutsideClass, ["]", ..output])
    ["(", "*", ..] if position == OutsideClass ->
      unsupported("backtracking control verb")
    ["(", "?", ..rest] if position == OutsideClass -> group(rest, output)
    ["*", "+", ..]
      | ["+", "+", ..]
      | ["?", "+", ..]
      | ["}", "+", ..]
      if position == OutsideClass
    -> unsupported("possessive quantifier")
    ["$", ..rest] if position == OutsideClass ->
      translate(rest, position, ["(?![\\s\\S])", ..output])
    [".", ..rest] if position == OutsideClass ->
      translate(rest, position, ["[^\n\r\u{2028}\u{2029}]", ..output])
    [char, ..rest] -> translate(rest, position, [char, ..output])
  }
}

fn group(
  rest: List(String),
  output: List(String),
) -> Result(String, CompileError) {
  case rest {
    [":" as kind, ..rest] | ["=" as kind, ..rest] | ["!" as kind, ..rest] ->
      translate(rest, OutsideClass, ["(?" <> kind, ..output])
    ["<", "=" as kind, ..rest] | ["<", "!" as kind, ..rest] ->
      translate(rest, OutsideClass, ["(?<" <> kind, ..output])
    _ -> unsupported("group extension or named capture")
  }
}

fn escaped(
  escape: String,
  rest: List(String),
  position: Position,
) -> Result(#(String, List(String)), CompileError) {
  case escape {
    "d" -> Ok(#(character_class("0-9", position), rest))
    "w" -> Ok(#(character_class("A-Za-z0-9_", position), rest))
    "s" -> Ok(#(character_class(whitespace, position), rest))
    "D" -> complemented_class("0-9", rest, position)
    "W" -> complemented_class("A-Za-z0-9_", rest, position)
    "S" -> complemented_class(whitespace, rest, position)
    "b" ->
      case position {
        InsideClass -> Ok(#("\u{0008}", rest))
        OutsideClass ->
          Ok(#(
            "(?:(?<![A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<=[A-Za-z0-9_])(?![A-Za-z0-9_]))",
            rest,
          ))
      }
    "B" ->
      case position {
        InsideClass ->
          unsupported("word-boundary complement inside a character class")
        OutsideClass ->
          Ok(#(
            "(?:(?<=[A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<![A-Za-z0-9_])(?![A-Za-z0-9_]))",
            rest,
          ))
      }
    "p" | "P" -> property(escape, rest)
    "u" -> unicode_escape(rest, position)
    "x" -> fixed_escape(rest, 2, position)
    "v" -> Ok(#("\u{000B}", rest))
    "0" ->
      case rest {
        [digit, ..] ->
          case
            list.contains(
              ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
              digit,
            )
          {
            True -> unsupported("octal escape")
            False -> Ok(#("\u{0000}", rest))
          }
        _ -> Ok(#("\u{0000}", rest))
      }
    "c" -> control_escape(rest)
    "n"
    | "r"
    | "t"
    | "f"
    | "\\"
    | "/"
    | "^"
    | "$"
    | "."
    | "*"
    | "+"
    | "?"
    | "("
    | ")"
    | "["
    | "]"
    | "{"
    | "}"
    | "|"
    | "-" -> Ok(#("\\" <> escape, rest))
    _ -> unsupported("escape or backreference")
  }
}

fn character_class(contents: String, position: Position) -> String {
  case position {
    InsideClass -> contents
    OutsideClass -> "[" <> contents <> "]"
  }
}

fn complemented_class(
  contents: String,
  rest: List(String),
  position: Position,
) -> Result(#(String, List(String)), CompileError) {
  case position {
    InsideClass ->
      unsupported("complemented shorthand inside a character class")
    OutsideClass -> Ok(#("[^" <> contents <> "]", rest))
  }
}

fn property(
  escape: String,
  rest: List(String),
) -> Result(#(String, List(String)), CompileError) {
  case rest {
    ["{", ..rest] -> {
      use #(name, rest) <- result.try(until_brace(rest, []))
      use alias <- result.try(category(name))
      Ok(#("\\" <> escape <> "{" <> alias <> "}", rest))
    }
    _ -> unsupported("Unicode property without braces")
  }
}

fn category(name: String) -> Result(String, CompileError) {
  let aliases = [
    #("Letter", "L"),
    #("Lowercase_Letter", "Ll"),
    #("Uppercase_Letter", "Lu"),
    #("Titlecase_Letter", "Lt"),
    #("Modifier_Letter", "Lm"),
    #("Other_Letter", "Lo"),
    #("Mark", "M"),
    #("Nonspacing_Mark", "Mn"),
    #("Spacing_Mark", "Mc"),
    #("Enclosing_Mark", "Me"),
    #("Number", "N"),
    #("Decimal_Number", "Nd"),
    #("Letter_Number", "Nl"),
    #("Other_Number", "No"),
    #("Punctuation", "P"),
    #("Connector_Punctuation", "Pc"),
    #("Dash_Punctuation", "Pd"),
    #("Close_Punctuation", "Pe"),
    #("Final_Punctuation", "Pf"),
    #("Initial_Punctuation", "Pi"),
    #("Other_Punctuation", "Po"),
    #("Open_Punctuation", "Ps"),
    #("Symbol", "S"),
    #("Currency_Symbol", "Sc"),
    #("Modifier_Symbol", "Sk"),
    #("Math_Symbol", "Sm"),
    #("Other_Symbol", "So"),
    #("Separator", "Z"),
    #("Line_Separator", "Zl"),
    #("Paragraph_Separator", "Zp"),
    #("Space_Separator", "Zs"),
    #("Other", "C"),
    #("Control", "Cc"),
    #("Format", "Cf"),
    #("Unassigned", "Cn"),
    #("Private_Use", "Co"),
    #("Surrogate", "Cs"),
  ]
  let name =
    name
    |> string.remove_prefix("General_Category=")
    |> string.remove_prefix("gc=")
  case list.key_find(aliases, name) {
    Ok(alias) -> Ok(alias)
    Error(_) ->
      case list.any(aliases, fn(pair) { pair.1 == name }) {
        True -> Ok(name)
        False -> unsupported("Unicode property outside general categories")
      }
  }
}

fn until_brace(
  rest: List(String),
  output: List(String),
) -> Result(#(String, List(String)), CompileError) {
  case rest {
    ["}", ..rest] -> Ok(#(output |> list.reverse |> string.concat, rest))
    [char, ..rest] -> until_brace(rest, [char, ..output])
    [] -> unsupported("unclosed Unicode escape")
  }
}

fn unicode_escape(
  rest: List(String),
  position: Position,
) -> Result(#(String, List(String)), CompileError) {
  case rest {
    ["{", ..rest] -> {
      use #(hex, rest) <- result.try(until_brace(rest, []))
      use character <- result.try(hex_character(hex, position))
      Ok(#(character, rest))
    }
    _ -> fixed_escape(rest, 4, position)
  }
}

fn fixed_escape(
  rest: List(String),
  length: Int,
  position: Position,
) -> Result(#(String, List(String)), CompileError) {
  let #(digits, rest) = list.split(rest, length)
  case list.length(digits) == length {
    False -> unsupported("short hexadecimal escape")
    True -> {
      use character <- result.try(hex_character(string.concat(digits), position))
      Ok(#(character, rest))
    }
  }
}

fn hex_character(
  hex: String,
  position: Position,
) -> Result(String, CompileError) {
  use _ <- result.try(
    case
      hex != ""
      && list.all(string.to_graphemes(string.lowercase(hex)), fn(char) {
        string.contains("0123456789abcdef", char)
      })
    {
      True -> Ok(Nil)
      False -> unsupported("invalid hexadecimal escape")
    },
  )
  use number <- result.try(
    int.base_parse(hex, 16)
    |> result.map_error(fn(_) { error("invalid hexadecimal escape") }),
  )
  use character <- result.try(
    string.utf_codepoint(number)
    |> result.map_error(fn(_) { error("unsupported surrogate or codepoint") }),
  )
  let text = string.from_utf_codepoints([character])
  case string.contains("\\^$.*+?()[]{}|-", text), position {
    True, _ -> Ok("\\" <> text)
    False, _ -> Ok(text)
  }
}

fn control_escape(
  rest: List(String),
) -> Result(#(String, List(String)), CompileError) {
  case rest {
    [letter, ..rest] -> {
      let codepoints = string.to_utf_codepoints(string.uppercase(letter))
      use point <- result.try(
        list.first(codepoints)
        |> result.map_error(fn(_) { error("invalid control escape") }),
      )
      let number = string.utf_codepoint_to_int(point)
      case number >= 65 && number <= 90 {
        False -> unsupported("invalid control escape")
        True -> {
          use character <- result.try(
            string.utf_codepoint(number - 64)
            |> result.map_error(fn(_) { error("invalid control escape") }),
          )
          Ok(#(string.from_utf_codepoints([character]), rest))
        }
      }
    }
    [] -> unsupported("short control escape")
  }
}

fn error(reason: String) -> CompileError {
  regexp.CompileError("unsupported ECMAScript pattern: " <> reason, 0)
}

fn unsupported(reason: String) -> Result(a, CompileError) {
  Error(error(reason))
}
