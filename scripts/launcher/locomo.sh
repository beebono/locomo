#!/bin/sh
# Portable locomo launcher script

LOCOMO_DIR=$(cd "$(dirname "$0")" && pwd)
cd $LOCOMO_DIR

export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$LOCOMO_DIR/lib"
./locomo
