#!/usr/bin/env python

# vala-langserv.py
#
# Copyright 2016 Christian Hergert <chergert@redhat.com>
# Copyright 2019 Princeton Ferro <princetonferro@gmail.com>
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

gi.require_version('Ide', '1.0')

from gi.repository import GLib
from gi.repository import Gio
from gi.repository import GObject
from gi.repository import Ide

DEV_MODE = False

class ValaService(Ide.Object, Ide.Service):
    _client = None
    _has_started = False
    _supervisor = None
    _monitor = None

    @GObject.Property(type=Ide.LangservClient)
    def client(self):
        return self._client

    @client.setter
    def client(self, value):
        self._client = value
        self.notify('client')

    def do_context_loaded(self):
        """
        After the context has been loaded, we want to watch the project
        Cargo.toml for changes if we find one. That will allow us to
        restart the process as necessary to pick up changes.
        """
        context = self.get_context()
        project_file = context.get_project_file()
        if project_file is not None:
            if project_file.get_basename() == 'Cargo.toml':
                try:
                    self._monitor = project_file.monitor(0, None)
                    self._monitor.set_rate_limit(5 * 1000) # 5 Seconds
                    self._monitor.connect('changed', self._monitor_changed_cb)
                except Exception as ex:
                    Ide.debug('Failed to monitor Cargo.toml for changes:', repr(ex))

    def _monitor_changed_cb(self, monitor, file, other_file, event_type):
        """
        This method is called when Cargo.toml has changed. We need to
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
        ValaService.
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
        Start the vala service which provides communication with the
        Vala Language Server. We supervise our own instance of the
        language server and restart it as necessary using the
        Ide.SubprocessSupervisor.

        Various extension points (diagnostics, symbol providers, etc) use
        the ValaService to access the vala components they need.
        """
        # To avoid starting the `rls` process unconditionally at startup,
        # we lazily start it when the first provider tries to bind a client
        # to its :client property.
        if not self._has_started:
            self._has_started = True

            # Setup a launcher to spawn the vala language server
            launcher = self._create_launcher()
            launcher.set_clear_env(False)
            # sysroot = self._discover_sysroot()
            # if sysroot:
            #     launcher.setenv("SYS_ROOT", sysroot, True)
            #     launcher.setenv("LD_LIBRARY_PATH", os.path.join(sysroot, "lib"), True)
            if DEV_MODE:
                launcher.setenv('G_MESSAGES_DEBUG', 'all', True)

            # Locate the directory of the project and run rls from there.
            workdir = self.get_context().get_vcs().get_working_directory()
            launcher.set_cwd(workdir.get_path())

            # If rls was installed with Cargo, try to discover that
            # to save the user having to update PATH.
            # path_to_rls = os.path.expanduser("~/.cargo/bin/rls")
            # if os.path.exists(path_to_rls):
            #     launcher.setenv('PATH', os.path.expanduser("~/.cargo/bin"), True)
            # else:
            path_to_rls = "vala-language-server"

            # Setup our Argv. We want to communicate over STDIN/STDOUT,
            # so it does not require any command line options.
            launcher.push_argv(path_to_rls)

            # Spawn our peer process and monitor it for
            # crashes. We may need to restart it occasionally.
            self._supervisor = Ide.SubprocessSupervisor()
            self._supervisor.connect('spawned', self._rls_spawned)
            self._supervisor.set_launcher(launcher)
            self._supervisor.start()

    def _rls_spawned(self, supervisor, subprocess):
        """
        This callback is executed when the `rls` process is spawned.
        We can use the stdin/stdout to create a channel for our
        LangservClient.
        """
        stdin = subprocess.get_stdin_pipe()
        stdout = subprocess.get_stdout_pipe()
        io_stream = Gio.SimpleIOStream.new(stdout, stdin)

        if self._client:
            self._client.stop()

        self._client = Ide.LangservClient.new(self.get_context(), io_stream)
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
        The Rust Language Server needs to know where the sysroot is of
        the Rust installation we are using. This is simple enough to
        get, by using `rust --print sysroot` as the rust-language-server
        documentation suggests.
        """
        for rustc in ['rustc', os.path.expanduser('~/.cargo/bin/rustc')]:
            try:
                launcher = self._create_launcher()
                launcher.push_args([rustc, '--print', 'sysroot'])
                subprocess = launcher.spawn()
                _, stdout, _ = subprocess.communicate_utf8()
                return stdout.strip()
            except:
                pass

    @classmethod
    def bind_client(klass, provider):
        """
        This helper tracks changes to our client as it might happen when
        our `rls` process has crashed.
        """
        context = provider.get_context()
        self = context.get_service_typed(ValaService)
        self._ensure_started()
        self.bind_property('client', provider, 'client', GObject.BindingFlags.SYNC_CREATE)

class ValaDiagnosticProvider(Ide.LangservDiagnosticProvider):
    def do_load(self):
        ValaService.bind_client(self)

class ValaCompletionProvider(Ide.LangservCompletionProvider):
    def do_load(self, context):
        ValaService.bind_client(self)

    def do_get_priority(self, context):
        # This provider only activates when it is very likely that we
        # want the results. So use high priority (negative is better).
        return -1000

class ValaRenameProvider(Ide.LangservRenameProvider):
    def do_load(self):
        ValaService.bind_client(self)

class ValaSymbolResolver(Ide.LangservSymbolResolver):
    def do_load(self):
        ValaService.bind_client(self)

class ValaHighlighter(Ide.LangservHighlighter):
    def do_load(self):
        ValaService.bind_client(self)

class ValaFormatter(Ide.LangservFormatter):
    def do_load(self):
        ValaService.bind_client(self)

class ValaHoverProvider(Ide.LangservHoverProvider):
    def do_prepare(self):
        self.props.category = 'Vala'
        self.props.priority = 200
        ValaService.bind_client(self)
