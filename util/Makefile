jsonrpc_docs:
	-rm -rf docs
	valadoc -o docs ../build/subprojects/jsonrpc-glib/src/jsonrpc-glib-1.0.vapi --importdir ../build/subprojects/jsonrpc-glib/src --import Jsonrpc-1.0 --pkg gio-2.0
	xdg-open docs/index.html

client:
	node_modules/.bin/ts-node client.ts
