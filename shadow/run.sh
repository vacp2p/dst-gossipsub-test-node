#!/bin/sh
set -e

if [ $# -ne 11 ]; then
    echo "Usage: $0 <runs> <nodes> <Message_size> <num_fragment> <num_publishers>
            <min_bandwidth> <max_bandwidth> <min_latency> <max_latency> <anchor_stages <packet_loss>>"
    
    echo "The following sample command runs simulation 1 time, for a 1000 node network. Each published message size \
            is 15KB (no-fragmentation), peer bandwidth varies between 50-130 Mbps, Latency between 60-160ms, and \
            bandwidth,latency is roughly distributed in five different groups. \
            see the generated network_topology.gml and shadow.yaml for peers/edges details"   
    
    echo "$0 1 1000 15000 1 10 50 130 60 160 5 0.0" 
    exit 1
fi

runs="$1"			        #number of simulation runs
nodes="$2"			        #number of nodes to simulate
msg_size="$3"			    #message size to use (in bytes)
num_frag="$4"			    #number of fragments per message (1 for no fragmentation)
num_publishers="$5"         #number of publishers 
min_bandwidth="$6"
max_bandwidth="$7"
min_latency="$8"
max_latency="$9"
steps="${10}"
pkt_loss="${11}"

connect_to=5                #number of peers we connect with to form full message mesh


#topogen.py uses networkx module from python to generate gml and yaml files
PYTHON=$(which python3 || which python)

if [ -z "$PYTHON" ]; then
    echo "Error: Python, Networkx is required for topology files generation."
    exit 1
fi

"$PYTHON" topogen.py $nodes $min_bandwidth $max_bandwidth $min_latency $max_latency $steps $pkt_loss $msg_size $num_frag $num_publishers



rm -f shadowlog* latencies* stats* main && rm -rf shadow.data/
nim c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:release main 

for i in $(seq $runs); do
    echo "Running for turn "$i
    shadow shadow.yaml > shadowlog$i && 
        grep -rne 'milliseconds\|BW' shadow.data/ > latencies$i && 
        grep -rne 'statcounters:' shadow.data/ > stats$i
    #uncomment to to receive every nodes log in shadow data (only if runs == 1, or change data directory in yaml file)
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