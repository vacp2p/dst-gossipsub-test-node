import chronos, chronicles, results
from times import nil
import metrics, metrics/chronos_httpserver
import stew/[byteutils, endians2]
import
  std/[
    strformat, random, hashes, sequtils, strutils, tables, os,
    nativesockets,
  ]
import mix
import ./node
import
  libp2p,
  libp2p/[
    crypto/secp,
    multiaddress,
    builders,
    protocols/pubsub/gossipsub,
    protocols/pubsub/pubsubpeer,
    protocols/pubsub/rpc/messages,
  ]
from times import getTime, toUnixFloat, `-`, initTime, `$`, inMilliseconds, Time

# const D* = 4 # No. of peers to forward to
const D* = 1 # No. of peers to forward to

template toUnixNanoseconds(t: times.Time): int64 =
  (t.toUnixFloat() * 1_000_000_000).int64

template fromUnixNanoseconds(ns: int64): times.Time =
  initTime(ns div 1_000_000_000, ns mod 1_000_000_000)

template toUnixNanoseconds(t: times.Time): int64 =
  (t.toUnixFloat() * 1_000_000_000).int64

template fromUnixNanoseconds(ns: int64): times.Time =
  initTime(ns div 1_000_000_000, ns mod 1_000_000_000)

proc mixPeerSelection*(
    allPeers: HashSet[PubSubPeer],
    directPeers: HashSet[PubSubPeer],
    meshPeers: HashSet[PubSubPeer],
    fanoutPeers: HashSet[PubSubPeer],
): HashSet[PubSubPeer] {.gcsafe, raises: [].} =
  var
    peers: HashSet[PubSubPeer]
    allPeersSeq = allPeers.toSeq()
  let rng = newRng()
  rng.shuffle(allPeersSeq)
  for p in allPeersSeq:
    peers.incl(p)
    if peers.len >= D:
      break
  return peers

proc createSwitch(id, port: int, isMix: bool, filePath: string): Switch =
  {.gcsafe.}:
    var
      multiAddrStr: string
      libp2pPubKey: SkPublicKey
      libp2pPrivKey: SkPrivateKey

    var mixNodes: MixNodes = @[]

    if isMix:
      mixNodes = initializeMixNodes(1, port).valueOr:
        error "Could not generate mix nodes"
        return

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
      .withYamux()
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
      let initRes = mixNodes.initMixMultiAddrByIndex(0, externalMultiAddr)
      if initRes.isErr:
        error "Failed to initialize mix node", id = 0, err = initRes.error
        return
      let writeNodeRes =
        writeMixNodeInfoToFile(mixNodes[0], id, filePath / fmt"nodeInfo")
      if writeNodeRes.isErr:
        error "Failed to write mix info to file", nodeId = id, err = writeNodeRes.error
        return

      let nodePubInfo = mixNodes.getMixPubInfoByIndex(0).valueOr:
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

  let server = MetricsHttpServerRef.new($serverIp, serverPort).valueOr:
    return err("metrics HTTP server start failed: " & $error)

  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort

  ok(server)

proc makeMixConnCb(mixProto: MixProtocol): CustomConnCreationProc =
  return proc(
      destAddr: Option[MultiAddress], destPeerId: PeerId, codec: string
  ): Connection {.gcsafe, raises: [].} =
    try:
      let dest = destAddr.valueOr:
        debug "No destination address available"
        return
      return mixProto.toConnection(MixDestination.init(destPeerId, dest), codec).get()
    except CatchableError as e:
      error "Error during execution of MixEntryConnection callback: ", err = e.msg
      return nil

proc main() {.async.} =
  randomize()

  let
    hostname = getHostname()
    node_count = parseInt(getEnv("NODES"))
    messages = parseInt(getEnv("MESSAGES"))
    msg_rate = parseInt(getEnv("MSGRATE"))
    msg_size = parseInt(getEnv("MSGSIZE"))
    publisherCount = parseInt(getEnv("PUBLISHERS"))
    isMix = parseBool(getEnv("ISMIX"))
    mixCount = parseInt(getEnv("NUMMIX"))
      # Ensures all nodes run Mix so that any GossipSub peer can act as an exit node
    connectTo = parseInt(getEnv("CONNECTTO"))
    filePath = getEnv("FILEPATH", "./")
    rng = libp2p.newRng()

  if publisherCount > node_count:
    error "Publisher count is greater than total node count"
    return

  info "Hostname", host = hostname
  # let myId = getHostname().split('-')[^1].parseInt()
  let myId = getHostname().split('-')[^1].parseInt() + (if not isMix: mixCount else: 0)

  info "ID", id = myId

  let
    isPublisher = myId < publisherCount
    triggerSelf = parseBool(getEnv("SELFTRIGGER"))
    myport = parseInt(getEnv("PORT", "5000"))
    switch = createSwitch(myId, myport, isMix, filePath)

  info "params", triggerSelf = triggerSelf, isMix = isMix, hostname = hostname, publisherCount = publisherCount

  await sleepAsync(10.seconds)

  var gossipSub: GossipSub

  if isMix:
    let mixProto = MixProtocol.new(myId, mixCount, switch, filePath).expect(
        "could not instantiate mix"
      )

    let mixConn = makeMixConnCb(mixProto)

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

    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = triggerSelf,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
      customConnCallbacks = some(
        CustomConnectionCallbacks(
          customConnCreationCB: mixConn, customPeerSelectionCB: mixPeerSelect
        )
      ),
    )

    switch.mount(mixProto)
  else:
    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = triggerSelf,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
    )

  # Metrics
  info "Starting metrics HTTP server"
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
    if data.len < 16:
      warn "Message too short"
      return

    let
      timestampNs = uint64.fromBytesLE(data[0 ..< 8]).int64
      sendTime = fromUnixNanoseconds(timestampNs)
      msgId = uint64.fromBytesLE(data[8 ..< 16])
      recvTime = getTime()
      delay = recvTime - sendTime

    info "Received message",
      msgId = msgId,
      sentAt = timestampNs,
      current = recvTime.toUnixNanoseconds(),
      delayMs = delay.inMilliseconds()

  proc messageValidator(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async.} =
    return ValidationResult.Accept

  gossipSub.subscribe("test", messageHandler)
  gossipSub.addValidator(["test"], messageValidator)
  switch.mount(gossipSub)
  await switch.start()

  info "PeerId ", peerid = switch.peerInfo.peerId
  info "Listening", addrs = switch.peerInfo.addrs

  info "Waiting 20 seconds for node building..."

  await sleepAsync(20.seconds)

  var connected = 0
  var addrs: seq[MultiAddress]

  for i in 0 ..< node_count:
    if i == myId:
      continue

    let pubInfo = readPubInfoFromFile(i, filePath / fmt"libp2pPubInfo").expect(
        "should be able to read pubinfo"
      )
    let (multiAddr, _) = getPubInfo(pubInfo)
    let ma = MultiAddress.init(multiAddr).expect("should be a multiaddr")
    info "Add", ma = ma
    addrs.add ma

  rng.shuffle(addrs)
  var index = 0
  while true:
    if connected >= connectTo:
      break
    while true:
      try:
        info "Trying to connect", index = index, addrs = addrs[index]
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

  await sleepAsync(2.seconds)

  info "Mesh size", meshSize = gossipSub.mesh.getOrDefault("test").len

  info "Publishing turn", id = myId
  for msg in 0 ..< messages: #client.param(int, "message_count"):
    await sleepAsync(msg_rate.milliseconds)
    if msg mod publisherCount == myId:
      let timestampNs = getTime().toUnixNanoseconds()
      let msgId = uint64(msg)

      var payload: seq[byte]
      payload.add(toBytesLE(timestampNs.uint64))

      info "Publish LE", le = toBytesLE(timestampNs.uint64)
      info "Publish uint", ui = timestampNs.uint64
      info "Publish timestamp", ts = timestampNs

      payload.add(toBytesLE(msgId))
      info "Publish msgId", id = msgId
      payload.add(newSeq[byte](msg_size - 16)) # Fill the rest with padding

      info "Publish payload", bytes = payload

      info "Publishing message", msgId = msgId, timestamp = timestampNs

      doAssert(
        (
          await gossipSub.publish(
            "test",
            payload,
            publishParams = some(PublishParams(skipMCache: true, useCustomConn: isMix)),
          )
        ) > 0
      )
  info "Out of for loop"
  await sleepAsync(10.days)
  info "end of main"

waitFor(main())
