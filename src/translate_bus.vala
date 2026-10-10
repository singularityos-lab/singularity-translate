namespace Singularity.Apps.Translate {

    [DBus (name = "dev.sinty.Translate1")]
    public class TranslateBus : Object {
        private unowned GLib.Application app;

        public TranslateBus (GLib.Application app) {
            this.app = app;
        }

        public void translate (string text) throws Error {
            app.activate_action ("translate-text", new Variant.string (text));
        }
    }
}
