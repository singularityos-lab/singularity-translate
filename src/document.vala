namespace Singularity.Apps.Translate {

    public class Segment : Object {
        public string text;
        public bool translatable;
        public string result = "";

        public Segment (string text, bool translatable) {
            this.text = text;
            this.translatable = translatable;
        }
    }

    namespace Chunker {
        private bool is_space (unichar c) {
            return c == ' ' || c == '\t' || c == '\n' || c == '\r';
        }

        private bool ends_sentence (unichar c) {
            return c == '.' || c == '!' || c == '?' || c == ';' || c == 0x3002 || c == 0xFF01 || c == 0xFF1F;
        }

        private int cut_point (unichar[] chars, int from, int limit) {
            int end = from + limit;
            int paragraph = -1, line = -1, sentence = -1, space = -1;
            for (int i = from + 1; i < end; i++) {
                unichar c = chars[i];
                unichar prev = chars[i - 1];
                if (c == '\n' && prev == '\n') paragraph = i + 1;
                else if (c == '\n') line = i + 1;
                if (is_space (c) && ends_sentence (prev)) sentence = i + 1;
                if (ends_sentence (c) && c >= 0x3000) sentence = i + 1;
                if (is_space (c)) space = i + 1;
            }
            int floor = from + limit / 3;
            if (paragraph > floor) return paragraph;
            if (line > floor) return line;
            if (sentence > floor) return sentence;
            if (space > from) return space;
            return end;
        }

        public string[] split (string text, int limit) {
            string[] pieces = {};
            if (limit <= 0 || text.char_count () <= limit) {
                pieces += text;
                return pieces;
            }
            unichar[] chars = {};
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) chars += c;
            int start = 0;
            while (start < chars.length) {
                if (chars.length - start <= limit) {
                    pieces += join (chars, start, chars.length);
                    break;
                }
                int cut = cut_point (chars, start, limit);
                if (cut <= start) cut = start + limit;
                pieces += join (chars, start, cut);
                start = cut;
            }
            return pieces;
        }

        private string join (unichar[] chars, int from, int to) {
            var sb = new StringBuilder ();
            for (int i = from; i < to; i++) sb.append_unichar (chars[i]);
            return sb.str;
        }
    }

    namespace Formats {
        private bool has_letters (string s) {
            unichar c;
            int i = 0;
            while (s.get_next_char (ref i, out c)) if (c.isalpha ()) return true;
            return false;
        }

        private void push (Gee.List<Segment> out_list, string text, bool translatable) {
            if (text == "") return;
            if (out_list.size > 0) {
                var last = out_list[out_list.size - 1];
                if (last.translatable == translatable) {
                    last.text += text;
                    return;
                }
            }
            out_list.add (new Segment (text, translatable));
        }

        private Gee.List<Segment> tidy (Gee.List<Segment> raw) {
            var merged = new Gee.ArrayList<Segment> ();
            foreach (var s in raw) push (merged, s.text, s.translatable && has_letters (s.text));
            return merged;
        }

        private int match_bracket (string s, int open, char left, char right) {
            int depth = 0;
            for (int i = open; i < s.length; i++) {
                char ch = s[i];
                if (ch == '\\') {
                    i++;
                    continue;
                }
                if (ch == left) depth++;
                else if (ch == right) {
                    depth--;
                    if (depth == 0) return i;
                }
            }
            return -1;
        }

        private int url_end (string s, int from) {
            int i = from;
            while (i < s.length && !s[i].isspace () && s[i] != '<' && s[i] != '>' && s[i] != '"') i++;
            while (i > from && (s[i - 1] == '.' || s[i - 1] == ',' || s[i - 1] == ';' || s[i - 1] == ':' || s[i - 1] == '!' || s[i - 1] == '?' || s[i - 1] == ')' || s[i - 1] == '\'')) i--;
            return i;
        }

        private bool starts_url (string s, int i) {
            string rest = s.substring (i, int.min (8, s.length - i)).down ();
            if (!(rest.has_prefix ("http://") || rest.has_prefix ("https://"))) return false;
            return i == 0 || !s[i - 1].isalnum ();
        }

        public void inline (string s, Gee.List<Segment> out_list) {
            var text = new StringBuilder ();
            int i = 0;
            while (i < s.length) {
                char ch = s[i];
                if (ch == '\\' && i + 1 < s.length) {
                    text.append_c (ch);
                    text.append_c (s[i + 1]);
                    i += 2;
                    continue;
                }
                if (ch == '`') {
                    int run = 0;
                    while (i + run < s.length && s[i + run] == '`') run++;
                    string fence = string.nfill (run, '`');
                    int close = s.index_of (fence, i + run);
                    if (close > 0) {
                        push (out_list, text.str, true);
                        text.truncate ();
                        push (out_list, s.substring (i, close + run - i), false);
                        i = close + run;
                        continue;
                    }
                }
                if (ch == '<') {
                    int close = s.index_of_char ('>', i);
                    if (close > i + 1) {
                        string inner = s.substring (i + 1, close - i - 1);
                        if (!inner.contains (" ") || inner.has_prefix ("/") || inner.has_prefix ("!") || inner.contains ("=")) {
                            push (out_list, text.str, true);
                            text.truncate ();
                            push (out_list, s.substring (i, close + 1 - i), false);
                            i = close + 1;
                            continue;
                        }
                    }
                }
                if (ch == '!' && i + 1 < s.length && s[i + 1] == '[' || ch == '[') {
                    int open = ch == '!' ? i + 1 : i;
                    int close = match_bracket (s, open, '[', ']');
                    if (close > open && close + 1 < s.length && (s[close + 1] == '(' || s[close + 1] == '[')) {
                        char left = s[close + 1];
                        int target_end = match_bracket (s, close + 1, left, left == '(' ? ')' : ']');
                        if (target_end > close) {
                            push (out_list, text.str, true);
                            text.truncate ();
                            push (out_list, s.substring (i, open + 1 - i), false);
                            inline (s.substring (open + 1, close - open - 1), out_list);
                            push (out_list, s.substring (close, target_end + 1 - close), false);
                            i = target_end + 1;
                            continue;
                        }
                    }
                }
                if ((ch == 'h' || ch == 'H') && starts_url (s, i)) {
                    int end = url_end (s, i);
                    push (out_list, text.str, true);
                    text.truncate ();
                    push (out_list, s.substring (i, end - i), false);
                    i = end;
                    continue;
                }
                text.append_c (ch);
                i++;
            }
            push (out_list, text.str, true);
        }

        private bool is_fence (string stripped, out string marker) {
            marker = "";
            if (!stripped.has_prefix ("```") && !stripped.has_prefix ("~~~")) return false;
            char ch = stripped[0];
            int n = 0;
            while (n < stripped.length && stripped[n] == ch) n++;
            marker = string.nfill (n, ch);
            return true;
        }

        private int indent_of (string line) {
            int n = 0;
            foreach (uint8 b in line.data) {
                if (b == ' ') n++;
                else if (b == '\t') n += 4;
                else break;
            }
            return n;
        }

        private bool only_chars (string s, string allowed) {
            if (s == "") return false;
            for (int i = 0; i < s.length; i++) if (allowed.index_of_char (s[i]) < 0) return false;
            return true;
        }

        private bool is_rule (string stripped) {
            string compact = stripped.replace (" ", "");
            if (compact.length < 3) return false;
            return only_chars (compact, "-") || only_chars (compact, "*") || only_chars (compact, "_") || only_chars (compact, "=");
        }

        private bool is_table_separator (string stripped) {
            return stripped.contains ("-") && only_chars (stripped.replace (" ", ""), "|-:");
        }

        private bool is_reference (string stripped) {
            if (!stripped.has_prefix ("[")) return false;
            int close = stripped.index_of ("]:");
            return close > 1;
        }

        private int list_marker (string s, int at) {
            if (at >= s.length) return -1;
            char ch = s[at];
            if ((ch == '-' || ch == '*' || ch == '+') && at + 1 < s.length && s[at + 1] == ' ') return at + 2;
            int i = at;
            while (i < s.length && s[i].isdigit ()) i++;
            if (i > at && i - at <= 9 && i + 1 < s.length && (s[i] == '.' || s[i] == ')') && s[i + 1] == ' ') return i + 2;
            return -1;
        }

        private int structure_prefix (string line, out bool is_list) {
            is_list = false;
            int i = 0;
            while (i < line.length && (line[i] == ' ' || line[i] == '\t')) i++;
            while (i < line.length && line[i] == '>') {
                i++;
                while (i < line.length && line[i] == ' ') i++;
            }
            if (i < line.length && line[i] == '#') {
                int h = i;
                while (h < line.length && line[h] == '#') h++;
                if (h - i <= 6 && (h == line.length || line[h] == ' ')) {
                    while (h < line.length && line[h] == ' ') h++;
                    return h;
                }
            }
            int after = list_marker (line, i);
            if (after > 0) {
                is_list = true;
                i = after;
                while (i < line.length && line[i] == ' ') i++;
                if (i + 3 <= line.length && line[i] == '[' && line[i + 2] == ']' && (line[i + 1] == ' ' || line[i + 1] == 'x' || line[i + 1] == 'X')) {
                    i += 3;
                    while (i < line.length && line[i] == ' ') i++;
                }
            }
            return i;
        }

        private void table_row (string body, Gee.List<Segment> out_list) {
            var cell = new StringBuilder ();
            for (int i = 0; i < body.length; i++) {
                char ch = body[i];
                if (ch == '\\' && i + 1 < body.length) {
                    cell.append_c (ch);
                    cell.append_c (body[i + 1]);
                    i++;
                    continue;
                }
                if (ch == '|') {
                    inline (cell.str, out_list);
                    cell.truncate ();
                    push (out_list, "|", false);
                    continue;
                }
                cell.append_c (ch);
            }
            inline (cell.str, out_list);
        }

        private string[] lines_of (string doc) {
            string[] lines = {};
            int start = 0;
            while (start < doc.length) {
                int nl = doc.index_of_char ('\n', start);
                if (nl < 0) {
                    lines += doc.substring (start);
                    break;
                }
                lines += doc.substring (start, nl + 1 - start);
                start = nl + 1;
            }
            return lines;
        }

        public Gee.List<Segment> markdown (string doc) {
            var out_list = new Gee.ArrayList<Segment> ();
            string[] lines = lines_of (doc);
            int n = lines.length;
            int i = 0;
            if (n > 0 && lines[0].strip () == "---") {
                for (int j = 1; j < n; j++) {
                    string t = lines[j].strip ();
                    if (t == "---" || t == "...") {
                        var sb = new StringBuilder ();
                        for (int k = 0; k <= j; k++) sb.append (lines[k]);
                        push (out_list, sb.str, false);
                        i = j + 1;
                        break;
                    }
                }
            }
            bool prev_blank = true;
            bool prev_code = false;
            bool in_list = false;
            bool in_code = false;
            string fence = "";
            for (; i < n; i++) {
                string line = lines[i];
                string body = line.has_suffix ("\n") ? line.substring (0, line.length - 1) : line;
                string eol = line.substring (body.length);
                if (body.has_suffix ("\r")) {
                    body = body.substring (0, body.length - 1);
                    eol = "\r" + eol;
                }
                string stripped = body.strip ();
                string marker;
                if (in_code) {
                    push (out_list, line, false);
                    if (is_fence (stripped, out marker) && marker.has_prefix (fence) && stripped.replace (marker, "").strip () == "") in_code = false;
                    continue;
                }
                if (is_fence (stripped, out marker) && indent_of (body) < 4) {
                    in_code = true;
                    fence = marker;
                    push (out_list, line, false);
                    continue;
                }
                if (stripped == "") {
                    push (out_list, line, false);
                    prev_blank = true;
                    continue;
                }
                bool indented_code = indent_of (body) >= 4 && !in_list && (prev_blank || (out_list.size > 0 && !out_list[out_list.size - 1].translatable && prev_code));
                prev_code = false;
                if (indented_code) {
                    push (out_list, line, false);
                    prev_code = true;
                    prev_blank = false;
                    continue;
                }
                if (is_rule (stripped) || is_table_separator (stripped) || is_reference (stripped) || (stripped.has_prefix ("<") && stripped.has_suffix (">"))) {
                    push (out_list, line, false);
                    prev_blank = false;
                    continue;
                }
                bool list;
                int prefix = structure_prefix (body, out list);
                if (list) in_list = true;
                else if (indent_of (body) == 0 && prev_blank) in_list = false;
                push (out_list, body.substring (0, prefix), false);
                string rest = body.substring (prefix);
                if (rest.strip ().has_prefix ("|") || (rest.contains ("|") && i + 1 < n && is_table_separator (lines[i + 1].strip ()))) table_row (rest, out_list);
                else inline (rest, out_list);
                push (out_list, eol, false);
                prev_blank = false;
            }
            return tidy (out_list);
        }

        public Gee.List<Segment> plain (string doc) {
            var out_list = new Gee.ArrayList<Segment> ();
            string[] lines = lines_of (doc);
            var para = new StringBuilder ();
            foreach (string line in lines) {
                if (line.strip () == "") {
                    if (para.len > 0) {
                        split_edges (para.str, out_list);
                        para.truncate ();
                    }
                    push (out_list, line, false);
                } else {
                    para.append (line);
                }
            }
            if (para.len > 0) split_edges (para.str, out_list);
            return tidy (out_list);
        }

        private void split_edges (string text, Gee.List<Segment> out_list) {
            string core = text.chomp ();
            push (out_list, core, true);
            push (out_list, text.substring (core.length), false);
        }

        public bool is_markdown (string name) {
            string l = name.down ();
            return l.has_suffix (".md") || l.has_suffix (".markdown") || l.has_suffix (".mdown") || l.has_suffix (".mkd");
        }
    }

    public class DocumentJob : Object {
        private class Unit {
            public Segment segment;
            public string lead = "";
            public string core = "";
            public string trail = "";
            public string? result;
        }

        public Gee.List<Segment> segments;
        public int total { get; private set; }
        public int done { get; private set; }
        public string detected = "";
        private Gee.ArrayList<Unit> units = new Gee.ArrayList<Unit> ();
        private Gee.ArrayList<Gee.List<Unit>> requests = new Gee.ArrayList<Gee.List<Unit>> ();
        public const int MAX_BATCH = 40;

        public signal void progress ();

        public DocumentJob (Gee.List<Segment> segments, int limit) {
            this.segments = segments;
            foreach (var s in segments) {
                if (!s.translatable) continue;
                foreach (string piece in Chunker.split (s.text, limit)) {
                    var u = new Unit ();
                    u.segment = s;
                    string stripped = piece.strip ();
                    int lead_len = piece.index_of (stripped);
                    if (stripped == "" || lead_len < 0) lead_len = piece.length;
                    u.lead = piece.substring (0, lead_len);
                    u.core = stripped;
                    u.trail = piece.substring (lead_len + stripped.length);
                    if (u.core == "") u.result = "";
                    units.add (u);
                }
            }
            Gee.List<Unit>? batch = null;
            int size = 0;
            foreach (var u in units) {
                if (u.core == "") continue;
                int len = u.core.char_count ();
                bool alone = u.core.contains ("\n");
                if (batch != null && (alone || size + 1 + len > limit || batch.size >= MAX_BATCH)) {
                    requests.add (batch);
                    batch = null;
                }
                if (alone) {
                    var single = new Gee.ArrayList<Unit> ();
                    single.add (u);
                    requests.add (single);
                    continue;
                }
                if (batch == null) {
                    batch = new Gee.ArrayList<Unit> ();
                    size = 0;
                } else {
                    size += 1;
                }
                batch.add (u);
                size += len;
            }
            if (batch != null) requests.add (batch);
            total = requests.size;
        }

        public int request_count {
            get { return requests.size; }
        }

        public int max_request_chars () {
            int max = 0;
            foreach (var r in requests) {
                int n = 0;
                foreach (var u in r) n += u.core.char_count ();
                n += r.size - 1;
                if (n > max) max = n;
            }
            return max;
        }

        public bool finished {
            get {
                foreach (var u in units) if (u.result == null) return false;
                return true;
            }
        }

        public async void run (Backend backend, string source, string target, Cancellable? cancel) throws Error {
            done = 0;
            foreach (var r in requests) {
                bool pending = false;
                foreach (var u in r) if (u.result == null) pending = true;
                if (!pending) {
                    done++;
                    continue;
                }
                var sb = new StringBuilder ();
                foreach (var u in r) {
                    if (sb.len > 0) sb.append_c ('\n');
                    sb.append (u.core);
                }
                var t = yield backend.translate (sb.str, source, target, cancel);
                if (t.detected != "" && detected == "") detected = t.detected;
                string[] parts = {};
                if (r.size > 1) {
                    foreach (string p in t.text.strip ().split ("\n")) if (p.strip () != "") parts += p;
                } else {
                    parts += t.text;
                }
                if (parts.length == r.size) {
                    for (int k = 0; k < r.size; k++) r[k].result = parts[k].strip ();
                } else {
                    total += r.size - 1;
                    progress ();
                    foreach (var u in r) {
                        var one = yield backend.translate (u.core, source, target, cancel);
                        u.result = one.text.strip ();
                        done++;
                        progress ();
                    }
                    done--;
                }
                done++;
                progress ();
            }
        }

        public string assemble () {
            foreach (var s in segments) s.result = s.translatable ? "" : s.text;
            foreach (var u in units) u.segment.result += u.lead + (u.result ?? u.core) + u.trail;
            var sb = new StringBuilder ();
            foreach (var s in segments) sb.append (s.result);
            return sb.str;
        }
    }
}
