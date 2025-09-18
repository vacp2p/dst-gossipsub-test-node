mode = ScriptMode.Verbose

packageName = "test_node"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "A test node for gossipsub"
license = "MIT"
skipDirs = @[]

requires "nim >= 2.0.8",

  #"https://github.com/vacp2p/nim-libp2p#tmp/mix-gossipsub-logging",
  #"https://github.com/vacp2p/nim-libp2p#7a8a24d1fda862f560b7d91e325aa361543b2ef9", # pwhite/tmp/mix-gossipsub-logging
  #"https://github.com/vacp2p/nim-libp2p#7f1b5b7fb6062aebf261f11f0eb79f466b6089ca", # pwhite/mix_2
  #"https://github.com/vacp2p/nim-libp2p#4509ade75ca872a52c5f0003d10c713aa756c1db", # master
  "https://github.com/vacp2p/nim-libp2p#a923e204472dcc911ecf48bdcb6a00b3bee3386f", # master_fix


  "https://github.com/vacp2p/nim-libp2p#a923e204472dcc911ecf48bdcb6a00b3bee3386f",
  "https://github.com/vacp2p/mix#80a97d3f6c2cfbd1be9085ca019cd5626ea05045", # main

  "chronos", "ggplotnim"
