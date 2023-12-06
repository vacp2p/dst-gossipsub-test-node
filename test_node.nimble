mode = ScriptMode.Verbose

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 1.6.0",
          "libp2p#08d9c84aca622f39a434880fee9f9648fd4b60cf",
          "ggplotnim"
