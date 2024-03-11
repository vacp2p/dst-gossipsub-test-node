import stew/endians2, stew/byteutils, tables, strutils, os
import libp2p, libp2p/protocols/pubsub/rpc/messages
import libp2p/muxers/mplex/lpchannel, libp2p/protocols/ping
#import libp2p/protocols/pubsub/pubsubpeer

import chronos
import sequtils, hashes, math, metrics
from times import getTime, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

#These parameters are passed from yaml file, and each defined peer may receive different parameters (e.g. message size)
var
  publisherCount = parseInt(getEnv("PUBLISHERS"))
  msg_size = parseInt(getEnv("MSG_SIZE")) 
  chunks = parseInt(getEnv("FRAGMENTS"))

#we experiment with upto 10 fragments. 1 means, the messages are not fragmented
if chunks < 1 or chunks > 10:     
  chunks = 1

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc main {.async.} =
  let
    hostname = getHostname()
    myId = parseInt(hostname[4..^1])
    isPublisher = myId <= publisherCount      #need to adjust is publishers ldont start from peer1
    #isAttacker = (not isPublisher) and myId - publisherCount <= client.param(int, "attacker_count")
    isAttacker = false
    rng = libp2p.newRng()
    #randCountry = rng.rand(distribCumSummed[^1])
    #country = distribCumSummed.find(distribCumSummed.filterIt(it >= randCountry)[0])
  let
    address = initTAddress("0.0.0.0:5000")
    switch =
      SwitchBuilder
        .new()
        .withAddress(MultiAddress.init(address).tryGet())
        .withRng(rng)
        #.withYamux()
        .withMplex()
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
  gossipSub.parameters.heartbeatInterval = 700.milliseconds
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

    #  pubId = byte(data[11])
    
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


  let connectTo = parseInt(getEnv("CONNECTTO"))
  var connected = 0
  for peerInfo in peersInfo:
    if connected >= connectTo+2: break
    let tAddress = "peer" & $peerInfo & ":5000"
    echo tAddress
    let addrs = resolveTAddress(tAddress).mapIt(MultiAddress.init(it).tryGet())
    try:
      let peerId = await switch.connect(addrs[0], allowUnknownPeerId=true).wait(5.seconds)
      #asyncSpawn pinger(peerId)
      connected.inc()
    except CatchableError as exc:
      echo "Failed to dial", exc.msg

  #let
  #  maxMessageDelay = client.param(int, "max_message_delay")
  #  warmupMessages = client.param(int, "warmup_messages")
  #startOfTest = Moment.now() + milliseconds(warmupMessages * maxMessageDelay div 2)

  await sleepAsync(12.seconds)
  echo "Mesh size: ", gossipSub.mesh.getOrDefault("test").len, 
      ", Total Peers Known : ", gossipSub.gossipsub.getOrDefault("test").len,
      ", Direct Peers : ", gossipSub.subscribedDirectPeers.getOrDefault("test").len,
      ", Fanout", gossipSub.fanout.getOrDefault("test").len, 
      ", Heartbeat : ", gossipSub.parameters.heartbeatInterval.milliseconds

  await sleepAsync(5.seconds)  

  # Actual message publishing, one message published every 3 seconds
  # First 1-2 messages take longer than expected time due to low cwnd. 
  # warmup_messages can set cwnd to a desired level. or alternatively, warmup messages can be set to 0
  let
    warmup_messages = 2 
    #shadow.yaml defines peers with changing latency/bandwith. In the current arrangement all the publishers 
    #will get different latency/bandwidth
    pubStart = 4                                                       
    pubEnd = pubStart + publisherCount + warmup_messages


  #we send warmup_messages for adjusting TCP cwnd  
  for i in pubStart..<(pubStart + warmup_messages):
    await sleepAsync(2.seconds)
    if i == myId:
      #two warmup messages for cwnd raising
      let
          now = getTime()
          nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
      var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msg_size)
      doAssert((await gossipSub.publish("test", nowBytes)) > 0)
  #done sending warmup_messages , wait for short time
  await sleepAsync(5.seconds)


  #We now send publisher_count messages
  for msg in (pubStart + warmup_messages) .. pubEnd:#client.param(int, "message_count"):
    await sleepAsync(3.seconds)
    if msg mod (pubEnd+1) == myId:
      let
        now = getTime()
        nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
    #[    
      if chunks == 1:
        var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](50000)
      else:
        var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](500_000 div chunks)
    ]#
      var nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msg_size div chunks)
      for chunk in 0..<chunks:
        nowBytes[10] = byte(chunk)
        doAssert((await gossipSub.publish("test", nowBytes)) > 0)
      echo "Done Publishing ", nowInt.nanoseconds

  #we need to export these counters from gossipsub.nim
  echo "statcounters: dup_during_validation ", libp2p_gossipsub_duplicate_during_validation.value(),
       "\tidontwant_saves ", libp2p_gossipsub_idontwant_saved_messages.value(),
       "\tdup_received ", libp2p_gossipsub_duplicate.value(),
       "\tUnique_msg_received ", libp2p_gossipsub_received.value(),
       "\tStaggered_Saves ", libp2p_gossipsub_staggerDontWantSave.value(),
       "\tDontWant_IN_Stagger ", libp2p_gossipsub_staggerDontWantSave2.value()
waitFor(main())
