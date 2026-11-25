## Strict JSON parsing and world validation for ordinary players, including
## rune-boundary truncation that keeps replay bytes parseable.

import std/[json, strutils, unicode]
import curly
import support/helpers
import raid/[orders, llm, baselines]

proc parseStrictFor(world: Sim, slot: int, text: string): Order =
  parseStrictOrder(parseJsonObject(text), world, slot)

proc mustReject(world: Sim, slot: int, text, label: string) =
  var caught = false
  try:
    discard world.parseStrictFor(slot, text)
  except RaidError:
    caught = true
  check(caught, label)

proc testStrictJsonObjectOnly() =
  var world = quietWorld()
  let valid = world.parseStrictFor(0,
    "{\"intent\": \"tank_boss\", \"target\": \"boss\", \"station\": \"melee\"," &
    " \"on_telegraph\": \"hold\", \"note\": \"holding\", \"say\": \"on it\"}")
  checkEq($valid.intent, "tank_boss", "clean JSON object parses")
  checkEq($valid.station, "melee", "station parses")
  checkEq($valid.onTelegraph, "hold", "on_telegraph parses")
  world.mustReject(0,
    "Let me think.\n{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"melee\",\"on_telegraph\":\"hold\"}",
    "prose-prefixed JSON is rejected")
  world.mustReject(0,
    "```json\n{\"intent\":\"taunt\",\"target\":\"boss\",\"station\":\"melee\",\"on_telegraph\":\"hold\"}\n```",
    "markdown-fenced JSON is rejected")
  world.mustReject(2,
    "{\"intent\":\"burn_boss\",\"target\":\"boss\",\"station\":\"ranged\",\"on_telegraph\":\"dodge\"} trailing prose",
    "trailing prose is rejected")
  world.mustReject(2, "I refuse to answer.", "non-JSON text is rejected")
  done("strict JSON object parsing rejects prose and markdown fences")

proc testUnknownAndWrongRoleEnumsRejected() =
  var world = quietWorld()
  world.mustReject(0,
    "{\"intent\":\"do_a_barrel_roll\",\"target\":\"boss\",\"station\":\"melee\",\"on_telegraph\":\"hold\"}",
    "unknown intent is rejected")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"orbit\",\"on_telegraph\":\"hold\"}",
    "unknown station is rejected")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"melee\",\"on_telegraph\":\"panic\"}",
    "unknown on_telegraph is rejected")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"on_telegraph\":\"hold\"}",
    "missing station is rejected")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"melee\"}",
    "missing on_telegraph is rejected")
  world.mustReject(world.healerSlot(),
    "{\"intent\":\"burn_boss\",\"target\":\"boss\",\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}",
    "healer sending dps intent is rejected")
  world.mustReject(2,
    "{\"intent\":\"heal_lowest\",\"target\":null,\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}",
    "dps sending healer intent is rejected")
  let shared = world.parseStrictFor(2,
    "{\"intent\":\"wait\",\"target\":null,\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}")
  checkEq($shared.intent, "wait", "explicit wait is legal for everyone")
  done("unknown and wrong-role enum values are rejected, not repaired")

proc testPointFormsAndClamping() =
  var world = quietWorld()
  let inside = world.parseStrictFor(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"point\"," &
    "\"point\":[620,330],\"on_telegraph\":\"hold\"}")
  checkEq((inside.px, inside.py), (620, 330), "numeric point parses")
  let outside = world.parseStrictFor(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"point\"," &
    "\"point\":[9000,-9000],\"on_telegraph\":\"hold\"}")
  check(withinPx(outside.px, outside.py, PitCx, PitCy, ClampRadius),
    "a numeric point outside the pit is clamped onto the pit circle")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"point\"," &
    "\"point\":[\"620\",\"330\"],\"on_telegraph\":\"hold\"}",
    "string-encoded coordinates are rejected")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"point\"," &
    "\"on_telegraph\":\"hold\"}",
    "station point without point array is rejected")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"point\"," &
    "\"point\":[\"north\",\"west\"],\"on_telegraph\":\"hold\"}",
    "non-numeric point is rejected")
  done("point parsing, pit clamping and strict validation")

proc testTargetFormsStrict() =
  var world = quietWorld()
  world.adds.add(Add(id: 3, x: PitCx + 100, y: PitCy, hp: AddHp, alive: true,
    target: 0))
  let validAdd = world.parseStrictFor(2,
    "{\"intent\":\"kill_adds\",\"target\":\"A3\",\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}")
  checkEq(validAdd.target, "A3", "canonical add target A3 parses")
  let alias = world.parseStrictFor(world.healerSlot(),
    "{\"intent\":\"heal_target\",\"target\":\"Delta\",\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}")
  checkEq(alias.target, "Delta", "canonical ally alias parses")
  world.mustReject(2,
    "{\"intent\":\"kill_adds\",\"target\":3,\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}",
    "integer add target alias is rejected")
  world.mustReject(0,
    "{\"intent\":\"tank_boss\",\"target\":\"smelter-9\",\"station\":\"melee\",\"on_telegraph\":\"hold\"}",
    "smelter-9 target alias is rejected")
  world.mustReject(2,
    "{\"intent\":\"kill_adds\",\"target\":\"A99\",\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}",
    "missing add target is rejected")
  world.cogs[3].alive = false
  world.mustReject(world.healerSlot(),
    "{\"intent\":\"heal_target\",\"target\":\"Delta\",\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}",
    "dead ally target is rejected")
  world.adds = @[]
  world.mustReject(2,
    "{\"intent\":\"kill_adds\",\"target\":null,\"station\":\"ranged\",\"on_telegraph\":\"dodge\"}",
    "kill_adds with no adds alive is rejected rather than degraded to wait")
  done("strict target validation rejects aliases, dead targets, and missing targets")

proc testCanonicalScriptKindsOnly() =
  checkEq(parseScriptKind("stalwart"), skStalwart, "stalwart is accepted")
  checkEq(parseScriptKind("greenhorn"), skGreenhorn, "greenhorn is accepted")
  for alias in ["1", "true", "yes", "default", "green", "novice", ""]:
    checkEq(parseScriptKind(alias), skNone,
      "obsolete script alias '" & alias & "' is rejected")
  done("parseScriptKind accepts only canonical stalwart and greenhorn")

proc testNoteAndSayCaps() =
  var world = quietWorld()
  let long = "x".repeat(400)
  let order = world.parseStrictFor(0,
    "{\"intent\":\"tank_boss\",\"target\":\"boss\",\"station\":\"melee\"," &
    "\"on_telegraph\":\"hold\",\"note\":\"" & long & "\"}")
  checkEq(order.note.runeLen, MaxNoteRunes, "a 400-character note is trimmed")
  done("note and say caps")

proc testRuneBoundaryTruncation() =
  ## The 32nd and 33rd runes of the `say` are 4-byte emoji. Truncation must
  ## land on the RUNE boundary, or the bytes render in a browser and then fail
  ## a strict JSON parser.
  var world = quietWorld()
  let emoji = "\u{1F525}"          ## FIRE, four bytes in UTF-8
  checkEq(emoji.len, 4, "the test emoji really is four bytes")
  let say = "a".repeat(31) & emoji & emoji & "tail"
  checkEq(say.runeLen, 31 + 2 + 4, "the source string is 37 runes")
  let order = world.parseStrictFor(0,
    $ %*{"intent": "tank_boss", "target": "boss", "station": "melee",
         "on_telegraph": "hold", "say": say})
  checkEq(order.say.runeLen, MaxSayRunes, "trimmed to exactly 32 runes")
  checkEq(order.say, "a".repeat(31) & emoji,
    "and the 32nd rune is the whole emoji, not two of its bytes")
  checkEq(validateUtf8(order.say), -1, "the result is valid UTF-8")
  let round = parseJson($ %*{"say": order.say})
  checkEq(round["say"].getStr(), order.say, "round-trips through JSON")
  world.pendingSays[0] = order.say
  world.says[1] = world.pendingSays[0]
  let serialised = $ %*{"callouts": [{"alias": "Alpha", "say": world.says[1]}]}
  checkEq(validateUtf8(serialised), -1,
    "and a callout carrying it is still valid UTF-8")
  discard parseJson(serialised)
  done("say truncates on a rune boundary with a 4-byte emoji on the seam")

proc testMissingIntentIsUnrecoverable() =
  var world = quietWorld()
  world.mustReject(2, "{\"say\":\"hello\"}", "an object with no intent raises")
  done("missing intent raises")

proc raisedBy(client: LlmClient, code: int, body: string): string =
  try:
    discard client.textOf(Response(code: code, body: body), "",
      "https://example.invalid/v1/messages")
  except RaidError as error:
    return error.msg
  check(false, "textOf must raise on a " & $code & " response")

proc testCapturedErrorTextIsRuneSafe() =
  let client = LlmClient()
  let emoji = "\u{1F525}"
  for (code, cap) in [(403, 400), (429, 300), (500, 300)]:
    let body = "e".repeat(cap - 2) & emoji & "tail"
    let message = client.raisedBy(code, body)
    checkEq(validateUtf8(message), -1,
      "the " & $code & " message is valid UTF-8")
    check(emoji in message,
      "and carries the whole emoji, not two of its bytes (" & $code & ")")
    check("e".repeat(cap - 2) in message, "having quoted the body")
  let cutOff = $ %*{
    "stop_reason": "max_tokens",
    "content": [{"type": "text", "text": "e".repeat(158) & emoji & "tail"}]
  }
  let cutMessage = client.raisedBy(200, cutOff)
  checkEq(validateUtf8(cutMessage), -1,
    "a reply cut off at max_tokens is quoted on a rune boundary")
  check(emoji in cutMessage, "with its last rune whole")
  let broken = "e".repeat(40) & emoji[0 ..< 2] & "tail"
  check(validateUtf8(broken) >= 0, "the fixture really is invalid UTF-8")
  checkEq(validateUtf8(client.raisedBy(429, broken)), -1,
    "an invalid-UTF-8 body is dropped, not quoted")
  done("captured error text is cut on rune boundaries")

when isMainModule:
  testStrictJsonObjectOnly()
  testUnknownAndWrongRoleEnumsRejected()
  testPointFormsAndClamping()
  testTargetFormsStrict()
  testCanonicalScriptKindsOnly()
  testNoteAndSayCaps()
  testRuneBoundaryTruncation()
  testMissingIntentIsUnrecoverable()
  testCapturedErrorTextIsRuneSafe()
  echo "test_orders: strict parsing, validation and rune-boundary truncation check out"
