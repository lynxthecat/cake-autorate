#!/usr/bin/awk -f

# Set defaults for the record set
BEGIN {
    RS = "len=[0-9]+ "
    FS = " "
    # Set an arbitrary high MIN value to compare against
    min_uplink_time = min_downlink_time = 999
}

# This is to skip the "header" line from hping3 output. This replaces the previous 'tail -n+2' pipe.
NR == 1 { next }

# Main loop to iterate over each record in the record set
{
    # RTT
    rtt = $5
    sub(/rtt=/, "", rtt) # Remove 'rtt=' from field

    # Originate
    orig = $9
    sub(/Originate=/, "", orig) # Remove 'Originate=' from field

    # Receive
    rx = $10
    sub(/Receive=/, "", rx) # Remove 'Receive=' from field

    # Transmit
    tx = $11
    sub(/Transmit=/, "", tx) # Remove 'Transmit=' from field

    # Calculate uplink and downlink times
    uplink_time = rx - orig
    downlink_time = orig + rtt - tx

    # Evaluate if new MINs have been achieved
    min_uplink_time = uplink_time < min_uplink_time ? uplink_time : min_uplink_time
    min_downlink_time = downlink_time < min_downlink_time ? downlink_time : min_downlink_time

    # Uncomment to get full hping3 output...
    # print $0

    # Uncomment to see record-by-record uplink and downlink timings...
    # print uplink_time, downlink_time, min_uplink_time, min_downlink_time
}

# Final actions once record set has been iterated
END {
    print min_uplink_time, min_downlink_time
}
