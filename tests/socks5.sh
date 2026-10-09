#!/bin/bash

set -e

# The SOCKS5 client test requires a real SOCKS5 server to test against. It is
# installed by the CI workflow and is not available on all platforms.
if ! command -v microsocks >/dev/null 2>&1; then
	echo "SKIPPING SOCKS5 test (microsocks is not installed)"
	exit 0
fi

PROXY_PORT=1080
AUTH_PORT=1081
AUTH_USER=testuser
AUTH_PASS=testpass

PROXY_PID=
AUTH_PID=
cleanup() {
	[ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
	[ -n "$AUTH_PID" ] && kill "$AUTH_PID" 2>/dev/null
	return 0
}
trap cleanup EXIT

microsocks -p $PROXY_PORT &
PROXY_PID=$!
microsocks -p $AUTH_PORT -u $AUTH_USER -P $AUTH_PASS &
AUTH_PID=$!

# wait until a port accepts connections
wait_port() {
	for _ in {1..50}; do
		(echo > /dev/tcp/127.0.0.1/$1) 2>/dev/null && return 0
		sleep 0.1
	done
	return 1
}

if ! wait_port $PROXY_PORT; then
	echo "microsocks failed to start on port $PROXY_PORT" >&2
	exit 1
fi
if ! wait_port $AUTH_PORT; then
	echo "microsocks failed to start on port $AUTH_PORT" >&2
	exit 1
fi

echo "Running SOCKS5 test against microsocks (ports $PROXY_PORT and $AUTH_PORT)"

SOCKS5_PROXY_HOST=127.0.0.1 \
SOCKS5_PROXY_PORT=$PROXY_PORT \
SOCKS5_AUTH_HOST=127.0.0.1 \
SOCKS5_AUTH_PORT=$AUTH_PORT \
SOCKS5_USER="$AUTH_USER" \
SOCKS5_PASS="$AUTH_PASS" \
	dub --temp-build ${DC:+--compiler=$DC} --single socks5.d

echo "OK"
