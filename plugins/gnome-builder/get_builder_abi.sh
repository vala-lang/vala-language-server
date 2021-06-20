#!/bin/env sh

# usage: [gnome-builder location] [sed location]

$1 --version | $2 -nr '/GNOME Builder/ { s/GNOME Builder ([[:digit:]]+\.[[:digit:]]+).*$/\1/ p }'
