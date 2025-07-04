#!/bin/bash

set -e

if [ ! -e ".__norebuild" ]; then
  defines=$(cat <<EOF
#define U_DISABLE_RENAMING 1
EOF
)
  cat <(echo "$defines") common/unicode/uconfig.h > tmp.h
  mv tmp.h common/unicode/uconfig.h
  # We use this file to signal that we shouldn't rebuild. This file SHOULD NEVER
  # be deleted and uconfig.h SHOULD NEVER be modified unless they're both deleted
  # together. Modifying only one has risk of some weird strange errors.
  touch .__norebuild
fi
