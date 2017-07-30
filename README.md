# Vala Language Server


### Setup
```
$ meson build
$ ninja -C build
$ cd util
$ npm i
```

### Build JsonRpc valadocs
```
$ cd util
$ make jsonrpc_docs
```

### Workflow
1. `cd util`
2. Change code
3. `ninja -C ../build && make client`
4. go to 2
