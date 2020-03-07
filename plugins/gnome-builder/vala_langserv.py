
#!/usr/bin/env python

#   vala_langserv.py
#
# Copyright 2016 Christian Hergert <chergert@redhat.com>
# Copyright 2020 Princeton Ferro <chergert@redhat.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""
This plugin provides integration with the Vala Language Server.
It builds off the generic language service components in libide
by bridging them to our supervised Vala Language Server.
"""

import gi
import os

from gi.repository import GLib
from gi.repository import Gio
from gi.repository import GObject
from gi.repository import Ide

DEV_MODE = False

class VlsService(Ide.Object):
    _client = None
    _has_started = False
    _supervisor = None
    _monitor = None

    @classmethod
    def from_context(klass, context):
        return context.ensure_child_typed(VlsService)

    @GObject.Property(type=Ide.LspClient)
    def client(self):
        return self._client

    @client.setter
    def client(self, value):
        self._client = value
        self.notify('client')

    def do_parent_set(self, parent):
        """
        After the context has been loaded, we want to watch the project
        meson.build for changes if we find one. That will allow us to
        restart the process as necessary to pick up changes.
        """
        if parent is None:
            return

        context = self.get_context()
        workdir = context.ref_workdir()
        meson_build = workdir.get_child('meson.build')

        if meson_build.query_exists():
            try:
                self._monitor = meson_build.monitor(0, None)
                self._monitor.set_rate_limit(5 * 1000) # 5 Seconds
                self._monitor.connect('changed', self._monitor_changed_cb)
            except Exception as ex:
                Ide.debug('Failed to monitor meson.build for changes:', repr(ex))

    def _monitor_changed_cb(self, monitor, file, other_file, event_type):
        """
        This method is called when meson.build has changed. We need to
        cancel any supervised process and force the language server to
        restart. Otherwise, we risk it not picking up necessary changes.
        """
        if self._supervisor is not None:
            subprocess = self._supervisor.get_subprocess()
            if subprocess is not None:
                subprocess.force_exit()

    def do_stop(self):
        """
        Stops the Vala Language Server upon request to shutdown the
        VlsService.
        """
        if self._monitor is not None:
            monitor, self._monitor = self._monitor, None
            if monitor is not None:
                monitor.cancel()

        if self._supervisor is not None:
            supervisor, self._supervisor = self._supervisor, None
            supervisor.stop()

    def _ensure_started(self):
        """
        Start the rust service which provides communication with the
        Vala Language Server. We supervise our own instance of the
        language server and restart it as necessary using the
        Ide.SubprocessSupervisor.

        Various extension points (diagnostics, symbol providers, etc) use
        the VlsService to access the rust components they need.
        """
        # To avoid starting the `vls` process unconditionally at startup,
        # we lazily start it when the first provider tries to bind a client
        # to its :client property.
        if not self._has_started:
            self._has_started = True

            # Setup a launcher to spawn the rust language server
            launcher = self._create_launcher()
            launcher.set_clear_env(False)
            sysroot = self._discover_sysroot()
            if sysroot:
                launcher.setenv("SYS_ROOT", sysroot, True)
                launcher.setenv("LD_LIBRARY_PATH", os.path.join(sysroot, "lib"), True)
            if DEV_MODE:
                launcher.setenv('G_MESSAGES_DEBUG', 'all', True)

            # Locate the directory of the project and run vls from there.
            workdir = self.get_context().ref_workdir()
            launcher.set_cwd(workdir.get_path())

            # If vls was installed with Cargo, try to discover that
            # to save the user having to update PATH.
#             path_to_vls = os.path.expanduser("~/.cargo/bin/vls")
#             if os.path.exists(path_to_vls):
#                 old_path = os.getenv('PATH')
#                 new_path = os.path.expanduser('~/.cargo/bin')
#                 if old_path is not None:
#                     new_path += os.path.pathsep + old_path
#                 launcher.setenv('PATH', new_path, True)
#             else:
#                 path_to_vls = "vls"
            path_to_vls = "vala-language-server"

            # Setup our Argv. We want to communicate over STDIN/STDOUT,
            # so it does not require any command line options.
            launcher.push_argv(path_to_vls)

            # Spawn our peer process and monitor it for
            # crashes. We may need to restart it occasionally.
            self._supervisor = Ide.SubprocessSupervisor()
            self._supervisor.connect('spawned', self._vls_spawned)
            self._supervisor.set_launcher(launcher)
            self._supervisor.start()

    def _vls_spawned(self, supervisor, subprocess):
        """
        This callback is executed when the `vls` process is spawned.
        We can use the stdin/stdout to create a channel for our
        LspClient.
        """
        stdin = subprocess.get_stdin_pipe()
        stdout = subprocess.get_stdout_pipe()
        io_stream = Gio.SimpleIOStream.new(stdout, stdin)

        if self._client:
            self._client.stop()
            self._client.destroy()

        self._client = Ide.LspClient.new(io_stream)
        self.append(self._client)
        self._client.add_language('vala')
        self._client.start()
        self.notify('client')

    def _create_launcher(self):
        """
        Creates a launcher to be used by the rust service. This needs
        to be run on the host because we do not currently bundle rust
        inside our flatpak.

        In the future, we might be able to rely on the runtime for
        the tooling. Maybe even the program if flatpak-builder has
        prebuilt our dependencies.
        """
        flags = Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE
        if not DEV_MODE:
            flags |= Gio.SubprocessFlags.STDERR_SILENCE
        launcher = Ide.SubprocessLauncher()
        launcher.set_flags(flags)
        launcher.set_cwd(GLib.get_home_dir())
        launcher.set_run_on_host(True)
        return launcher

    def _discover_sysroot(self):
        """
        The Vala Language Server needs to know where the sysroot is of
        the Vala installation we are using. This is simple enough to
        get, by using `rust --print sysroot` as the rust-language-server
        documentation suggests.
        """

        pass
#        for valac in ['valac', os.path.expanduser('~/.cargo/bin/valac')]:
#            try:
#                launcher = self._create_launcher()
#                launcher.push_args([valac, '--print', 'sysroot'])
#                subprocess = launcher.spawn()
#                _, stdout, _ = subprocess.communicate_utf8()
#                return stdout.strip()
#            except:
#                pass

    @classmethod
    def bind_client(klass, provider):
        """
        This helper tracks changes to our client as it might happen when
        our `vls` process has crashed.
        """
        context = provider.get_context()
        self = VlsService.from_context(context)
        self._ensure_started()
        self.bind_property('client', provider, 'client', GObject.BindingFlags.SYNC_CREATE)

class VlsDiagnosticProvider(Ide.LspDiagnosticProvider):
    def do_load(self):
        VlsService.bind_client(self)

class VlsCompletionProvider(Ide.LspCompletionProvider):
    def do_load(self, context):
        VlsService.bind_client(self)

    def do_get_priority(self, context):
        # This provider only activates when it is very likely that we
        # want the results. So use high priority (negative is better).
        return -1000

class VlsRenameProvider(Ide.LspRenameProvider):
    def do_load(self):
        VlsService.bind_client(self)

class VlsSymbolResolver(Ide.LspSymbolResolver):
    def do_load(self):
        VlsService.bind_client(self)

class VlsHighlighter(Ide.LspHighlighter):
    def do_load(self):
        VlsService.bind_client(self)

class VlsFormatter(Ide.LspFormatter):
    def do_load(self):
        VlsService.bind_client(self)

class VlsHoverProvider(Ide.LspHoverProvider):
    def do_prepare(self):
        self.props.category = 'Vala'
        self.props.priority = 200
        VlsService.bind_client(self)

