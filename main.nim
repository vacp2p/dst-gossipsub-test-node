import chronos, chronicles, hashes, math, sequtils, strutils, tables, os
import metrics, metrics/chronos_httpserver
import stew/[byteutils, endians2]
import std/[enumerate, options, strformat, sysrand]
import entry_connection, entry_connection_callbacks, mix_node, mix_protocol, protocol
import
  libp2p,
  libp2p/[
    crypto/secp,
    multiaddress,
    builders,
    muxers/mplex/lpchannel,
    protocols/pubsub/gossipsub,
    protocols/pubsub/pubsubpeer,
    protocols/pubsub/rpc/messages,
    transports/tcptransport,
  ]
from times import getTime, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

proc createSwitch(id, port: int): Switch =
  {.gcsafe.}:
    discard initializeMixNodes(1, port)

    let nodePubInfo = getMixPubInfoByIndex(0).valueOr:
      error "Get mix pub info by index error", err = error
      return

    let writePubRes = writePubInfoToFile(nodePubInfo, id)
    if writePubRes.isErr:
      error "Failed to write pub info to file", nodeId = id
      return

    let writeNodeRes = writeMixNodeInfoToFile(mixNodes[0], id)
    if writeNodeRes.isErr:
      error "Failed to write mix info to file", nodeId = id
      return

    let (multiAddrStr, _, _, _, libp2pPrivKey) = getMixNodeInfo(mixNodes[0])

    let multiAddr = MultiAddress.init(multiAddrStr.split("/p2p/")[0]).valueOr:
      error "Failed to initialize MultiAddress", err = error
      return

    let switch = SwitchBuilder
      .new()
      .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: libp2pPrivKey))
      .withAddress(multiAddr)
      .withRng(crypto.newRng())
      .withMplex()
      .withTcpTransport()
      .withNoise()
      .build()

    if switch.isNil:
      warn "Failed to set up node", nodeId = id
      return

    return switch

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Result[MetricsHttpServerRef, string] =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort

  let metricsServerRes = MetricsHttpServerRef.new($serverIp, serverPort)
  if metricsServerRes.isErr():
    return err("metrics HTTP server start failed: " & $metricsServerRes.error)

  let server = metricsServerRes.value
  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  ok(metricsServerRes.value)

proc main() {.async.} =
  let
    hostname = getHostname()
    myId = parseInt(getEnv("PEERNUMBER"))
    msg_rate = parseInt(getEnv("MSGRATE"))
    msg_size = parseInt(getEnv("MSGSIZE"))
    publisherCount = parseInt(getEnv("PEERS"))
    isPublisher = myId <= publisherCount
    rng = libp2p.newRng()
  echo "Hostname: ", hostname
  let
    myport = 5000 + parseInt(getEnv("PEERNUMBER"))
    switch = createSwitch(myId, myport)
    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = true,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
      customConnCallbacks = some(
        CustomConnectionCallbacks(
          customConnCreationCB: mixConn, peerSelectionCB: mixPeerSelect
        )
      ),
    )
  # Metrics
  echo "Starting metrics HTTP server"
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), Port(8008))

  gossipSub.parameters.floodPublish = true
  gossipSub.parameters.opportunisticGraftThreshold = -10000
  gossipSub.parameters.heartbeatInterval = 1.seconds
  gossipSub.parameters.pruneBackoff = 60.seconds
  gossipSub.parameters.gossipFactor = 0.25
  gossipSub.parameters.d = 6
  gossipSub.parameters.dLow = 4
  gossipSub.parameters.dHigh = 8
  gossipSub.parameters.dScore = 6
  gossipSub.parameters.dOut = 6 div 2
  gossipSub.parameters.dLazy = 6
  gossipSub.topicParams["test"] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.9,
  )

  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    let sentUint = uint64.fromBytesLE(data)
    # warm-up
    if sentUint < 1000000:
      return

    let
      sentMoment = nanoseconds(int64(uint64.fromBytesLE(data)))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      diff = getTime() - sentDate
    echo sentUint, " milliseconds: ", diff.inMilliseconds()

  proc messageValidator(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async.} =
    return ValidationResult.Accept

  gossipSub.subscribe("test", messageHandler)
  gossipSub.addValidator(["test"], messageValidator)
  switch.mount(gossipSub)
  await switch.start()

  echo "Listening on ", switch.peerInfo.addrs
  echo myId, ", ", isPublisher, ", ", switch.peerInfo.peerId
  echo "Waiting 60 seconds for node building..."
  await sleepAsync(60.seconds)

  let connectTo = parseInt(getEnv("CONNECTTO"))
  var connected = 0
  let tAddress = "nimp2p-service:5000"
  var addrs: seq[MultiAddress]

  echo "Trying to resolve ", tAddress
  while true:
    try:
      addrs = resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
      echo tAddress, " resolved: ", addrs
      break # Break out of the loop on successful resolution
    except CatchableError as exc:
      echo "Failed to resolve address:", exc.msg
      echo "Waiting 15 seconds..."
      await sleepAsync(15.seconds)

  rng.shuffle(addrs)
  var index = 0
  while true:
    if connected >= connectTo:
      break
    while true:
      try:
        echo "Trying to connect to ", addrs[index]
        let peerId =
          await switch.connect(addrs[index], allowUnknownPeerId = true).wait(5.seconds)
        connected.inc()
        index.inc()
        echo "Connected!"
        break
      except CatchableError as exc:
        echo "Failed to dial", exc.msg
        echo "Waiting 15 seconds..."
        await sleepAsync(15.seconds)

  echo "Mesh size: ", gossipSub.mesh.getOrDefault("test").len

  let turnToPublish = parseInt(getHostname()[4 ..^ 1])
  echo "Publishing turn is: ", turnToPublish
  for msg in 0 ..< 10000: #client.param(int, "message_count"):
    await sleepAsync(msg_rate)
    if msg mod publisherCount == turnToPublish:
      echo "Sending message at: ", times.getTime()
      let
        now = getTime()
        nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
      var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msg_size)
      doAssert((await gossipSub.publish("test", nowBytes)) > 0)

waitFor(main())
