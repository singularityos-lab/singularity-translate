using Gtk;
using Singularity;

namespace SingularityTranslateWidget {

    public class QuickProvider : Object, OverviewWidgetProvider {
        public string id { get { return "translate.quick"; } }
        public string provider_id { get { return "dev.sinty.translate"; } }
        public string display_name { get { return _("Quick Translation"); } }
        public string icon_name { get { return "preferences-desktop-locale-symbolic"; } }
        public WidgetSize[] supported_sizes {
            get {
                if (_sizes == null) {
                    _sizes = new WidgetSize[3];
                    _sizes[0] = WidgetSize (2, 2);
                    _sizes[1] = WidgetSize (4, 2);
                    _sizes[2] = WidgetSize (4, 4);
                }
                return _sizes;
            }
        }
        private WidgetSize[] _sizes;

        public Gtk.Widget create_instance (string instance_id, WidgetSize size, Variant? config) {
            string target = config != null && config.is_of_type (VariantType.STRING) ? config.get_string () : "";
            return new QuickInstance (target);
        }

        public bool can_configure (string instance_id) {
            return true;
        }

        public void configure_instance (string instance_id) {
            var registry = OverviewWidgetRegistry.get_default ();
            Variant? current = registry.get_instance_config (instance_id);
            string target = current != null && current.is_of_type (VariantType.STRING) ? current.get_string () : "";
            Singularity.Apps.Translate.ServiceClient.language_names.begin ((o, res) => {
                HashTable<string, string> names;
                try {
                    names = Singularity.Apps.Translate.ServiceClient.language_names.end (res);
                } catch (Error e) {
                    warning ("translate widget: %s", e.message);
                    return;
                }
                show_dialog (instance_id, target, names);
            });
        }

        private void show_dialog (string instance_id, string target, HashTable<string, string> names) {
            var dialog = new Singularity.Shell.ShellDialog.anchored (GLib.Application.get_default (), true, true, true, true);
            var box = new Box (Orientation.VERTICAL, 16);
            box.set_size_request (380, -1);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            var auto_option = new Singularity.Core.AppSettingOption ();
            auto_option.id = "";
            auto_option.label = _("Same as Translate");
            options.add (auto_option);
            var codes = new Gee.ArrayList<string> ();
            names.foreach ((code, name) => codes.add (code));
            codes.sort ((a, b) => names[a].collate (names[b]));
            foreach (string code in codes) {
                var opt = new Singularity.Core.AppSettingOption ();
                opt.id = code;
                opt.label = names[code];
                options.add (opt);
            }
            var group = new Singularity.Widgets.PreferencesGroup ();
            group.title = _("Quick Translation");
            var row = new Singularity.Widgets.SelectionRow.with_options (_("Translate To"), options, target);
            string chosen = target;
            row.selected.connect ((item) => chosen = item);
            group.add_row (row);
            box.append (group);

            var buttons = new Box (Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            var cancel = new Button.with_label (_("Cancel"));
            cancel.clicked.connect (() => dialog.close_dialog ());
            buttons.append (cancel);
            var save = new Button.with_label (_("Save"));
            save.add_css_class ("suggested-action");
            save.clicked.connect (() => {
                OverviewWidgetRegistry.get_default ().save_instance_config (instance_id, chosen != "" ? new Variant.string (chosen) : null);
                dialog.close_dialog ();
            });
            buttons.append (save);
            box.append (buttons);
            dialog.content_box.append (box);
            dialog.present ();
        }
    }

    public class QuickInstance : Box {
        private string target;
        private Label pair;
        private Entry entry;
        private Label result;
        private Label detail;
        private Button copy;
        private Spinner spinner;
        private HashTable<string, string>? names;
        private uint generation;

        public QuickInstance (string target) {
            Object (orientation: Orientation.VERTICAL, spacing: 8);
            this.target = target;
            add_css_class ("overview-widget-card");
            hexpand = true;
            vexpand = true;
            overflow = Overflow.HIDDEN;

            var inner = new Box (Orientation.VERTICAL, 8);
            inner.margin_top = 12;
            inner.margin_bottom = 12;
            inner.margin_start = 14;
            inner.margin_end = 14;
            inner.vexpand = true;
            append (inner);

            var head = new Box (Orientation.HORIZONTAL, 8);
            var title = new Label (_("Translate"));
            title.add_css_class ("heading");
            title.xalign = 0;
            title.hexpand = true;
            head.append (title);
            pair = new Label ("");
            pair.add_css_class ("dim-label");
            pair.add_css_class ("caption");
            pair.ellipsize = Pango.EllipsizeMode.END;
            head.append (pair);
            inner.append (head);

            entry = new Entry ();
            entry.placeholder_text = _("Type and press Enter");
            entry.activate.connect (() => run ());
            inner.append (entry);

            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            result = new Label (_("The translation appears here"));
            result.add_css_class ("dim-label");
            result.wrap = true;
            result.wrap_mode = Pango.WrapMode.WORD_CHAR;
            result.xalign = 0;
            result.yalign = 0;
            result.selectable = true;
            result.valign = Align.START;
            scroll.child = result;
            inner.append (scroll);

            var foot = new Box (Orientation.HORIZONTAL, 6);
            detail = new Label ("");
            detail.add_css_class ("dim-label");
            detail.add_css_class ("caption");
            detail.xalign = 0;
            detail.hexpand = true;
            detail.ellipsize = Pango.EllipsizeMode.END;
            foot.append (detail);
            spinner = new Spinner ();
            spinner.visible = false;
            foot.append (spinner);
            copy = new Button.from_icon_name ("edit-copy-symbolic");
            copy.tooltip_text = _("Copy");
            copy.update_property (AccessibleProperty.LABEL, _("Copy"), -1);
            copy.add_css_class ("flat");
            copy.add_css_class ("circular");
            copy.sensitive = false;
            copy.clicked.connect (() => {
                get_clipboard ().set_text (result.label);
                detail.label = _("Copied");
            });
            foot.append (copy);
            inner.append (foot);

            load_names.begin ();
        }

        private async void load_names () {
            try {
                names = yield Singularity.Apps.Translate.ServiceClient.language_names ();
                if (target == "") target = yield Singularity.Apps.Translate.ServiceClient.default_target ();
            } catch (Error e) {
                detail.label = Singularity.Apps.Translate.ServiceClient.error_text (e);
            }
            pair.label = target != "" ? _("To %s").printf (name_for (target)) : "";
        }

        private string name_for (string code) {
            if (names != null && names.contains (code)) return names[code];
            return code;
        }

        private void run () {
            string text = entry.text.strip ();
            if (text == "") return;
            uint gen = ++generation;
            spinner.visible = true;
            spinner.spinning = true;
            copy.sensitive = false;
            detail.label = _("Translating…");
            Singularity.Apps.Translate.ServiceClient.translate.begin (text, "auto", target, (o, res) => {
                if (gen != generation) return;
                spinner.spinning = false;
                spinner.visible = false;
                try {
                    string detected, provider;
                    string translation = Singularity.Apps.Translate.ServiceClient.translate.end (res, out detected, out provider);
                    result.label = translation;
                    result.remove_css_class ("dim-label");
                    copy.sensitive = translation != "";
                    detail.label = detected != "" && detected != "auto" ? _("From %s").printf (name_for (detected)) : provider;
                } catch (Error e) {
                    result.label = _("Could not translate");
                    result.add_css_class ("dim-label");
                    detail.label = Singularity.Apps.Translate.ServiceClient.error_text (e);
                }
            });
        }
    }

    [CCode (cname = "singularity_translate_widget_new")]
    public static Object singularity_translate_widget_new () {
        return new QuickProvider ();
    }
}
