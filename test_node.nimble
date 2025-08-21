mode = ScriptMode.Verbose

packageName   = "test_node"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "A test node for gossipsub"
license       = "MIT"
skipDirs      = @[]

requires "nim >= 2.0.8",
         "https://github.com/vacp2p/nim-libp2p#tmp/mix-gossipsub-logging",
         "https://github.com/vacp2p/mix#tmp/benchmark-logging",
         "chronos",
         "ggplotnim"
