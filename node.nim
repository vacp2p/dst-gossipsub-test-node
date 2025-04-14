import strformat
import mix/[config, utils]
import libp2p/[crypto/crypto, crypto/secp, multiaddress, peerid]

const NodeInfoSize* = addrSize + (SkRawPublicKeySize + SkRawPrivateKeySize)
const PubInfoSize* = addrSize + SkRawPublicKeySize

type NodeInfo* = object
  multiAddr: string
  libp2pPubKey: SkPublicKey
  libp2pPrivKey: SkPrivateKey

var nodes*: seq[NodeInfo] = @[]

proc initNodeInfo*(
    multiAddr: string, libp2pPubKey: SkPublicKey, libp2pPrivKey: SkPrivateKey
): NodeInfo =
  NodeInfo(
    multiAddr: multiAddr, libp2pPubKey: libp2pPubKey, libp2pPrivKey: libp2pPrivKey
  )

proc getNodeInfo*(info: NodeInfo): (string, SkPublicKey, SkPrivateKey) =
  (info.multiAddr, info.libp2pPubKey, info.libp2pPrivKey)

proc serializeNodeInfo*(nodeInfo: NodeInfo): Result[seq[byte], string] =
  let addrBytes = multiAddrToBytes(nodeInfo.multiAddr).valueOr:
    return err("Error in multiaddress conversion to bytes: " & error)

  let
    libp2pPubKeyBytes = nodeInfo.libp2pPubKey.getBytes()
    libp2pPrivKeyBytes = nodeInfo.libp2pPrivKey.getBytes()

  return ok(addrBytes & libp2pPubKeyBytes & libp2pPrivKeyBytes)

proc deserializeNodeInfo*(data: openArray[byte]): Result[NodeInfo, string] =
  if len(data) != NodeInfoSize:
    return err("Serialized node info must be exactly " & $NodeInfoSize & " bytes")

  let multiAddr = bytesToMultiAddr(data[0 .. addrSize - 1]).valueOr:
    return err("Error in multiaddress conversion to bytes: " & error)

  let libp2pPubKey = SkPublicKey.init(
    data[addrSize .. addrSize + SkRawPublicKeySize - 1]
  ).valueOr:
    return err("Failed to initialize libp2p public key")

  let libp2pPrivKey = SkPrivateKey.init(data[addrSize + SkRawPublicKeySize ..^ 1]).valueOr:
    return err("Failed to initialize libp2p private key")

  ok(
    NodeInfo(
      multiAddr: multiAddr, libp2pPubKey: libp2pPubKey, libp2pPrivKey: libp2pPrivKey
    )
  )

type PubInfo* = object
  multiAddr: string
  libp2pPubKey: SkPublicKey

proc initPubInfo*(multiAddr: string, libp2pPubKey: SkPublicKey): PubInfo =
  PubInfo(multiAddr: multiAddr, libp2pPubKey: libp2pPubKey)

proc getPubInfo*(info: PubInfo): (string, SkPublicKey) =
  (info.multiAddr, info.libp2pPubKey)

proc serializePubInfo*(nodeInfo: PubInfo): Result[seq[byte], string] =
  let addrBytes = multiAddrToBytes(nodeInfo.multiAddr).valueOr:
    return err("Error in multiaddress conversion to bytes: " & error)
  let libp2pPubKeyBytes = nodeInfo.libp2pPubKey.getBytes()

  return ok(addrBytes & libp2pPubKeyBytes)

proc deserializePubInfo*(data: openArray[byte]): Result[PubInfo, string] =
  if len(data) != PubInfoSize:
    return err("Serialized public info must be exactly " & $PubInfoSize & " bytes")

  let multiAddr = bytesToMultiAddr(data[0 .. addrSize - 1]).valueOr:
    return err("Error in bytes to multiaddress conversion: " & error)

  let libp2pPubKey = SkPublicKey.init(data[addrSize ..^ 1]).valueOr:
    return err("Failed to initialize libp2p public key: ")

  ok(PubInfo(multiAddr: multiAddr, libp2pPubKey: libp2pPubKey))

proc getPubInfoByIndex*(index: int): Result[PubInfo, string] =
  if index < 0 or index >= nodes.len:
    return err("Index must be between 0 and " & $(nodes.len))
  ok(
    PubInfo(multiAddr: nodes[index].multiAddr, libp2pPubKey: nodes[index].libp2pPubKey)
  )

proc generateNodes(count: int, basePort: int = 4242): Result[seq[NodeInfo], string] =
  var nodes = newSeq[NodeInfo](count)
  for i in 0 ..< count:
    let
      rng = newRng()
      keyPair = SkKeyPair.random(rng[])
      libp2pPrivKey = keyPair.seckey
      libp2pPubKey = keyPair.pubkey
      pubKeyProto = PublicKey(scheme: Secp256k1, skkey: libp2pPubKey)
      peerId = PeerId.init(pubKeyProto).get()
      multiAddr = fmt"/ip4/127.0.0.1/tcp/{basePort + i}/p2p/{peerId}"

    nodes[i] = NodeInfo(
      multiAddr: multiAddr, libp2pPubKey: libp2pPubKey, libp2pPrivKey: libp2pPrivKey
    )

  ok(nodes)

proc initializeNodes*(count: int, basePort: int = 4242): Result[void, string] =
  nodes = generateNodes(count, basePort).valueOr:
    return err("Node initialization error: " & error)
