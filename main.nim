import chronos, chronicles, hashes, math, sequtils, strutils, tables, os
import metrics, metrics/chronos_httpserver
import stew/[byteutils, endians2]
import std/[enumerate, options, strformat, sysrand, os, sequtils, dirs]

import node
import json
import mix/[entry_connection, entry_connection_callbacks, mix_node, mix_protocol, protocol, utils]
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

proc createSwitch(id, port: int, isMix: bool, filePath: string): Switch =
  {.gcsafe.}:
    var
      multiAddrStr: string
      libp2pPubKey: SkPublicKey
      libp2pPrivKey: SkPrivateKey

    let idBytes = uint32ToBytes(uint32(id))

    if isMix:
      discard initializeMixNodes(1, port)

      let writeNodeRes = writeMixNodeInfoToFile(mixNodes[0], id)
      if writeNodeRes.isErr:
        error "Failed to write mix info to file", nodeId = id
        return

      let nodePubInfo = getMixPubInfoByIndex(0).valueOr:
        error "Get mix pub info by index error", err = error
        return

      let writePubInfoRes = writePubInfoToFile(nodePubInfo, id)
      if writePubInfoRes.isErr:
        error "Failed to write pub info to file", nodeId = id
        return

      let mixNodeInfo = getMixNodeInfo(mixNodes[0])
      multiAddrStr = mixNodeInfo[0]
      libp2pPubKey = mixNodeInfo[3]
      libp2pPrivKey = mixNodeInfo[4]

    else:
      discard initializeNodes(1, port)

      (multiAddrStr, libp2pPubKey, libp2pPrivKey) = getNodeInfo(nodes[0])

    let
      nodeInfo = initNodeInfo(multiAddrStr, libp2pPubKey, libp2pPrivKey)
      pubInfo = initPubInfo(multiAddrStr, libp2pPubKey)

    let multiAddrParts = multiAddrStr.split("/p2p/")
    let multiAddr = MultiAddress.init(multiAddrParts[0]).valueOr:
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
    publisherCount = parseInt(getEnv("PUBLISHERS"))
    isPublisher = myId <= publisherCount
    isMix = isPublisher # Publishers will be the mix nodes for now
    mixCount = publisherCount # Publishers will be the mix nodes for now
    connectTo = parseInt(getEnv("CONNECTTO"))
    mixPoolSize = parseInt(getEnv("MIXPOOLSIZE"))
    filePath = getEnv("FILEPATH", ".")
    rng = libp2p.newRng()

  echo "Hostname: ", hostname
  if mixPoolSize > mixCount:
    error "Mix pool size is greater than total mix count"
    return


  let
    myport = 5000 + parseInt(getEnv("PEERNUMBER"))
    switch = createSwitch(myId, myport, isMix, filePath)

  await sleepAsync(10.seconds)


  let mixProto = MixProtocol.new(myId, mixCount, switch).expect("could not instantiate mix")

  let mixConn = proc(
        destAddr: Option[MultiAddress], destPeerId: PeerId, codec: string
    ): Connection {.gcsafe, raises: [].} =
      try:
        return mixProto.createMixEntryConnection(destAddr, destPeerId, codec)
      except CatchableError as e:
        error "Error during execution of MixEntryConnection callback: ", err = e.msg
        return nil

  let mixPeerSelect = proc(
      allPeers: HashSet[PubSubPeer],
      directPeers: HashSet[PubSubPeer],
      meshPeers: HashSet[PubSubPeer],
      fanoutPeers: HashSet[PubSubPeer],
    ): HashSet[PubSubPeer] {.gcsafe, raises: [].} =
      try:
        return mixPeerSelection(allPeers, directPeers, meshPeers, fanoutPeers)
      except CatchableError as e:
        error "Error during execution of MixPeerSelection callback: ", err = e.msg
        return initHashSet[PubSubPeer]()

  let
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

  var
    curPoolSize = 0
    pool: seq[string] = @[]



  #[
  while true:
    await sleepAsync(5.seconds)
    if curPoolSize == mixCount:
      break

    var mixList: seq[string] = @[]
    try:
      mixList = redisClient.lRange("mix", curPoolSize, -1)
    except Exception as e:
      warn "Error retrieving mix nodes", startInd = curPoolSize, err = e
      continue
    
    pool.add(mixList[0 .. ^ 1])
    curPoolSize += mixList.len
  ]#

  #[
  rng.shuffle(pool)
  let mixPool = pool[0..mixPoolSize]

  for index, node in enumerate(mixPool):
    let pubInfo = cast[seq[byte]](mixPool[index])
    if len(pubInfo) != MixPubInfoSize + 4:
      error "Serialized id and pub info must be exactly " & $(MixPubInfoSize + 4) & " bytes"
      return
      
      let id = bytesToUInt32(pubInfo[0..3]).valueOr:
        error "Error in bytes to id conversion", err = error
        return

      let dMixPubInfo = deserializeMixPubInfo(pubInfo[4..^1]).valueOr:
        error "Error in bytes to mix public info conversion", err = error
        return

      let writePubRes = writePubInfoToFile(dMixPubInfo, int(id))
      if writePubRes.isErr:
        error "Failed to write mix pub info to file", nodeId = id
        return
  ]#


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

  var connected = 0
  var addrs: seq[MultiAddress]
  # TODO: get addrs

 
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
