using Singularity.Apps.Translate;

string fixtures;

string fixture (string name) {
    string text;
    try {
        FileUtils.get_contents (Path.build_filename (fixtures, name), out text);
    } catch (Error e) {
        error ("fixture %s: %s", name, e.message);
    }
    return text;
}

void expect_error (string name, Error? e, int code) {
    if (e == null) error ("%s: expected an error", name);
    if (!(e is TranslateError) || e.code != code) error ("%s: wrong error %s (%d)", name, e.message, e.code);
}


class FakeBackend : Backend {
    public int limit = 60;
    public bool drop_newlines;
    public int calls;
    public int longest;
    public Gee.ArrayList<string> seen = new Gee.ArrayList<string> ();
    public override string id { get { return "fake"; } }
    public override string title { get { return "Fake"; } }
    public override int char_limit { get { return limit; } }

    public override async Gee.List<Language> languages (Cancellable? cancel) throws Error {
        return Languages.builtin ();
    }

    public override async Translation translate (string text, string source, string target, Cancellable? cancel) throws Error {
        calls++;
        seen.add (text);
        if (text.char_count () > limit) throw new TranslateError.TOO_LONG ("too long: %d".printf (text.char_count ()));
        longest = int.max (longest, text.char_count ());
        Idle.add (translate.callback);
        yield;
        var t = new Translation ();
        t.text = drop_newlines ? text.up ().replace ("\n", " ") : text.up ();
        t.detected = "en";
        return t;
    }
}

string run_job (DocumentJob job, FakeBackend b) {
    var loop = new MainLoop ();
    Error? failure = null;
    job.run.begin (b, "auto", "it", null, (o, res) => {
        try {
            job.run.end (res);
        } catch (Error e) {
            failure = e;
        }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) error ("job failed: %s", failure.message);
    return job.assemble ();
}

string kept_text (Gee.List<Segment> segs) {
    var sb = new StringBuilder ();
    foreach (var s in segs) sb.append (s.text);
    return sb.str;
}

bool has_segment (Gee.List<Segment> segs, string text, bool translatable) {
    foreach (var s in segs) if (s.text == text && s.translatable == translatable) return true;
    return false;
}

bool fixed_contains (Gee.List<Segment> segs, string needle) {
    foreach (var s in segs) if (!s.translatable && s.text.contains (needle)) return true;
    return false;
}

bool translatable_contains (Gee.List<Segment> segs, string needle) {
    foreach (var s in segs) if (s.translatable && s.text.contains (needle)) return true;
    return false;
}

void main (string[] args) {
    Test.init (ref args);
    fixtures = args.length > 1 ? args[1] : "tests/fixtures";

    Test.add_func ("/libre/languages", () => {
        try {
            var list = LibreTranslateBackend.parse_languages (fixture ("libre_languages.json"));
            assert (list.size == 4);
            assert (list[0].code == "en" && list[0].name == "English");
            assert (list[2].code == "zh-Hans" && list[2].name == "Chinese (Simplified)");
            assert (list[3].code == "de");
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/libre/languages-error", () => {
        Error? err = null;
        try {
            LibreTranslateBackend.parse_languages (fixture ("libre_error_key.json"));
        } catch (Error e) {
            err = e;
        }
        expect_error ("languages-error", err, TranslateError.FAILED);
        assert (err.message.contains ("API key"));
        err = null;
        try {
            LibreTranslateBackend.parse_languages (fixture ("broken.txt"));
        } catch (Error e) {
            err = e;
        }
        expect_error ("languages-broken", err, TranslateError.FAILED);
    });
    Test.add_func ("/libre/translation", () => {
        try {
            var t = LibreTranslateBackend.parse_translation (fixture ("libre_translate.json"));
            assert (t.text == "Ciao, mondo!");
            assert (t.detected == "en");
            var p = LibreTranslateBackend.parse_translation (fixture ("libre_translate_plain.json"));
            assert (p.text == "Guten Morgen");
            assert (p.detected == "");
        } catch (Error e) {
            error (e.message);
        }
        Error? err = null;
        try {
            LibreTranslateBackend.parse_translation (fixture ("libre_error_key.json"));
        } catch (Error e) {
            err = e;
        }
        expect_error ("translation-error", err, TranslateError.FAILED);
        assert (LibreTranslateBackend.parse_error (fixture ("libre_error_key.json")).has_prefix ("Visit"));
        assert (LibreTranslateBackend.parse_error (fixture ("broken.txt")) == null);
        assert (LibreTranslateBackend.parse_error (fixture ("libre_translate.json")) == null);
    });
    Test.add_func ("/libre/limits", () => {
        assert (LibreTranslateBackend.parse_char_limit (fixture ("libre_settings.json")) == 2000);
        assert (LibreTranslateBackend.parse_char_limit (fixture ("libre_settings_unlimited.json")) == -1);
        assert (LibreTranslateBackend.parse_char_limit (fixture ("broken.txt")) == -1);
    });
    Test.add_func ("/libre/request", () => {
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (LibreTranslateBackend.build_request ("Say \"hi\"\n", "auto", "it", ""));
            var o = parser.get_root ().get_object ();
            assert (o.get_string_member ("q") == "Say \"hi\"\n");
            assert (o.get_string_member ("source") == "auto");
            assert (o.get_string_member ("target") == "it");
            assert (o.get_string_member ("format") == "text");
            assert (!o.has_member ("api_key"));
            parser.load_from_data (LibreTranslateBackend.build_request ("x", "en", "de", "k-123"));
            assert (parser.get_root ().get_object ().get_string_member ("api_key") == "k-123");
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/lingva/languages", () => {
        try {
            var list = LingvaBackend.parse_languages (fixture ("lingva_languages.json"));
            assert (list.size == 4);
            foreach (var l in list) assert (l.code != "auto");
            assert (list[3].code == "zh_HANT");
        } catch (Error e) {
            error (e.message);
        }
    });
    Test.add_func ("/lingva/translation", () => {
        try {
            var t = LingvaBackend.parse_translation (fixture ("lingva_translate.json"));
            assert (t.text == "Buongiorno a tutti");
            assert (t.detected == "en");
        } catch (Error e) {
            error (e.message);
        }
        Error? err = null;
        try {
            LingvaBackend.parse_translation (fixture ("lingva_error.json"));
        } catch (Error e) {
            err = e;
        }
        expect_error ("lingva-error", err, TranslateError.FAILED);
        assert (err.message == "Invalid target language");
    });
    Test.add_func ("/lingva/audio", () => {
        try {
            var bytes = LingvaBackend.parse_audio (fixture ("lingva_audio.json"));
            assert (bytes.get_size () == 14);
            assert (bytes.get_data ()[0] == 'I' && bytes.get_data ()[1] == 'D' && bytes.get_data ()[2] == '3');
        } catch (Error e) {
            error (e.message);
        }
        Error? err = null;
        try {
            LingvaBackend.parse_audio (fixture ("lingva_audio_bad.json"));
        } catch (Error e) {
            err = e;
        }
        expect_error ("audio-bad", err, TranslateError.FAILED);
    });
    Test.add_func ("/lingva/paths", () => {
        assert (LingvaBackend.translate_path ("auto", "it", "a/b c?") == "/api/v1/auto/it/a%2Fb%20c%3F");
        assert (LingvaBackend.audio_path ("en", "hi #1") == "/api/v1/audio/en/hi%20%231");
        assert (LingvaBackend.translate_path ("en", "de", "caffè") == "/api/v1/en/de/caff%C3%A8");
    });
    Test.add_func ("/mymemory/translation", () => {
        try {
            var t = MyMemoryBackend.parse_translation (fixture ("mymemory_ok.json"));
            assert (t.text == "L'albero & il \"fiore\"");
            assert (t.detected == "en");
        } catch (Error e) {
            error (e.message);
        }
        Error? err = null;
        try {
            MyMemoryBackend.parse_translation (fixture ("mymemory_quota.json"));
        } catch (Error e) {
            err = e;
        }
        expect_error ("quota", err, TranslateError.RATE_LIMITED);
        err = null;
        try {
            MyMemoryBackend.parse_translation (fixture ("mymemory_badpair.json"));
        } catch (Error e) {
            err = e;
        }
        expect_error ("badpair", err, TranslateError.FAILED);
        assert (err.message.contains ("INVALID TARGET"));
    });
    Test.add_func ("/mymemory/url", () => {
        assert (MyMemoryBackend.translate_url ("Hello world!", "en", "it") == MyMemoryBackend.ENDPOINT + "?q=Hello%20world%21&langpair=en%7Cit");
        assert (MyMemoryBackend.translate_url ("a&b", "auto", "de") == MyMemoryBackend.ENDPOINT + "?q=a%26b&langpair=Autodetect%7Cde");
    });
    Test.add_func ("/mymemory/entities", () => {
        assert (MyMemoryBackend.decode_entities ("plain") == "plain");
        assert (MyMemoryBackend.decode_entities ("&lt;b&gt; &#233;t&#xE9; &unknown; & done") == "<b> été &unknown; & done");
    });
    Test.add_func ("/http/errors", () => {
        expect_error ("429", Http.status_error (429, null, "S"), TranslateError.RATE_LIMITED);
        expect_error ("403", Http.status_error (403, "bad key", "S"), TranslateError.AUTH);
        expect_error ("502", Http.status_error (502, null, "S"), TranslateError.UNREACHABLE);
        expect_error ("404", Http.status_error (404, null, "S"), TranslateError.UNREACHABLE);
        expect_error ("413", Http.status_error (413, null, "S"), TranslateError.TOO_LONG);
        expect_error ("400", Http.status_error (400, "Invalid request", "S"), TranslateError.FAILED);
        assert (Http.status_error (400, "Invalid request", "S").message == "Invalid request");
    });
    Test.add_func ("/http/instance", () => {
        assert (Http.normalize_instance (" translate.example.org/ ") == "https://translate.example.org");
        assert (Http.normalize_instance ("http://10.0.0.2:5000//") == "http://10.0.0.2:5000");
        assert (Http.normalize_instance ("") == "");
        assert (Http.host_of ("https://lingva.example/api") == "lingva.example");
    });
    Test.add_func ("/languages/names", () => {
        var list = Languages.builtin ();
        assert (list.size > 60);
        assert (Languages.name_for (list, "it") == "Italian");
        assert (Languages.name_for (list, "pt-BR") == "Portuguese");
        assert (Languages.name_for (list, "xx") == "xx");
    });
    Test.add_func ("/history/merge", () => {
        string dir;
        try {
            dir = DirUtils.make_tmp ("translate-XXXXXX");
        } catch (Error e) {
            error (e.message);
        }
        string file = Path.build_filename (dir, "h.json");
        var h = new History (file);
        var a = new HistoryEntry ();
        a.source = "en"; a.target = "it"; a.text = "Hel"; a.translation = "Hel"; a.time = 1000;
        h.add (a);
        var b = new HistoryEntry ();
        b.source = "en"; b.target = "it"; b.text = "Hello"; b.translation = "Ciao"; b.time = 1010;
        h.add (b);
        assert (h.items.size == 1 && h.items[0].text == "Hello");
        var c = new HistoryEntry ();
        c.source = "en"; c.target = "de"; c.text = "Hello"; c.translation = "Hallo"; c.time = 5000;
        h.add (c);
        var d = new HistoryEntry ();
        d.source = "en"; d.target = "it"; d.text = "Hello"; d.translation = "Ciao"; d.time = 6000;
        h.add (d);
        assert (h.items.size == 2 && h.items[0].target == "it" && h.items[1].target == "de");
        var empty = new HistoryEntry ();
        empty.target = "it";
        h.add (empty);
        assert (h.items.size == 2);
        for (int i = 0; i < History.MAX + 5; i++) {
            var e = new HistoryEntry ();
            e.source = "en"; e.target = "fr"; e.text = "item %d".printf (i); e.translation = "t"; e.time = 100000 + i * 1000;
            h.add (e);
        }
        assert (h.items.size == History.MAX);
        var reload = new History (file);
        assert (reload.items.size == History.MAX);
        assert (reload.items[0].text == "item %d".printf (History.MAX + 4));
        FileUtils.remove (file);
        DirUtils.remove (dir);
    });
    Test.add_func ("/config/migrate", () => {
        string dir;
        try {
            dir = DirUtils.make_tmp ("translate-XXXXXX");
        } catch (Error e) {
            error (e.message);
        }
        string file = Path.build_filename (dir, "c.json");
        var c = new Config (file);
        assert (c.backend == "libretranslate" && c.source == "auto" && c.target != "");
        try {
            FileUtils.set_contents (file, "{ \"backend\": \"lingva\", \"lingva_instance\": \"lingva.example/\", \"target\": \"ja\", \"live\": false }");
        } catch (Error e) {
            error (e.message);
        }
        var d = new Config (file);
        assert (d.backend == "lingva" && d.instance_for ("lingva") == "https://lingva.example" && d.target == "ja" && !d.live);
        assert (!FileUtils.test (file, FileTest.EXISTS) && FileUtils.test (file + ".migrated", FileTest.EXISTS));
        d.live = true;
        var e = new Config (file);
        assert (e.backend == "lingva" && e.live);
        FileUtils.remove (file + ".migrated");
        DirUtils.remove (dir);
    });

    Test.add_func ("/document/chunker", () => {
        assert (Chunker.split ("short", 10).length == 1);
        assert (Chunker.split ("", 10).length == 1);
        string text = "First sentence here. Second sentence is a bit longer! Third one? Fourth sentence ends the paragraph.\n\nNew paragraph starts here and goes on for a while without stopping at all.";
        foreach (int limit in new int[] { 12, 25, 40, 70, 100 }) {
            var pieces = Chunker.split (text, limit);
            var sb = new StringBuilder ();
            foreach (string p in pieces) {
                assert (p.char_count () <= limit);
                assert (p != "");
                sb.append (p);
            }
            assert (sb.str == text);
        }
        var sentences = Chunker.split (text, 70);
        assert (sentences[0] == "First sentence here. Second sentence is a bit longer! Third one? ");
        var para = Chunker.split (text, 120);
        assert (para[0].has_suffix ("paragraph.\n\n"));
        var hard = Chunker.split ("abcdefghijklmnopqrstuvwxyz", 10);
        assert (hard.length == 3 && hard[0] == "abcdefghij" && hard[2] == "uvwxyz");
        var wide = Chunker.split ("ééééé ééééé ééééé", 7);
        assert (wide[0] == "ééééé " && wide.length == 3);
        var cjk = Chunker.split ("你好世界。今天很好。我们走吧。", 8);
        assert (cjk[0] == "你好世界。" && cjk.length == 3);
    });
    Test.add_func ("/document/markdown", () => {
        string doc = fixture ("docs/guide.md");
        var segs = Formats.markdown (doc);
        assert (kept_text (segs) == doc);
        assert (segs[0].text.has_prefix ("---\ntitle: Getting started") && !segs[0].translatable);
        assert (has_segment (segs, "Getting started", true));
        assert (has_segment (segs, "](https://docs.example.org/install#linux \"Install\")", false));
        assert (has_segment (segs, "installation guide", true));
        assert (translatable_contains (segs, "Welcome to the **project**. Read the "));
        assert (has_segment (segs, "`git`", false));
        assert (fixed_contains (segs, "<https://example.org/faq>"));
        assert (translatable_contains (segs, "First numbered step"));
        assert (translatable_contains (segs, "Second numbered step"));
        assert (translatable_contains (segs, "Unchecked task"));
        assert (translatable_contains (segs, "Nested quote here."));
        foreach (var s in segs) {
            if (!s.translatable) continue;
            foreach (string never in new string[] { "git clone", "do not translate", "indented code block", "images/main.png", "https://", "[faq]", "---", "|", "- [", "# ", "> ", "1. ", "2) ", "===", "<span", "Frequently asked" }) {
                if (s.text.contains (never)) error ("translatable segment contains %s: %s", never, s.text);
            }
        }
        assert (translatable_contains (segs, "Screenshot of the main window"));
        assert (translatable_contains (segs, "The command line tool"));
        assert (translatable_contains (segs, "Setext heading"));
        assert (translatable_contains (segs, "inline html"));
        assert (has_segment (segs, "https://example.org/help", false));
        assert (translatable_contains (segs, "the FAQ"));
        var plain = Formats.plain (fixture ("docs/notes.txt"));
        assert (kept_text (plain) == fixture ("docs/notes.txt"));
        assert (plain[0].translatable && plain[0].text == "First paragraph line one\ncontinues on line two.");
        assert (has_segment (plain, "Third paragraph after two blank lines.", true));
        assert (Formats.is_markdown ("README.MD") && !Formats.is_markdown ("notes.txt"));
    });
    Test.add_func ("/document/job", () => {
        string doc = fixture ("docs/guide.md");
        var b = new FakeBackend ();
        var job = new DocumentJob (Formats.markdown (doc), b.request_limit);
        assert (job.max_request_chars () <= b.limit);
        string out_doc = run_job (job, b);
        assert (job.finished && job.done == job.total && job.detected == "en");
        assert (b.longest <= b.limit);
        assert (b.calls == job.request_count);
        assert (out_doc.contains ("# GETTING STARTED\n"));
        assert (out_doc.contains ("[INSTALLATION GUIDE](https://docs.example.org/install#linux \"Install\")"));
        assert (out_doc.contains ("```sh\ngit clone https://example.org/repo.git\necho \"do not translate\"\n```"));
        assert (out_doc.contains ("    indented code block stays\n    as it is\n"));
        assert (out_doc.contains ("- A COMPUTER WITH `git` INSTALLED\n"));
        assert (out_doc.contains ("  - NESTED ITEM WITH A LINK TO <https://example.org/faq>\n"));
        assert (out_doc.contains ("- [x] DONE TASK\n"));
        assert (out_doc.contains ("> > NESTED QUOTE HERE.\n"));
        assert (out_doc.contains ("|------|-------------|\n| `cli` | THE COMMAND LINE TOOL |"));
        assert (out_doc.contains ("![SCREENSHOT OF THE MAIN WINDOW](images/main.png)"));
        assert (out_doc.contains ("VISIT https://example.org/help, OR SEE [THE FAQ][faq] AND <span class=\"note\">INLINE HTML</span>."));
        assert (out_doc.contains ("[faq]: https://example.org/faq \"Frequently asked\""));
        assert (out_doc.has_prefix ("---\ntitle: Getting started\ntags: [intro]\n---\n"));
        assert (out_doc.split ("\n").length == doc.split ("\n").length);

        var dropping = new FakeBackend ();
        dropping.drop_newlines = true;
        var job2 = new DocumentJob (Formats.markdown (doc), dropping.request_limit);
        string out2 = run_job (job2, dropping);
        assert (out2 == out_doc);
        assert (dropping.calls > job2.request_count);
        assert (job2.done == job2.total);

        var tiny = new FakeBackend ();
        tiny.limit = 20;
        string long_text = "This paragraph is much longer than the tiny limit allows, so it must be split into several requests.\n\nShort one.\n";
        var job3 = new DocumentJob (Formats.plain (long_text), tiny.request_limit);
        string out3 = run_job (job3, tiny);
        assert (out3 == long_text.up ());
        assert (tiny.longest <= 20);
    });
    Test.add_func ("/phrasebook", () => {
        string dir;
        try {
            dir = DirUtils.make_tmp ("translate-XXXXXX");
        } catch (Error e) {
            error (e.message);
        }
        string file = Path.build_filename (dir, "p.json");
        var p = new Phrasebook (file);
        assert (p.items.size == 0);
        assert (p.add ("en", "it", " Good morning ", "Buongiorno", 1000) != null);
        assert (p.add ("en", "de", "Good morning", "Guten Morgen", 1001) != null);
        assert (p.add ("en", "it", "Say \"hi\", please", "Di' \"ciao\", per favore\nsubito", 1002) != null);
        assert (p.add ("en", "it", "", "x", 1) == null && p.add ("en", "", "x", "y", 1) == null);
        assert (p.add ("en", "it", "Good morning", "Buon giorno", 1003) != null);
        assert (p.items.size == 3 && p.items[0].translation == "Buon giorno");
        assert (p.find ("en", "it", "Good morning") != null && p.find ("fr", "it", "Good morning") == null);
        assert (p.search ("MORNING").size == 2 && p.search ("morgen").size == 1 && p.search ("good giorno").size == 1 && p.search ("").size == 3);
        var reload = new Phrasebook (file);
        assert (reload.items.size == 3 && reload.items[0].text == "Good morning" && reload.items[0].time == 1003);
        string csv = reload.to_csv (Languages.builtin ());
        string[] rows = csv.split ("\r\n");
        assert (rows[0] == "Source Language,Target Language,Text,Translation,Saved");
        assert (rows[1] == "English,Italian,Good morning,Buon giorno,1970-01-01 00:16");
        assert (csv.contains ("English,Italian,\"Say \"\"hi\"\", please\",\"Di' \"\"ciao\"\", per favore\nsubito\",1970-01-01 00:16"));
        assert (Phrasebook.csv_field ("a,b") == "\"a,b\"" && Phrasebook.csv_field ("plain") == "plain");
        reload.remove (reload.items[0]);
        assert (new Phrasebook (file).items.size == 2);
        FileUtils.remove (file);
        DirUtils.remove (dir);
    });
    Test.run ();
}
