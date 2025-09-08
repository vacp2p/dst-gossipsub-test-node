import std/[sequtils, sets]
import libp2p/[protocols/pubsub/pubsubpeer, switch]

const D* = 4 # No. of peers to forward to

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
