# Vala Language Server

### Dependencies
`jsonrpc-glib-1.0`

### Setup
```
$ meson build
$ ninja -C build
```

### libvala docs
https://benwaffle.github.io/vala-language-server/docs/index.htm

### Workflow
- Clone this repo: https://github.com/benwaffle/vala-code
- Check out the `language-server` branch
- Run `npm install`
- open this folder in VS Code
- `git submodule update --init`
- cd to vala-language-server and checkout master
- compile the language server (see above)
- Hit F5 in VS Code to run a new instance with the VLS
