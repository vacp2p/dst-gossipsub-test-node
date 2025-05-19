import chronos, chronicles, hashes, math, sequtils, strutils, tables, os
import nimcrypto/sysrand
import metrics, metrics/chronos_httpserver
import stew/[byteutils, endians2]
import
  std/[
    enumerate, options, strformat, sysrand, os, sequtils, dirs, parseutils, random,
    posix, algorithm,
  ]
import node
import json
import
  mix/[
    entry_connection, entry_connection_callbacks, mix_node, mix_protocol, protocol,
    utils,
  ]
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

    if isMix:
      discard initializeMixNodes(1, port)

      let mixNodeInfo = getMixNodeInfo(mixNodes[0])
      multiAddrStr = mixNodeInfo[0]
      libp2pPubKey = mixNodeInfo[3]
      libp2pPrivKey = mixNodeInfo[4]
    else:
      discard initializeNodes(1, port)

      (multiAddrStr, libp2pPubKey, libp2pPrivKey) = getNodeInfo(nodes[0])

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

    let addresses = getInterfaces().filterIt(it.name == "eth0").mapIt(it.addresses)
    if addresses.len < 1 or addresses[0].len < 1:
      error "Can't find local ip!"
      return

    let
      externalAddr = ($addresses[0][0].host).split(":")[0]
      peerId = switch.peerInfo.peerId
      externalMultiAddr = fmt"/ip4/{externalAddr}/tcp/{port}/p2p/{peerId}"

    if isMix:
      discard initMixMultiAddrByIndex(0, externalMultiAddr)
      let writeNodeRes =
        writeMixNodeInfoToFile(mixNodes[0], id, filePath / fmt"nodeInfo")
      if writeNodeRes.isErr:
        error "Failed to write mix info to file", nodeId = id, err = writeNodeRes.error
        return

      let nodePubInfo = getMixPubInfoByIndex(0).valueOr:
        error "Get mix pub info by index error", err = error
        return

      let writeMixPubInfoRes =
        writeMixPubInfoToFile(nodePubInfo, id, filePath / fmt"pubInfo")
      if writeMixPubInfoRes.isErr:
        error "Failed to write mix pub info to file", nodeId = id
        return

    let pubInfo = initPubInfo(externalMultiAddr, libp2pPubKey)

    let writePubInfoRes = writePubInfoToFile(pubInfo, id, filePath / fmt"libp2pPubInfo")
    if writePubInfoRes.isErr:
      error "Failed to write pub info to file", nodeId = id
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

const uidLen = 32
type
  MainObj = ref object
    hostname: string
    id: int
    nodeCount: int
    msgRate: int
    msgSize: int
    publisherCount: int
    isPublisher: bool
    mixCount: int
    connectTo: int
    filePath: string
    rng: ref HmacDrbgContext

proc makeMainObj(): Result[MainObj, string] =
  error "this is the nodes env: " & getEnv("NODES")
  let
    hostname = getHostname()
    nodeCount = parseInt(getEnv("NODES"))
    msgRate = parseInt(getEnv("MSGRATE"))
    msgSize = parseInt(getEnv("MSGSIZE"))
    publisherCount = parseInt(getEnv("PUBLISHERS"))
    connectTo = parseInt(getEnv("CONNECTTO"))
    filePath = getEnv("FILEPATH", "./")
    rng = libp2p.newRng()

  if publisherCount > nodeCount:
    return err("Publisher count is greater than total node count")

  let id = hostname.split('-')[^1].parseInt()
  info "Hostname", host = hostname
  info "ID", id = id
  result = ok(MainObj(
    hostname: hostname,
    id: id,
    nodeCount: nodeCount,
    msgRate: msgRate,
    msgSize: msgSize,
    publisherCount: publisherCount,
    isPublisher: id < publisherCount,
    mixCount: publisherCount,  # same for now
    connectTo: connectTo,
    filePath: filePath,
    rng: rng
  ))


proc switchFromMainObj(m: MainObj, port: int): Switch =
  createSwitch(m.id, port, m.isPublisher, m.filePath)

proc mixProtoFromMainObj(m: MainObj, switch: Switch): Result[MixProtocol, string] =
  MixProtocol.new(m.id, m.mixCount, switch, m.filePath)

proc doMix(m: MainObj, switch: Switch): GossipSub = 
  let mixProto = mixProtoFromMainObj(m, switch).expect(
      "could not instantiate mix"
    )

  let mixConn = proc(
      destAddr: Option[MultiAddress], destPeerId: PeerId, codec: string
  ): Connection {.gcsafe, raises: [].} =
    try:
      return mixProto.createMixEntryConnection(destAddr, destPeerId, codec)
    except CatchableError as e:
      error "Error during execution of MixEntryConnection callback", err = e.msg
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
      error "Error during execution of MixPeerSelection callback", err = e.msg
      return initHashSet[PubSubPeer]()

  let gossipSub = GossipSub.init(
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

  switch.mount(mixProto)
  return gossipSub


proc main() {.async.} =
  randomize()

  let main_obj = makeMainObj().valueOr:
    error "Failed to make a main object: ", error
    return

  let
      # [0..<publisherCount] contains all the publishers
    isMix = main_obj.isPublisher # Publishers will be the mix nodes for now
    # myport = parseInt(getEnv("PORT", "5000"))
    switch = switchFromMainObj(main_obj, parseInt(getEnv("PORT", "5000")))

  # TODO: what's this await for? any way to trigger an await on the setup?
  await sleepAsync(10.seconds)

  var gossipSub: GossipSub

  if isMix:
    gossipSub = doMix(main_obj, switch)
  else:
    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = true,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
    )

  # Metrics
  info "Starting metrics HTTP server"
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), Port(8008))

  # can this be done with the builder pattern
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

  # TODO? make a message interface for handler and validator?
  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    if data.len < 16:
      warn "Message too short"
      return

    let
      timestampNs = uint64.fromBytesLE(data[0 ..< 8])
      msgId = uint64.fromBytesLE(data[8 ..< 16])
      sentMoment = nanoseconds(int64(timestampNs))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      recvTime = getTime()
      delay = recvTime - sentDate

    info "Received message", msgId = msgId, sentAt = timestampNs, delayMs = delay.inMilliseconds()

  proc messageValidator(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async.} =
    return ValidationResult.Accept

  gossipSub.subscribe("test", messageHandler)
  gossipSub.addValidator(["test"], messageValidator)
  switch.mount(gossipSub)
  await switch.start()

  info "Listening", addrs = switch.peerInfo.addrs

  # TODO: can node-building be an async so we don't have to hard-code the await?
  info "Waiting 20 seconds for node building..."
  await sleepAsync(20.seconds)

  var connected = 0
  var addrs: seq[MultiAddress]

  # This loop can be a function.
  for i in 0 ..< main_obj.node_count:
    if i == main_obj.id:
      continue

    let pubInfo = readPubInfoFromFile(i, main_obj.filePath / fmt"libp2pPubInfo").expect(
        "should be able to read pubinfo"
      )
    let (multiAddr, _) = getPubInfo(pubInfo)
    let ma = MultiAddress.init(multiAddr).expect("should be a multiaddr")
    addrs.add ma

  main_obj.rng.shuffle(addrs)
  var index = 0
  # `while true` is often a tell.
  while true:
    if connected >= main_obj.connectTo:
      break
    while true:
      try:
        info "Trying to connect", addrs = addrs[index]
        let peerId =
          await switch.connect(addrs[index], allowUnknownPeerId = true).wait(5.seconds)
        connected.inc()
        index.inc()
        info "Connected!"
        break
      except CatchableError as exc:
        error "Failed to dial", err = exc.msg
        info "Waiting 15 seconds..."
        await sleepAsync(15.seconds)

  # why hard coded pause?
  await sleepAsync(2.seconds)

  info "Mesh size", meshSize = gossipSub.mesh.getOrDefault("test").len

  info "Publishing turn", id = main_obj.id
  for msg in 0 ..< 10000: #client.param(int, "message_count"):
    await sleepAsync(main_obj.msg_rate)
    if msg mod main_obj.publisherCount == main_obj.id:
      info "Sending message", time = times.getTime()
      let now = getTime()
      let timestampNs = now.toUnix().int64 * 1_000_000_000 + times.nanosecond(now).int64
      let msgId = uint64(msg)

      var payload: seq[byte]
      payload.add(toBytesLE(uint64(timestampNs)))
      payload.add(toBytesLE(msgId))
      payload.add(newSeq[byte](main_obj.msg_size - 16))  # Fill the rest with padding

      info "Publishing message", msgId = msgId, timestamp = timestampNs

      doAssert((await gossipSub.publish("test", payload, useCustomConn = true)) > 0)

waitFor(main())
