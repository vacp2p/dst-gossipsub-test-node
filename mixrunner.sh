
#!/bin/bash

N="$1"
DATADIR="$2"

if [[ -z "$N" || -z "$DATADIR" ]]; then
  echo "usage: $0 <N> <datadir>"
  exit 1
fi

mkdir -p "$DATADIR"
if [[ "$(ls -A "$DATADIR")" ]]; then
  echo "error: $DATADIR is not empty"
  exit 1
fi

for i in $(seq 0 $((N-1))); do
  docker run \
    -d \
    --name node-$i \
    --hostname node-$i \
    -v "$DATADIR":/data \
    -e NODES="$N" \
    -e MESSAGES=10 \
    -e MSGRATE=1000 \
    -e MSGSIZE=100 \
    -e PUBLISHERS=4 \
    -e CONNECTTO=4 \
    --entrypoint /node/main \
    mixrunner
done