import stew/endians2, stew/byteutils, tables, strutils, os
import libp2p, libp2p/protocols/pubsub/rpc/messages
import libp2p/muxers/mplex/lpchannel, libp2p/protocols/ping
import chronos
import sequtils, hashes, math, metrics
from times import getTime, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

const chunks = 1

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc main {.async.} =
  let
    hostname = getHostname()
    myId = parseInt(getEnv("PEERNUMBER"))
    #publisherCount = client.param(int, "publisher_count")
    publisherCount = parseInt(getEnv("PEERS"))
    isPublisher = myId <= publisherCount
    #isAttacker = (not isPublisher) and myId - publisherCount <= client.param(int, "attacker_count")
    isAttacker = false
    rng = libp2p.newRng()
    #randCountry = rng.rand(distribCumSummed[^1])
    #country = distribCumSummed.find(distribCumSummed.filterIt(it >= randCountry)[0])
  echo "Hostname: ", hostname
  let
    myport = 5000 + parseInt(getEnv("PEERNUMBER"))
    myaddress = "0.0.0.0:" & $myport
    address = initTAddress(myaddress)
    switch =
      SwitchBuilder
        .new()
        .withAddress(MultiAddress.init(address).tryGet())
        .withRng(rng)
        #.withYamux()
        .withMplex()
        .withMaxConnections(250)
        .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
        #.withPlainText()
        .withNoise()
        .build()
    gossipSub = GossipSub.init(
      switch = switch,
#      triggerSelf = true,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
      )
    pingProtocol = Ping.new(rng=rng)
gossipSub.parameters.floodPublish = true
  #gossipSub.parameters.lazyPushThreshold = 1_000_000_000
  #gossipSub.parameters.lazyPushThreshold = 0
  gossipSub.parameters.opportunisticGraftThreshold = -10000
  gossipSub.parameters.heartbeatInterval = 700.milliseconds
  gossipSub.parameters.pruneBackoff = 3.seconds
  gossipSub.parameters.gossipFactor = 0.05
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
    firstMessageDeliveriesDecay: 0.9
  )

  var messagesChunks: CountTable[uint64]
  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    let sentUint = uint64.fromBytesLE(data)
    # warm-up
    if sentUint < 1000000: return
    #if isAttacker: return

    messagesChunks.inc(sentUint)
    if messagesChunks[sentUint] < chunks: return
    let
      sentMoment = nanoseconds(int64(uint64.fromBytesLE(data)))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      diff = getTime() - sentDate
    echo sentUint, " milliseconds: ", diff.inMilliseconds()


  var
    startOfTest: Moment
    attackAfter = 10000.hours
  proc messageValidator(topic: string, msg: Message): Future[ValidationResult] {.async.} =
    if isAttacker and Moment.now - startOfTest >= attackAfter:
      return ValidationResult.Ignore

    return ValidationResult.Accept

  gossipSub.subscribe("test", messageHandler)
  gossipSub.addValidator(["test"], messageValidator)
  switch.mount(gossipSub)
  switch.mount(pingProtocol)
  await switch.start()
  #TODO
  #defer: await switch.stop()

  echo "Listening on ", switch.peerInfo.addrs
  echo myId, ", ", isPublisher, ", ", switch.peerInfo.peerId
  echo "Waiting 60 seconds for node building..."
  await sleepAsync(60.seconds)

  var peersInfo = toSeq(0..<parseInt(getEnv("PEERS")))
  var peerPerPod = parseInt(getEnv("PEERSPERPOD"))
  rng.shuffle(peersInfo)

  proc pinger(peerId: PeerId) {.async.} =
    try:
      await sleepAsync(20.seconds)
      while true:
        let stream = await switch.dial(peerId, PingCodec)
        let delay = await pingProtocol.ping(stream)
        await stream.close()
        #echo delay
        await sleepAsync(delay)
    except:
      echo "Failed to ping"


  let connectTo = parseInt(getEnv("CONNECTTO"))
  var connected = 0
  for peerInfo in peersInfo:
    if connected >= connectTo: break
    let number = peerInfo div peerPerPod
    let port = 5000 + (peerInfo mod peerPerPod)
    let tAddress = "pod-" & $number & ":" & $port
    echo "Will connect to peer " , peerInfo
    echo "Service : ", tAddress

    var addrs: seq[MultiAddress]
    echo "Trying to resolve ", tAddress
    while true:
      try:
        addrs = resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
        echo tAddress, " resolved: ", addrs
        break  # Break out of the loop on successful resolution
      except CatchableError as exc:
        echo "Failed to resolve address:", exc.msg
        echo "Waiting 15 seconds..."
        await sleepAsync(15.seconds)

    while true:
      try:
        echo "Trying to connect to ", addrs[0]
        let peerId = await switch.connect(addrs[0], allowUnknownPeerId=true).wait(5.seconds)
        #asyncSpawn pinger(peerId)
        connected.inc()
        echo "Connected!"
        break
      except CatchableError as exc:
        echo "Failed to dial", exc.msg
        echo "Waiting 15 seconds..."
        await sleepAsync(15.seconds)

  #let
  #  maxMessageDelay = client.param(int, "max_message_delay")
  #  warmupMessages = client.param(int, "warmup_messages")
  #startOfTest = Moment.now() + milliseconds(warmupMessages * maxMessageDelay div 2)

  echo "Mesh size: ", gossipSub.mesh.getOrDefault("test").len

  let turnToPublish = parseInt(getHostname()[4..^1])
  echo "Publishing turn is: ", turnToPublish
  for msg in 0 ..< 10000:#client.param(int, "message_count"):
    await sleepAsync(1.seconds)
    if msg mod publisherCount == turnToPublish:
      echo "Sending message at: " ,times.getTime()
      let
        now = getTime()
        nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
      var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](10000)
      doAssert((await gossipSub.publish("test", nowBytes)) > 0)

  #echo "BW: ", libp2p_protocols_bytes.value(labelValues=["/meshsub/1.1.0", "in"]) + libp2p_protocols_bytes.value(labelValues=["/meshsub/1.1.0", "out"])
  #echo "DUPS: ", libp2p_gossipsub_duplicate.value(), " / ", libp2p_gossipsub_received.value()

waitFor(main())