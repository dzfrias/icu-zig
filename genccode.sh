#!/bin/bash

set -e

genccode=$1
input=$2
output=$3

$genccode "$input" -e icudt77
mv icudt77_dat.c "$output"
