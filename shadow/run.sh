#!/bin/sh

if [ $# -ne 4 ]; then
    echo "Usage: $0 <runs> <nodes> <Message_Size in bytes> <num_fragments:[1-10] use 1 for no fragmentation>"
    exit 1
fi

runs="$1"			    #number of simulation runs
nodes="$2"			    #number of nodes to simulate
msg_size="$3"			#message size to use (in bytes)
num_frag="$4"			#number of fragments per message (1 for no fragmentation)
connect_to=5
shadow_file="shadow.yaml"	

#we modify shadow.yaml for simulation environment
sed -i '/environment:/q' "$shadow_file"
sed -E -i "s/\"PEERS\": \"[0-9]+\".*}/\"PEERS\": \"$nodes\", \"CONNECTTO\": \"$connect_to\", \
\"MSG_SIZE\": \"$msg_size\", \"FRAGMENTS\": \"$num_frag\"}/" "$shadow_file"

#we modify shadow.yaml for the number of nodes
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
    #uncomment to to receive every nodes log in shadow data
    #rm -rf shadow.data/
done

for i in $(seq $runs); do
    echo "Summary for turn "$i
    if [ "$msg_size" -lt 1000 ]; then
    	awk -f summary_latency.awk latencies$i		#precise per hop coverage for short messages only
    else
	awk -f summary_latency_large.awk latencies$i	#estimated coverage for large messages (TxTime adds to latency)
    fi
    awk -f summary_shadowlog.awk shadowlog$i
    awk -f summary_dontwant.awk stats$i    
done
