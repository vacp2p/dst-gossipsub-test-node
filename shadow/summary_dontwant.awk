BEGIN {
	FS = " ";		#default column separator
	idontwant_saves = min_idontwant = max_idontwant = 0;
    dup_received = min_dup = max_dup = 0;
    unique_msg_received        = 0;
    stagger_saves           = 0;
    stagger_DontWantSaves   = 0;
}

{
	#print $5, $7, $9
    idontwant_saves += $5
    if ($5 < min_idontwant || min_idontwant == 0)  min_idontwant  = $5
    if ($5 > max_idontwant) max_idontwant = $5

    dup_received += $7
    if ($7 < min_dup || min_dup == 0)  min_dup  = $7
    if ($7 > max_dup) max_dup = $7

    unique_msg_received     += $9
    stagger_saves           += $11
    stagger_DontWantSaves   += $13

}

END {
    print "idontwant_saves min, max, avg, total : ", min_idontwant, "\t", max_idontwant, "\t", idontwant_saves/NR, "\t", idontwant_saves 
    print "dup_received    min, max, avg, total : ", min_dup, "\t", max_dup, "\t", dup_received/NR, "\t", dup_received
    print "Unique_msg_received: ", unique_msg_received, "\tStagger Saves : ", stagger_saves, "\tStaggerDontWantSaves", stagger_DontWantSaves
}
