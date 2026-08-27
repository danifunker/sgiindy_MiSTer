#!/bin/sh
# Convenience wrapper: rebuild and run.
set -e
make "$@"
exec ./obj_dir/Vemu
