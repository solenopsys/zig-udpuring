#!/bin/bash

# This script launches 16 threads of hping3 with flood mode
# targeting localhost on port 8888 with UDP packets

# Function to run hping3 command
run_hping() {
    sudo hping3 --flood -i m999 --udp -p 8888 -d 1450 127.0.0.1
}

# Launch 16 threads in the background
echo "Starting 16 hping3 threads..."
for i in {1..8}; do
    echo "Launching thread $i"
    run_hping &
    # Store PID of the background process
    pids[$i]=$!
done

# Wait for user to press Ctrl+C
echo "All threads launched. Press Ctrl+C to stop..."
trap "echo 'Stopping all threads...'; kill ${pids[*]} 2>/dev/null; exit" INT
wait