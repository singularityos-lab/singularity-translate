using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Translate {

    public class SplitBox : Widget {
        public int breakpoint { get; set; default = 720; }
        public int spacing { get; set; default = 16; }
        private Widget first;
        private Widget second;

        public SplitBox (Widget first, Widget second) {
            this.first = first;
            this.second = second;
            first.set_parent (this);
            second.set_parent (this);
        }

        public override void dispose () {
            if (first != null) first.unparent ();
            if (second != null) second.unparent ();
            first = null;
            second = null;
            base.dispose ();
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        protected override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            int m1, n1, m2, n2, b;
            first.measure (orientation, -1, out m1, out n1, out b, out b);
            second.measure (orientation, -1, out m2, out n2, out b, out b);
            if (orientation == Orientation.HORIZONTAL) {
                minimum = int.max (m1, m2);
                natural = int.max (minimum, n1 + n2 + spacing);
            } else {
                minimum = m1 + m2 + spacing;
                natural = int.max (minimum, int.max (n1, n2));
            }
            minimum_baseline = natural_baseline = -1;
        }

        protected override void size_allocate (int width, int height, int baseline) {
            if (width >= breakpoint) {
                int w = (width - spacing) / 2;
                first.allocate (w, height, -1, null);
                var t = new Gsk.Transform ().translate (Graphene.Point () { x = w + spacing, y = 0 });
                second.allocate (width - w - spacing, height, -1, t);
            } else {
                int h = (height - spacing) / 2;
                first.allocate (width, h, -1, null);
                var t = new Gsk.Transform ().translate (Graphene.Point () { x = 0, y = h + spacing });
                second.allocate (width, height - h - spacing, -1, t);
            }
        }
    }

    public class LanguagePopover : Popover {
        public signal void chosen (string code);
        private ListBox list;
        private Gtk.SearchEntry search;
        private string filter = "";

        public LanguagePopover (Gee.List<Language> languages, bool with_detect, string current) {
            has_arrow = false;
            add_css_class ("translate-languages");
            var box = new Box (Orientation.VERTICAL, 6);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 8;
            box.margin_end = 8;
            search = new Gtk.SearchEntry ();
            search.placeholder_text = _("Search Languages");
            box.append (search);
            list = new ListBox ();
            list.selection_mode = SelectionMode.SINGLE;
            list.add_css_class ("navigation-sidebar");
            if (with_detect) list.append (make_row ("auto", _("Detect Language"), current == "auto"));
            foreach (var l in languages) list.append (make_row (l.code, l.name, l.code == current));
            list.set_filter_func ((row) => {
                if (filter == "") return true;
                string code = row.get_data<string> ("code");
                string name = row.get_data<string> ("name");
                return name.down ().contains (filter) || code.down () == filter;
            });
            list.row_activated.connect ((row) => {
                chosen (row.get_data<string> ("code"));
                popdown ();
            });
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 380;
            scroll.min_content_width = 240;
            scroll.child = list;
            box.append (scroll);
            child = box;
            search.search_changed.connect (() => {
                filter = search.text.strip ().down ();
                list.invalidate_filter ();
            });
            search.activate.connect (() => {
                var row = first_visible ();
                if (row != null) {
                    chosen (row.get_data<string> ("code"));
                    popdown ();
                }
            });
            search.stop_search.connect (() => popdown ());
            map.connect (() => search.grab_focus ());
        }

        private ListBoxRow? first_visible () {
            for (var c = list.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var row = c as ListBoxRow;
                if (row != null && row.get_child_visible () && row.visible) return row;
            }
            return null;
        }

        private ListBoxRow make_row (string code, string name, bool current) {
            var row = new ListBoxRow ();
            row.set_data<string> ("code", code);
            row.set_data<string> ("name", name);
            var box = new Box (Orientation.HORIZONTAL, 8);
            box.margin_top = 6;
            box.margin_bottom = 6;
            box.margin_start = 8;
            box.margin_end = 8;
            var label = new Label (name);
            label.xalign = 0;
            label.hexpand = true;
            box.append (label);
            if (current) {
                var check = new Image.from_icon_name ("object-select-symbolic");
                box.append (check);
            }
            row.child = box;
            if (current) Idle.add (() => {
                list.select_row (row);
                return Source.REMOVE;
            });
            return row;
        }
    }

    public class TranslateWindow : Singularity.Widgets.Window {
        private TranslateApp app;
        private Config config;
        private History history;
        private Phrasebook phrasebook;
        private Backend backend;
        private Gee.List<Language> languages;
        private TextView source_view;
        private TextView target_view;
        private Label source_placeholder;
        private Label target_placeholder;
        private Button source_lang;
        private Button target_lang;
        private Label count_label;
        private Label provider_label;
        private Stack result_stack;
        private StatusPage error_page;
        private Button error_prefs;
        private Button error_key;
        private Button listen_source;
        private Button listen_target;
        private Button copy_button;
        private Button star_button;
        private Stack main_stack;
        private Box phrase_list;
        private Stack phrase_stack;
        private StatusPage phrase_empty;
        private SearchBubble phrase_search;
        private Button phrase_bubble;
        private Button export_bubble;
        private Button swap_bubble;
        private Button history_bubble;
        private string phrase_query = "";
        private Spinner busy;
        private Button translate_bubble;
        private AppSidebar history_bar;
        private Label? toast;
        private uint toast_id;
        private uint debounce_id;
        private uint history_id;
        private uint backend_id;
        private ulong settings_handler;
        private Cancellable? inflight;
        private Cancellable? lang_cancel;
        private uint serial;
        private string detected = "";
        private string last_text = "";
        private MediaFile? player;
        private bool syncing;
        private uint speech_serial;
        private Overlay content_root;

        public TranslateWindow (TranslateApp app) {
            Object (application: app);
            this.app = app;
            config = app.config;
            history = app.history;
            phrasebook = app.phrasebook;
            set_title (_("Translate"));
            set_default_size (1000, 620);
            set_size_request (360, 420);

            content_root = new Overlay ();
            var root = content_root;
            var split = new SplitBox (build_source_pane (), build_target_pane ());
            split.margin_top = 64;
            split.margin_bottom = 20;
            split.margin_start = 20;
            split.margin_end = 20;
            main_stack = new Stack ();
            main_stack.transition_type = StackTransitionType.CROSSFADE;
            main_stack.add_named (split, "translate");
            main_stack.add_named (build_phrasebook (), "phrasebook");
            root.child = main_stack;
            set_content (root);

            history_bar = new AppSidebar (260);
            set_sidebar (history_bar);
            set_sidebar_visible (false);

            phrase_search = add_bubble_search (_("Search Phrasebook"), (t) => {
                phrase_query = t.strip ();
                rebuild_phrasebook ();
            });
            swap_bubble = add_bubble_icon ("object-flip-horizontal-symbolic", _("Swap Languages"), () => swap ());
            history_bubble = add_bubble_icon ("document-open-recent-symbolic", _("History"), () => toggle_history ());
            export_bubble = add_bubble_icon ("document-save-as-symbolic", _("Export Phrasebook as CSV (Ctrl+Shift+E)"), () => export_phrasebook ());
            phrase_bubble = add_bubble_icon ("user-bookmarks-symbolic", _("Phrasebook (Ctrl+B)"), () => toggle_phrasebook ());
            translate_bubble = add_bubble_suggested (_("Translate"), () => translate_now ());

            install_actions ();
            history.changed.connect (rebuild_history);
            rebuild_history ();
            phrasebook.changed.connect (() => {
                rebuild_phrasebook ();
                sync_star ();
                set_action_enabled ("export-phrasebook", phrasebook.items.size > 0);
            });
            rebuild_phrasebook ();
            sync_mode ();
            sync_star ();
            apply_backend ();
            sync_live ();
            settings_handler = config.settings.changed.connect (on_setting_changed);
            close_request.connect (() => {
                if (settings_handler != 0) config.settings.disconnect (settings_handler);
                settings_handler = 0;
                if (debounce_id != 0) Source.remove (debounce_id);
                if (history_id != 0) Source.remove (history_id);
                if (backend_id != 0) Source.remove (backend_id);
                debounce_id = history_id = backend_id = 0;
                if (inflight != null) inflight.cancel ();
                if (lang_cancel != null) lang_cancel.cancel ();
                return false;
            });
            source_view.grab_focus ();
        }

        private Widget pane_header (out Button lang_button) {
            var header = new Box (Orientation.HORIZONTAL, 6);
            header.add_css_class ("translate-pane-header");
            var btn = new Button ();
            btn.add_css_class ("flat");
            btn.add_css_class ("translate-language");
            var inner = new Box (Orientation.HORIZONTAL, 6);
            var label = new Label ("");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 22;
            inner.append (label);
            inner.append (new Image.from_icon_name ("pan-down-symbolic"));
            btn.child = inner;
            btn.set_data<Label> ("label", label);
            header.append (btn);
            lang_button = btn;
            return header;
        }

        private Button footer_button (string icon, string tooltip) {
            var b = new Button.from_icon_name (icon);
            b.add_css_class ("flat");
            b.add_css_class ("circular");
            b.tooltip_text = tooltip;
            b.update_property (Gtk.AccessibleProperty.LABEL, tooltip, -1);
            return b;
        }

        private Widget build_source_pane () {
            var pane = new Box (Orientation.VERTICAL, 0);
            pane.add_css_class ("translate-pane");
            pane.append (pane_header (out source_lang));
            source_lang.tooltip_text = _("Translate From");
            source_lang.clicked.connect (() => pick_language (source_lang, true));

            source_view = new TextView ();
            source_view.wrap_mode = WrapMode.WORD_CHAR;
            source_view.add_css_class ("translate-text");
            source_view.top_margin = 8;
            source_view.bottom_margin = 8;
            source_view.left_margin = 16;
            source_view.right_margin = 16;
            source_view.accepts_tab = false;
            source_view.update_property (Gtk.AccessibleProperty.LABEL, _("Text to translate"), -1);
            source_view.buffer.changed.connect (on_source_changed);
            ContextMenu.attach_editable (source_view, true);
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((val, code, state) => {
                if ((val == Gdk.Key.Return || val == Gdk.Key.KP_Enter) && (state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    translate_now ();
                    return true;
                }
                return false;
            });
            source_view.add_controller (keys);
            source_placeholder = new Label (_("Type or paste text"));
            source_placeholder.add_css_class ("dim-label");
            source_placeholder.add_css_class ("translate-placeholder");
            source_placeholder.halign = Align.START;
            source_placeholder.valign = Align.START;
            source_placeholder.margin_start = 18;
            source_placeholder.margin_top = 8;
            source_placeholder.can_target = false;
            var overlay = new Overlay ();
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = source_view;
            overlay.child = scroll;
            overlay.add_overlay (source_placeholder);
            pane.append (overlay);

            var footer = new Box (Orientation.HORIZONTAL, 4);
            footer.add_css_class ("translate-pane-footer");
            count_label = new Label ("");
            count_label.add_css_class ("dim-label");
            count_label.add_css_class ("caption");
            count_label.add_css_class ("numeric");
            count_label.hexpand = true;
            count_label.xalign = 0;
            footer.append (count_label);
            listen_source = footer_button ("audio-speakers-symbolic", _("Listen"));
            listen_source.clicked.connect (() => speak (false));
            footer.append (listen_source);
            var paste = footer_button ("edit-paste-symbolic", _("Paste"));
            paste.clicked.connect (() => paste_text ());
            footer.append (paste);
            var clear = footer_button ("edit-clear-symbolic", _("Clear"));
            clear.clicked.connect (() => clear_text ());
            footer.append (clear);
            pane.append (footer);
            return pane;
        }

        private Widget build_target_pane () {
            var pane = new Box (Orientation.VERTICAL, 0);
            pane.add_css_class ("translate-pane");
            pane.add_css_class ("translate-result");
            pane.append (pane_header (out target_lang));
            target_lang.tooltip_text = _("Translate To");
            target_lang.clicked.connect (() => pick_language (target_lang, false));

            target_view = new TextView ();
            target_view.editable = false;
            target_view.cursor_visible = false;
            target_view.wrap_mode = WrapMode.WORD_CHAR;
            target_view.add_css_class ("translate-text");
            target_view.top_margin = 8;
            target_view.bottom_margin = 8;
            target_view.left_margin = 16;
            target_view.right_margin = 16;
            target_view.update_property (Gtk.AccessibleProperty.LABEL, _("Translation"), -1);
            ContextMenu.attach_editable (target_view);
            target_placeholder = new Label (_("The translation appears here"));
            target_placeholder.add_css_class ("dim-label");
            target_placeholder.add_css_class ("translate-placeholder");
            target_placeholder.halign = Align.START;
            target_placeholder.valign = Align.START;
            target_placeholder.margin_start = 18;
            target_placeholder.margin_top = 8;
            target_placeholder.can_target = false;
            var overlay = new Overlay ();
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = target_view;
            overlay.child = scroll;
            overlay.add_overlay (target_placeholder);

            error_page = new StatusPage ();
            error_page.icon_name = "network-error";
            var actions = new Box (Orientation.HORIZONTAL, 12);
            actions.halign = Align.CENTER;
            error_prefs = new Button.with_label (_("Settings"));
            error_prefs.add_css_class ("pill");
            error_prefs.clicked.connect (() => app.activate_action ("settings", null));
            actions.append (error_prefs);
            error_key = new Button.with_label (_("Set API Key"));
            error_key.add_css_class ("pill");
            error_key.clicked.connect (() => ask_api_key ());
            actions.append (error_key);
            var retry = new Button.with_label (_("Try Again"));
            retry.add_css_class ("pill");
            retry.add_css_class ("suggested-action");
            retry.clicked.connect (() => translate_now ());
            actions.append (retry);
            error_page.child = actions;
            var error_scroll = new ScrolledWindow ();
            error_scroll.hscrollbar_policy = PolicyType.NEVER;
            error_scroll.child = error_page;

            var loading = new Box (Orientation.VERTICAL, 12);
            loading.valign = Align.CENTER;
            loading.halign = Align.CENTER;
            var spinner = new Spinner ();
            spinner.spinning = true;
            spinner.set_size_request (32, 32);
            loading.append (spinner);
            var loading_label = new Label (_("Translating…"));
            loading_label.add_css_class ("dim-label");
            loading.append (loading_label);

            result_stack = new Stack ();
            result_stack.transition_type = StackTransitionType.CROSSFADE;
            result_stack.vexpand = true;
            result_stack.add_named (overlay, "text");
            result_stack.add_named (loading, "loading");
            result_stack.add_named (error_scroll, "error");
            pane.append (result_stack);

            var footer = new Box (Orientation.HORIZONTAL, 4);
            footer.add_css_class ("translate-pane-footer");
            busy = new Spinner ();
            busy.visible = false;
            footer.append (busy);
            provider_label = new Label ("");
            provider_label.add_css_class ("dim-label");
            provider_label.add_css_class ("caption");
            provider_label.ellipsize = Pango.EllipsizeMode.END;
            provider_label.hexpand = true;
            provider_label.xalign = 0;
            footer.append (provider_label);
            listen_target = footer_button ("audio-speakers-symbolic", _("Listen"));
            listen_target.clicked.connect (() => speak (true));
            footer.append (listen_target);
            star_button = footer_button ("non-starred-symbolic", _("Add to Phrasebook"));
            star_button.clicked.connect (() => toggle_star ());
            footer.append (star_button);
            copy_button = footer_button ("edit-copy-symbolic", _("Copy Translation"));
            copy_button.clicked.connect (() => copy_result ());
            footer.append (copy_button);
            pane.append (footer);
            return pane;
        }

        private void install_actions () {
            var entries = new ActionEntry[] {
                { "new", () => clear_text () },
                { "copy-translation", () => copy_result () },
                { "swap", () => swap () },
                { "translate", () => translate_now () },
                { "history", () => toggle_history () },
                { "clear-history", () => confirm_clear_history () },
                { "api-key", () => ask_api_key () },
                { "pick-source", () => pick_language (source_lang, true) },
                { "pick-target", () => pick_language (target_lang, false) },
                { "listen", () => speak (true) },
                { "star", () => toggle_star () },
                { "phrasebook", () => toggle_phrasebook () },
                { "export-phrasebook", () => export_phrasebook () },
                { "translate-file", () => translate_file () },
                { "find", () => find_in_phrasebook () },
                { "close", () => close () }
            };
            add_action_entries (entries, this);
        }

        private void set_action_enabled (string name, bool enabled) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (enabled);
        }

        private void find_in_phrasebook () {
            if (main_stack.visible_child_name != "phrasebook") toggle_phrasebook ();
            else phrase_search.grab_focus_entry ();
        }

        private void on_setting_changed (string key) {
            switch (key) {
                case "backend":
                case "libre-instance":
                case "lingva-instance":
                    if (backend_id != 0) Source.remove (backend_id);
                    backend_id = Timeout.add (700, () => {
                        backend_id = 0;
                        if (backend.id != config.backend || backend.instance != config.instance_for (config.backend)) {
                            apply_backend ();
                            translate_now ();
                        }
                        return Source.REMOVE;
                    });
                    break;
                case "live":
                    sync_live ();
                    break;
                case "keep-history":
                    rebuild_history ();
                    break;
            }
        }

        private string text_of (TextView view) {
            TextIter a, b;
            view.buffer.get_bounds (out a, out b);
            return view.buffer.get_text (a, b, false);
        }

        private void set_lang_label (Button button, string text) {
            var label = button.get_data<Label> ("label");
            if (label != null) label.label = text;
        }

        private string language_name (string code) {
            return Languages.name_for (languages != null ? languages : Languages.builtin (), code);
        }

        private void sync_languages () {
            string src;
            if (config.source == "auto") {
                src = detected != "" ? _("%s (Detected)").printf (language_name (detected)) : _("Detect Language");
            } else {
                src = language_name (config.source);
            }
            set_lang_label (source_lang, src);
            set_lang_label (target_lang, language_name (config.target));
            sync_speech ();
        }

        private void sync_speech () {
            bool can = backend.supports_speech;
            listen_source.visible = can;
            listen_target.visible = can;
            string src_lang = config.source == "auto" ? detected : config.source;
            listen_source.sensitive = src_lang != "" && text_of (source_view).strip () != "";
            listen_target.sensitive = text_of (target_view).strip () != "" && result_stack.visible_child_name == "text";
            set_action_enabled ("listen", can && listen_target.sensitive);
        }

        private void sync_live () {
            translate_bubble.visible = !config.live && main_stack.visible_child_name == "translate";
        }

        private void apply_backend () {
            backend = Backend.create (config.backend);
            backend.instance = config.instance_for (backend.id);
            string inst = backend.instance;
            string id = backend.id;
            languages = LanguageCache.load (id, inst) ?? Languages.builtin ();
            Languages.sort (languages);
            sync_languages ();
            update_count ();
            if (backend.id == "libretranslate") {
                Keys.lookup.begin (inst, (o, res) => {
                    string key = Keys.lookup.end (res);
                    if (backend.id == id && backend.instance == inst) {
                        backend.api_key = key;
                        load_languages ();
                    }
                });
            } else {
                load_languages ();
            }
        }

        private void load_languages () {
            if (lang_cancel != null) lang_cancel.cancel ();
            var cancel = new Cancellable ();
            lang_cancel = cancel;
            var b = backend;
            b.refresh_limits.begin (cancel, (o, res) => {
                b.refresh_limits.end (res);
                if (b == backend) update_count ();
            });
            b.languages.begin (cancel, (o, res) => {
                try {
                    var list = b.languages.end (res);
                    if (b != backend || list.size == 0) return;
                    Languages.sort (list);
                    languages = list;
                    LanguageCache.save (b.id, b.instance, list);
                    sync_languages ();
                } catch (Error e) {
                }
                if (b == backend && text_of (source_view).strip () != "" && text_of (target_view) == "") translate_now ();
            });
        }

        private void update_count () {
            int n = text_of (source_view).char_count ();
            int limit = backend.char_limit;
            if (limit > 0) count_label.label = _("%d / %d").printf (n, limit);
            else count_label.label = ngettext ("%d character", "%d characters", n).printf (n);
            if (limit > 0 && n > limit) count_label.add_css_class ("error");
            else count_label.remove_css_class ("error");
        }

        private void on_source_changed () {
            string text = text_of (source_view);
            source_placeholder.visible = text == "";
            update_count ();
            sync_speech ();
            if (syncing) return;
            if (text.strip () == "") {
                cancel_pending ();
                show_result ("", "");
                return;
            }
            if (!config.live) return;
            if (debounce_id != 0) Source.remove (debounce_id);
            debounce_id = Timeout.add (650, () => {
                debounce_id = 0;
                run_translation.begin ();
                return Source.REMOVE;
            });
        }

        private void cancel_pending () {
            if (debounce_id != 0) Source.remove (debounce_id);
            debounce_id = 0;
            if (inflight != null) inflight.cancel ();
            inflight = null;
            busy.visible = false;
            busy.spinning = false;
            last_text = "";
        }

        public void translate_now () {
            if (debounce_id != 0) Source.remove (debounce_id);
            debounce_id = 0;
            last_text = "";
            run_translation.begin ();
        }

        private void show_result (string text, string provider_note) {
            target_view.buffer.text = text;
            target_placeholder.visible = text == "";
            provider_label.label = provider_note;
            result_stack.visible_child_name = "text";
            copy_button.sensitive = text != "";
            sync_speech ();
            sync_star ();
        }

        private bool fallback_allowed (Error e, string text) {
            if (!config.fallback || backend.id == "mymemory") return false;
            if (text.char_count () > 500) return false;
            return e is TranslateError.UNREACHABLE || e is TranslateError.RATE_LIMITED || e is TranslateError.AUTH;
        }

        private async void run_translation () {
            string text = text_of (source_view);
            if (text.strip () == "") {
                show_result ("", "");
                return;
            }
            string key = "%s|%s|%s|%s".printf (backend.id, config.source, config.target, text);
            if (key == last_text && result_stack.visible_child_name == "text") return;
            int limit = backend.char_limit;
            if (limit > 0 && text.char_count () > limit) {
                show_error (new TranslateError.TOO_LONG (_("%s accepts up to %d characters at a time. Shorten the text or choose another service in Settings.").printf (backend.title, limit)));
                return;
            }
            if (config.source == config.target) {
                show_result (text, "");
                return;
            }
            if (inflight != null) inflight.cancel ();
            var cancel = new Cancellable ();
            inflight = cancel;
            uint mine = ++serial;
            busy.visible = true;
            busy.spinning = true;
            if (text_of (target_view) == "" || result_stack.visible_child_name != "text") result_stack.visible_child_name = "loading";
            Translation? result = null;
            Error? failure = null;
            var b = backend;
            try {
                result = yield b.translate (text, config.source, config.target, cancel);
            } catch (Error e) {
                failure = e;
            }
            if (mine != serial) return;
            if (failure != null && !(failure is IOError.CANCELLED) && fallback_allowed (failure, text)) {
                try {
                    var mm = new MyMemoryBackend ();
                    result = yield mm.translate (text, config.source, config.target, cancel);
                    result.fallback = true;
                } catch (Error e2) {
                }
                if (mine != serial) return;
            }
            busy.visible = false;
            busy.spinning = false;
            if (result == null) {
                if (failure is IOError.CANCELLED) return;
                show_error (failure ?? new TranslateError.FAILED (_("The text could not be translated.")));
                return;
            }
            last_text = key;
            if (config.source == "auto" && result.detected != "" && result.detected != "auto") detected = result.detected;
            string note;
            if (result.fallback) note = _("Translated by MyMemory because %s is unavailable").printf (b.service_name);
            else note = _("Translated by %s").printf (b.service_name);
            show_result (result.text, note);
            sync_languages ();
            queue_history (text, result.text);
        }

        private void queue_history (string text, string translation) {
            if (!config.keep_history) return;
            if (history_id != 0) Source.remove (history_id);
            string src = config.source == "auto" && detected != "" ? detected : config.source;
            string tgt = config.target;
            history_id = Timeout.add_seconds (2, () => {
                history_id = 0;
                var e = new HistoryEntry ();
                e.source = src;
                e.target = tgt;
                e.text = text.strip ();
                e.translation = translation.strip ();
                e.time = new DateTime.now_utc ().to_unix ();
                history.add (e);
                return Source.REMOVE;
            });
        }

        private void show_error (Error e) {
            busy.visible = false;
            busy.spinning = false;
            string title = _("Translation Failed");
            bool prefs = false;
            if (e is TranslateError.OFFLINE) {
                title = _("You Are Offline");
            } else if (e is TranslateError.UNREACHABLE) {
                title = _("Service Unavailable");
                prefs = true;
            } else if (e is TranslateError.RATE_LIMITED) {
                title = _("Too Many Requests");
                prefs = true;
            } else if (e is TranslateError.AUTH) {
                title = backend.api_key == "" ? _("API Key Needed") : _("API Key Refused");
                prefs = true;
            } else if (e is TranslateError.TOO_LONG) {
                title = _("Text Too Long");
            }
            error_page.title = title;
            error_page.description = e.message;
            error_prefs.visible = prefs;
            error_key.visible = e is TranslateError.AUTH && backend.id == "libretranslate";
            provider_label.label = "";
            copy_button.sensitive = false;
            result_stack.visible_child_name = "error";
            sync_star ();
            sync_speech ();
        }

        private void pick_language (Button anchor, bool is_source) {
            var pop = new LanguagePopover (languages, is_source && backend.supports_detection, is_source ? config.source : config.target);
            pop.set_parent (anchor);
            pop.chosen.connect ((code) => {
                if (is_source) {
                    if (code == config.target && config.source != "auto") config.target = config.source;
                    config.source = code;
                    if (code != "auto") detected = "";
                } else {
                    if (code == config.source) config.source = config.target;
                    config.target = code;
                }
                sync_languages ();
                translate_now ();
            });
            pop.closed.connect (() => Idle.add (() => {
                pop.unparent ();
                return Source.REMOVE;
            }));
            pop.popup ();
        }

        public void swap () {
            string src = config.source == "auto" ? detected : config.source;
            if (src == "") {
                show_toast (_("Choose the language of the text first"));
                return;
            }
            string translated = result_stack.visible_child_name == "text" ? text_of (target_view) : "";
            config.source = config.target;
            config.target = src;
            detected = "";
            sync_languages ();
            if (translated != "") {
                syncing = true;
                source_view.buffer.text = translated;
                syncing = false;
                source_placeholder.visible = false;
            }
            translate_now ();
        }

        private void copy_result () {
            string text = text_of (target_view);
            if (text == "" || result_stack.visible_child_name != "text") return;
            get_clipboard ().set_text (text);
            show_toast (_("Translation copied"));
        }

        private void paste_text () {
            get_clipboard ().read_text_async.begin (null, (o, res) => {
                try {
                    string? text = get_clipboard ().read_text_async.end (res);
                    if (text == null || text == "") return;
                    source_view.buffer.insert_at_cursor (text, -1);
                    source_view.grab_focus ();
                } catch (Error e) {
                    show_toast (_("There is no text to paste"));
                }
            });
        }

        public void clear_text () {
            source_view.buffer.text = "";
            detected = "";
            sync_languages ();
            source_view.grab_focus ();
        }

        private void speak (bool translation) {
            if (!backend.supports_speech) return;
            string text = translation ? text_of (target_view) : text_of (source_view);
            string lang = translation ? config.target : (config.source == "auto" ? detected : config.source);
            if (text.strip () == "" || lang == "") return;
            var b = backend;
            var btn = translation ? listen_target : listen_source;
            btn.sensitive = false;
            b.speak.begin (text, lang, null, (o, res) => {
                btn.sensitive = true;
                try {
                    var bytes = b.speak.end (res);
                    if (player != null) player.playing = false;
                    string dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-translate");
                    DirUtils.create_with_parents (dir, 0700);
                    string path = Path.build_filename (dir, "speech-%u.mp3".printf (++speech_serial % 2));
                    FileUtils.set_data (path, bytes.get_data ());
                    player = MediaFile.for_filename (path);
                    player.notify["error"].connect (() => {
                        if (player != null && player.error != null) show_toast (_("The speech could not be played"));
                    });
                    player.play ();
                } catch (Error e) {
                    show_toast (e.message);
                }
            });
        }

        private void toggle_history () {
            set_sidebar_visible (!get_sidebar_visible ());
        }

        private void rebuild_history () {
            Widget? child;
            while ((child = history_bar.box.get_first_child ()) != null) history_bar.box.remove (child);
            history_bar.box.append (new SidebarSectionLabel (_("History")));
            if (history.items.size == 0) {
                var empty = new Label (config.keep_history ? _("Your translations will be listed here") : _("History is turned off in Settings"));
                empty.add_css_class ("dim-label");
                empty.add_css_class ("caption");
                empty.wrap = true;
                empty.xalign = 0;
                empty.margin_start = 12;
                empty.margin_end = 12;
                empty.margin_top = 6;
                history_bar.box.append (empty);
                return;
            }
            foreach (var e in history.items) {
                string first = e.text.split ("\n")[0];
                var row = new SidebarRow ("document-open-recent-symbolic", first);
                row.tooltip_text = "%s\n%s\n\n%s: %s".printf (e.text, e.translation, language_name (e.source), language_name (e.target));
                var entry = e;
                row.clicked.connect (() => restore (entry));
                var right = new GestureClick ();
                right.button = Gdk.BUTTON_SECONDARY;
                right.pressed.connect ((n, x, y) => history_menu (row, entry, x, y));
                row.add_controller (right);
                history_bar.box.append (row);
            }
            var clear = new SidebarRow ("user-trash-symbolic", _("Clear History"));
            clear.margin_top = 8;
            clear.clicked.connect (() => confirm_clear_history ());
            history_bar.box.append (clear);
        }

        private void history_menu (Widget anchor, HistoryEntry entry, double x, double y) {
            var menu = new ContextMenu (anchor);
            menu.pointing_to = { (int) x, (int) y, 1, 1 };
            menu.add_item (_("Open"), "document-open-symbolic", () => restore (entry));
            menu.add_item (_("Copy Translation"), "edit-copy-symbolic", () => {
                get_clipboard ().set_text (entry.translation);
                show_toast (_("Translation copied"));
            });
            menu.add_separator ();
            menu.add_item (_("Remove"), "user-trash-symbolic", () => history.remove (entry), "destructive");
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void restore (HistoryEntry entry) {
            cancel_pending ();
            config.source = entry.source;
            config.target = entry.target;
            detected = "";
            syncing = true;
            source_view.buffer.text = entry.text;
            syncing = false;
            source_placeholder.visible = entry.text == "";
            update_count ();
            last_text = "%s|%s|%s|%s".printf (backend.id, config.source, config.target, entry.text);
            show_result (entry.translation, entry.time > 0 && phrasebook.items.contains (entry) ? _("From your phrasebook") : _("From your history"));
            sync_languages ();
        }

        private void confirm_clear_history () {
            if (history.items.size == 0) return;
            var dlg = new ConfirmDialog ((Gtk.Application) application, _("Clear History?"), "user-trash-symbolic",
                _("All your recent translations are removed from this computer."), _("Clear"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) history.clear ();
            });
            dlg.present ();
        }

        private void ask_api_key () {
            string instance = config.libre_instance;
            var dlg = new ConfirmDialog ((Gtk.Application) application, _("LibreTranslate API Key"), "dev.sinty.translate",
                _("The key for %s is kept in the keyring. Leave it empty to remove it.").printf (Http.host_of (instance)),
                _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            var group = new PreferencesGroup ();
            var key = new PasswordRow (_("API Key"));
            group.add_row (key);
            dlg.custom_area.append (group);
            string original = "";
            Keys.lookup.begin (instance, (o, res) => {
                original = Keys.lookup.end (res);
                if (key.text == "") key.text = original;
            });
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                string new_key = key.text.strip ();
                if (new_key == original) return;
                Keys.store.begin (instance, new_key, (o, res) => {
                    if (!Keys.store.end (res)) show_toast (_("The API key could not be saved in the keyring"));
                    apply_backend ();
                    translate_now ();
                });
            });
            dlg.present ();
            key.grab_focus ();
        }

        private string current_source () {
            return config.source == "auto" && detected != "" ? detected : config.source;
        }

        private void sync_star () {
            if (star_button == null) return;
            string text = text_of (source_view).strip ();
            string translation = result_stack.visible_child_name == "text" ? text_of (target_view).strip () : "";
            bool can = text != "" && translation != "";
            star_button.sensitive = can;
            set_action_enabled ("star", can);
            set_action_enabled ("copy-translation", translation != "");
            bool saved = can && phrasebook.find (current_source (), config.target, text) != null;
            star_button.icon_name = saved ? "starred-symbolic" : "non-starred-symbolic";
            string tip = saved ? _("Remove from Phrasebook") : _("Add to Phrasebook");
            star_button.tooltip_text = tip + " (Ctrl+D)";
            star_button.update_property (Gtk.AccessibleProperty.LABEL, tip, -1);
        }

        private void toggle_star () {
            string text = text_of (source_view).strip ();
            string translation = result_stack.visible_child_name == "text" ? text_of (target_view).strip () : "";
            if (text == "" || translation == "") return;
            var existing = phrasebook.find (current_source (), config.target, text);
            if (existing != null) {
                phrasebook.remove (existing);
                show_toast (_("Removed from the phrasebook"));
            } else {
                phrasebook.add (current_source (), config.target, text, translation, new DateTime.now_utc ().to_unix ());
                show_toast (_("Added to the phrasebook"));
            }
        }

        private void sync_mode () {
            bool book = main_stack.visible_child_name == "phrasebook";
            phrase_search.visible = book;
            export_bubble.visible = book;
            export_bubble.sensitive = phrasebook.items.size > 0;
            set_action_enabled ("export-phrasebook", phrasebook.items.size > 0);
            swap_bubble.visible = !book;
            history_bubble.visible = !book;
            phrase_bubble.icon_name = book ? "go-previous-symbolic" : "user-bookmarks-symbolic";
            phrase_bubble.tooltip_text = book ? _("Back to Translation (Ctrl+B)") : _("Phrasebook (Ctrl+B)");
            sync_live ();
        }

        public void toggle_phrasebook () {
            bool book = main_stack.visible_child_name != "phrasebook";
            main_stack.visible_child_name = book ? "phrasebook" : "translate";
            if (book) {
                set_sidebar_visible (false);
                phrase_search.grab_focus_entry ();
            } else {
                phrase_search.clear ();
                source_view.grab_focus ();
            }
            sync_mode ();
        }

        private Widget build_phrasebook () {
            phrase_list = new Box (Orientation.VERTICAL, 18);
            phrase_list.margin_top = 12;
            phrase_list.margin_bottom = 24;
            var clamp = new Clamp (phrase_list);
            clamp.maximum = 760;
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = clamp;
            phrase_empty = new StatusPage ();
            phrase_empty.vexpand = true;
            phrase_empty.icon_name = "system-search";
            phrase_empty.title = _("No Results");
            phrase_empty.description = _("No saved phrase matches your search.");
            var clear = new Button.with_label (_("Clear Search"));
            clear.add_css_class ("pill");
            clear.add_css_class ("suggested-action");
            clear.halign = Align.CENTER;
            clear.clicked.connect (() => phrase_search.clear ());
            phrase_empty.child = clear;
            var none = new WelcomePage ();
            none.is_section = true;
            none.app_icon_name = "user-bookmarks";
            none.title = _("No Saved Phrases");
            none.subtitle = _("Star a translation with Ctrl+D to keep it in your phrasebook.");
            none.add_action ("dev.sinty.translate", _("Translate Something"), _("Type or paste the text to translate"), () => toggle_phrasebook ());
            none.add_action ("text-x-generic", _("Translate a File"), _("A text or Markdown file in one go"), () => translate_file ());
            phrase_stack = new Stack ();
            phrase_stack.add_named (scroll, "list");
            phrase_stack.add_named (phrase_empty, "empty");
            phrase_stack.add_named (none, "none");
            phrase_stack.margin_top = 64;
            phrase_stack.margin_start = 20;
            phrase_stack.margin_end = 20;
            return phrase_stack;
        }

        private void rebuild_phrasebook () {
            if (phrase_list == null) return;
            Widget? child;
            while ((child = phrase_list.get_first_child ()) != null) phrase_list.remove (child);
            if (export_bubble != null) export_bubble.sensitive = phrasebook.items.size > 0;
            var found = phrasebook.search (phrase_query);
            if (found.size == 0) {
                phrase_stack.visible_child_name = phrasebook.items.size == 0 ? "none" : "empty";
                return;
            }
            phrase_stack.visible_child_name = "list";
            var groups = new Gee.HashMap<string, PreferencesGroup> ();
            foreach (var e in found) {
                string pair = e.source + "|" + e.target;
                var group = groups[pair];
                if (group == null) {
                    group = new PreferencesGroup (_("%s to %s").printf (language_name (e.source), language_name (e.target)));
                    groups[pair] = group;
                    phrase_list.append (group);
                }
                var row = new ActionRow (e.text, e.translation);
                row.tooltip_text = "%s\n\n%s".printf (e.text, e.translation);
                var entry = e;
                var copy = new Button.from_icon_name ("edit-copy-symbolic");
                copy.add_css_class ("flat");
                copy.add_css_class ("circular");
                copy.valign = Align.CENTER;
                copy.tooltip_text = _("Copy Translation");
                copy.update_property (Gtk.AccessibleProperty.LABEL, _("Copy Translation"), -1);
                copy.clicked.connect (() => {
                    get_clipboard ().set_text (entry.translation);
                    show_toast (_("Translation copied"));
                });
                row.add_suffix (copy);
                var remove = new Button.from_icon_name ("user-trash-symbolic");
                remove.add_css_class ("flat");
                remove.add_css_class ("circular");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Remove");
                remove.update_property (Gtk.AccessibleProperty.LABEL, _("Remove from Phrasebook"), -1);
                remove.clicked.connect (() => phrasebook.remove (entry));
                row.add_suffix (remove);
                row.activated.connect (() => {
                    toggle_phrasebook ();
                    restore (entry);
                });
                group.add_row (row);
            }
        }

        private void export_phrasebook () {
            if (phrasebook.items.size == 0) {
                show_toast (_("The phrasebook is empty"));
                return;
            }
            var dialog = new FileDialog ();
            dialog.title = _("Export Phrasebook");
            dialog.initial_name = _("Phrasebook") + ".csv";
            dialog.save.begin (this, null, (o, res) => {
                try {
                    var file = dialog.save.end (res);
                    string csv = phrasebook.to_csv (languages ?? Languages.builtin ());
                    file.replace_contents_bytes_async.begin (new Bytes (csv.data), null, false, FileCreateFlags.REPLACE_DESTINATION, null, (o2, r2) => {
                        try {
                            file.replace_contents_bytes_async.end (r2, null);
                            show_toast (_("Phrasebook exported"));
                        } catch (Error e) {
                            show_error_dialog (_("Could Not Export"), e.message);
                        }
                    });
                } catch (Error e) {
                }
            });
        }

        private void show_error_dialog (string title, string message) {
            var dlg = new ConfirmDialog.message ((Gtk.Application) application, title, "dialog-error", message);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.present ();
        }

        private void translate_file () {
            var dialog = new FileDialog ();
            dialog.title = _("Translate a File");
            var filters = new GLib.ListStore (typeof (FileFilter));
            var f = new FileFilter ();
            f.name = _("Text and Markdown Files");
            f.add_pattern ("*.txt");
            f.add_pattern ("*.md");
            f.add_pattern ("*.markdown");
            f.add_mime_type ("text/plain");
            f.add_mime_type ("text/markdown");
            filters.append (f);
            dialog.filters = filters;
            dialog.open.begin (this, null, (o, res) => {
                try {
                    open_document (dialog.open.end (res));
                } catch (Error e) {
                }
            });
        }

        public void open_document (File file) {
            var dlg = new FileTranslationDialog ((Gtk.Application) application, config, backend, file, language_name (config.source == "auto" ? "auto" : config.source), language_name (config.target));
            dlg.transient_for = this;
            dlg.present ();
            dlg.start ();
        }

        public void show_text (string text, string translation, string source, string target) {
            if (main_stack.visible_child_name != "translate") toggle_phrasebook ();
            var e = new HistoryEntry ();
            e.source = source;
            e.target = target;
            e.text = text;
            e.translation = translation;
            restore (e);
            source_view.grab_focus ();
        }

        private void show_toast (string text) {
            if (toast == null) {
                toast = new Label ("");
                toast.add_css_class ("translate-toast");
                toast.halign = Align.CENTER;
                toast.valign = Align.END;
                toast.margin_bottom = 36;
                toast.can_target = false;
                content_root.add_overlay (toast);
            }
            toast.label = text;
            toast.visible = true;
            if (toast_id != 0) Source.remove (toast_id);
            toast_id = Timeout.add (2500, () => {
                toast_id = 0;
                toast.visible = false;
                return Source.REMOVE;
            });
        }
    }
}
