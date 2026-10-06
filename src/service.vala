namespace Singularity.Apps.Translate {

    [DBus (name = "dev.sinty.TranslateService")]
    public class TranslateService : Object {
        private Config config;

        [DBus (visible = false)]
        public signal void used ();

        public TranslateService (Config config) {
            this.config = config;
        }

        public async void translate (string text, string source, string target, out string translation, out string detected, out string provider) throws Error {
            used ();
            translation = "";
            detected = "";
            provider = "";
            if (text.strip () == "") return;
            string from = source.strip () != "" ? source.strip () : "auto";
            string to = target.strip () != "" ? target.strip () : config.target;
            if (from == to) {
                translation = text;
                detected = from;
                return;
            }
            var backend = Backend.create (config.backend);
            backend.instance = config.instance_for (backend.id);
            if (backend.id == "libretranslate") backend.api_key = yield Keys.lookup (backend.instance);
            int limit = backend.char_limit;
            if (limit > 0 && text.char_count () > limit) {
                throw new TranslateError.TOO_LONG (_("%s accepts up to %d characters at a time.").printf (backend.title, limit));
            }
            Translation? result = null;
            try {
                result = yield backend.translate (text, from, to, null);
                provider = backend.service_name;
            } catch (Error e) {
                bool retry = config.fallback && backend.id != "mymemory" && text.char_count () <= 500
                    && (e is TranslateError.UNREACHABLE || e is TranslateError.RATE_LIMITED || e is TranslateError.AUTH);
                if (!retry) throw e;
                result = yield new MyMemoryBackend ().translate (text, from, to, null);
                provider = "MyMemory";
            }
            translation = result.text;
            detected = result.detected != "" ? result.detected : from;
        }

        public string[] languages () throws Error {
            used ();
            string[] codes = {};
            foreach (var l in Languages.builtin ()) codes += l.code;
            return codes;
        }

        public HashTable<string, string> language_names () throws Error {
            used ();
            var names = new HashTable<string, string> (str_hash, str_equal);
            foreach (var l in Languages.builtin ()) names[l.code] = l.name;
            return names;
        }

        public string default_target () throws Error {
            used ();
            return config.target;
        }
    }

    public class ServiceMain : Object {
        private const uint IDLE_SECONDS = 120;
        private static MainLoop loop;
        private static uint idle_id;

        private static void touch () {
            if (idle_id != 0) Source.remove (idle_id);
            idle_id = Timeout.add_seconds (IDLE_SECONDS, () => {
                idle_id = 0;
                loop.quit ();
                return Source.REMOVE;
            });
        }

        public static int main (string[] args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            Intl.bindtextdomain ("singularity-translate", Path.build_filename (Path.get_dirname (Path.get_dirname (args[0])), "share", "locale"));
            Intl.bind_textdomain_codeset ("singularity-translate", "UTF-8");
            Intl.textdomain ("singularity-translate");
            loop = new MainLoop ();
            var service = new TranslateService (new Config ());
            service.used.connect (touch);
            int status = 0;
            Bus.own_name (BusType.SESSION, "dev.sinty.TranslateService", BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        conn.register_object ("/dev/sinty/TranslateService", service);
                    } catch (IOError e) {
                        warning ("translate-service: %s", e.message);
                        status = 1;
                        loop.quit ();
                    }
                },
                () => touch (),
                () => {
                    status = 1;
                    loop.quit ();
                });
            loop.run ();
            return status;
        }
    }
}
