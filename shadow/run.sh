#!/bin/sh

if [ $# -ne 2 ]; then
    echo "Usage: $0 <runs> <nodes>"
    exit 1
fi

runs="$1"			#number of simulation runs
nodes="$2"			#number of nodes to simulate
shadow_file="shadow.yaml"	
sed -i '/environment:/q' "$shadow_file"
sed -E -i "s/\"PEERS\": \"[0-9]+\"/\"PEERS\": \"$nodes\"/" "$shadow_file"

counter=2
while [ $counter -le $nodes ]; do
  echo "  peer$counter: *client_host" >> "$shadow_file"
  counter=$((counter + 1))
done

rm -f shadowlog* latencies* stats* main && rm -rf shadow.data/
nim c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:release main 

for i in $(seq $runs); do
    echo "Running for turn "$i
    shadow shadow.yaml > shadowlog$i && 
        grep -rne 'milliseconds\|BW' shadow.data/ > latencies$i && 
        grep -rne 'statcounters:' shadow.data/ > stats$i
    rm -rf shadow.data/
done

for i in $(seq $runs); do
    echo "Summary for turn "$i
    awk -f summary_latency.awk latencies$i
    awk -f summary_shadowlog.awk shadowlog$i
    awk -f summary_dontwant.awk stats$i    
done
