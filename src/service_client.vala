namespace Singularity.Apps.Translate.ServiceClient {

    private const string BUS_NAME = "dev.sinty.TranslateService";
    private const string OBJECT_PATH = "/dev/sinty/TranslateService";

    public async string translate (string text, string source, string target, out string detected, out string provider) throws Error {
        var bus = yield Bus.get (BusType.SESSION);
        var reply = yield bus.call (BUS_NAME, OBJECT_PATH, BUS_NAME, "Translate",
            new Variant ("(sss)", text, source, target), new VariantType ("(sss)"),
            DBusCallFlags.NONE, 30000, null);
        string translation;
        reply.get ("(sss)", out translation, out detected, out provider);
        return translation;
    }

    public async HashTable<string, string> language_names () throws Error {
        var bus = yield Bus.get (BusType.SESSION);
        var reply = yield bus.call (BUS_NAME, OBJECT_PATH, BUS_NAME, "LanguageNames",
            null, new VariantType ("(a{ss})"), DBusCallFlags.NONE, 5000, null);
        var names = new HashTable<string, string> (str_hash, str_equal);
        var iter = reply.get_child_value (0).iterator ();
        string code, name;
        while (iter.next ("{ss}", out code, out name)) names[code] = name;
        return names;
    }

    public async string default_target () throws Error {
        var bus = yield Bus.get (BusType.SESSION);
        var reply = yield bus.call (BUS_NAME, OBJECT_PATH, BUS_NAME, "DefaultTarget",
            null, new VariantType ("(s)"), DBusCallFlags.NONE, 5000, null);
        string target;
        reply.get ("(s)", out target);
        return target;
    }

    public string error_text (Error e) {
        DBusError.strip_remote_error (e);
        return e.message;
    }
}
