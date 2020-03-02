# Vala Language Server [![Gitter](https://badges.gitter.im/vala-language-server/community.svg)](https://gitter.im/vala-language-server/community)

### Features
- [x] diagnostics
- [x] code completion
    - [x] basic (member access and scope-visible completion)
    - [ ] advanced (context-sensitive suggestions)
- [x] document symbol outline
- [x] goto definition
- [x] symbol references
- [x] goto implementation
- [x] signature help
    - active parameter support requires upstream changes in vala and is disabled by default. use `meson -Dactive_parameter=true` to enable. see [this MR](https://gitlab.gnome.org/GNOME/vala/-/merge_requests/95)
- [x] hover
- [x] symbol documentation
    - [x] basic (from comments)
    - [x] advanced (from GIR and VAPI files)
        - this feature is unstable and depends on changes to GirParser in uptream vala, therefore it's currently disabled by default. use `meson -Dparse_system_girs=true` to enable
- [x] search for symbols in workspace
- [x] highlight active symbol in document
- [ ] snippets
- [ ] code actions

#### build systems / environments:
- [x] meson
- [ ] cmake

### Dependencies
- `jsonrpc-glib-1.0`
- `libvala-0.48` or later
    - you MUST compile with vala master from commit `f8676a6584d5b67ac76e132061a9df5d92258b0f` or later

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

#### With VSCode
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

#### With GNOME Builder (experimental)
- In progress. See [this issue](https://github.com/benwaffle/vala-language-server/issues/12)
- if you really want to try it out:

1. open a Vala project in GNOME Builder
2. make sure Vala plugin is installed and enabled, and Vala Pack is disabled
3. open a file and run `kill <pidof vala-language-server>`. The server should restart and from then on you should be able to type and get diagnostics.

### libvala docs
https://benwaffle.github.io/vala-language-server/index.html
