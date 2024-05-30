mode = ScriptMode.Verbose

packageName   = "dstnode"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 1.6.0",
          "libp2p",
          "ggplotnim"
