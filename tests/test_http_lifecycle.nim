## End-to-end HTTP-to-game lifecycle and terminal failure preservation tests.
##
## Spawns the real raid server and five real raid-player processes against a
## local HTTP Messages API server (mummy) to verify:
##   1. Genuine HTTP-to-game action (including single-fenced JSON) drives
##      movement and combat with zero fallbacks.
##   2. Mid-episode ambiguous/invalid LLM reply after turn 0 terminates with
##      player_failure.json (compatible with GamePlayerFailure), preserves raw
##      output, retains partial replay progress (tick_count >= 120), and writes
##      no results.json.
##   3. Invalid model / HTTP 403 terminates immediately with the exact HTTP
##      error preserved (not masked as no_credentials) and no results.json.
##   4. Missing credentials terminates cleanly with player_failure.json and no
##      results.json.

import std/[json, locks, os, osproc, strtabs, strutils]
import curly
import mummy
import mummy/routers
import support/helpers

type
  MockMode = enum
    mmValidFenced
    mmFailOnTurn1
    mmAuth403

var
  mockLock: Lock
  mockMode: MockMode
  mockCalls: int
  mockLastModel: string
  mockLastSlot: string
  mockServer: Server
  mockThread: Thread[int]

initLock(mockLock)

proc messagesHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var mode: MockMode
    var callNum: int
    let body = parseJson(request.body)
    let model = body{"model"}.getStr()
    let slot = request.headers["X-Coworld-Player-Slot"]
    withLock mockLock:
      mode = mockMode
      callNum = mockCalls
      mockCalls.inc
      mockLastModel = model
      mockLastSlot = slot

    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"

    if mode == mmAuth403:
      request.respond(403, headers,
        $ %*{"type": "error", "error": {"type": "permission_error",
          "message": "model not allowed: " & model}})
      return

    let text =
      if mode == mmValidFenced or (mode == mmFailOnTurn1 and callNum == 0):
        "```json\n" &
        """{"intent":"burn_boss","target":"boss","station":"point","point":[617,500],"on_telegraph":"dodge","say":"moving south"}""" &
        "\n```"
      else:
        "I am unsure whether to burn_boss or wait right now."

    let resp = %*{
      "id": "msg_test_" & $callNum,
      "type": "message",
      "role": "assistant",
      "stop_reason": "end_turn",
      "content": [{"type": "text", "text": text}]
    }
    request.respond(200, headers, $resp)

proc runMockServer(port: int) {.thread.} =
  {.gcsafe.}:
    var router: Router
    router.post("/v1/messages", messagesHandler)
    mockServer = newServer(router, workerThreads = 2)
    mockServer.serve(Port(port), "127.0.0.1")

proc waitForPort(port: int): bool =
  let curl = newCurly()
  for _ in 0 ..< 100:
    try:
      let r = curl.get("http://127.0.0.1:" & $port & "/healthz", timeout = 1)
      if r.code == 200:
        return true
    except CatchableError:
      discard
    sleep(50)
  false

proc buildBinaries(dir: string): (string, string) =
  let raidBin = dir / "raid"
  let playerBin = dir / "raid-player"
  let flags = when defined(release): "-d:release " else: ""
  let rc1 = execCmd("nim c " & flags & "--hints:off --path:src -o:" &
    quoteShell(raidBin) & " src/raid.nim")
  checkEq(rc1, 0, "compile src/raid.nim")
  let rc2 = execCmd("nim c " & flags & "--hints:off --path:src -o:" &
    quoteShell(playerBin) & " src/raid_player.nim")
  checkEq(rc2, 0, "compile src/raid_player.nim")
  (raidBin, playerBin)

proc baseEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k notin ["COWORLD_LLM_ENDPOINT", "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY", "PLAYER_SCRIPTED", "PLAYER_PROMPT",
        "COGAME_CONFIG_URI", "COGAME_RESULTS_URI", "COGAME_SAVE_REPLAY_URI",
        "COGAME_PLAYER_FAILURE_URI", "COGAME_EVENTS_URI", "COGAME_METRICS_URI"]:
      result[k] = v

proc runScenario(raidBin, playerBin, workDir: string, gamePort: int,
    llmEndpoint, llmModel: string): int =
  createDir(workDir)
  let cfgPath = workDir / "config.json"
  let resPath = workDir / "results.json"
  let repPath = workDir / "replay.json"
  let failPath = workDir / "player_failure.json"
  let cfg = %*{
    "players": [{"name": "P1"}, {"name": "P2"}, {"name": "P3"},
                {"name": "P4"}, {"name": "P5"}],
    "tokens": ["t0", "t1", "t2", "t3", "t4"],
    "num_agents": 5,
    "seed": 42,
    "roles": ["tank", "healer", "dps", "dps", "dps"],
    "bossMaxHp": 3000,
    "turnTicks": 120,
    "enrageTicks": 960,
    "maxTicks": 1200,
    "turnBudgetSeconds": 10,
    "llmAttemptSeconds": 3.0,
    "llmRetrySeconds": 2.0,
    "wallClockBudgetSeconds": 60,
    "playerConnectTimeoutSeconds": 20,
    "mapPath": "foundry"
  }
  writeFile(cfgPath, $cfg)

  let gEnv = baseEnv()
  gEnv["COGAME_HOST"] = "127.0.0.1"
  gEnv["COGAME_PORT"] = $gamePort
  gEnv["COGAME_CONFIG_URI"] = "file://" & cfgPath
  gEnv["COGAME_RESULTS_URI"] = "file://" & resPath
  gEnv["COGAME_SAVE_REPLAY_URI"] = "file://" & repPath
  gEnv["COGAME_PLAYER_FAILURE_URI"] = "file://" & failPath

  let gameProc = startProcess(raidBin, env = gEnv,
    options = {poStdErrToStdOut})
  check(waitForPort(gamePort), "game server listening on port " & $gamePort)

  var players: seq[Process]
  for slot in 0 ..< 5:
    let pEnv = baseEnv()
    pEnv["COWORLD_PLAYER_WS_URL"] =
      "ws://127.0.0.1:" & $gamePort & "/player?slot=" & $slot & "&token=t" & $slot
    if slot == 3:
      if llmEndpoint.len > 0:
        pEnv["COWORLD_LLM_ENDPOINT"] = llmEndpoint
      if llmModel.len > 0:
        pEnv["COWORLD_LLM_MODEL"] = llmModel
    elif slot == 2:
      pEnv["PLAYER_SCRIPTED"] = "greenhorn"
    else:
      pEnv["PLAYER_SCRIPTED"] = "stalwart"
    players.add(startProcess(playerBin, env = pEnv,
      options = {poStdErrToStdOut}))

  result = gameProc.waitForExit(30000)
  gameProc.close()
  for p in players:
    discard p.waitForExit(5000)
    p.close()

proc checkFailureSchema(failNode: JsonNode, expectedSlot: int) =
  checkEq(failNode.kind, JObject, "player_failure.json is a JSON object")
  for k, _ in failNode.pairs:
    check(k in ["failed_policy_index", "message", "kind"],
      "player_failure.json key '" & k & "' is allowed by GamePlayerFailure")
  checkEq(failNode["failed_policy_index"].getInt(), expectedSlot,
    "failed_policy_index attributes failing seat " & $expectedSlot)
  let msg = failNode["message"].getStr()
  check(msg.len >= 1 and msg.len <= 2000,
    "failure message length is within GamePlayerFailure bounds")

proc main() =
  let tmpRoot = getTempDir() / ("raid-http-lifecycle-" & $getCurrentProcessId())
  createDir(tmpRoot)
  defer:
    try: removeDir(tmpRoot)
    except CatchableError: discard

  let (raidBin, playerBin) = buildBinaries(tmpRoot)

  const MockPort = 18741
  createThread(mockThread, runMockServer, MockPort)
  sleep(200)
  let endpoint = "http://127.0.0.1:" & $MockPort

  ## 1. Genuine HTTP-to-game action (single fenced JSON)
  withLock mockLock:
    mockMode = mmValidFenced
    mockCalls = 0
    mockLastModel = ""
    mockLastSlot = ""
  let dir1 = tmpRoot / "valid"
  let rc1 = runScenario(raidBin, playerBin, dir1, 18742,
    endpoint, "anthropic/claude-haiku-4.5")
  checkEq(rc1, 0, "valid HTTP episode exits 0")
  check(not fileExists(dir1 / "player_failure.json"),
    "no player_failure.json on valid episode")
  check(fileExists(dir1 / "results.json"), "results.json written")
  check(fileExists(dir1 / "replay.json"), "replay.json written")
  let res1 = parseJson(readFile(dir1 / "results.json"))
  check(res1["llm_turns"][3].getInt() >= 1, "seat 3 recorded genuine llm_turns")
  for s in 0 ..< 5:
    checkEq(res1["fallback_turns"][s].getInt(), 0,
      "zero fallback_turns on seat " & $s)
  withLock mockLock:
    check(mockCalls >= 1, "mock HTTP endpoint received real LLM calls")
    checkEq(mockLastModel, "anthropic/claude-haiku-4.5",
      "COWORLD_LLM_MODEL forwarded verbatim")
    checkEq(mockLastSlot, "3", "X-Coworld-Player-Slot attributed to seat 3")
  done("genuine HTTP-to-game action with single-fenced JSON completes cleanly")

  ## 2. Mid-episode ambiguous output preserves partial replay + raw output
  withLock mockLock:
    mockMode = mmFailOnTurn1
    mockCalls = 0
  let dir2 = tmpRoot / "partial_fail"
  let rc2 = runScenario(raidBin, playerBin, dir2, 18743,
    endpoint, "anthropic/claude-haiku-4.5")
  check(rc2 != 0, "ambiguous mid-episode reply exits non-zero")
  check(not fileExists(dir2 / "results.json"),
    "no results.json published on mid-episode policy failure")
  check(fileExists(dir2 / "player_failure.json"),
    "player_failure.json written on mid-episode failure")
  let fail2 = parseJson(readFile(dir2 / "player_failure.json"))
  checkFailureSchema(fail2, 3)
  check("I am unsure whether to burn_boss or wait right now." in
    fail2["message"].getStr(),
    "raw ambiguous output preserved in player_failure.json")
  check(fileExists(dir2 / "replay.json"),
    "partial replay.json retained on mid-episode failure")
  let rep2 = parseJson(readFile(dir2 / "replay.json"))
  check(rep2["tick_count"].getInt() >= 120,
    "partial replay retains turn 0 progress (>= 120 ticks)")
  done("mid-episode ambiguous failure retains partial replay and raw output without scores")

  ## 3. Invalid model / HTTP 403 terminates immediately without masking error
  withLock mockLock:
    mockMode = mmAuth403
    mockCalls = 0
  let dir3 = tmpRoot / "auth_403"
  let rc3 = runScenario(raidBin, playerBin, dir3, 18744,
    endpoint, "invalid/nonexistent-model")
  check(rc3 != 0, "HTTP 403 invalid model exits non-zero")
  check(not fileExists(dir3 / "results.json"),
    "no results.json published on HTTP 403")
  check(fileExists(dir3 / "player_failure.json"),
    "player_failure.json written on HTTP 403")
  let fail3 = parseJson(readFile(dir3 / "player_failure.json"))
  checkFailureSchema(fail3, 3)
  check("invalid/nonexistent-model" in fail3["message"].getStr(),
    "exact 403 model error preserved (not masked as no_credentials)")
  withLock mockLock:
    checkEq(mockCalls, 1, "fatal 403 fails immediately without pointless retry")
  done("HTTP 403 / invalid model fails immediately with preserved error and no scores")

  ## 4. Missing credentials terminates cleanly with no scores
  let dir4 = tmpRoot / "no_creds"
  let rc4 = runScenario(raidBin, playerBin, dir4, 18745, "", "")
  check(rc4 != 0, "missing credentials exits non-zero")
  check(not fileExists(dir4 / "results.json"),
    "no results.json published without credentials")
  check(fileExists(dir4 / "player_failure.json"),
    "player_failure.json written without credentials")
  let fail4 = parseJson(readFile(dir4 / "player_failure.json"))
  checkFailureSchema(fail4, 3)
  check("no_credentials" in fail4["message"].getStr(),
    "no_credentials cause recorded")
  done("missing credentials fails cleanly with no scores")

  echo "test_http_lifecycle: HTTP-to-game actions and terminal failure preservation check out"
  quit(0)

when isMainModule:
  main()
