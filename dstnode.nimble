mode = ScriptMode.Verbose

### Package
version       = "0.1.0"
author        = "Distributed Systems Testing"
description   = "DstNode - Libp2p version: V1.2 (c4da9be32cc01efa2de066c396fe9ef1c7769aa1)"
license       = "MIT or Apache License 2.0"
#bin           = @["build/waku"]

### Dependencies
requires "nim >= 1.6.0",
          "libp2p",
          "stew",
          "chronos",
          "chronicles"


### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

### DstNode tasks
task dstnode, "Build DstNode":
  let name = "main"
  buildBinary name
