using Gtk;

namespace Singularity.Apps.Translate {

    public class TranslateApp : Singularity.Application {
        public Config config;
        public History history;
        public Phrasebook phrasebook;
        private bool quick_pending;
        private TranslateSearch search;

        public TranslateApp () {
            Object (application_id: "dev.sinty.translate", flags: ApplicationFlags.DEFAULT_FLAGS);
            add_main_option ("translate-clipboard", 0, OptionFlags.NONE, OptionArg.NONE, _("Translate the text in the clipboard in a small window"), null);
            search = new TranslateSearch (this);
            search.export (this);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("translate-clipboard")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("translate: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("translate-clipboard", null);
                return 0;
            }
            quick_pending = true;
            return -1;
        }

        private uint translate_bus_id = 0;

        public override bool dbus_register (DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register (connection, object_path)) return false;
            translate_bus_id = connection.register_object ("/dev/sinty/translate/Translate", new TranslateBus (this));
            return true;
        }

        public override void dbus_unregister (DBusConnection connection, string object_path) {
            if (translate_bus_id != 0) connection.unregister_object (translate_bus_id);
            translate_bus_id = 0;
            base.dbus_unregister (connection, object_path);
        }

        protected override void startup () {
            base.startup ();
            config = new Config ();
            history = new History ();
            phrasebook = new Phrasebook ();
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("New Translation"), "win.new");
            f1.append (_("Translate File…"), "win.translate-file");
            f1.append (_("Export Phrasebook…"), "win.export-phrasebook");
            f1.append (_("Set API Key…"), "win.api-key");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Close Window"), "win.close");
            f2.append (_("Quit"), "app.quit");
            file.append_section (null, f2);
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Translate"), "win.translate");
            e1.append (_("Copy Translation"), "win.copy-translation");
            e1.append (_("Add to Phrasebook"), "win.star");
            e1.append (_("Translate Clipboard"), "app.translate-clipboard");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Swap Languages"), "win.swap");
            e2.append (_("Translate From…"), "win.pick-source");
            e2.append (_("Translate To…"), "win.pick-target");
            edit.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Find in Phrasebook"), "win.find");
            edit.append_section (null, e3);
            var e4 = new GLib.Menu ();
            e4.append (_("Settings"), "app.settings");
            edit.append_section (null, e4);
            menu.append_submenu (_("Edit"), edit);
            var view = new GLib.Menu ();
            view.append (_("Phrasebook"), "win.phrasebook");
            view.append (_("History"), "win.history");
            view.append (_("Clear History"), "win.clear-history");
            view.append (_("Listen to Translation"), "win.listen");
            menu.append_submenu (_("View"), view);
            set_menubar (menu);
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.translate");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var clipboard_action = new SimpleAction ("translate-clipboard", null);
            clipboard_action.activate.connect (() => quick_translate ());
            add_action (clipboard_action);
            var files_action = new SimpleAction ("translate-files", new VariantType ("as"));
            files_action.activate.connect ((param) => {
                string[] uris = param.get_strv ();
                if (uris.length == 0) return;
                var w = main_window ();
                var doc = File.new_for_uri (uris[0]);
                if (w.get_mapped ()) {
                    w.present ();
                    w.open_document (doc);
                    return;
                }
                ulong handler = 0;
                handler = w.map.connect (() => {
                    w.disconnect (handler);
                    Idle.add (() => {
                        w.open_document (doc);
                        return Source.REMOVE;
                    });
                });
                w.present ();
            });
            add_action (files_action);
            var text_action = new SimpleAction ("show-text", new VariantType ("(ssss)"));
            text_action.activate.connect ((param) => {
                string text, translation, source, target;
                param.get ("(ssss)", out text, out translation, out source, out target);
                show_in_window (text, translation, source, target != "" ? target : config.target);
            });
            add_action (text_action);
            var translate_text = new SimpleAction ("translate-text", VariantType.STRING);
            translate_text.activate.connect ((param) => show_in_window (param.get_string (), "", "auto", config.target));
            add_action (translate_text);
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("win.new", { "<Control>n" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.translate", { "<Control>Return" });
            set_accels_for_action ("win.copy-translation", { "<Control><Shift>c" });
            set_accels_for_action ("win.swap", { "<Control><Shift>s" });
            set_accels_for_action ("win.pick-source", { "<Control>l" });
            set_accels_for_action ("win.pick-target", { "<Control><Shift>l" });
            set_accels_for_action ("win.history", { "<Control>h" });
            set_accels_for_action ("win.listen", { "<Control>k" });
            set_accels_for_action ("win.star", { "<Control>d" });
            set_accels_for_action ("win.phrasebook", { "<Control>b" });
            set_accels_for_action ("win.export-phrasebook", { "<Control><Shift>e" });
            set_accels_for_action ("win.translate-file", { "<Control>o" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("app.translate-clipboard", { "<Control><Shift>t" });
        }

        public override void activate () {
            if (quick_pending) {
                quick_pending = false;
                quick_translate ();
                return;
            }
            main_window ().present ();
        }

        private TranslateWindow main_window () {
            foreach (var w in get_windows ()) {
                if (w is TranslateWindow) return (TranslateWindow) w;
            }
            return new TranslateWindow (this);
        }

        public void quick_translate () {
            foreach (var w in get_windows ()) {
                if (w is QuickTranslateDialog) w.close ();
            }
            var dlg = new QuickTranslateDialog (this);
            dlg.present ();
        }

        public void show_in_window (string text, string translation, string source, string target) {
            var w = main_window ();
            w.present ();
            w.show_text (text, translation, source, target);
        }

        private const string CSS = """
.translate-pane {
    border-radius: 18px;
    background-color: alpha(@window_fg_color, 0.04);
    border: 1px solid alpha(@window_fg_color, 0.06);
}

.translate-result {
    background-color: alpha(@accent_bg_color, 0.07);
}

.translate-pane-header {
    padding: 8px 8px 0 8px;
}

.translate-language {
    font-weight: 700;
    border-radius: 12px;
    padding: 4px 10px;
}

.translate-pane-footer {
    padding: 4px 8px 8px 16px;
    min-height: 36px;
}

.translate-text,
.translate-text text {
    background: transparent;
    font-size: 17px;
}

.translate-placeholder {
    font-size: 17px;
}

.translate-languages contents {
    padding: 0;
}

.translate-quick-result {
    font-size: 17px;
}

.translate-file-preview {
    border-radius: 12px;
}

.translate-file-preview,
.translate-file-preview text {
    background-color: alpha(@window_fg_color, 0.04);
}

.translate-toast {
    padding: 8px 16px;
    border-radius: 18px;
    background-color: alpha(black, 0.7);
    color: white;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-translate", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-translate", "UTF-8");
        Intl.textdomain ("singularity-translate");
        return new TranslateApp ().run (args);
    }
}
