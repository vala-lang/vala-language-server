# Vala Language Server

### Setup
```
$ meson build
$ ninja -C build
```

### Build JsonRpc valadocs
```
$ cd util
$ make jsonrpc_docs
```

### Workflow
- Clone this repoe: https://github.com/benwaffle/vala-code
- Check out the `vala-language-server` branch
- Run `npm install`
- open this folder in VS Code
- `git submodule update --init`
- cd to vala-language-server and checkout master
- compile the language server (see above)
- Hit F5 in VS Code to run a new instance with the VLS
