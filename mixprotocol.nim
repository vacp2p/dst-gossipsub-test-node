import chronicles, chronos, os, strutils
import std/[strformat]
import
  mix/[
    mix_node, mix_protocol, tag_manager,
  ]
import libp2p
import
  libp2p/
    [protocols/ping, protocols/protocol, stream/connection, stream/lpstream, switch]

proc loadNodeInfo*(index: int, nodeFolderInfoPath: string = "./nodeInfo"): Result[MixNodeInfo, string] =
  let readNode = readMixNodeInfoFromFile(index, nodeFolderInfoPath).valueOr:
    return err("Failed to load node info from file: " & error)
  ok(readNode)

proc loadAllButIdPubInfo*(
    id, numNodes: int,
    pubInfoFolderPath: string = "./pubInfo"
): Result[Table[PeerId, MixPubInfo], string] =
  var pubInfoTable = initTable[PeerId, MixPubInfo]()
  for file in walkFiles(pubInfoFolderPath / "*"):
    let nodeId = parseInt(file.split("_")[1])
    if id != nodeId:
      let pubInfo = readMixPubInfoFromFile(nodeId, pubInfoFolderPath).valueOr:
        return err("Failed to load pub info from file: " & error)

      let (multiAddr, _, _) = getMixPubInfo(pubInfo)

      let peerId = getPeerIdFromMultiAddr(multiAddr).valueOr:
        return err("Failed to get peer id from multiaddress: " & error)

      pubInfoTable[peerId] = pubInfo
  return ok(pubInfoTable)

proc newMixProtocol*(
    T: typedesc[MixProtocol], id, numNodes: int, switch: Switch, nodeFolderInfoPath: string = "."
): Result[T, string] =
  let mixNodeInfo = loadNodeInfo(id, nodeFolderInfoPath / fmt"nodeInfo").valueOr:
    return err("Failed to load mix node info for id " & $id & " - err: " & error)

  let pubNodeInfo = loadAllButIdPubInfo(id, numNodes, nodeFolderInfoPath / fmt"pubInfo").valueOr:
    return err("Failed to load mix pub info for id " & $id & " - err: " & error)

  let mixProto = T(
    mixNodeInfo: mixNodeInfo,
    pubNodeInfo: pubNodeInfo,
    switch: switch,
    tagManager: initTagManager(),
  )
  mixProto.init()
  return ok(mixProto)
