# Vala Language Server

### Dependencies
- `jsonrpc-glib-1.0`
- `libvala-dev`

### Setup
```
$ meson build
$ ninja -C build
```

#### With Vim
Once you have VLS installed, you can use it with `vim`.

1. Make sure [vim-lsp](https://github.com/prabirshrestha/vim-lsp) is installed
2. Add the following to your `.vimrc`:

```vim
if executable('vala-language-server')                     
  au User lsp_setup call lsp#register_server({              
        \ 'name': 'vala-language-server',
        \ 'cmd': {server_info->[&shell, &shellcmdflag, 'vala-language-server']}, 
        \ 'whitelist': ['vala'],
        \ })
endif
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
