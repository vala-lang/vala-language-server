# Vala Language Server

### Dependencies
`jsonrpc-glib-1.0`

### Setup
```
$ meson build
$ ninja -C build
```

### libvala docs
https://benwaffle.github.io/vala-language-server/index.html

### Workflow
- Clone this repo: https://github.com/benwaffle/vala-code
- Check out the `language-server` branch
- Run `npm install`
- open this folder in VS Code
- `git submodule update --init`
- `cd vala-lanugage-server`
- `git checkout master`
- `meson build`
- `ninja -C build`
- Hit F5 in VS Code to run a new instance with the VLS
