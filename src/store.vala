namespace Singularity.Apps.Translate {

    public class Config : Object {
        public GLib.Settings settings { get; private set; }

        public string backend {
            owned get { return settings.get_string ("backend"); }
            set { settings.set_string ("backend", value == "lingva" || value == "mymemory" ? value : "libretranslate"); }
        }

        public string libre_instance {
            owned get {
                string s = Http.normalize_instance (settings.get_string ("libre-instance"));
                return s != "" ? s : LibreTranslateBackend.DEFAULT_INSTANCE;
            }
            set { settings.set_string ("libre-instance", value); }
        }

        public string lingva_instance {
            owned get {
                string s = Http.normalize_instance (settings.get_string ("lingva-instance"));
                return s != "" ? s : LingvaBackend.DEFAULT_INSTANCE;
            }
            set { settings.set_string ("lingva-instance", value); }
        }

        public string source {
            owned get { return settings.get_string ("source"); }
            set { settings.set_string ("source", value); }
        }

        public string target {
            owned get {
                string t = settings.get_string ("target");
                if (t != "") return t;
                return Languages.system_language () == "en" ? "es" : Languages.system_language ();
            }
            set { settings.set_string ("target", value); }
        }

        public bool fallback {
            get { return settings.get_boolean ("fallback"); }
            set { settings.set_boolean ("fallback", value); }
        }

        public bool live {
            get { return settings.get_boolean ("live"); }
            set { settings.set_boolean ("live", value); }
        }

        public bool keep_history {
            get { return settings.get_boolean ("keep-history"); }
            set { settings.set_boolean ("keep-history", value); }
        }

        public Config (string? legacy_file = null) {
            settings = new GLib.Settings ("dev.sinty.translate");
            migrate (legacy_file ?? Path.build_filename (Environment.get_user_config_dir (), "singularity", "translate.json"));
        }

        public string instance_for (string id) {
            if (id == "lingva") return lingva_instance;
            if (id == "libretranslate") return libre_instance;
            return "";
        }

        private void migrate (string path) {
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                    var o = root.get_object ();
                    backend = o.get_string_member_with_default ("backend", "libretranslate");
                    libre_instance = o.get_string_member_with_default ("libre_instance", LibreTranslateBackend.DEFAULT_INSTANCE);
                    lingva_instance = o.get_string_member_with_default ("lingva_instance", LingvaBackend.DEFAULT_INSTANCE);
                    source = o.get_string_member_with_default ("source", "auto");
                    target = o.get_string_member_with_default ("target", "");
                    fallback = o.get_boolean_member_with_default ("fallback", true);
                    live = o.get_boolean_member_with_default ("live", true);
                    keep_history = o.get_boolean_member_with_default ("keep_history", true);
                    GLib.Settings.sync ();
                }
                FileUtils.rename (path, path + ".migrated");
            } catch (Error e) {
                warning ("translate: %s", e.message);
            }
        }
    }

    public class HistoryEntry : Object {
        public string source = "";
        public string target = "";
        public string text = "";
        public string translation = "";
        public int64 time;

        public bool same_as (HistoryEntry other) {
            return source == other.source && target == other.target && text == other.text;
        }
    }

    public class History : Object {
        public const int MAX = 50;
        public Gee.ArrayList<HistoryEntry> items = new Gee.ArrayList<HistoryEntry> ();
        private string path;
        public signal void changed ();

        public History (string? file = null) {
            path = file ?? Path.build_filename (Environment.get_user_data_dir (), "singularity-translate", "history.json");
            load ();
        }

        private void load () {
            items.clear ();
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
                foreach (var node in root.get_array ().get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var o = node.get_object ();
                    var e = new HistoryEntry ();
                    e.source = o.get_string_member_with_default ("source", "auto");
                    e.target = o.get_string_member_with_default ("target", "");
                    e.text = o.get_string_member_with_default ("text", "");
                    e.translation = o.get_string_member_with_default ("translation", "");
                    e.time = o.get_int_member_with_default ("time", 0);
                    if (e.text != "" && e.target != "" && items.size < MAX) items.add (e);
                }
            } catch (Error e) {
                warning ("translate: %s", e.message);
            }
        }

        private void save () {
            var arr = new Json.Array ();
            foreach (var e in items) {
                var o = new Json.Object ();
                o.set_string_member ("source", e.source);
                o.set_string_member ("target", e.target);
                o.set_string_member ("text", e.text);
                o.set_string_member ("translation", e.translation);
                o.set_int_member ("time", e.time);
                arr.add_object_element (o);
            }
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (arr);
            var gen = new Json.Generator ();
            gen.pretty = true;
            gen.set_root (root);
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents (path, gen.to_data (null));
                FileUtils.chmod (path, 0600);
            } catch (Error e) {
                warning ("translate: %s", e.message);
            }
            changed ();
        }

        public void add (HistoryEntry entry) {
            if (entry.text.strip () == "" || entry.translation.strip () == "") return;
            for (int i = 0; i < items.size; i++) {
                if (items[i].same_as (entry)) {
                    items.remove_at (i);
                    break;
                }
            }
            if (items.size > 0) {
                var top = items[0];
                if (top.source == entry.source && top.target == entry.target && entry.text.has_prefix (top.text) && entry.time - top.time < 120) {
                    items.remove_at (0);
                }
            }
            items.insert (0, entry);
            while (items.size > MAX) items.remove_at (items.size - 1);
            save ();
        }

        public void remove (HistoryEntry entry) {
            items.remove (entry);
            save ();
        }

        public void clear () {
            items.clear ();
            save ();
        }
    }

    public class Phrasebook : Object {
        public Gee.ArrayList<HistoryEntry> items = new Gee.ArrayList<HistoryEntry> ();
        private string path;
        public signal void changed ();

        public Phrasebook (string? file = null) {
            path = file ?? Path.build_filename (Environment.get_user_data_dir (), "singularity-translate", "phrasebook.json");
            load ();
        }

        private void load () {
            items.clear ();
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
                foreach (var node in root.get_array ().get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var o = node.get_object ();
                    var e = new HistoryEntry ();
                    e.source = o.get_string_member_with_default ("source", "");
                    e.target = o.get_string_member_with_default ("target", "");
                    e.text = o.get_string_member_with_default ("text", "");
                    e.translation = o.get_string_member_with_default ("translation", "");
                    e.time = o.get_int_member_with_default ("time", 0);
                    if (e.text != "" && e.target != "" && find (e.source, e.target, e.text) == null) items.add (e);
                }
            } catch (Error e) {
                warning ("translate: %s", e.message);
            }
        }

        private void save () {
            var arr = new Json.Array ();
            foreach (var e in items) {
                var o = new Json.Object ();
                o.set_string_member ("source", e.source);
                o.set_string_member ("target", e.target);
                o.set_string_member ("text", e.text);
                o.set_string_member ("translation", e.translation);
                o.set_int_member ("time", e.time);
                arr.add_object_element (o);
            }
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (arr);
            var gen = new Json.Generator ();
            gen.pretty = true;
            gen.set_root (root);
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents_full (path, gen.to_data (null), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning ("translate: %s", e.message);
            }
            changed ();
        }

        public HistoryEntry? find (string source, string target, string text) {
            string t = text.strip ();
            foreach (var e in items) if (e.source == source && e.target == target && e.text == t) return e;
            return null;
        }

        public HistoryEntry? add (string source, string target, string text, string translation, int64 time) {
            string t = text.strip ();
            string tr = translation.strip ();
            if (t == "" || tr == "" || target == "") return null;
            var old = find (source, target, t);
            if (old != null) items.remove (old);
            var e = new HistoryEntry ();
            e.source = source;
            e.target = target;
            e.text = t;
            e.translation = tr;
            e.time = time;
            items.insert (0, e);
            save ();
            return e;
        }

        public void remove (HistoryEntry entry) {
            if (items.remove (entry)) save ();
        }

        public Gee.List<HistoryEntry> search (string query) {
            var list = new Gee.ArrayList<HistoryEntry> ();
            string[] words = {};
            foreach (string w in query.casefold ().split (" ")) if (w != "") words += w;
            foreach (var e in items) {
                string hay = (e.text + "\n" + e.translation).casefold ();
                bool ok = true;
                foreach (string w in words) if (!hay.contains (w)) ok = false;
                if (ok) list.add (e);
            }
            return list;
        }

        public static string csv_field (string value) {
            if (!value.contains (",") && !value.contains ("\"") && !value.contains ("\n") && !value.contains ("\r")) return value;
            return "\"" + value.replace ("\"", "\"\"") + "\"";
        }

        public string to_csv (Gee.List<Language> languages) {
            var sb = new StringBuilder ();
            sb.append ("Source Language,Target Language,Text,Translation,Saved\r\n");
            foreach (var e in items) {
                string when = e.time > 0 ? new DateTime.from_unix_utc (e.time).format ("%Y-%m-%d %H:%M") : "";
                string[] fields = { Languages.name_for (languages, e.source), Languages.name_for (languages, e.target), e.text, e.translation, when };
                for (int i = 0; i < fields.length; i++) {
                    if (i > 0) sb.append_c (',');
                    sb.append (csv_field (fields[i]));
                }
                sb.append ("\r\n");
            }
            return sb.str;
        }
    }

    namespace LanguageCache {
        private string file_for (string backend, string instance) {
            string key = Checksum.compute_for_string (ChecksumType.SHA1, backend + "|" + instance).substring (0, 12);
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity-translate", "languages-%s.json".printf (key));
        }

        public Gee.List<Language>? load (string backend, string instance) {
            try {
                string text;
                FileUtils.get_contents (file_for (backend, instance), out text);
                return LibreTranslateBackend.parse_languages (text);
            } catch (Error e) {
                return null;
            }
        }

        public void save (string backend, string instance, Gee.List<Language> list) {
            var arr = new Json.Array ();
            foreach (var l in list) {
                var o = new Json.Object ();
                o.set_string_member ("code", l.code);
                o.set_string_member ("name", l.name);
                arr.add_object_element (o);
            }
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (arr);
            var gen = new Json.Generator ();
            gen.set_root (root);
            string path = file_for (backend, instance);
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents (path, gen.to_data (null));
            } catch (Error e) {
            }
        }
    }

    namespace Keys {
        private Secret.Schema schema () {
            return new Secret.Schema ("dev.sinty.translate", Secret.SchemaFlags.NONE, "instance", Secret.SchemaAttributeType.STRING);
        }

        public async string lookup (string instance) {
            try {
                return (yield Secret.password_lookup (schema (), null, "instance", Http.normalize_instance (instance))) ?? "";
            } catch (Error e) {
                return "";
            }
        }

        public async bool store (string instance, string key) {
            string inst = Http.normalize_instance (instance);
            try {
                if (key == "") {
                    yield Secret.password_clear (schema (), null, "instance", inst);
                    return true;
                }
                return yield Secret.password_store (schema (), Secret.COLLECTION_DEFAULT, _("Translate API key for %s").printf (Http.host_of (inst)), key, null, "instance", inst);
            } catch (Error e) {
                warning ("translate: %s", e.message);
                return false;
            }
        }
    }
}
