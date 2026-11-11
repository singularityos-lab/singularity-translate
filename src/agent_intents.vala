namespace Singularity.Apps.Translate {

    internal class TranslateIntents : Object {

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static string language(string value) throws Error {
            string v = value.strip();
            if (v == "" || v == "auto") return v;
            string want = v.casefold();
            foreach (var l in Languages.builtin()) {
                if (l.code.casefold() == want || l.name.casefold() == want) return l.code;
            }
            throw new IOError.INVALID_ARGUMENT("unknown language %s; see translate_languages", value);
        }

        private static void entry(Json.Builder b, HistoryEntry e) {
            b.begin_object();
            b.set_member_name("from").add_string_value(e.source);
            b.set_member_name("to").add_string_value(e.target);
            b.set_member_name("text").add_string_value(e.text);
            b.set_member_name("translation").add_string_value(e.translation);
            if (e.time > 0) b.set_member_name("time").add_string_value(new DateTime.from_unix_local(e.time).format_iso8601());
            b.end_object();
        }

        private static async void run(TranslateApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                string body = args.has_member("text") ? args.get_string_member("text") : "";
                if (body.strip() == "") throw new IOError.INVALID_ARGUMENT("give the text to translate");
                string from = language(text(args, "from"));
                string to = language(text(args, "to"));
                if (to == "auto") throw new IOError.INVALID_ARGUMENT("give the language to translate into");
                var backend = Backend.create(app.config.backend);
                backend.instance = app.config.instance_for(backend.id);
                if (backend.id == "libretranslate") backend.api_key = yield Keys.lookup(backend.instance);
                if (from == "") from = "auto";
                if (to == "") to = app.config.target;
                int limit = backend.request_limit;
                string[] pieces = Chunker.split(body, limit);
                var sb = new StringBuilder();
                string detected = "";
                string provider = "";
                foreach (string piece in pieces) {
                    if (piece.strip() == "") {
                        sb.append(piece);
                        continue;
                    }
                    Translation result;
                    try {
                        result = yield backend.translate(piece, from, to, null);
                        provider = backend.service_name;
                    } catch (Error e) {
                        bool retry = app.config.fallback && backend.id != "mymemory" && piece.char_count() <= 500
                            && (e is TranslateError.UNREACHABLE || e is TranslateError.RATE_LIMITED || e is TranslateError.AUTH);
                        if (!retry) throw e;
                        result = yield new MyMemoryBackend().translate(piece, from, to, null);
                        provider = "MyMemory";
                    }
                    sb.append(result.text);
                    if (detected == "" && result.detected != "") detected = result.detected;
                }
                string result = sb.str;
                if (app.config.keep_history && body.char_count() <= 2000) {
                    var h = new HistoryEntry();
                    h.source = detected != "" ? detected : from;
                    h.target = to != "" ? to : app.config.target;
                    h.text = body;
                    h.translation = result;
                    h.time = new DateTime.now_local().to_unix();
                    app.history.add(h);
                }
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("translation").add_string_value(result);
                b.set_member_name("from").add_string_value(detected != "" ? detected : from);
                b.set_member_name("to").add_string_value(to != "" ? to : app.config.target);
                b.set_member_name("service").add_string_value(provider);
                b.set_member_name("pieces").add_int_value(pieces.length);
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                reply(null, e);
            } finally {
                app.release();
            }
        }

        internal static void install(TranslateApp app) {
            var agent = app.agent;
            agent.add_async_intent("translate_text",
                "Translate text with the online service chosen in Translate (the text is sent to it). from is detected when left out; to defaults to the language set in Translate. Long text is split and joined back.",
                "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"},\"from\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    run.begin(app, args, (owned) reply);
                });
            agent.add_intent("translate_languages", "The languages Translate knows, by code and name, the default target and the online service in use.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("default_to").add_string_value(app.config.target);
                    b.set_member_name("service").add_string_value(Backend.create(app.config.backend).title);
                    b.set_member_name("languages").begin_array();
                    foreach (var l in Languages.builtin()) {
                        b.begin_object();
                        b.set_member_name("code").add_string_value(l.code);
                        b.set_member_name("name").add_string_value(l.name);
                        b.end_object();
                    }
                    b.end_array();
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("translate_history", "Recent translations and saved phrases, optionally filtered by words in the text or the translation.",
                "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}", Singularity.AppIntentRisk.READ, (args) => {
                    string q = text(args, "query").casefold();
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("recent").begin_array();
                    foreach (var e in app.history.items) {
                        if (q == "" || e.text.casefold().contains(q) || e.translation.casefold().contains(q)) entry(b, e);
                    }
                    b.end_array();
                    b.set_member_name("phrases").begin_array();
                    foreach (var e in q == "" ? app.phrasebook.items : app.phrasebook.search(q)) entry(b, e);
                    b.end_array();
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("translate_save_phrase", "Save a text and its translation in the phrasebook.",
                "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"translation\":{\"type\":\"string\"},\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"}},\"required\":[\"text\",\"translation\",\"from\",\"to\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string from = language(text(args, "from"));
                    string to = language(text(args, "to"));
                    if (from == "" || from == "auto" || to == "" || to == "auto") throw new IOError.INVALID_ARGUMENT("give both languages");
                    var saved = app.phrasebook.add(from, to, text(args, "text"), text(args, "translation"), new DateTime.now_local().to_unix());
                    if (saved == null || app.phrasebook.find(from, to, text(args, "text")) == null) throw new IOError.FAILED("the phrase was not saved");
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("saved");
                    entry(b, saved);
                    b.set_member_name("undo").add_string_value("translate_remove_phrase with the same text, from and to");
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("translate_remove_phrase", "Remove a saved phrase from the phrasebook.",
                "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"}},\"required\":[\"text\",\"from\",\"to\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string from = language(text(args, "from"));
                    string to = language(text(args, "to"));
                    var e = app.phrasebook.find(from, to, text(args, "text"));
                    if (e == null) throw new IOError.NOT_FOUND("no saved phrase matches");
                    app.phrasebook.remove(e);
                    if (app.phrasebook.find(from, to, text(args, "text")) != null) throw new IOError.FAILED("the phrase is still saved");
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("removed");
                    entry(b, e);
                    b.set_member_name("undo").add_string_value("translate_save_phrase with the same fields");
                    b.end_object();
                    return b.get_root();
                });
        }
    }
}
