BEGIN {
	FS = " ";			#column separator
	fg_index = 7		#flags start index in $10
	flag_size  = 12		#size of flags
	local_in   = 0		#inbound-localhost-counters
	local_out  = 1		#outbound-localhost-counters
	remote_in  = 2		#inbound-remote-counters
	remote_out = 3		#outbound-remote-counters
}

{
    if ($9 == "[node]") {    
        #$5: peer info,      $10: traffic stats, we need to split
        peerlist[$5] = 1     #list for all peers

        if (split($10, arr, ",|;")) {
        #arr[2]: received bytes,    arr[3]: transferred bytes    
            if (arr[2] > 0) {sum_rx[$5] += arr[2]} #bytes received
            if (arr[3] > 0) {sum_tx[$5] += arr[3]} #bytes transferred

            #inbound-localhost-counters
            idx = fg_index + (flag_size * local_in)
            #if (arr[idx] > 0) {
                local_in_pkt[$5]				+= arr[idx]
                local_in_bytes[$5]				+= arr[idx+1]
                local_in_ctrl_pkt[$5]			+= arr[idx+2]
                local_in_ctrl_hdr_bytes[$5]	    += arr[idx+3]
                local_in_data_pkt[$5]			+= arr[idx+6]
                local_in_data_hdr_bytes[$5]	    += arr[idx+7]
                local_in_data_bytes[$5]		    += arr[idx+8]
            #}
            #outbound-localhost-counters
            idx = fg_index + (flag_size * local_out)
            #if (arr[idx] > 0) {
                local_out_pkt[$5]				+= arr[idx]
                local_out_bytes[$5]				+= arr[idx+1]
                local_out_ctrl_pkt[$5]			+= arr[idx+2]
                local_out_ctrl_hdr_bytes[$5]	+= arr[idx+3]
                local_out_data_pkt[$5]			+= arr[idx+6]
                local_out_data_hdr_bytes[$5]	+= arr[idx+7]
                local_out_data_bytes[$5]		+= arr[idx+8]
            #}
            #inbound-remote-counters
            idx = fg_index + (flag_size * remote_in)
            #if (arr[idx] > 0) {
                remote_in_pkt[$5]				+= arr[idx]
                remote_in_bytes[$5]				+= arr[idx+1]
                remote_in_ctrl_pkt[$5]			+= arr[idx+2]
                remote_in_ctrl_hdr_bytes[$5]	+= arr[idx+3]
                remote_in_data_pkt[$5]			+= arr[idx+6]
                remote_in_data_hdr_bytes[$5]	+= arr[idx+7]
                remote_in_data_bytes[$5]		+= arr[idx+8]
            #}
            #outbound-remote-counters
            idx = fg_index + (flag_size * remote_out)
            #if (arr[idx] > 0) {
                remote_out_pkt[$5]				+= arr[idx]
                remote_out_bytes[$5]			+= arr[idx+1]
                remote_out_ctrl_pkt[$5]			+= arr[idx+2]
                remote_out_ctrl_hdr_bytes[$5]	+= arr[idx+3]
                remote_out_data_pkt[$5]			+= arr[idx+6]
                remote_out_data_hdr_bytes[$5]	+= arr[idx+7]
                remote_out_data_bytes[$5]		+= arr[idx+8]
            #}

        }		
    } 
}

END {
        nw_size = length(peerlist)
        min_in  = max_in = min_out = max_out = sum_in = sum_out = avg_in = avg_out = 0
        for (value in peerlist) {               #node specific tx/rx stats (bytes)
            sum_in  += sum_rx[value]
            sum_out += sum_tx[value]

            if (sum_rx[value] < min_in  || min_in == 0)  min_in  = sum_rx[value]
            if (sum_tx[value] < min_out || min_out == 0) min_out = sum_tx[value] 
            if (sum_rx[value] > max_in)  max_in  = sum_rx[value]
            if (sum_tx[value] > max_out) max_out = sum_tx[value] 
        }
        avg_in  = sum_in/nw_size
        avg_out = sum_out/nw_size



        for (value in peerlist) {

            sum_sq_in  += (sum_rx[value] - avg_in) ^ 2      #for stddev
            sum_sq_out += (sum_tx[value] - avg_out) ^ 2

                sum_local_in_pkt               += local_in_pkt[value]
                sum_local_in_bytes             += local_in_bytes[value]
                sum_local_in_ctrl_pkt          += local_in_ctrl_pkt[value]
                sum_local_in_ctrl_hdr_bytes    += local_in_ctrl_hdr_bytes[value]
                sum_local_in_data_pkt          += local_in_data_pkt[value]
                sum_local_in_data_hdr_bytes    += local_in_data_hdr_bytes[value]
                sum_local_in_data_bytes        += local_in_data_bytes[value]

                sum_local_out_pkt               += local_out_pkt[value]
                sum_local_out_bytes             += local_out_bytes[value]
                sum_local_out_ctrl_pkt          += local_out_ctrl_pkt[value]
                sum_local_out_ctrl_hdr_bytes    += local_out_ctrl_hdr_bytes[value]
                sum_local_out_data_pkt          += local_out_data_pkt[value]
                sum_local_out_data_hdr_bytes    += local_out_data_hdr_bytes[value]
                sum_local_out_data_bytes        += local_out_data_bytes[value]

                sum_remote_in_pkt               += remote_in_pkt[value]
                sum_romote_in_bytes             += remote_in_bytes[value]
                sum_remote_in_ctrl_pkt          += remote_in_ctrl_pkt[value]
                sum_remote_in_ctrl_hdr_bytes    += remote_in_ctrl_hdr_bytes[value]
                sum_remote_in_data_pkt          += remote_in_data_pkt[value]
                sum_remote_in_data_hdr_bytes    += remote_in_data_hdr_bytes[value]
                sum_remote_in_data_bytes        +=remote_in_data_bytes[value]

                sum_remote_out_pkt              +=remote_out_pkt[value]
                sum_remote_out_bytes            +=remote_out_bytes[value]
                sum_remote_out_ctrl_pkt         +=remote_out_ctrl_pkt[value]
                sum_remote_out_ctrl_hdr_bytes   +=remote_out_ctrl_hdr_bytes[value] 
                sum_remote_out_data_pkt         +=remote_out_data_pkt[value]
                sum_remote_out_data_hdr_bytes   +=remote_out_data_hdr_bytes[value]
                sum_remote_out_data_bytes       +=remote_out_data_bytes[value]

            #}
        }

    print "\nTotal Bytes Received : ", sum_in, "Total Bytes Transferred : ", sum_out
    print "Per Node Pkt Receives : min, max, avg, stddev = ", min_in, max_in, avg_in, sqrt(sum_sq_in/nw_size)
    print "Per Node Pkt Transfers: min, max, avg, stddev = ", min_out, max_out, avg_out, sqrt(sum_sq_out/nw_size)    
    

    print "Details..."
    #print "Local IN pkt: ", sum_local_in_pkt, "Bytes : ", sum_local_in_bytes, "ctrlPkt: ", sum_local_in_ctrl_pkt, "ctrlHdrBytes: ", sum_local_in_ctrl_hdr_bytes, 
    #        "DataPkt: ", sum_local_in_data_pkt, "DataHdrBytes: ", sum_local_in_data_hdr_bytes, "DataBytes", sum_local_in_data_bytes
    #print "Local OUT pkt: ", sum_local_out_pkt, "Bytes : ", sum_local_out_bytes, "ctrlPkt: ", sum_local_out_ctrl_pkt, "ctrlHdrBytes: ", sum_local_out_ctrl_hdr_bytes, 
    #        "DataPkt: ", sum_local_out_data_pkt, "DataHdrBytes: ", sum_local_out_data_hdr_bytes, "DataBytes", sum_local_out_data_bytes
    print "Remote IN pkt: ", sum_remote_in_pkt, "Bytes : ", sum_romote_in_bytes, "ctrlPkt: ", sum_remote_in_ctrl_pkt, "ctrlHdrBytes: ", sum_remote_in_ctrl_hdr_bytes, 
            "DataPkt: ", sum_remote_in_data_pkt, "DataHdrBytes: ", sum_remote_in_data_hdr_bytes, "DataBytes", sum_remote_in_data_bytes
    print "Remote OUT pkt: ", sum_remote_out_pkt, "Bytes : ", sum_romote_out_bytes, "ctrlPkt: ", sum_remote_out_ctrl_pkt, "ctrlHdrBytes: ", sum_remote_out_ctrl_hdr_bytes, 
            "DataPkt: ", sum_remote_out_data_pkt, "DataHdrBytes: ", sum_remote_out_data_hdr_bytes, "DataBytes", sum_remote_out_data_bytes


}


