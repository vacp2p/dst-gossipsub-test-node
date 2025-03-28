import stew/endians2, stew/byteutils, tables, strutils, os
import "../../nim-libp2p/libp2p", "../../nim-libp2p/libp2p/protocols/pubsub/rpc/messages"
import "../../nim-libp2p/libp2p/muxers/mplex/lpchannel", "../../nim-libp2p/libp2p/protocols/ping"

import chronos, std/atomics
import sequtils, hashes, math, metrics
from times import getTime, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

#These parameters are passed from yaml file, and each defined peer may receive different parameters (e.g. message size)
var
  messageCount = parseInt(getEnv("PUBLISHERS"))
  msg_size = parseInt(getEnv("MSG_SIZE")) 
  chunks = parseInt(getEnv("FRAGMENTS"))
  publisherID = parseInt(getEnv("PUBLISHER_ID"))
  publishWait = parseInt(getEnv("MESSAGE_DELAY"))
  connectTo   = parseInt(getEnv("CONNECTTO"))

#we experiment with upto 10 fragments. 1 means, the messages are not fragmented
if chunks < 1 or chunks > 10:     
  chunks = 1

let
    pubStart = 1              #first publisher ID if publisherID set to 0                                         
    warmup_messages = 2       #to raise cwnd, not included in stats
    pubEnd = pubStart + messageCount + warmup_messages    #every publisher sends one message

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc main {.async.} =
  let
    hostname = getHostname()
    myId = parseInt(hostname[4..^1])
    isPublisher = (myId == publisherID) or (myId >= pubStart and myId < pubEnd)
    #isAttacker = (not isPublisher) and myId - messageCount <= client.param(int, "attacker_count")
    isAttacker = false
    rng = libp2p.newRng()
  

  let
    address = initTAddress("0.0.0.0:5000")
    switch =
      SwitchBuilder
        .new()
        .withAddress(MultiAddress.init(address).tryGet())
        .withRng(rng)
        .withYamux()
        #.withMplex()
        .withMaxConnections(10000)
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
  gossipSub.parameters.floodPublish = false 
  #gossipSub.parameters.lazyPushThreshold = 1_000_000_000
  #gossipSub.parameters.lazyPushThreshold = 0
  gossipSub.parameters.opportunisticGraftThreshold = -10000
  gossipSub.parameters.heartbeatInterval = 1000.milliseconds
  gossipSub.parameters.pruneBackoff = 3.seconds
  gossipSub.parameters.gossipFactor = 0.05
  gossipSub.parameters.d = 8
  gossipSub.parameters.dLow = 6
  gossipSub.parameters.dHigh = 12
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

  var peersInfo = toSeq(1..parseInt(getEnv("PEERS")))
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


  var connected = 0
  for peerInfo in peersInfo:
    if connected > connectTo+2: break
    let tAddress = "peer" & $peerInfo & ":5000"
    echo tAddress
    let addrs = resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
    try:
      let peerId = await switch.connect(addrs[0], allowUnknownPeerId=true).wait(5.seconds)
      #asyncSpawn pinger(peerId)
      connected.inc()
    except CatchableError as exc:
      echo "Failed to dial", exc.msg

  await sleepAsync(12.seconds)
  echo "Mesh size: ", gossipSub.mesh.getOrDefault("test").len, 
      ", Total Peers Known : ", gossipSub.gossipsub.getOrDefault("test").len,
#      ", Direct Peers : ", gossipSub.subscribedDirectPeers.getOrDefault("test").len,
      ", Fanout", gossipSub.fanout.getOrDefault("test").len, 
      ", Heartbeat : ", gossipSub.parameters.heartbeatInterval.milliseconds

  await sleepAsync(5.seconds)  

  # warmup message publishing, one message published every 5 seconds
  # First 1-2 messages take longer than expected time due to low cwnd. 
  # warmup_messages can set cwnd to a desired level. or alternatively, warmup messages can be set to 0
  var nextSender: int 
  for i in pubStart..<(pubStart + warmup_messages):
    await sleepAsync(5.seconds)

    if publisherID != 0:
      nextSender = publisherID
    else:
      nextSender = i
    
    if nextSender == myId:
      let
          now = getTime()
          nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
      var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msg_size div chunks)
      for chunk in 0..<chunks:
        nowBytes[10] = byte(chunk)
        doAssert((await gossipSub.publish("test", nowBytes)) > 0)
  #done sending warmup_messages , wait for short time
  await sleepAsync(10.seconds)

  #We now send messageCount messages
  for msg in (pubStart + warmup_messages) ..< pubEnd:
    #await sleepAsync(100.milliseconds)
    await sleepAsync(publishWait.milliseconds)

    if publisherID != 0:
      nextSender = publisherID
    else:
      nextSender = msg

    if nextSender == myId:
      let
        now = getTime()
        nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
      var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds)+uint64(msg))) & newSeq[byte](msg_size div chunks)
      for chunk in 0..<chunks:
        nowBytes[10] = byte(chunk)
        doAssert((await gossipSub.publish("test", nowBytes)) > 0)
      echo "Done Publishing ", nowInt.nanoseconds
  await sleepAsync(5.seconds)

  #we need to export these counters from gossipsub.nim, or comment these
  echo "statcounters: Dup_During_Validation ", lma_dup_during_validation.load(),
       "\tDup_Received ", lma_duplicate_count.load(),
       "\tIWANTS_Sent ", lma_iwants_sent.load(),
       "\tIWANTS_Replied ", lma_iwants_replied.load(),
       "\tIDontWant_Saves ", lma_idontwant_saves.load(),
       "\tIMReceiving_Saves ", lma_imreceiving_saves.load()

waitFor(main())
