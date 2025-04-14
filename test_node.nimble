mode = ScriptMode.Verbose

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 1.6.0",
         "https://github.com/AkshayaMani/nim-libp2p#gossipsub-custom-conn",
         "https://github.com/vacp2p/mix#poc/gossipsub",
         "ggplotnim",
         "redis >= 0.2.0"
