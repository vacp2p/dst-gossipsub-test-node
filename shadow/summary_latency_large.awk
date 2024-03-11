# we parse the latencies(x) file produced by run.sh to receive results summary (Max/Avg Latency --> per packet, overall)
# runs $awk -f result_summary.awk latencies(x)

BEGIN {
	FS = " ";		#default column separator
	network_size = 0
	max_nw_lat = sum_nw_lat = sum_max_delays = 0
	hop_lat = 100	#should be consistent with shadow.yaml
}

{
	clean_int = $3
	gsub(/[^0-9]/, "", clean_int); 
	if ($3 == clean_int){	#get rid of unwanted rows
		sum_nw_lat += $NF 
		if (max_nw_lat < $NF) {max_nw_lat = $NF} 
		if (split($1, arr, "peer|/main|:.*:")) {
				#$3 = rx_latency,	arr[4] = publish_time,	arr[2] = peerID
				
				#We compute network-wide dissemination latency for each message
				if (max_msg_latency[arr[4]] < $NF) {max_msg_latency[arr[4]] = $NF}
				
				#we round to values to nearest hop_lat to estimate hop coverage
				rounded_RxTime = (int($3/hop_lat + 0.5)) * hop_lat
				lat_arr[arr[4], rounded_RxTime]++;	
				msg_arr[arr[4]] = 1;	#we maintain set of messages identified by their publish time
				if (network_size < arr[2]) {network_size = arr[2]}
		}
	}
}

END {

	print "Total Nodes : ", network_size, "Total Messages Published : ", length(msg_arr), 
            "Network Latency\t MAX : ", max_nw_lat, "\tAverage : ", sum_nw_lat/NR
	print "   Message ID \t       Avg Latency \t Messages Received"
	for (value in msg_arr) {
		sum_rx_msgs = 0;
        latency = 0;
		spread[1] = spread[2] = spread[3] = spread[4] = spread[5] = spread[6] = spread[7] = spread[8] = spread[9] = 0 
		spread[10] = spread[11] = spread[12] = spread[13] = spread[14] = spread[15] = spread[16] = spread[17] = spread[18] = 0
		for (key in lat_arr) {
			split(key, parts, SUBSEP);
			if (parts[1] == value) {
				#parts[2] recv time
				#10% 20% 30%....90% under parts[2]
				sum_rx_msgs = sum_rx_msgs + lat_arr[key]; 					#total receives / message
				latency = latency + (lat_arr[key] * parts[2]) 
				spread[ int((parts[2]) / hop_lat) ] = lat_arr[key]           #hop-by-hop spread count of messages
	    	}
	    }

		print value, "\t", latency/sum_rx_msgs, "\t  ", sum_rx_msgs, "spread is", 
                spread[1], spread[2], spread[3], spread[4], spread[5], spread[6], spread[7], spread[8], spread[9], 
		spread[10], spread[11], spread[12], spread[13], spread[14], spread[15], spread[16], spread[17], spread[18],
		spread[19], spread[20], spread[21], spread[22], spread[23], spread[24], spread[25], spread[26], spread[27],
		spread[28], spread[29], spread[30], spread[31], spread[32], spread[33], spread[34], spread[35], spread[36],
		spread[37], spread[38], spread[39], spread[40], spread[41], spread[42], spread[43], spread[44], spread[45],
		spread[46], spread[47], spread[48], spread[49], spread[50], spread[51], spread[52], spread[53], spread[54]		   
        	delete spread
    	}
    	
    	for (delay_val in max_msg_latency) {
    		print "MAX delay for ", delay_val, "is \t", max_msg_latency[delay_val]
    		sum_max_delays = sum_max_delays + max_msg_latency[delay_val]
    	}
    	
    	print "Total Messages Published : ", length(max_msg_latency), "Average Max Message Dissemination Latency : ", sum_max_delays/length(max_msg_latency) 
    
    
}


