using Gtk;
using Singularity;

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Plugin), typeof (TranslateTilePlugin));
}

public class TranslateTilePlugin : Object, Singularity.Plugin {
    private const string NOTIFICATIONS = "org.freedesktop.Notifications";
    private const string NOTIFICATIONS_PATH = "/org/freedesktop/Notifications";
    private const int MAX_CHARS = 5000;

    private PluginContext context;
    private QuickTile tile;
    private DBusConnection? bus;
    private uint action_sub;
    private uint closed_sub;
    private uint notice_id;
    private string text = "";
    private string translation = "";
    private string detected = "";
    private bool busy;

    public void activate (PluginContext context) {
        this.context = context;
        tile = new QuickTile ("dev.sinty.translate.clipboard", _("Translate"), "preferences-desktop-locale-symbolic");
        tile.toggleable = false;
        tile.subtitle = _("Clipboard");
        tile.clicked.connect (() => run.begin ());
        context.add_quick_tile (tile);
        try {
            bus = Bus.get_sync (BusType.SESSION);
            action_sub = bus.signal_subscribe (NOTIFICATIONS, NOTIFICATIONS, "ActionInvoked", NOTIFICATIONS_PATH,
                null, DBusSignalFlags.NONE, on_action);
            closed_sub = bus.signal_subscribe (NOTIFICATIONS, NOTIFICATIONS, "NotificationClosed", NOTIFICATIONS_PATH,
                null, DBusSignalFlags.NONE, on_closed);
        } catch (Error e) {
            warning ("translate tile: %s", e.message);
        }
    }

    public void deactivate () {
        context.remove_quick_tile (tile);
        if (bus != null) {
            if (action_sub != 0) bus.signal_unsubscribe (action_sub);
            if (closed_sub != 0) bus.signal_unsubscribe (closed_sub);
        }
        action_sub = 0;
        closed_sub = 0;
        text = "";
        translation = "";
    }

    public Gtk.Widget? get_settings_widget () {
        return null;
    }

    private async void run () {
        if (busy) return;
        var display = Gdk.Display.get_default ();
        if (display == null) return;
        string? copied = null;
        try {
            copied = yield display.get_clipboard ().read_text_async (null);
        } catch (Error e) {
            copied = null;
        }
        if (copied == null || copied.strip () == "") {
            yield send_notice (_("Nothing to Translate"), _("Copy some text first, then use the tile again."), false);
            return;
        }
        text = copied.strip ();
        if (text.char_count () > MAX_CHARS) text = text.substring (0, text.index_of_nth_char (MAX_CHARS));
        busy = true;
        tile.active = true;
        tile.subtitle = _("Translating…");
        try {
            string provider;
            translation = yield Singularity.Apps.Translate.ServiceClient.translate (text, "auto", "", out detected, out provider);
            yield send_notice (_("Translation"), translation, true);
        } catch (Error e) {
            translation = "";
            yield send_notice (_("Could Not Translate"), Singularity.Apps.Translate.ServiceClient.error_text (e), false);
        }
        busy = false;
        tile.active = false;
        tile.subtitle = _("Clipboard");
    }

    private async void send_notice (string summary, string body, bool with_actions) {
        if (bus == null) return;
        string[] actions = {};
        if (with_actions) actions = { "copy", _("Copy"), "open", _("Open in Translate") };
        var hints = new VariantBuilder (new VariantType ("a{sv}"));
        hints.add ("{sv}", "desktop-entry", new Variant.string ("dev.sinty.translate"));
        string shown = body.char_count () > 600 ? body.substring (0, body.index_of_nth_char (600)) + "…" : body;
        try {
            var args = new Variant.tuple ({
                new Variant.string (_("Translate")), new Variant.uint32 (notice_id), new Variant.string ("dev.sinty.translate"),
                new Variant.string (summary), new Variant.string (shown), new Variant.strv (actions), hints.end (), new Variant.int32 (-1)
            });
            var reply = yield bus.call (NOTIFICATIONS, NOTIFICATIONS_PATH, NOTIFICATIONS, "Notify", args,
                new VariantType ("(u)"), DBusCallFlags.NONE, 5000, null);
            reply.get ("(u)", out notice_id);
        } catch (Error e) {
            warning ("translate tile: %s", e.message);
        }
    }

    private void on_action (DBusConnection connection, string? sender, string path, string iface, string name, Variant parameters) {
        uint id;
        string key;
        parameters.get ("(us)", out id, out key);
        if (id != notice_id || translation == "") return;
        if (key == "copy") {
            var display = Gdk.Display.get_default ();
            if (display != null) display.get_clipboard ().set_text (translation);
        } else if (key == "open") {
            var args = new Variant ("(ssss)", text, translation, detected != "" ? detected : "auto", "");
            var call = new Variant.tuple ({
                new Variant.string ("show-text"), new Variant.array (VariantType.VARIANT, { new Variant.variant (args) }),
                new Variant.array (new VariantType ("{sv}"), {})
            });
            bus.call.begin ("dev.sinty.translate", "/dev/sinty/translate", "org.freedesktop.Application", "ActivateAction",
                call, null, DBusCallFlags.NONE, 10000, null);
        }
    }

    private void on_closed (DBusConnection connection, string? sender, string path, string iface, string name, Variant parameters) {
        uint id;
        uint reason;
        parameters.get ("(uu)", out id, out reason);
        if (id != notice_id) return;
        notice_id = 0;
        text = "";
        translation = "";
    }
}
