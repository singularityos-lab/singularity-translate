namespace Singularity.Apps.Translate {

    public class SearchTranslation : Object {
        public string text = "";
        public string target = "";
        public string translation = "";
        public string detected = "";
        public string provider = "";
        public string error = "";
    }

    public class TranslateSearch : Singularity.SearchProviderService {
        private const uint SETTLE_MS = 450;
        private const string[] PREFIXES = { "tr", "translate" };

        private weak TranslateApp app;
        private uint generation;
        private Gee.HashMap<string, SearchTranslation> done = new Gee.HashMap<string, SearchTranslation> ();

        public TranslateSearch (TranslateApp app) {
            this.app = app;
        }

        public bool parse (string[] terms, out string target, out string text) {
            target = "";
            text = "";
            if (terms.length == 0) return false;
            string first = terms[0];
            string rest = terms.length > 1 ? string.joinv (" ", terms[1:terms.length]).strip () : "";
            foreach (unowned string p in PREFIXES) {
                if (first.down () == p) {
                    target = app.config.target;
                    text = rest;
                    return text != "";
                }
            }
            int colon = first.index_of_char (':');
            if (colon < 2) return false;
            string code = first.substring (0, colon).down ();
            if (!is_language (code)) return false;
            string after = first.substring (colon + 1).strip ();
            text = after != "" && rest != "" ? after + " " + rest : after + rest;
            target = code;
            return text != "";
        }

        private static bool is_language (string code) {
            foreach (var l in Languages.builtin ()) if (l.code == code) return true;
            return false;
        }

        private static string make_id (string target, string text) {
            return target + "\n" + text;
        }

        private static bool split_id (string id, out string target, out string text) {
            int nl = id.index_of_char ('\n');
            target = nl > 0 ? id.substring (0, nl) : "";
            text = nl > 0 ? id.substring (nl + 1) : "";
            return nl > 0 && text != "";
        }

        private async void pause (uint ms) {
            Timeout.add (ms, pause.callback);
            yield;
        }

        private async SearchTranslation run (string target, string text) {
            string id = make_id (target, text);
            var cached = done[id];
            if (cached != null) return cached;
            var job = new SearchTranslation ();
            job.text = text;
            job.target = target;
            try {
                string detected, provider;
                job.translation = yield ServiceClient.translate (text, "auto", target, out detected, out provider);
                job.detected = detected;
                job.provider = provider;
            } catch (Error e) {
                job.error = ServiceClient.error_text (e);
            }
            if (job.error == "") done[id] = job;
            return job;
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            string target, text;
            if (!parse (terms, out target, out text)) return {};
            string id = make_id (target, text);
            if (done.has_key (id)) return { id };
            uint gen = ++generation;
            yield pause (SETTLE_MS);
            if (gen != generation) return {};
            yield run (target, text);
            if (gen != generation) return {};
            return { id };
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            var names = Languages.builtin ();
            foreach (string id in ids) {
                string target, text;
                if (!split_id (id, out target, out text)) continue;
                var job = yield run (target, text);
                Singularity.SearchResultMeta meta;
                if (job.error != "") {
                    meta = new Singularity.SearchResultMeta (id, _("Could Not Translate"));
                    meta.description = job.error;
                } else {
                    string shown = job.translation.replace ("\n", " ").strip ();
                    if (shown.char_count () > 200) shown = shown.substring (0, shown.index_of_nth_char (200)) + "…";
                    meta = new Singularity.SearchResultMeta (id, shown);
                    string to_name = Languages.name_for (names, target);
                    string pair = job.detected != "" && job.detected != "auto"
                        ? _("%s to %s").printf (Languages.name_for (names, job.detected), to_name)
                        : _("To %s").printf (to_name);
                    meta.description = job.provider != "" ? _("%s, by %s").printf (pair, job.provider) : pair;
                }
                meta.add_action ("open", _("Open in Translate"), "document-open-symbolic");
                meta.score = 100.0;
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            string target, text;
            if (!split_id (id, out target, out text)) return null;
            var job = yield run (target, text);
            if (job.error != "" || job.translation == "") {
                open (job);
                return null;
            }
            return Singularity.SearchActivationReply.copy (job.translation);
        }

        public override async Singularity.SearchActivationReply? activate_action (string id, string action_id, string[] terms, uint32 timestamp) throws Error {
            string target, text;
            if (!split_id (id, out target, out text) || action_id != "open") return null;
            open (yield run (target, text));
            return null;
        }

        public override void launch_search (string[] terms, uint32 timestamp) {
            string target, text;
            if (!parse (terms, out target, out text)) {
                app.activate ();
                return;
            }
            var job = done[make_id (target, text)];
            if (job == null) {
                job = new SearchTranslation ();
                job.text = text;
                job.target = target;
            }
            open (job);
        }

        private void open (SearchTranslation job) {
            string source = job.detected != "" ? job.detected : "auto";
            app.show_in_window (job.text, job.translation, source, job.target);
        }
    }
}
