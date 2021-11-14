sudo add-apt-repository ppa:vala-team
sudo apt-get update
sudo apt-get install python3-setuptools valac libvala-0.48-dev libgee-0.8-dev libjsonrpc-glib-1.0-dev gobject-introspection libgirepository1.0-dev ninja-build
sudo pip3 install meson
meson build
ninja -C build