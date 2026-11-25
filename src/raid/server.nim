## The raid game server: the Coworld game contract over mummy.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/player              - seat page
##   GET /client/global              - spectator page
##   GET /client/replay              - the broadcast replay page
##   GET /client/<asset>             - chrome_common.js, broadcast_core.js
##   GET /replay-data                - the recorded replay JSON (replay mode)
##   WS  /player?slot=N&token=T      - the player protocol
##   WS  /global                     - spectator snapshots
##
## Player protocol (raid.player.v2), JSON text frames:
##   player -> game: {"type":"register","kind":str,"scripted":str|null,
##                    "policy":str}   on connect
##   game -> player: {"type":"welcome","protocol":"raid.player.v2","slot":N,
##                    "alias":str,"turn_seconds":float}
##                   {"type":"decision","id":N,"view":{...},
##                    "system":str,"retry":bool,"timeout_seconds":N}
##   player -> game: {"type":"action","id":N,"action":{...}} or
##                   {"type":"action","id":N,"cause":str,"error":str}
##                   {"type":"turn","turn":N,"tick":T,"phase":P,"role":str,
##                    "view":{...},"order_source":"llm"|"scripted"|"fallback"}
##                   {"done":true,"result":{...}}
##
## The game owns visibility, timing, order repair and fallback. The player
## owns its policy and any model credentials.

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import curly
import mummy
import mummy/routers
import types, config, state, sim, baselines, broadcast, scoring,
  replay, engine, llm, orders, labels

const
  DoneBroadcastSeconds = 3.0
  PlayerProtocol = "raid.player.v2"

type
  ServerState = object
    kinds: seq[string]
    scripted: seq[ScriptKind]
    policies: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    requestIds: seq[int]
    replies: seq[JsonNode]
    unavailable: seq[bool]
    globalSockets: HashSet[WebSocket]
    snapshot: string
    seats: int
    started: bool
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: Sim
  gameServer: Server
  replayPayload: string
  eventsSinkPath: string
  metricsSinkPath: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc connectedFlags(): seq[bool] =
  result = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    result[slot] = shared.playerSockets.hasKey(slot)

proc refreshSnapshotLocked() =
  shared.snapshot = $globalSnapshot(gameSim, connectedFlags())
  for socket in shared.globalSockets:
    socket.send(shared.snapshot)

const
  MaxFailureMessageRunes = 1000

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc declarePlayerFailure(slot: int, message: string) =
  ## Reports an explicit policy failure to Coworld via COGAME_PLAYER_FAILURE_URI.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot,
           "message": runeCap(message, MaxFailureMessageRunes)}),
      "application/json")
  except CatchableError as error:
    echo "raid: player-failure declaration failed: ", error.msg

proc failEpisode(runtimeConfig: RuntimeConfig, slot: int, message: string) =
  ## Terminates an unplayed or invalid episode as an explicit policy failure
  ## with no fabricated moves and no published results/scores. Retains partial
  ## replay progress when ticks have elapsed.
  let detail = runeCap(message, MaxFailureMessageRunes)
  echo "raid: policy failure on seat ", slot, " (", aliasOf(slot), "): ", detail
  var partialReplay = ""
  let payload = $ %*{"done": true, "error": runeCap(detail, 500)}
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    if gameSim.tick > 0 and runtimeConfig.replayUri.len > 0:
      gameSim.record("policy_failure", %*{
        "turn": gameSim.turn, "seat": slot, "alias": aliasOf(slot),
        "detail": runeCap(detail, 500)
      })
      partialReplay = replayBytes(gameSim)
    for _, socket in shared.playerSockets:
      try:
        socket.send(payload)
      except CatchableError:
        discard
  if partialReplay.len > 0:
    try:
      echo "raid: preserving partial replay (", partialReplay.len,
        " bytes, tick ", gameSim.tick, ")"
      writeArtifact(runtimeConfig.replayUri, partialReplay, "application/json",
        "COGAME_SAVE_REPLAY_METHOD")
    except CatchableError as error:
      echo "raid: partial replay write failed: ", error.msg
  declarePlayerFailure(slot, detail)
  quit(1)

proc requireFileUri*(name: string): string =
  let uri = getEnv(name)
  if uri.len == 0:
    return ""
  if not uri.startsWith("file://"):
    raise newException(RaidError, name & " must be a file:// path, got: " & uri)
  uri[7 .. ^1]

proc pushTurnFrames() =
  ## Post-order informational frame. A dead seat gets one frame with
  ## `you.alive == false` and nothing further until `done`.
  for slot, socket in shared.playerSockets:
    if slot < 0 or slot >= gameSim.cogs.len:
      continue
    try:
      socket.send($ %*{
        "type": "turn", "turn": gameSim.turn, "tick": gameSim.tick,
        "phase": gameSim.boss.phase,
        "role": $gameSim.cogs[slot].role,
        "view": seatView(gameSim, slot),
        "order_source": $gameSim.orderSources[slot]
      })
    except CatchableError:
      discard

proc broadcastDone(results: JsonNode) =
  ## Bounded at DoneBroadcastSeconds per seat, then we move on: the artifacts
  ## matter more than a slow reader. The budget is ENFORCED, not just measured
  ## - each seat adds 3.0 s to the allowance and a seat whose turn comes up
  ## after the allowance is already spent is skipped, so the whole broadcast
  ## can never hold the artifact writes for more than seats x 3.0 s.
  let payload = $ %*{"done": true, "result": results}
  var allowance = epochTime()
  for slot, socket in shared.playerSockets:
    allowance += DoneBroadcastSeconds
    if epochTime() > allowance:
      echo "raid: done broadcast is past its ", DoneBroadcastSeconds,
        "s-per-seat budget; skipping slot ", slot
      continue
    try:
      socket.send(payload)
    except CatchableError as error:
      echo "raid: done frame to slot ", slot, " failed: ", error.msg
    if epochTime() > allowance:
      echo "raid: done frame to slot ", slot, " exceeded its ",
        DoneBroadcastSeconds, "s budget; moving on"

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  let eventsPath = eventsSinkPath
  let metricsPath = metricsSinkPath
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    results = resultsJson(gameSim)
    replayData = replayBytes(gameSim)
    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists.
    broadcastDone(results)
    refreshSnapshotLocked()
  echo "raid: writing results and replay (", replayData.len, " bytes)"
  ## The REPLAY first, then the results: the hosted worker treats results.json
  ## as the end of the episode and tears the pods down when it appears, so a
  ## replay written after it can be lost. Same order as the starter
  ## (`src/ctf/server.nim:1940-1956`).
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  if eventsPath.len > 0:
    try:
      writeFile(eventsPath, $gameSim.events.toJson())
    except CatchableError as error:
      echo "raid: event sink write failed: ", error.msg
  if metricsPath.len > 0:
    try:
      writeFile(metricsPath, $ %*{
        "ticks": gameSim.tick, "turns": gameSim.turn,
        "events": gameSim.events.records.len,
        "keyframes": gameSim.keyframes.len
      })
    except CatchableError as error:
      echo "raid: metrics sink write failed: ", error.msg
  echo "raid: episode complete (", gameSim.reason, "/", gameSim.endRule,
    ") after ", gameSim.tick, " ticks"

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its register frame.
    let registerDeadline = min(epochTime() + 3.0, connectDeadline + 3.0)
    while epochTime() < registerDeadline:
      var allRegistered = false
      withLock stateLock:
        allRegistered = true
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var noShow = -1
    withLock stateLock:
      shared.started = true
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
        else:
          gameSim.policyKinds[slot] = shared.kinds[slot]
      echo "raid: starting with ", shared.playerSockets.len, "/",
        shared.seats, " players connected"
      refreshSnapshotLocked()
    if noShow >= 0:
      failEpisode(runtimeConfig, noShow, "player slot " & $noShow & " never registered")

    var kinds: seq[ScriptKind]
    withLock stateLock:
      kinds = shared.scripted

    proc now(): float {.closure.} = epochTime() - gameStart

    proc raisePolicyFailure(seat: int, message: string) {.noreturn.} =
      var err = newException(PolicyFailureError, message)
      err.seat = seat
      raise err

    proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
      let started = epochTime()
      result = newSeq[Decision](seats.len)
      var failMsg = newSeq[string](seats.len)
      var pending: seq[int]
      for index, seat in seats:
        if kinds[seat] != skNone:
          result[index] = Decision(order: scriptedOrder(view, seat, kinds[seat]),
            source: osScripted)
        else:
          pending.add(index)
      for attempt in 0 .. 1:
        if pending.len == 0:
          break
        var sent: seq[int]
        let timeout = if attempt == 0:
          deadlineSeconds(config.llmAttemptSeconds)
        else:
          deadlineSeconds(config.llmRetrySeconds)
        withLock stateLock:
          for index in pending:
            let seat = seats[index]
            if shared.unavailable[seat]:
              raisePolicyFailure(seat,
                "seat " & $seat & " has no LLM credentials configured")
            if not shared.registered[seat] or
                not shared.playerSockets.hasKey(seat):
              raisePolicyFailure(seat,
                "seat " & $seat & " disconnected before decision")
            let id = (view.tick div config.turnTicks) * 2 + attempt + 1
            shared.requestIds[seat] = id
            shared.replies[seat] = nil
            try:
              shared.playerSockets[seat].send($ %*{
                "type": "decision", "id": id, "slot": seat,
                "view": seatView(view, seat),
                "system": systemPrompt(config.promptSelection, config), "retry": attempt > 0,
                "timeout_seconds": timeout
              })
              sent.add(index)
            except CatchableError as error:
              raisePolicyFailure(seat,
                "seat " & $seat & " socket send failed: " & error.msg)
        let deadline = epochTime() + timeout.float
        while sent.len > 0 and epochTime() < deadline:
          var waiting = false
          withLock stateLock:
            for index in sent:
              if shared.replies[seats[index]] == nil:
                waiting = true
          if not waiting:
            break
          sleep(10)
        var retry: seq[int]
        for index in sent:
          let seat = seats[index]
          var reply: JsonNode
          withLock stateLock:
            reply = shared.replies[seat]
            shared.requestIds[seat] = 0
          if reply == nil:
            failMsg[index] = "seat " & $seat & " decision timed out"
            retry.add(index)
          elif reply.hasKey("cause"):
            let cause = reply["cause"].getStr()
            let detail = runeCap(reply{"error"}.getStr(), 500)
            failMsg[index] = "seat " & $seat & " " & cause &
              (if detail.len > 0: ": " & detail else: "")
            if cause == "no_credentials" or cause == "auth_error":
              withLock stateLock:
                shared.unavailable[seat] = true
              raisePolicyFailure(seat, failMsg[index])
            else:
              retry.add(index)
          else:
            try:
              let actionNode = reply{"action"}
              let order = parseStrictOrder(actionNode, view, seat)
              result[index] = Decision(order: order,
                source: osLlm, attempts: attempt + 1)
            except CatchableError as error:
              let rawHead = runeCap($reply{"action"}, 400)
              failMsg[index] = "seat " & $seat & " invalid order (" &
                error.msg & "): " & rawHead
              retry.add(index)
        pending = retry
      if pending.len > 0:
        let index = pending[0]
        raisePolicyFailure(seats[index], failMsg[index])
      let latency = int((epochTime() - started) * 1000.0)
      for i in 0 ..< result.len:
        if result[i].source != osScripted:
          result[i].latencyMs = latency

    proc onTurn(view: Sim) {.closure.} =
      withLock stateLock:
        pushTurnFrames()
        refreshSnapshotLocked()
      echo "raid: turn ", gameSim.turn, " tick ", gameSim.tick,
        " boss ", gameSim.boss.hp, "/", gameSim.boss.maxHp,
        " alive ", gameSim.aliveCount(), " at ", int(now()), "s"

    try:
      runEncounter(gameSim, decide, now, kinds, onTurn)
    except PolicyFailureError as error:
      failEpisode(runtimeConfig, error.seat, error.msg)
    finishEpisode(runtimeConfig)
    quit(0)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc replayPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "replay_broadcast.html",
      "text/html; charset=utf-8")

proc playerPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "player.html",
      "text/html; charset=utf-8")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "global.html",
      "text/html; charset=utf-8")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".js"): "application/javascript; charset=utf-8"
      elif name.endsWith(".css"): "text/css; charset=utf-8"
      elif name.endsWith(".html"): "text/html; charset=utf-8"
      elif name.endsWith(".png"): "image/png"
      elif name.endsWith(".jpg"): "image/jpeg"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, clientDir() / name, contentType)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayload.len == 0:
      request.respond(404)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(200, headers, replayPayload)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "raid: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": PlayerProtocol, "slot": slot,
        "alias": aliasOf(slot),
        "turn_seconds": gameSim.config.turnTicks.float / TargetFps.float
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      if shared.snapshot.len > 0:
        websocket.send(shared.snapshot)

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "action":
          withLock stateLock:
            if shared.requestIds[slot] != 0 and
                payload{"id"}.getInt() == shared.requestIds[slot]:
              shared.replies[slot] = payload
          return
        if payload{"type"}.getStr() != "register":
          return
        let kind = payload["kind"].getStr()
        if kind notin ["scripted", "prompt", "external"]:
          raise newException(RaidError, "unknown policy kind")
        let node = payload{"scripted"}
        let scripted =
          if node == nil or node.kind == JNull: skNone
          elif node.kind == JString: parseScriptKind(node.getStr())
          else: raise newException(RaidError, "scripted must be a string or null")
        if kind == "scripted" and scripted == skNone or
            kind != "scripted" and scripted != skNone:
          raise newException(RaidError, "policy kind and baseline disagree")
        let policy = runeCap(payload{"policy"}.getStr(), MaxPolicyLabelRunes)
        withLock stateLock:
          shared.kinds[slot] = kind
          shared.scripted[slot] = scripted
          shared.policies[slot] = policy
          shared.registered[slot] = true
          shared.everRegistered[slot] = true
        echo "raid: slot ", slot, " registered as ", kind
      except CatchableError as error:
        echo "raid: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let slot = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(slot) == websocket:
            shared.playerSockets.del(slot)
          ## A non-scripted seat that drops is marked unregistered so the next
          ## decision fails cleanly instead of fabricating a move.
          if shared.everRegistered[slot] and shared.scripted[slot] == skNone:
            shared.registered[slot] = false
        shared.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/replay", replayPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: hold the recorded replay for /replay-data and serve the
  ## broadcast page off the identical bundle the static viewer uses.
  replayPayload = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "raid: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc stopServer*() =
  ## Only the tests use this: the hosted container exits with the episode.
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(RaidError,
      "tokens must name exactly num_agents seats")
  ## Load the arena and build every render-independent cache BEFORE the
  ## listener opens: a viewer's first-message clock starts at its connect.
  ## file:// ONLY for the two optional sinks, and loudly rejected otherwise:
  ## the dispatcher writes these as workdir paths and the runner uploads the
  ## files afterwards, so an http target means the contract changed.
  eventsSinkPath = requireFileUri("COGAME_EVENTS_URI")
  metricsSinkPath = requireFileUri("COGAME_METRICS_URI")
  let bakeStart = epochTime()
  gameSim = initSim(config)
  echo "raid: arena baked in ",
    int((epochTime() - bakeStart) * 1000.0), " ms"
  shared.seats = config.numAgents
  shared.kinds = newSeq[string](shared.seats)
  shared.scripted = newSeq[ScriptKind](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  shared.requestIds = newSeq[int](shared.seats)
  shared.replies = newSeq[JsonNode](shared.seats)
  shared.unavailable = newSeq[bool](shared.seats)
  shared.snapshot = $globalSnapshot(gameSim, newSeq[bool](shared.seats))

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, runtimeConfig)
  echo "raid: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
