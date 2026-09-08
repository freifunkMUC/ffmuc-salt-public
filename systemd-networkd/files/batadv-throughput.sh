#!/bin/bash

for i in $(ip -br a | awk '/vx-/ {print $1}'); do
    logger -t batadv-override "Set throughput_override on $i"
    batctl hardif "$i" throughput_override 1000000
done
