//// Evaluation carries annotation coverage alongside each successful assertion.
//// Coverage belongs to the current instance location; child-value coverage never
//// leaks to its parent. Failed branches discard annotations but retain their work
//// charge, so alternatives cannot reset the evaluator's finite allowance.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/regexp
import gleam/result
import gleam/string
import gleam_mcp/internal/schema/document.{type Document, type Node}
import gleam_mcp/internal/schema/number
import gleam_mcp/internal/schema/pattern
import gleam_mcp/internal/schema/value
import gleam_mcp/json.{type JsonValue}

/// An assertion refusal or an exhausted evaluation allowance.
pub type Error {
  /// The path and failed keyword, without echoing instance data.
  Mismatch(path: String, reason: String)

  /// Recursion or structural comparisons exhausted the evaluation allowance.
  Limit
}

type Coverage {
  Coverage(properties: Dict(String, Nil), indices: Dict(Int, Nil))
}

type Context {
  Context(
    document: Document,
    path: String,
    depth: Int,
    remaining: Int,
    scope: List(String),
  )
}

type Evaluated {
  Evaluated(result: Result(Coverage, Error), remaining: Int)
}

/// Evaluates the root after bounding the complete instance, including annotations.
///
/// ## Examples
///
/// ```gleam
/// // evaluate.validate(document, instance) returns Ok(Nil) for an accepted value.
/// ```
pub fn validate(document: Document, instance: JsonValue) -> Result(Nil, Error) {
  use _ <- result.try(
    document.bounded(instance, 0, 100_000) |> result.map_error(fn(_) { Limit }),
  )
  let context = Context(document, "", 0, 100_000, [document.entry.base])
  eval(document.entry, instance, context).result |> result.map(fn(_) { Nil })
}

fn empty() -> Coverage {
  Coverage(dict.new(), dict.new())
}

fn merge(a: Coverage, b: Coverage) -> Coverage {
  Coverage(
    dict.merge(a.properties, b.properties),
    dict.merge(a.indices, b.indices),
  )
}

fn accepted(coverage: Coverage, context: Context) -> Evaluated {
  Evaluated(Ok(coverage), context.remaining)
}

fn refused(context: Context, keyword: String) -> Evaluated {
  Evaluated(
    Error(Mismatch(context.path, "failed " <> keyword)),
    context.remaining,
  )
}

fn eval(node: Node, instance: JsonValue, context: Context) -> Evaluated {
  let scope = case list.contains(context.scope, node.base) {
    True -> context.scope
    False -> list.append(context.scope, [node.base])
  }
  let context = Context(..context, scope: scope)
  case context.remaining <= 0 || context.depth >= 128 {
    True -> Evaluated(Error(Limit), 0)
    False -> {
      let context =
        Context(
          ..context,
          remaining: context.remaining - 1,
          depth: context.depth + 1,
        )
      case node.schema {
        json.Bool(True) -> accepted(empty(), context)
        json.Bool(False) -> refused(context, "false schema")
        json.Object(_) -> evaluate_object(node, instance, context)
        _ -> refused(context, "invalid schema")
      }
    }
  }
}

fn evaluate_object(
  node: Node,
  instance: JsonValue,
  context: Context,
) -> Evaluated {
  // Structural comparisons can inspect more than one schema node. Charging
  // their conservative comparison count keeps uniqueItems and enum branches
  // within the same allowance as recursive applicators.
  let context =
    Context(
      ..context,
      remaining: context.remaining - assertion_cost(node.schema, instance),
    )
  case context.remaining < 0 {
    True -> Evaluated(Error(Limit), 0)
    False -> evaluate_keywords(node, instance, context)
  }
}

fn evaluate_keywords(
  node: Node,
  instance: JsonValue,
  context: Context,
) -> Evaluated {
  let checks = case document.enabled(context.document, node, "validation") {
    True -> assertions(node.schema, instance)
    False -> Ok(Nil)
  }
  let initial = case checks {
    Ok(_) -> accepted(empty(), context)
    Error(keyword) -> refused(context, keyword)
  }

  // Adjacent applicators contribute coverage before unevaluated keywords run.
  // Each operation receives the remaining allowance from the previous one.
  let operations = [
    #("core", references),
    #("applicator", composition),
    #("applicator", conditional),
    #("applicator", object_keywords),
    #("applicator", array_keywords),
    #("unevaluated", unevaluated),
  ]
  list.fold(operations, initial, fn(previous, operation) {
    case
      previous.result,
      document.enabled(context.document, node, operation.0)
    {
      Error(_), _ | _, False -> previous
      Ok(coverage), True ->
        operation.1(
          node,
          instance,
          Context(..context, remaining: previous.remaining),
          coverage,
        )
    }
  })
}

fn assertions(schema: JsonValue, instance: JsonValue) -> Result(Nil, String) {
  use _ <- result.try(
    assert_keyword(schema, "type", fn(types) { matches_types(types, instance) }),
  )
  use _ <- result.try(assert_keyword(schema, "const", value.equal(_, instance)))
  use _ <- result.try(
    assert_keyword(schema, "enum", fn(values) {
      value.items(values) |> list.any(value.equal(_, instance))
    }),
  )
  use _ <- result.try(numeric_assertions(schema, instance))
  case instance {
    json.String(text) -> string_assertions(schema, text)
    json.Array(items) -> array_assertions(schema, items)
    json.Object(fields) -> object_assertions(schema, fields)
    _ -> Ok(Nil)
  }
}

fn assert_keyword(
  schema: JsonValue,
  keyword: String,
  predicate: fn(JsonValue) -> Bool,
) -> Result(Nil, String) {
  case value.get(schema, keyword) {
    Error(_) -> Ok(Nil)
    Ok(data) ->
      case predicate(data) {
        True -> Ok(Nil)
        False -> Error(keyword)
      }
  }
}

fn matches_types(types: JsonValue, instance: JsonValue) -> Bool {
  case types {
    json.Array(types) -> list.any(types, matches_types(_, instance))
    json.String("integer") -> number.is_integer(instance)
    json.String("number") -> result.is_ok(number.from_json(instance))
    json.String("string") ->
      case instance {
        json.String(_) -> True
        _ -> False
      }
    json.String("object") ->
      case instance {
        json.Object(_) -> True
        _ -> False
      }
    json.String("array") ->
      case instance {
        json.Array(_) -> True
        _ -> False
      }
    json.String("boolean") ->
      case instance {
        json.Bool(_) -> True
        _ -> False
      }
    json.String("null") -> instance == json.Null
    _ -> False
  }
}

fn numeric_assertions(
  schema: JsonValue,
  instance: JsonValue,
) -> Result(Nil, String) {
  case number.from_json(instance) {
    Error(_) -> Ok(Nil)
    Ok(_) -> {
      use _ <- result.try(
        assert_keyword(schema, "minimum", fn(bound) {
          number.compare(instance, bound) != Ok(-1)
        }),
      )
      use _ <- result.try(
        assert_keyword(schema, "maximum", fn(bound) {
          number.compare(instance, bound) != Ok(1)
        }),
      )
      use _ <- result.try(
        assert_keyword(schema, "exclusiveMinimum", fn(bound) {
          number.compare(instance, bound) == Ok(1)
        }),
      )
      use _ <- result.try(
        assert_keyword(schema, "exclusiveMaximum", fn(bound) {
          number.compare(instance, bound) == Ok(-1)
        }),
      )
      assert_keyword(schema, "multipleOf", number.multiple(instance, _))
    }
  }
}

fn string_assertions(schema: JsonValue, text: String) -> Result(Nil, String) {
  let length = json.Int(list.length(string.to_utf_codepoints(text)))
  use _ <- result.try(
    assert_keyword(schema, "minLength", fn(bound) {
      number.compare(length, bound) != Ok(-1)
    }),
  )
  use _ <- result.try(
    assert_keyword(schema, "maxLength", fn(bound) {
      number.compare(length, bound) != Ok(1)
    }),
  )
  assert_keyword(schema, "pattern", fn(pattern) {
    case pattern {
      json.String(pattern) -> matches(pattern, text)
      _ -> False
    }
  })
}

fn matches(pattern: String, text: String) -> Bool {
  pattern.compile(pattern)
  |> result.map(fn(regex) { regexp.check(regex, text) })
  |> result.unwrap(False)
}

fn array_assertions(
  schema: JsonValue,
  items: List(JsonValue),
) -> Result(Nil, String) {
  let length = json.Int(list.length(items))
  use _ <- result.try(
    assert_keyword(schema, "minItems", fn(bound) {
      number.compare(length, bound) != Ok(-1)
    }),
  )
  use _ <- result.try(
    assert_keyword(schema, "maxItems", fn(bound) {
      number.compare(length, bound) != Ok(1)
    }),
  )
  assert_keyword(schema, "uniqueItems", fn(enabled) {
    enabled != json.Bool(True) || value.unique(items)
  })
}

fn object_assertions(
  schema: JsonValue,
  fields: List(#(String, JsonValue)),
) -> Result(Nil, String) {
  let length = json.Int(list.length(fields))
  use _ <- result.try(
    assert_keyword(schema, "minProperties", fn(bound) {
      number.compare(length, bound) != Ok(-1)
    }),
  )
  use _ <- result.try(
    assert_keyword(schema, "maxProperties", fn(bound) {
      number.compare(length, bound) != Ok(1)
    }),
  )
  use _ <- result.try(
    assert_keyword(schema, "required", fn(required) {
      required_names(required, fields)
    }),
  )
  assert_keyword(schema, "dependentRequired", fn(dependencies) {
    value.fields(dependencies)
    |> list.all(fn(pair) {
      list.key_find(fields, pair.0) |> result.is_error
      || required_names(pair.1, fields)
    })
  })
}

fn required_names(
  required: JsonValue,
  fields: List(#(String, JsonValue)),
) -> Bool {
  value.items(required)
  |> list.all(fn(name) {
    case name {
      json.String(name) -> list.key_find(fields, name) |> result.is_ok
      _ -> False
    }
  })
}

fn references(
  node: Node,
  instance: JsonValue,
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  list.fold(
    ["$ref", "$dynamicRef"],
    accepted(coverage, context),
    fn(previous, keyword) {
      case previous.result, value.get(node.schema, keyword) {
        Ok(coverage), Ok(json.String(reference)) -> {
          let context = Context(..context, remaining: previous.remaining)
          case document.resolve(context.document, node, reference) {
            Error(_) -> refused(context, "unresolved reference")
            Ok(target) -> {
              let target = case keyword {
                "$dynamicRef" -> dynamic_target(target, reference, context)
                _ -> target
              }
              let scope = case list.contains(context.scope, target.base) {
                True -> context.scope
                False -> list.append(context.scope, [target.base])
              }
              eval(target, instance, Context(..context, scope: scope))
              |> with_coverage(coverage)
            }
          }
        }
        _, _ -> previous
      }
    },
  )
}

// The first matching dynamic anchor belongs to the outermost active resource.
// Scope is copied into child evaluations and disappears when that child returns.
fn dynamic_target(target: Node, reference: String, context: Context) -> Node {
  case value.get(target.schema, "$dynamicAnchor") {
    Ok(json.String(anchor)) -> {
      let fragment =
        string.split(reference, "#") |> value.at(1) |> result.unwrap("")
      case fragment == anchor {
        False -> target
        True ->
          list.find_map(context.scope, fn(base) {
            use candidate <- result.try(dict.get(
              context.document.anchors,
              base <> "#" <> anchor,
            ))
            case
              value.get(candidate.schema, "$dynamicAnchor")
              == Ok(json.String(anchor))
            {
              True -> Ok(candidate)
              False -> Error(Nil)
            }
          })
          |> result.unwrap(target)
      }
    }
    _ -> target
  }
}

fn with_coverage(evaluated: Evaluated, previous: Coverage) -> Evaluated {
  Evaluated(
    ..evaluated,
    result: result.map(evaluated.result, merge(previous, _)),
  )
}

fn subnode(parent: Node, schema: JsonValue, suffix: String) -> Node {
  document.child(parent, schema, suffix) |> document.enter
}

fn composition(
  node: Node,
  instance: JsonValue,
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  list.fold(
    ["allOf", "anyOf", "oneOf", "not"],
    accepted(coverage, context),
    fn(previous, keyword) {
      case previous.result, value.get(node.schema, keyword) {
        Ok(coverage), Ok(schema) -> {
          let context = Context(..context, remaining: previous.remaining)
          combine_branches(node, instance, context, keyword, schema)
          |> with_coverage(coverage)
        }
        _, _ -> previous
      }
    },
  )
}

fn combine_branches(
  node: Node,
  instance: JsonValue,
  context: Context,
  keyword: String,
  schema: JsonValue,
) -> Evaluated {
  let schemas = case keyword {
    "not" -> [schema]
    _ -> value.items(schema)
  }
  let indexed = list.index_map(schemas, fn(schema, index) { #(schema, index) })
  let #(coverage, successes, remaining, limit) =
    list.fold(
      indexed,
      #(empty(), 0, context.remaining, Ok(Nil)),
      fn(state, pair) {
        let #(coverage, successes, remaining, limit) = state
        case limit {
          Error(_) -> state
          Ok(_) -> {
            let target =
              subnode(
                node,
                pair.0,
                "/" <> keyword <> "/" <> int.to_string(pair.1),
              )
            let evaluated =
              eval(target, instance, Context(..context, remaining: remaining))
            case evaluated.result {
              Ok(added) -> #(
                merge(coverage, added),
                successes + 1,
                evaluated.remaining,
                Ok(Nil),
              )
              Error(Limit) -> #(
                coverage,
                successes,
                evaluated.remaining,
                Error(Limit),
              )
              Error(Mismatch(_, _)) -> #(
                coverage,
                successes,
                evaluated.remaining,
                Ok(Nil),
              )
            }
          }
        }
      },
    )
  let context = Context(..context, remaining: remaining)
  let valid = case keyword {
    "allOf" -> successes == list.length(schemas)
    "anyOf" -> successes > 0
    "oneOf" -> successes == 1
    "not" -> successes == 0
    _ -> False
  }
  case limit, valid, keyword {
    Error(_), _, _ -> Evaluated(Error(Limit), remaining)
    Ok(_), False, _ -> refused(context, keyword)
    Ok(_), True, "not" -> accepted(empty(), context)
    Ok(_), True, _ -> accepted(coverage, context)
  }
}

fn conditional(
  node: Node,
  instance: JsonValue,
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  case value.get(node.schema, "if") {
    Error(_) -> accepted(coverage, context)
    Ok(condition) -> {
      let evaluated = eval(subnode(node, condition, "/if"), instance, context)
      let context = Context(..context, remaining: evaluated.remaining)
      case evaluated.result {
        Error(Limit) -> evaluated
        Error(Mismatch(_, _)) ->
          conditional_branch(node, instance, context, coverage, "else")
        Ok(added) ->
          conditional_branch(
            node,
            instance,
            context,
            merge(coverage, added),
            "then",
          )
      }
    }
  }
}

fn conditional_branch(
  node: Node,
  instance: JsonValue,
  context: Context,
  coverage: Coverage,
  keyword: String,
) -> Evaluated {
  case value.get(node.schema, keyword) {
    Error(_) -> accepted(coverage, context)
    Ok(schema) ->
      eval(subnode(node, schema, "/" <> keyword), instance, context)
      |> with_coverage(coverage)
  }
}

fn object_keywords(
  node: Node,
  instance: JsonValue,
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  case instance {
    json.Object(fields) -> {
      let initial = object_members(node, fields, context, coverage)
      case initial.result {
        Error(_) -> initial
        Ok(coverage) ->
          dependencies(
            node,
            instance,
            fields,
            Context(..context, remaining: initial.remaining),
            coverage,
          )
      }
    }
    _ -> accepted(coverage, context)
  }
}

// Successful child validation records the property name, never the child
// object's own property coverage. Annotation ownership follows instance location.
fn object_members(
  node: Node,
  fields: List(#(String, JsonValue)),
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  list.fold(fields, accepted(coverage, context), fn(previous, pair) {
    case previous.result {
      Error(_) -> previous
      Ok(coverage) -> {
        let context = Context(..context, remaining: previous.remaining)
        let schemas = member_schemas(node, pair.0)
        let name_schema = case value.get(node.schema, "propertyNames") {
          Ok(schema) -> [
            #(subnode(node, schema, "/propertyNames"), json.String(pair.0)),
          ]
          Error(_) -> []
        }
        let checks =
          list.append(
            name_schema,
            list.map(schemas, fn(schema) { #(schema, pair.1) }),
          )
        let context =
          Context(
            ..context,
            path: context.path <> "/" <> document.escape(pair.0),
          )
        let evaluated = evaluate_children(checks, context)
        let coverage = case schemas {
          [] -> coverage
          _ ->
            Coverage(
              ..coverage,
              properties: dict.insert(coverage.properties, pair.0, Nil),
            )
        }
        Evaluated(
          result.map(evaluated.result, fn(_) { coverage }),
          evaluated.remaining,
        )
      }
    }
  })
}

// additionalProperties observes only properties and patternProperties beside
// it. Coverage from other applicators belongs to unevaluatedProperties instead.
fn member_schemas(node: Node, name: String) -> List(Node) {
  let properties = value.field(node.schema, "properties", json.Object([]))
  let direct = case value.get(properties, name) {
    Ok(schema) -> [
      subnode(node, schema, "/properties/" <> document.escape(name)),
    ]
    Error(_) -> []
  }
  let patterns =
    value.field(node.schema, "patternProperties", json.Object([]))
    |> value.fields
  let matching =
    list.filter_map(patterns, fn(pair) {
      case matches(pair.0, name) {
        True ->
          Ok(subnode(
            node,
            pair.1,
            "/patternProperties/" <> document.escape(pair.0),
          ))
        False -> Error(Nil)
      }
    })
  case list.append(direct, matching) {
    [] ->
      case value.get(node.schema, "additionalProperties") {
        Ok(schema) -> [subnode(node, schema, "/additionalProperties")]
        Error(_) -> []
      }
    schemas -> schemas
  }
}

fn evaluate_children(
  checks: List(#(Node, JsonValue)),
  context: Context,
) -> Evaluated {
  list.fold(checks, accepted(empty(), context), fn(previous, check) {
    case previous.result {
      Error(_) -> previous
      Ok(_) ->
        eval(
          check.0,
          check.1,
          Context(..context, remaining: previous.remaining),
        )
    }
  })
}

fn dependencies(
  node: Node,
  instance: JsonValue,
  fields: List(#(String, JsonValue)),
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  let schemas =
    value.field(node.schema, "dependentSchemas", json.Object([]))
    |> value.fields
  list.fold(schemas, accepted(coverage, context), fn(previous, pair) {
    case previous.result, list.key_find(fields, pair.0) {
      Ok(coverage), Ok(_) -> {
        let target =
          subnode(node, pair.1, "/dependentSchemas/" <> document.escape(pair.0))
        eval(
          target,
          instance,
          Context(..context, remaining: previous.remaining),
        )
        |> with_coverage(coverage)
      }
      _, _ -> previous
    }
  })
}

fn array_keywords(
  node: Node,
  instance: JsonValue,
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  case instance {
    json.Array(items) -> {
      let initial = array_members(node, items, context, coverage)
      case initial.result {
        Error(_) -> initial
        Ok(coverage) ->
          contains(
            node,
            items,
            Context(..context, remaining: initial.remaining),
            coverage,
          )
      }
    }
    _ -> accepted(coverage, context)
  }
}

fn array_members(
  node: Node,
  items: List(JsonValue),
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  let prefix =
    value.field(node.schema, "prefixItems", json.Array([])) |> value.items
  let indexed = list.index_map(items, fn(item, index) { #(item, index) })
  list.fold(indexed, accepted(coverage, context), fn(previous, pair) {
    let schema = case value.at(prefix, pair.1) {
      Ok(schema) -> Ok(#(schema, "/prefixItems/" <> int.to_string(pair.1)))
      Error(_) ->
        value.get(node.schema, "items")
        |> result.map(fn(schema) { #(schema, "/items") })
    }
    case previous.result, schema {
      Ok(coverage), Ok(#(schema, suffix)) -> {
        let context =
          Context(
            ..context,
            remaining: previous.remaining,
            path: context.path <> "/" <> int.to_string(pair.1),
          )
        let evaluated = eval(subnode(node, schema, suffix), pair.0, context)
        let coverage =
          Coverage(
            ..coverage,
            indices: dict.insert(coverage.indices, pair.1, Nil),
          )
        Evaluated(
          result.map(evaluated.result, fn(_) { coverage }),
          evaluated.remaining,
        )
      }
      _, _ -> previous
    }
  })
}

fn contains(
  node: Node,
  items: List(JsonValue),
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  case value.get(node.schema, "contains") {
    Error(_) -> accepted(coverage, context)
    Ok(schema) -> {
      let target = subnode(node, schema, "/contains")
      let indexed = list.index_map(items, fn(item, index) { #(item, index) })
      let evaluated =
        list.fold(indexed, accepted(empty(), context), fn(previous, pair) {
          case previous.result {
            Error(_) -> previous
            Ok(found) ->
              contains_item(
                target,
                pair,
                Context(..context, remaining: previous.remaining),
                found,
              )
          }
        })
      check_contains_count(node, context, evaluated) |> with_coverage(coverage)
    }
  }
}

// A failed contains candidate contributes no index annotation but still spends
// its allowance. A limit is never interpreted as an ordinary nonmatching item.
fn contains_item(
  target: Node,
  pair: #(JsonValue, Int),
  context: Context,
  found: Coverage,
) -> Evaluated {
  let evaluated =
    eval(
      target,
      pair.0,
      Context(..context, path: context.path <> "/" <> int.to_string(pair.1)),
    )
  case evaluated.result {
    Error(Limit) -> evaluated
    Error(Mismatch(_, _)) -> Evaluated(Ok(found), evaluated.remaining)
    Ok(_) ->
      Evaluated(
        Ok(Coverage(..found, indices: dict.insert(found.indices, pair.1, Nil))),
        evaluated.remaining,
      )
  }
}

fn check_contains_count(
  node: Node,
  context: Context,
  evaluated: Evaluated,
) -> Evaluated {
  case evaluated.result {
    Error(_) -> evaluated
    Ok(found) -> {
      let count = json.Int(dict.size(found.indices))
      let minimum = value.field(node.schema, "minContains", json.Int(1))
      let maximum = value.field(node.schema, "maxContains", count)
      case
        number.compare(count, minimum) != Ok(-1)
        && number.compare(count, maximum) != Ok(1)
      {
        True -> evaluated
        False ->
          refused(
            Context(..context, remaining: evaluated.remaining),
            "contains",
          )
      }
    }
  }
}

fn unevaluated(
  node: Node,
  instance: JsonValue,
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  case instance {
    json.Object(fields) ->
      unevaluated_properties(node, fields, context, coverage)
    json.Array(items) -> unevaluated_items(node, items, context, coverage)
    _ -> accepted(coverage, context)
  }
}

fn unevaluated_properties(
  node: Node,
  fields: List(#(String, JsonValue)),
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  case value.get(node.schema, "unevaluatedProperties") {
    Error(_) -> accepted(coverage, context)
    Ok(schema) -> {
      let uncovered =
        list.filter(fields, fn(pair) {
          !dict.has_key(coverage.properties, pair.0)
        })
      list.fold(uncovered, accepted(coverage, context), fn(previous, pair) {
        case previous.result {
          Error(_) -> previous
          Ok(coverage) -> {
            let context =
              Context(
                ..context,
                remaining: previous.remaining,
                path: context.path <> "/" <> document.escape(pair.0),
              )
            let evaluated =
              eval(
                subnode(node, schema, "/unevaluatedProperties"),
                pair.1,
                context,
              )
            let coverage =
              Coverage(
                ..coverage,
                properties: dict.insert(coverage.properties, pair.0, Nil),
              )
            Evaluated(
              result.map(evaluated.result, fn(_) { coverage }),
              evaluated.remaining,
            )
          }
        }
      })
    }
  }
}

fn unevaluated_items(
  node: Node,
  items: List(JsonValue),
  context: Context,
  coverage: Coverage,
) -> Evaluated {
  case value.get(node.schema, "unevaluatedItems") {
    Error(_) -> accepted(coverage, context)
    Ok(schema) -> {
      let uncovered =
        list.index_map(items, fn(item, index) { #(item, index) })
        |> list.filter(fn(pair) { !dict.has_key(coverage.indices, pair.1) })
      list.fold(uncovered, accepted(coverage, context), fn(previous, pair) {
        case previous.result {
          Error(_) -> previous
          Ok(coverage) -> {
            let context =
              Context(
                ..context,
                remaining: previous.remaining,
                path: context.path <> "/" <> int.to_string(pair.1),
              )
            let evaluated =
              eval(subnode(node, schema, "/unevaluatedItems"), pair.0, context)
            let coverage =
              Coverage(
                ..coverage,
                indices: dict.insert(coverage.indices, pair.1, Nil),
              )
            Evaluated(
              result.map(evaluated.result, fn(_) { coverage }),
              evaluated.remaining,
            )
          }
        }
      })
    }
  }
}

fn assertion_cost(schema: JsonValue, instance: JsonValue) -> Int {
  let weight = case document.bounded(instance, 0, 100_000) {
    Ok(remaining) -> 100_000 - remaining
    Error(_) -> 100_000
  }
  let enumeration =
    value.field(schema, "enum", json.Array([])) |> value.items |> list.length
  let constant = case value.get(schema, "const") {
    Ok(_) -> 1
    Error(_) -> 0
  }
  let comparisons = case instance {
    json.Array(items) ->
      case value.get(schema, "uniqueItems") {
        Ok(json.Bool(True)) -> list.length(items)
        _ -> 0
      }
    json.Object(_) ->
      value.field(schema, "patternProperties", json.Object([]))
      |> value.fields
      |> list.length
    _ -> 0
  }
  weight * { enumeration + constant + comparisons }
}
