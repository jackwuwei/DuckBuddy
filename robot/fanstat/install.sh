#!/bin/sh
# Run on the robot as root, from this directory:  sudo sh install.sh
set -eu
cd "$(dirname "$0")"
install -m 0755 duck-fanstat /usr/local/bin/duck-fanstat
install -m 0644 duck-fanstat.service /etc/systemd/system/duck-fanstat.service
systemctl daemon-reload
systemctl enable --now duck-fanstat.service
sleep 1
systemctl is-active duck-fanstat.service
python3 -I /usr/local/bin/duck-fanstat --once
