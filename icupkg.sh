#!/bin/bash

set -e

icupkg=$1
is_big_endian=$2
data_file_path=$3
output=$4
args=("$@")
to_remove=("${args[@]:4}")

cp "$data_file_path" tmp.dat

if [ ! "${#to_remove[@]}" -eq 0 ]; then
  $icupkg "$data_file_path" --remove "${to_remove[*]}"
fi

# Convert to big endian if necessary
if [ "$is_big_endian" = "1" ]; then
  $icupkg "$data_file_path" "$output" --type b
else
  cp "$data_file_path" "$output"
fi

# Restore the original data file
mv tmp.dat "$data_file_path"
