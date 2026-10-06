using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Translate {

    public class FileTranslationDialog : AppDialog {
        public const int64 MAX_BYTES = 2 * 1024 * 1024;

        private Config config;
        private Backend backend;
        private File file;
        private string source_code;
        private string target_code;
        private DocumentJob? job;
        private string result = "";
        private Cancellable? cancel;
        private CircularProgress progress;
        private Label status;
        private Label pair;
        private string target_name;
        private TextView preview;
        private ScrolledWindow preview_scroll;
        private Button close_button;
        private Button retry_button;
        private Button save_button;
        private bool running;

        public FileTranslationDialog (Gtk.Application app, Config config, Backend backend, File file, string source_name, string target_name) {
            base (app, false);
            this.config = config;
            this.backend = backend;
            this.file = file;
            source_code = config.source;
            target_code = config.target;
            this.target_name = target_name;
            set_title (_("Translate File"));
            set_default_size (520, 0);

            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 28;
            box.margin_end = 28;

            var head = new Box (Orientation.HORIZONTAL, 14);
            var icon = new Image.from_icon_name ("text-x-generic");
            icon.pixel_size = 48;
            head.append (icon);
            var names = new Box (Orientation.VERTICAL, 2);
            names.valign = Align.CENTER;
            var name = new Label (file.get_basename ());
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.add_css_class ("heading");
            names.append (name);
            pair = new Label (source_code == "auto" ? _("To %s").printf (target_name) : _("%s to %s").printf (source_name, target_name));
            pair.xalign = 0;
            pair.add_css_class ("dim-label");
            names.append (pair);
            head.append (names);
            box.append (head);

            var row = new Box (Orientation.HORIZONTAL, 16);
            row.margin_top = 8;
            progress = new CircularProgress (56);
            progress.valign = Align.CENTER;
            row.append (progress);
            status = new Label (_("Reading the file…"));
            status.xalign = 0;
            status.wrap = true;
            status.hexpand = true;
            status.valign = Align.CENTER;
            row.append (status);
            box.append (row);

            preview = new TextView ();
            preview.editable = false;
            preview.cursor_visible = false;
            preview.wrap_mode = WrapMode.WORD_CHAR;
            preview.monospace = true;
            preview.top_margin = 8;
            preview.bottom_margin = 8;
            preview.left_margin = 10;
            preview.right_margin = 10;
            preview.add_css_class ("translate-file-preview");
            preview.update_property (Gtk.AccessibleProperty.LABEL, _("Translated file"), -1);
            preview_scroll = new ScrolledWindow ();
            preview_scroll.hscrollbar_policy = PolicyType.NEVER;
            preview_scroll.min_content_height = 240;
            preview_scroll.max_content_height = 240;
            preview_scroll.child = preview;
            preview_scroll.add_css_class ("translate-file-preview");
            preview_scroll.visible = false;
            box.append (preview_scroll);

            var buttons = new Box (Orientation.HORIZONTAL, 12);
            buttons.halign = Align.END;
            buttons.margin_top = 8;
            close_button = new Button.with_label (_("Cancel"));
            close_button.add_css_class ("pill");
            close_button.clicked.connect (() => close_dialog ());
            set_cancel_button (close_button);
            buttons.append (close_button);
            retry_button = new Button.with_label (_("Try Again"));
            retry_button.add_css_class ("pill");
            retry_button.visible = false;
            retry_button.clicked.connect (() => run_job.begin ());
            buttons.append (retry_button);
            save_button = new Button.with_label (_("Save As…"));
            save_button.add_css_class ("pill");
            save_button.add_css_class ("suggested-action");
            save_button.visible = false;
            save_button.clicked.connect (() => save_as ());
            buttons.append (save_button);
            box.append (buttons);
            content_box.append (box);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((val, code, state) => {
                if (val == Gdk.Key.s && (state & Gdk.ModifierType.CONTROL_MASK) != 0 && save_button.visible) {
                    save_as ();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);
        }

        public override void close_dialog () {
            if (cancel != null) cancel.cancel ();
            base.close_dialog ();
        }

        public void start () {
            load.begin ();
        }

        public static string decode (uint8[] data) {
            var sb = new StringBuilder.sized (data.length + 1);
            if (data.length > 0) sb.append_len ((string) data, data.length);
            string text = sb.str;
            if (text.has_prefix ("\xef\xbb\xbf")) text = text.substring (3);
            if (text.validate ()) return text;
            try {
                return convert (text, text.length, "UTF-8", "WINDOWS-1252");
            } catch (Error e) {
                return text.make_valid ();
            }
        }

        private void fail (string message) {
            running = false;
            status.label = message;
            status.add_css_class ("error");
            close_button.label = _("Close");
        }

        private async void load () {
            if (source_code == target_code) {
                fail (_("The text is already in %s. Choose another language to translate to.").printf (Languages.name_for (Languages.builtin (), target_code)));
                return;
            }
            uint8[] data;
            try {
                var info = yield file.query_info_async (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                if (info.get_size () > MAX_BYTES) {
                    fail (_("The file is too large. Files up to %s can be translated.").printf (format_size (MAX_BYTES)));
                    return;
                }
                yield file.load_contents_async (null, out data, null);
            } catch (Error e) {
                fail (_("The file could not be read: %s").printf (e.message));
                return;
            }
            string text = decode (data);
            var segments = Formats.is_markdown (file.get_basename ()) ? Formats.markdown (text) : Formats.plain (text);
            job = new DocumentJob (segments, backend.request_limit);
            if (job.request_count == 0) {
                fail (_("There is no text to translate in this file."));
                return;
            }
            job.progress.connect (update_progress);
            yield run_job ();
        }

        private void update_progress () {
            if (job == null) return;
            int total = int.max (job.total, 1);
            progress.fraction = (double) job.done / total;
            status.label = _("Translating part %d of %d").printf (int.min (job.done + 1, job.total), job.total);
        }

        private async void run_job () {
            if (job == null || running) return;
            running = true;
            status.remove_css_class ("error");
            retry_button.visible = false;
            close_button.label = _("Cancel");
            cancel = new Cancellable ();
            update_progress ();
            try {
                yield job.run (backend, source_code, target_code, cancel);
            } catch (IOError.CANCELLED e) {
                running = false;
                return;
            } catch (Error e) {
                fail (_("Translation stopped: %s").printf (e.message));
                retry_button.visible = true;
                return;
            }
            running = false;
            result = job.assemble ();
            progress.fraction = 1;
            if (source_code == "auto" && job.detected != "") pair.label = _("%s to %s").printf (Languages.name_for (Languages.builtin (), job.detected), target_name);
            status.label = ngettext ("Translated in %d part. Review it, then save it.", "Translated in %d parts. Review it, then save it.", job.total).printf (job.total);
            preview.buffer.text = result;
            preview_scroll.visible = true;
            save_button.visible = true;
            close_button.label = _("Close");
            save_button.grab_focus ();
        }

        public static string suggested_name (string basename, string target) {
            int dot = basename.last_index_of (".");
            if (dot <= 0) return basename + "." + target;
            return basename.substring (0, dot) + "." + target + basename.substring (dot);
        }

        private void save_as () {
            var dialog = new FileDialog ();
            dialog.title = _("Save Translation");
            dialog.initial_name = suggested_name (file.get_basename (), target_code);
            var parent = file.get_parent ();
            if (parent != null) dialog.initial_folder = parent;
            dialog.save.begin (this, null, (o, res) => {
                try {
                    var dest = dialog.save.end (res);
                    dest.replace_contents_bytes_async.begin (new Bytes (result.data), null, false, FileCreateFlags.REPLACE_DESTINATION, null, (o2, r2) => {
                        try {
                            dest.replace_contents_bytes_async.end (r2, null);
                            status.remove_css_class ("error");
                            status.label = _("Saved as %s").printf (dest.get_basename ());
                        } catch (Error e) {
                            status.add_css_class ("error");
                            status.label = _("The file could not be saved: %s").printf (e.message);
                        }
                    });
                } catch (Error e) {
                }
            });
        }
    }

    public class QuickTranslateDialog : AppDialog {
        private TranslateApp app;
        private Config config;
        private Label pair;
        private Label source_label;
        private Label result_label;
        private ScrolledWindow result_scroll;
        private Stack stack;
        private Label problem;
        private Button copy_button;
        private Button open_button;
        private string text = "";
        private string translation = "";
        private string detected = "";
        private Cancellable cancel = new Cancellable ();
        private bool started;

        public QuickTranslateDialog (TranslateApp app) {
            base (app, false);
            this.app = app;
            config = app.config;
            set_title (_("Quick Translation"));
            set_default_size (480, 0);

            var box = new Box (Orientation.VERTICAL, 10);
            box.margin_top = 16;
            box.margin_bottom = 22;
            box.margin_start = 24;
            box.margin_end = 24;

            pair = new Label ("");
            pair.xalign = 0;
            pair.add_css_class ("caption");
            pair.add_css_class ("dim-label");
            box.append (pair);

            source_label = new Label ("");
            source_label.xalign = 0;
            source_label.wrap = true;
            source_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            source_label.lines = 3;
            source_label.ellipsize = Pango.EllipsizeMode.END;
            source_label.add_css_class ("dim-label");
            box.append (source_label);

            var loading = new Box (Orientation.HORIZONTAL, 10);
            loading.halign = Align.CENTER;
            var spinner = new Spinner ();
            spinner.spinning = true;
            loading.append (spinner);
            var wait = new Label (_("Translating…"));
            wait.add_css_class ("dim-label");
            loading.append (wait);

            result_label = new Label ("");
            result_label.xalign = 0;
            result_label.yalign = 0;
            result_label.wrap = true;
            result_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            result_label.selectable = true;
            result_label.add_css_class ("translate-quick-result");
            result_scroll = new ScrolledWindow ();
            result_scroll.hscrollbar_policy = PolicyType.NEVER;
            result_scroll.propagate_natural_height = true;
            result_scroll.max_content_height = 320;
            result_scroll.child = result_label;

            problem = new Label ("");
            problem.wrap = true;
            problem.xalign = 0;
            problem.add_css_class ("error");

            stack = new Stack ();
            stack.vhomogeneous = false;
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named (loading, "loading");
            stack.add_named (result_scroll, "result");
            stack.add_named (problem, "problem");
            stack.margin_top = 6;
            box.append (stack);

            var buttons = new Box (Orientation.HORIZONTAL, 12);
            buttons.halign = Align.END;
            buttons.margin_top = 10;
            open_button = new Button.with_label (_("Open in Translate"));
            open_button.add_css_class ("pill");
            open_button.clicked.connect (() => {
                app.show_in_window (text, translation, config.source, config.target);
                close_dialog ();
            });
            buttons.append (open_button);
            copy_button = new Button.with_label (_("Copy"));
            copy_button.add_css_class ("pill");
            copy_button.add_css_class ("suggested-action");
            copy_button.sensitive = false;
            copy_button.clicked.connect (() => copy ());
            buttons.append (copy_button);
            box.append (buttons);
            content_box.append (box);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((val, code, state) => {
                if (val == Gdk.Key.c && (state & Gdk.ModifierType.CONTROL_MASK) != 0 && copy_button.sensitive && !result_label.get_selection_bounds (null, null)) {
                    copy ();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);
            close_request.connect (() => {
                cancel.cancel ();
                return false;
            });
            map.connect (() => {
                if (started) return;
                started = true;
                Timeout.add (120, () => {
                    read_clipboard ();
                    return Source.REMOVE;
                });
            });
            sync_pair ();
        }

        private string name_of (string code) {
            return Languages.name_for (Languages.builtin (), code);
        }

        private void sync_pair () {
            string from;
            if (config.source == "auto") from = detected != "" ? _("%s (Detected)").printf (name_of (detected)) : _("Detect Language");
            else from = name_of (config.source);
            pair.label = _("%s to %s").printf (from, name_of (config.target));
        }

        private void copy () {
            if (translation == "") return;
            get_clipboard ().set_text (translation);
            copy_button.label = _("Copied");
            Timeout.add (1500, () => {
                copy_button.label = _("Copy");
                return Source.REMOVE;
            });
        }

        private void show_result (string value) {
            result_label.label = value;
            int width = stack.get_width () > 0 ? stack.get_width () : 432;
            int min, nat, mb, nb;
            result_label.measure (Orientation.VERTICAL, width, out min, out nat, out mb, out nb);
            result_scroll.min_content_height = int.min (nat, 320);
            stack.visible_child_name = "result";
            copy_button.sensitive = true;
        }

        private void show_problem (string message) {
            problem.label = message;
            stack.visible_child_name = "problem";
            copy_button.sensitive = false;
        }

        public void read_clipboard () {
            var clip = get_clipboard ();
            clip.read_text_async.begin (null, (o, res) => {
                string? value = null;
                try {
                    value = clip.read_text_async.end (res);
                } catch (Error e) {
                    value = null;
                }
                if (value == null || value.strip () == "") {
                    source_label.label = "";
                    source_label.visible = false;
                    open_button.visible = false;
                    show_problem (_("The clipboard has no text. Copy some text, then try again."));
                    return;
                }
                translate_text.begin (value.strip ());
            });
        }

        public async void translate_text (string value) {
            text = value;
            source_label.label = text;
            source_label.visible = true;
            open_button.visible = true;
            stack.visible_child_name = "loading";
            if (config.source == config.target) {
                translation = text;
                show_result (text);
                return;
            }
            var backend = Backend.create (config.backend);
            backend.instance = config.instance_for (backend.id);
            if (backend.id == "libretranslate") backend.api_key = yield Keys.lookup (backend.instance);
            yield backend.refresh_limits (cancel);
            if (cancel.is_cancelled ()) return;
            try {
                translation = yield run (backend, text);
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                bool fallback = config.fallback && backend.id != "mymemory" && text.char_count () <= 500
                    && (e is TranslateError.UNREACHABLE || e is TranslateError.RATE_LIMITED || e is TranslateError.AUTH);
                if (!fallback) {
                    show_problem (e.message);
                    return;
                }
                try {
                    translation = yield run (new MyMemoryBackend (), text);
                } catch (Error e2) {
                    if (!(e2 is IOError.CANCELLED)) show_problem (e.message);
                    return;
                }
            }
            show_result (translation);
            copy_button.grab_focus ();
            sync_pair ();
            if (config.keep_history) {
                var h = new HistoryEntry ();
                h.source = config.source == "auto" && detected != "" ? detected : config.source;
                h.target = config.target;
                h.text = text;
                h.translation = translation;
                h.time = new DateTime.now_utc ().to_unix ();
                app.history.add (h);
            }
        }

        private async string run (Backend backend, string value) throws Error {
            var job = new DocumentJob (Formats.plain (value), backend.request_limit);
            yield job.run (backend, config.source, config.target, cancel);
            if (job.detected != "" && job.detected != "auto") detected = job.detected.split ("-")[0];
            return job.assemble ().strip ();
        }
    }
}
