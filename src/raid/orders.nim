## The order schema: strict JSON parsing and world validation for ordinary
## players, plus world-aware repair for the factored numeric RL bridge.

import std/[json, strutils, unicode]
import types, state, labels

proc parseJsonObject*(text: string): JsonNode =
  ## Parses a strict single JSON object. No markdown fences or prose scraping.
  let trimmed = text.strip()
  if trimmed.len == 0 or trimmed[0] != '{':
    var head = trimmed
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(RaidError,
      "response must be a single JSON object starting with '{': " &
        head.replace("\n", " "))
  let parsed = try:
    parseJson(trimmed)
  except CatchableError as error:
    var head = trimmed
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(RaidError,
      "invalid JSON object (" & error.msg & "): " & head.replace("\n", " "))
  if parsed.kind != JObject:
    raise newException(RaidError, "response must be a JSON object")
  parsed

proc parseIntent*(text: string): (Intent, bool) =
  let wanted = runeCap(text, MaxIntentRunes).toLowerAscii()
  for intent in low(Intent) .. high(Intent):
    if $intent == wanted:
      return (intent, true)
  (inWait, false)

proc parseStation*(text: string): (Station, bool) =
  let wanted = runeCap(text, MaxStationRunes).toLowerAscii()
  for station in low(Station) .. high(Station):
    if $station == wanted:
      return (station, true)
  (stRanged, false)

proc parseReaction*(text: string): (Reaction, bool) =
  let wanted = runeCap(text, MaxStationRunes).toLowerAscii()
  for reaction in low(Reaction) .. high(Reaction):
    if $reaction == wanted:
      return (reaction, true)
  (rxDodge, false)

proc parseTargetStrict*(node: JsonNode): string =
  ## Strict canonical target parsing: null/omitted/"" -> "", "boss",
  ## "Alpha".."Echo", or "A<n>". Rejects integers and legacy aliases.
  if node == nil or node.kind == JNull:
    return ""
  if node.kind != JString:
    raise newException(RaidError, "target must be a string or null")
  let raw = node.getStr().strip()
  if raw.len == 0:
    return ""
  if raw.runeLen > MaxTargetRunes:
    raise newException(RaidError, "target exceeds " & $MaxTargetRunes & " runes")
  let lowered = raw.toLowerAscii()
  if lowered == "boss":
    return "boss"
  let slot = slotOfAlias(raw)
  if slot >= 0:
    return aliasOf(slot)
  if raw.len >= 2 and raw[0] in {'A', 'a'}:
    try:
      let n = parseInt(raw[1 .. ^1])
      if n >= 1 and n <= 99:
        return addName(n)
    except ValueError:
      discard
  raise newException(RaidError, "unknown target: " & runeCap(raw, 32))

proc canonicalTarget*(node: JsonNode): string =
  try:
    parseTargetStrict(node)
  except RaidError:
    ""

proc finiteCoord(node: JsonNode): int =
  if node == nil:
    raise newException(RaidError, "point coordinate is missing")
  case node.kind
  of JInt: node.getInt()
  of JFloat:
    let value = node.getFloat()
    if value != value or value > 1.0e9 or value < -1.0e9:
      raise newException(RaidError, "point coordinate must be finite")
    int(value)
  else:
    raise newException(RaidError, "point coordinates must be numbers")

proc parseOrder*(node: JsonNode, role = roleDps): Order =
  ## Shape-level parse used by the numeric RL bridge and strict order parser.
  if node == nil or node.kind != JObject:
    raise newException(RaidError, "order must be a JSON object")
  let intentNode = node{"intent"}
  if intentNode == nil or intentNode.kind != JString or
      intentNode.getStr().strip().len == 0:
    raise newException(RaidError, "order has no intent")
  let (intent, intentOk) = parseIntent(intentNode.getStr())
  let (station, stationOk) = parseStation(node{"station"}.getStr())
  let (reaction, _) = parseReaction(node{"on_telegraph"}.getStr())
  result = Order(
    intent: (if intentOk: intent else: defaultIntentFor(role)),
    target: canonicalTarget(node{"target"}),
    station: (if stationOk: station else: defaultStationFor(role)),
    onTelegraph: reaction,
    note: runeCap(node{"note"}.getStr(), MaxNoteRunes),
    say: runeCap(node{"say"}.getStr(), MaxSayRunes)
  )
  let point = node{"point"}
  if point != nil and point.kind == JArray and point.len == 2:
    try:
      result.px = finiteCoord(point[0])
      result.py = finiteCoord(point[1])
      result.hasPoint = true
    except RaidError:
      discard

proc orderToJson*(order: Order): JsonNode =
  %*{
    "intent": $order.intent,
    "target": order.target,
    "station": $order.station,
    "point": [order.px, order.py],
    "on_telegraph": $order.onTelegraph,
    "note": order.note,
    "say": order.say
  }

proc entityAlive*(sim: Sim, target: string): bool =
  if target.len == 0:
    return false
  if target == "boss":
    return sim.boss.hp > 0
  let slot = slotOfAlias(target)
  if slot >= 0:
    return sim.cogs[slot].alive
  if target.len >= 2 and target[0] == 'A':
    try:
      let index = sim.addIndexById(parseInt(target[1 .. ^1]))
      return index >= 0 and sim.adds[index].alive
    except ValueError:
      return false
  false

proc naturalTarget*(sim: Sim, slot: int, intent: Intent): string =
  case intent
  of inTankBoss, inBurnBoss, inTaunt, inKite:
    "boss"
  of inPickUpAdds, inKillAdds:
    let index = sim.nearestLivingAdd(sim.cogs[slot].x, sim.cogs[slot].y)
    if index < 0: "" else: addName(sim.adds[index].id)
  of inHealLowest, inHealTarget, inShieldTarget, inConserve:
    let ally = sim.lowestHpAlly()
    if ally < 0: "" else: aliasOf(ally)
  of inAssistTarget:
    let ally = sim.lowestHpAlly(slot)
    if ally < 0: "" else: aliasOf(ally)
  of inInterrupt, inSoak, inWait:
    ""

proc targetLegalFor*(intent: Intent, target: string): bool =
  if target.len == 0:
    return intent in {inInterrupt, inSoak, inWait, inConserve, inHealLowest}
  let isAlly = slotOfAlias(target) >= 0
  var isAdd = false
  if not isAlly and target.len >= 2 and target[0] == 'A':
    try:
      discard parseInt(target[1 .. ^1])
      isAdd = true
    except ValueError:
      isAdd = false
  let isBoss = target == "boss"
  case intent
  of inTankBoss, inBurnBoss, inTaunt, inKite: isBoss
  of inPickUpAdds, inKillAdds: isAdd
  of inHealTarget, inShieldTarget, inAssistTarget: isAlly
  of inHealLowest, inConserve: isAlly
  of inInterrupt, inSoak, inWait: isBoss or isAdd or isAlly

proc requiresTarget*(intent: Intent): bool =
  intent in {inPickUpAdds, inKillAdds, inHealTarget, inShieldTarget,
    inAssistTarget}

proc repairOrder*(sim: Sim, slot: int, raw: Order): Order =
  ## Every violation in the design note's repair table, applied in order.
  result = raw
  let role = sim.cogs[slot].role
  if not intentLegalFor(result.intent, role):
    result.intent = defaultIntentFor(role)
  if not targetLegalFor(result.intent, result.target) or
      (result.target.len > 0 and not sim.entityAlive(result.target)):
    result.target = naturalTarget(sim, slot, result.intent)
  if result.target.len == 0 and requiresTarget(result.intent):
    result.intent = inWait
    result.target = ""
  if not result.hasPoint:
    result.px = sim.cogs[slot].x
    result.py = sim.cogs[slot].y
    result.hasPoint = true
  let clamped = clampIntoPit(result.px, result.py)
  result.px = clamped[0]
  result.py = clamped[1]
  result.note = runeCap(result.note, MaxNoteRunes)
  result.say = runeCap(result.say, MaxSayRunes)

proc validateOrder*(sim: Sim, slot: int, order: Order): string =
  ## "" when the order is legal for this seat and this world; otherwise the
  ## first violation. Used by the bounded-orders test.
  let role = sim.cogs[slot].role
  if not intentLegalFor(order.intent, role):
    return "intent " & $order.intent & " illegal for " & $role
  if order.target.len > 0:
    if not targetLegalFor(order.intent, order.target):
      return "target " & order.target & " illegal for " & $order.intent
    if not sim.entityAlive(order.target):
      return "target " & order.target & " is not alive"
  elif requiresTarget(order.intent):
    return "intent " & $order.intent & " needs a target"
  if not withinPx(order.px, order.py, PitCx, PitCy, ClampRadius):
    return "point outside the pit"
  if order.note.runeLen > MaxNoteRunes:
    return "note over " & $MaxNoteRunes & " runes"
  if order.say.runeLen > MaxSayRunes:
    return "say over " & $MaxSayRunes & " runes"
  ""

proc parseStrictOrder*(node: JsonNode, sim: Sim, slot: int): Order =
  ## Strict order parser and world validator for the ordinary player protocol.
  ## Rejects unknown or wrong-role intents, unknown stations/reactions, illegal
  ## or dead targets, and malformed points instead of fabricating substitutes.
  if node == nil or node.kind != JObject:
    raise newException(RaidError, "order must be a JSON object")
  let role = sim.cogs[slot].role

  let intentNode = node{"intent"}
  if intentNode == nil or intentNode.kind != JString or
      intentNode.getStr().strip().len == 0:
    raise newException(RaidError, "order is missing required string field 'intent'")
  let (intent, intentOk) = parseIntent(intentNode.getStr().strip())
  if not intentOk:
    raise newException(RaidError, "unknown intent: " &
      runeCap(intentNode.getStr(), 32))
  if not intentLegalFor(intent, role):
    raise newException(RaidError, "intent " & $intent & " is illegal for role " & $role)

  let stationNode = node{"station"}
  if stationNode == nil or stationNode.kind != JString or
      stationNode.getStr().strip().len == 0:
    raise newException(RaidError, "order is missing required string field 'station'")
  let (station, stationOk) = parseStation(stationNode.getStr().strip())
  if not stationOk:
    raise newException(RaidError, "unknown station: " &
      runeCap(stationNode.getStr(), 32))

  let reactionNode = node{"on_telegraph"}
  if reactionNode == nil or reactionNode.kind != JString or
      reactionNode.getStr().strip().len == 0:
    raise newException(RaidError,
      "order is missing required string field 'on_telegraph'")
  let (reaction, reactionOk) = parseReaction(reactionNode.getStr().strip())
  if not reactionOk:
    raise newException(RaidError, "unknown on_telegraph: " &
      runeCap(reactionNode.getStr(), 32))

  let target = parseTargetStrict(node{"target"})
  if target.len > 0:
    if not targetLegalFor(intent, target):
      raise newException(RaidError, "target " & target & " is illegal for intent " & $intent)
    if not sim.entityAlive(target):
      raise newException(RaidError, "target " & target & " is not alive")
  elif requiresTarget(intent):
    raise newException(RaidError, "intent " & $intent & " requires a live target")

  var px = sim.cogs[slot].x
  var py = sim.cogs[slot].y
  let pointNode = node{"point"}
  if pointNode != nil and pointNode.kind != JNull:
    if pointNode.kind != JArray or pointNode.len != 2:
      raise newException(RaidError, "point must be a 2-element [x, y] array")
    px = finiteCoord(pointNode[0])
    py = finiteCoord(pointNode[1])
  elif station == stPoint:
    raise newException(RaidError, "station 'point' requires a [x, y] point array")
  let clamped = clampIntoPit(px, py)

  var note = ""
  let noteNode = node{"note"}
  if noteNode != nil and noteNode.kind != JNull:
    if noteNode.kind != JString:
      raise newException(RaidError, "note must be a string")
    note = runeCap(noteNode.getStr(), MaxNoteRunes)

  var say = ""
  let sayNode = node{"say"}
  if sayNode != nil and sayNode.kind != JNull:
    if sayNode.kind != JString:
      raise newException(RaidError, "say must be a string")
    say = runeCap(sayNode.getStr(), MaxSayRunes)

  Order(
    intent: intent,
    target: target,
    station: station,
    px: clamped[0],
    py: clamped[1],
    hasPoint: true,
    onTelegraph: reaction,
    note: note,
    say: say
  )
