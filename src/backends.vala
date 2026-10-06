namespace Singularity.Apps.Translate {

    public errordomain TranslateError {
        OFFLINE,
        UNREACHABLE,
        RATE_LIMITED,
        AUTH,
        TOO_LONG,
        UNSUPPORTED,
        FAILED
    }

    public class Language : Object {
        public string code { get; construct; }
        public string name { get; construct; }

        public Language (string code, string name) {
            Object (code: code, name: name);
        }
    }

    public class Translation : Object {
        public string text = "";
        public string detected = "";
        public string provider = "";
        public bool fallback;
    }

    public class Http : Object {
        private static Soup.Session? shared;

        public static Soup.Session session () {
            if (shared == null) {
                shared = new Soup.Session ();
                shared.timeout = 20;
                shared.user_agent = "Singularity-Translate";
            }
            return shared;
        }

        public static string normalize_instance (string url) {
            string s = url.strip ();
            while (s.has_suffix ("/")) s = s.substring (0, s.length - 1);
            if (s != "" && !s.contains ("://")) s = "https://" + s;
            return s;
        }

        public static string host_of (string url) {
            string host = url;
            int scheme = url.index_of ("://");
            if (scheme >= 0) host = url.substring (scheme + 3);
            int slash = host.index_of_char ('/');
            return slash > 0 ? host.substring (0, slash) : host;
        }

        public static string body_text (Bytes bytes) {
            unowned uint8[] data = bytes.get_data ();
            var sb = new StringBuilder.sized (data.length + 1);
            if (data.length > 0) sb.append_len ((string) data, data.length);
            return sb.str;
        }

        public static Error network_error (Error e, string service) {
            if (e is IOError.CANCELLED) return e;
            if (!NetworkMonitor.get_default ().network_available) {
                return new TranslateError.OFFLINE (_("You are offline. Check your connection and try again."));
            }
            if (e is IOError.TIMED_OUT) {
                return new TranslateError.UNREACHABLE (_("%s did not answer in time.").printf (service));
            }
            return new TranslateError.UNREACHABLE (_("%s could not be reached.").printf (service));
        }

        public static Error status_error (uint status, string? message, string service) {
            string detail = message != null && message.strip () != "" ? message.strip () : "";
            if (status == 429) {
                return new TranslateError.RATE_LIMITED (detail != "" ? detail : _("%s received too many requests. Wait a moment and try again.").printf (service));
            }
            if (status == 401 || status == 403) {
                return new TranslateError.AUTH (detail != "" ? detail : _("%s refused the request. Check the API key.").printf (service));
            }
            if (status == 413) {
                return new TranslateError.TOO_LONG (_("The text is too long for %s.").printf (service));
            }
            if (status >= 500 || status == 404) {
                return new TranslateError.UNREACHABLE (detail != "" ? detail : _("%s is not working right now (error %u).").printf (service, status));
            }
            return new TranslateError.FAILED (detail != "" ? detail : _("%s answered with error %u.").printf (service, status));
        }

        public static Json.Node parse_json (string text) throws Error {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (text);
            } catch (Error e) {
                throw new TranslateError.FAILED (_("The service sent an answer that could not be read."));
            }
            var root = parser.get_root ();
            if (root == null) throw new TranslateError.FAILED (_("The service sent an empty answer."));
            return root;
        }

        public static string? string_member (Json.Object o, string name) {
            if (!o.has_member (name)) return null;
            var n = o.get_member (name);
            if (n.get_node_type () != Json.NodeType.VALUE) return null;
            if (n.get_value_type () == typeof (string)) return n.get_string ();
            if (n.get_value_type () == typeof (int64)) return n.get_int ().to_string ();
            return null;
        }

        public static async string request (Soup.Message msg, string service, Cancellable? cancel, out uint status) throws Error {
            Bytes bytes;
            try {
                bytes = yield session ().send_and_read_async (msg, Priority.DEFAULT, cancel);
            } catch (Error e) {
                throw network_error (e, service);
            }
            status = msg.status_code;
            return body_text (bytes);
        }
    }

    public abstract class Backend : Object {
        public string instance { get; set; default = ""; }
        public string api_key { get; set; default = ""; }

        public abstract string id { get; }
        public abstract string title { get; }
        public virtual bool supports_speech { get { return false; } }
        public virtual bool supports_detection { get { return true; } }
        public virtual int char_limit { get { return -1; } }
        public virtual string service_name { owned get { return title; } }
        public virtual int request_limit { get { return char_limit > 0 ? char_limit : 4000; } }

        public abstract async Gee.List<Language> languages (Cancellable? cancel) throws Error;
        public abstract async Translation translate (string text, string source, string target, Cancellable? cancel) throws Error;

        public virtual async Bytes speak (string text, string language, Cancellable? cancel) throws Error {
            throw new TranslateError.UNSUPPORTED (_("%s cannot read text aloud.").printf (title));
        }

        public virtual async void refresh_limits (Cancellable? cancel) {
        }

        public static Backend create (string id) {
            if (id == "lingva") return new LingvaBackend ();
            if (id == "mymemory") return new MyMemoryBackend ();
            return new LibreTranslateBackend ();
        }
    }

    public class LibreTranslateBackend : Backend {
        public const string DEFAULT_INSTANCE = "https://libretranslate.com";
        private int limit = -1;

        public override string id { get { return "libretranslate"; } }
        public override string title { get { return "LibreTranslate"; } }
        public override int char_limit { get { return limit; } }

        public override string service_name {
            owned get {
                return Http.host_of (base_url ());
            }
        }

        public static Gee.List<Language> parse_languages (string text) throws Error {
            var list = new Gee.ArrayList<Language> ();
            var root = Http.parse_json (text);
            if (root.get_node_type () == Json.NodeType.OBJECT) {
                string? err = parse_error (text);
                throw new TranslateError.FAILED (err ?? _("The language list could not be read."));
            }
            if (root.get_node_type () != Json.NodeType.ARRAY) throw new TranslateError.FAILED (_("The language list could not be read."));
            foreach (var node in root.get_array ().get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = node.get_object ();
                string? code = Http.string_member (o, "code");
                string? name = Http.string_member (o, "name");
                if (code == null || code == "") continue;
                list.add (new Language (code, name ?? code));
            }
            return list;
        }

        public static string? parse_error (string text) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return null;
                return Http.string_member (root.get_object (), "error");
            } catch (Error e) {
                return null;
            }
        }

        public static Translation parse_translation (string text) throws Error {
            var root = Http.parse_json (text);
            if (root.get_node_type () != Json.NodeType.OBJECT) throw new TranslateError.FAILED (_("The translation could not be read."));
            var o = root.get_object ();
            string? err = Http.string_member (o, "error");
            if (err != null) throw new TranslateError.FAILED (err);
            string? translated = Http.string_member (o, "translatedText");
            if (translated == null) throw new TranslateError.FAILED (_("The translation could not be read."));
            var t = new Translation ();
            t.text = translated;
            if (o.has_member ("detectedLanguage") && o.get_member ("detectedLanguage").get_node_type () == Json.NodeType.OBJECT) {
                t.detected = Http.string_member (o.get_object_member ("detectedLanguage"), "language") ?? "";
            }
            return t;
        }

        public static int parse_char_limit (string text) {
            try {
                var root = Http.parse_json (text);
                if (root.get_node_type () != Json.NodeType.OBJECT) return -1;
                var o = root.get_object ();
                if (!o.has_member ("charLimit")) return -1;
                int64 v = o.get_int_member_with_default ("charLimit", -1);
                return v > 0 ? (int) v : -1;
            } catch (Error e) {
                return -1;
            }
        }

        public static string build_request (string text, string source, string target, string api_key) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("q").add_string_value (text);
            b.set_member_name ("source").add_string_value (source);
            b.set_member_name ("target").add_string_value (target);
            b.set_member_name ("format").add_string_value ("text");
            if (api_key != "") b.set_member_name ("api_key").add_string_value (api_key);
            b.end_object ();
            var gen = new Json.Generator ();
            gen.set_root (b.get_root ());
            return gen.to_data (null);
        }

        private string base_url () {
            string s = Http.normalize_instance (instance);
            return s != "" ? s : DEFAULT_INSTANCE;
        }

        public override async Gee.List<Language> languages (Cancellable? cancel) throws Error {
            var msg = new Soup.Message ("GET", base_url () + "/languages");
            if (msg == null) throw new TranslateError.FAILED (_("The instance address is not valid."));
            uint status;
            string text = yield Http.request (msg, service_name, cancel, out status);
            if (status < 200 || status >= 300) throw Http.status_error (status, parse_error (text), service_name);
            return parse_languages (text);
        }

        public override async void refresh_limits (Cancellable? cancel) {
            var msg = new Soup.Message ("GET", base_url () + "/frontend/settings");
            if (msg == null) return;
            try {
                uint status;
                string text = yield Http.request (msg, service_name, cancel, out status);
                if (status >= 200 && status < 300) limit = parse_char_limit (text);
            } catch (Error e) {
            }
        }

        public override async Translation translate (string text, string source, string target, Cancellable? cancel) throws Error {
            var msg = new Soup.Message ("POST", base_url () + "/translate");
            if (msg == null) throw new TranslateError.FAILED (_("The instance address is not valid."));
            string body = build_request (text, source, target, api_key);
            msg.set_request_body_from_bytes ("application/json", new Bytes (body.data));
            uint status;
            string answer = yield Http.request (msg, service_name, cancel, out status);
            if (status < 200 || status >= 300) {
                string? err = parse_error (answer);
                if ((status == 400 || status == 403) && err != null && err.down ().contains ("api key")) {
                    throw new TranslateError.AUTH (api_key == "" ? _("%s needs an API key. Set one with Set API Key or choose another service in Settings.").printf (service_name) : err);
                }
                throw Http.status_error (status, err, service_name);
            }
            var t = parse_translation (answer);
            t.provider = title;
            return t;
        }
    }

    public class LingvaBackend : Backend {
        public const string DEFAULT_INSTANCE = "https://lingva.ml";

        public override string id { get { return "lingva"; } }
        public override string title { get { return "Lingva"; } }
        public override bool supports_speech { get { return true; } }
        public override int char_limit { get { return 5000; } }
        public override int request_limit { get { return 1200; } }

        public override string service_name {
            owned get {
                return Http.host_of (base_url ());
            }
        }

        private string base_url () {
            string s = Http.normalize_instance (instance);
            return s != "" ? s : DEFAULT_INSTANCE;
        }

        public static string escape (string text) {
            return Uri.escape_string (text, null, false);
        }

        public static string translate_path (string source, string target, string text) {
            return "/api/v1/%s/%s/%s".printf (escape (source), escape (target), escape (text));
        }

        public static string audio_path (string language, string text) {
            return "/api/v1/audio/%s/%s".printf (escape (language), escape (text));
        }

        private static Json.Object object_root (string text) throws Error {
            var root = Http.parse_json (text);
            if (root.get_node_type () != Json.NodeType.OBJECT) throw new TranslateError.FAILED (_("The answer could not be read."));
            var o = root.get_object ();
            string? err = Http.string_member (o, "error");
            if (err != null) throw new TranslateError.FAILED (err);
            return o;
        }

        public static Gee.List<Language> parse_languages (string text) throws Error {
            var o = object_root (text);
            var list = new Gee.ArrayList<Language> ();
            if (!o.has_member ("languages") || o.get_member ("languages").get_node_type () != Json.NodeType.ARRAY) {
                throw new TranslateError.FAILED (_("The language list could not be read."));
            }
            foreach (var node in o.get_array_member ("languages").get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                var l = node.get_object ();
                string? code = Http.string_member (l, "code");
                if (code == null || code == "" || code == "auto") continue;
                list.add (new Language (code, Http.string_member (l, "name") ?? code));
            }
            return list;
        }

        public static Translation parse_translation (string text) throws Error {
            var o = object_root (text);
            string? translated = Http.string_member (o, "translation");
            if (translated == null) throw new TranslateError.FAILED (_("The translation could not be read."));
            var t = new Translation ();
            t.text = translated;
            if (o.has_member ("info") && o.get_member ("info").get_node_type () == Json.NodeType.OBJECT) {
                t.detected = Http.string_member (o.get_object_member ("info"), "detectedSource") ?? "";
            }
            return t;
        }

        public static Bytes parse_audio (string text) throws Error {
            var o = object_root (text);
            if (!o.has_member ("audio") || o.get_member ("audio").get_node_type () != Json.NodeType.ARRAY) {
                throw new TranslateError.FAILED (_("The speech could not be read."));
            }
            var arr = o.get_array_member ("audio");
            var data = new uint8[arr.get_length ()];
            for (uint i = 0; i < arr.get_length (); i++) {
                int64 v = arr.get_int_element (i);
                if (v < 0 || v > 255) throw new TranslateError.FAILED (_("The speech could not be read."));
                data[i] = (uint8) v;
            }
            if (data.length == 0) throw new TranslateError.FAILED (_("There is no speech for this text."));
            return new Bytes (data);
        }

        private async string fetch (string path, Cancellable? cancel) throws Error {
            var msg = new Soup.Message ("GET", base_url () + path);
            if (msg == null) throw new TranslateError.FAILED (_("The instance address is not valid."));
            uint status;
            string text = yield Http.request (msg, service_name, cancel, out status);
            if (status < 200 || status >= 300) {
                string? err = null;
                try {
                    var root = Http.parse_json (text);
                    if (root.get_node_type () == Json.NodeType.OBJECT) err = Http.string_member (root.get_object (), "error");
                } catch (Error e) {
                }
                throw Http.status_error (status, err, service_name);
            }
            return text;
        }

        public override async Gee.List<Language> languages (Cancellable? cancel) throws Error {
            return parse_languages (yield fetch ("/api/v1/languages", cancel));
        }

        public override async Translation translate (string text, string source, string target, Cancellable? cancel) throws Error {
            var t = parse_translation (yield fetch (translate_path (source, target, text), cancel));
            t.provider = title;
            return t;
        }

        public override async Bytes speak (string text, string language, Cancellable? cancel) throws Error {
            return parse_audio (yield fetch (audio_path (language, text), cancel));
        }
    }

    public class MyMemoryBackend : Backend {
        public const string ENDPOINT = "https://api.mymemory.translated.net/get";

        public override string id { get { return "mymemory"; } }
        public override string title { get { return "MyMemory"; } }
        public override int char_limit { get { return 500; } }

        public static string translate_url (string text, string source, string target) {
            string from = source == "auto" || source == "" ? "Autodetect" : source;
            return "%s?q=%s&langpair=%s".printf (ENDPOINT, Uri.escape_string (text, null, false), Uri.escape_string (from + "|" + target, null, false));
        }

        public static string decode_entities (string text) {
            if (!text.contains ("&")) return text;
            var sb = new StringBuilder ();
            int i = 0;
            while (i < text.length) {
                if (text[i] == '&') {
                    int end = text.index_of_char (';', i);
                    if (end > i && end - i <= 10) {
                        string ent = text.substring (i + 1, end - i - 1);
                        unichar c = 0;
                        if (ent == "amp") c = '&';
                        else if (ent == "lt") c = '<';
                        else if (ent == "gt") c = '>';
                        else if (ent == "quot") c = '"';
                        else if (ent == "apos") c = '\'';
                        else if (ent.has_prefix ("#x") || ent.has_prefix ("#X")) c = (unichar) ulong.parse (ent.substring (2), 16);
                        else if (ent.has_prefix ("#")) c = (unichar) ulong.parse (ent.substring (1));
                        if (c != 0 && c.validate ()) {
                            sb.append_unichar (c);
                            i = end + 1;
                            continue;
                        }
                    }
                }
                sb.append_c (text[i]);
                i++;
            }
            return sb.str;
        }

        public static Translation parse_translation (string text) throws Error {
            var root = Http.parse_json (text);
            if (root.get_node_type () != Json.NodeType.OBJECT) throw new TranslateError.FAILED (_("The translation could not be read."));
            var o = root.get_object ();
            string status = Http.string_member (o, "responseStatus") ?? "200";
            string details = Http.string_member (o, "responseDetails") ?? "";
            bool quota = false;
            if (o.has_member ("quotaFinished")) {
                var q = o.get_member ("quotaFinished");
                quota = q.get_node_type () == Json.NodeType.VALUE && q.get_value_type () == typeof (bool) && q.get_boolean ();
            }
            if (quota || status == "429" || details.has_prefix ("MYMEMORY WARNING")) {
                throw new TranslateError.RATE_LIMITED (_("MyMemory reached its daily limit for this computer. Try again tomorrow or choose another service."));
            }
            if (status != "200") {
                throw new TranslateError.FAILED (details != "" ? details : _("MyMemory answered with error %s.").printf (status));
            }
            if (!o.has_member ("responseData") || o.get_member ("responseData").get_node_type () != Json.NodeType.OBJECT) {
                throw new TranslateError.FAILED (_("The translation could not be read."));
            }
            var data = o.get_object_member ("responseData");
            string? translated = Http.string_member (data, "translatedText");
            if (translated == null) throw new TranslateError.FAILED (_("The translation could not be read."));
            var t = new Translation ();
            t.text = decode_entities (translated);
            string? detected = Http.string_member (data, "detectedLanguage");
            if (detected != null) t.detected = detected.split ("-")[0].down ();
            return t;
        }

        public override async Gee.List<Language> languages (Cancellable? cancel) throws Error {
            return Languages.builtin ();
        }

        public override async Translation translate (string text, string source, string target, Cancellable? cancel) throws Error {
            var msg = new Soup.Message ("GET", translate_url (text, source, target));
            if (msg == null) throw new TranslateError.FAILED (_("The text could not be sent."));
            uint status;
            string answer = yield Http.request (msg, title, cancel, out status);
            if (status < 200 || status >= 300) throw Http.status_error (status, null, title);
            var t = parse_translation (answer);
            t.provider = title;
            return t;
        }
    }

    namespace Languages {
        private const string[] BUILTIN = {
            "af", "Afrikaans", "sq", "Albanian", "am", "Amharic", "ar", "Arabic", "hy", "Armenian", "az", "Azerbaijani",
            "eu", "Basque", "be", "Belarusian", "bn", "Bengali", "bs", "Bosnian", "bg", "Bulgarian", "ca", "Catalan",
            "zh", "Chinese", "hr", "Croatian", "cs", "Czech", "da", "Danish", "nl", "Dutch", "en", "English",
            "eo", "Esperanto", "et", "Estonian", "fi", "Finnish", "fr", "French", "gl", "Galician", "ka", "Georgian",
            "de", "German", "el", "Greek", "gu", "Gujarati", "ht", "Haitian Creole", "he", "Hebrew", "hi", "Hindi",
            "hu", "Hungarian", "is", "Icelandic", "id", "Indonesian", "ga", "Irish", "it", "Italian", "ja", "Japanese",
            "kn", "Kannada", "kk", "Kazakh", "ko", "Korean", "lv", "Latvian", "lt", "Lithuanian", "mk", "Macedonian",
            "ms", "Malay", "ml", "Malayalam", "mt", "Maltese", "mr", "Marathi", "mn", "Mongolian", "ne", "Nepali",
            "nb", "Norwegian", "fa", "Persian", "pl", "Polish", "pt", "Portuguese", "pa", "Punjabi", "ro", "Romanian",
            "ru", "Russian", "sr", "Serbian", "sk", "Slovak", "sl", "Slovenian", "es", "Spanish", "sw", "Swahili",
            "sv", "Swedish", "tl", "Tagalog", "ta", "Tamil", "te", "Telugu", "th", "Thai", "tr", "Turkish",
            "uk", "Ukrainian", "ur", "Urdu", "uz", "Uzbek", "vi", "Vietnamese", "cy", "Welsh"
        };

        public Gee.List<Language> builtin () {
            var list = new Gee.ArrayList<Language> ();
            for (int i = 0; i + 1 < BUILTIN.length; i += 2) list.add (new Language (BUILTIN[i], BUILTIN[i + 1]));
            return list;
        }

        public string name_for (Gee.List<Language> list, string code) {
            foreach (var l in list) if (l.code == code) return l.name;
            string base_code = code.split ("-")[0].split ("_")[0];
            foreach (var l in list) if (l.code == base_code) return l.name;
            foreach (var l in builtin ()) if (l.code == base_code) return l.name;
            return code;
        }

        public void sort (Gee.List<Language> list) {
            list.sort ((a, b) => a.name.collate (b.name));
        }

        public string system_language () {
            foreach (unowned string lang in Intl.get_language_names ()) {
                if (lang == "C" || lang == "POSIX") continue;
                return lang.split (".")[0].split ("@")[0].split ("_")[0];
            }
            return "en";
        }
    }
}
