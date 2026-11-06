/// JSON for `-betterC`, which has no Phobos. A `Document` is minified JSON text with an index of its values over it: `parse` reads one, `set`, `append`, `insert`, `replace` and `remove` edit it in place, `json` gives its text and `pretty` lays that out for reading. A `Value` names one value of a document, stays valid across edits until the document is freed, and reads as missing once its value is removed; look further in with `v["key"]` and `v[i]`.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// auto o = setObject(d);
/// set(o, "id", 1);
/// auto tags = setArray(o, "tags");
/// set(o, "ok", true);
/// append(tags, "a");
/// assert(!d.refused && json(d) == `{"id":1,"tags":["a"],"ok":true}`);
///
/// auto p = parse(`{ "params": {"limit": 5, "trace": true} }`);
/// scope(exit) free(p.document);
/// assert(p.status == Status.ok && json(p.document) == `{"params":{"limit":5,"trace":true}}`);
/// auto params = root(p.document)["params"];
/// set(params, "limit", 10);
/// assert(remove(params["trace"]));
/// assert(integer(params["limit"]).get == 10 && !exists(params["trace"]["deeper"]));
/// ---
module bc.json;

static import core.stdc.string;
static import std.typecons;
static import fp.dynarray;
static import fp.string;

@nogc nothrow:


// --- documents ---------------------------------------------------------------

/// What a value is: `missing` for a `Value` that names none.
enum Kind : ubyte { missing, null_, false_, true_, number, string_, array, object }

/// One value of a document, in preorder after its container, so its next sibling is `nodes[i].skip`. An object's members are a key `string_` node followed by its value. Its bytes in the document's `text` are its JSON, a string's quotes and escapes included.
struct Node {
	Kind kind; /// What it is; never `missing`.
	uint start; /// Its first byte.
	uint end; /// Past its last byte.
	uint skip; /// The index of the node after its descendants.
	uint id; /// Its stable id: `ids[id]` is its index.
	uint parent; /// Its container's id, or `uint.max` for the root.
}

/// A JSON document: its minified text and its values in preorder over it, the first the root. Plain data, released by `free`; `Document.init` is empty and has no root.
struct Document {
	char* text = null; /// Its JSON, minified, as an fp dynarray.
	Node* nodes = null; /// Its values in preorder, an fp dynarray.
	uint* ids = null; /// Each id's current node index, `uint.max` once its node is removed; an fp dynarray.
	bool refused; /// Set when an edit's allocation is refused; that edit changed nothing.
	private Fragment scratch; // what each edit builds before splicing it in, kept between edits so they need not allocate
}

private enum uint dead = uint.max;

// Bytes and nodes to splice in, positioned relative to themselves; a parent of `dead` is the container spliced into.
private struct Fragment {
	char* text = null;
	Node* nodes = null;
	bool refused;
}

private void release(ref Fragment f) {
	fp.dynarray.free(f.text);
	fp.dynarray.free(f.nodes);
}

/// Releases `d`'s text, nodes and ids, and the space its edits reuse, leaving it empty.
///
/// Examples:
/// ---
/// auto p = parse("[1]");
/// free(p.document);
/// assert(p.document.nodes is null && json(p.document).length == 0);
/// ---
void free(ref Document d) {
	fp.dynarray.free(d.text);
	fp.dynarray.free(d.nodes);
	fp.dynarray.free(d.ids);
	release(d.scratch);
	d = Document.init;
}

// The node index `id` names in `d`, or `dead`.
private uint indexOf(const(Document)* d, uint id) {
	return d is null || id >= fp.dynarray.length(d.ids) ? dead : d.ids[id];
}


// --- escapes -----------------------------------------------------------------

private uint hexDigits(const(char)[] s, size_t at) {
	uint v = 0;
	foreach (c; s[at .. at + 4]) {
		if (!fp.string.isHexDigit(c)) return uint.max;
		v = v << 4 | fp.string.hexDigitValue(c);
	}
	return v;
}

// One escape decoded to UTF-8, and where what follows it starts.
private struct Unescaped {
	char[4] bytes;
	size_t length;
	size_t next;
}

// Decodes the escape at `s[i]`, a surrogate pair to one character and a broken `\u` or lone surrogate to U+FFFD.
private Unescaped unescape(const(char)[] s, size_t i) {
	Unescaped u;
	immutable c = i + 1 < s.length ? s[i + 1] : '\\';
	i += 2;
	u.length = 1;
	switch (c) {
		case 'n': u.bytes[0] = '\n'; break;
		case 'r': u.bytes[0] = '\r'; break;
		case 't': u.bytes[0] = '\t'; break;
		case 'b': u.bytes[0] = '\b'; break;
		case 'f': u.bytes[0] = '\f'; break;
		case 'u':
			uint code = i + 4 <= s.length ? hexDigits(s, i) : uint.max;
			if (code != uint.max) i += 4;
			else code = 0xFFFD;
			if (code >= 0xD800 && code < 0xDC00 && i + 6 <= s.length && s[i] == '\\' && s[i + 1] == 'u') {
				immutable low = hexDigits(s, i + 2);
				if (low >= 0xDC00 && low < 0xE000) {
					code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
					i += 6;
				}
			}
			if (code >= 0xD800 && code < 0xE000) code = 0xFFFD;
			u.length = fp.string.encodeUtf8(code, u.bytes.ptr);
			break;
		default: u.bytes[0] = c;
	}
	u.next = i;
	return u;
}

// Whether string bytes `raw`, escapes decoded, spell `name`.
private bool keyEquals(const(char)[] raw, const(char)[] name) {
	size_t at = 0, i = 0;
	while (i < raw.length) {
		if (raw[i] != '\\') {
			if (at >= name.length || name[at] != raw[i]) return false;
			++at;
			++i;
			continue;
		}
		immutable u = unescape(raw, i);
		if (name.length - at < u.length || name[at .. at + u.length] != u.bytes[0 .. u.length]) return false;
		at += u.length;
		i = u.next;
	}
	return at == name.length;
}


// --- values ------------------------------------------------------------------

/// One value of a document, or none: a `missing` value, which every lookup through it gives too. It stays valid across edits until its document is freed, and is missing once its value is removed. Plain data; it does not own its document, which must not move while it is used.
struct Value {
@nogc nothrow:
	Document* document; /// The document it is in.
	uint id = dead; /// Its node's id.

	/// Member `name`'s value, comparing keys with their escapes decoded; missing if there is none or this is not an object.
	///
	/// Examples:
	/// ---
	/// auto p = parse(`{"a":{"b!":2}}`);
	/// scope(exit) free(p.document);
	/// assert(integer(root(p.document)["a"]["b!"]).get == 2);
	/// assert(!exists(root(p.document)["x"]["y"]));
	/// ---
	Value opIndex(const(char)[] name) {
		immutable o = indexOf(document, id);
		if (o == dead || document.nodes[o].kind != Kind.object) return Value(document);
		for (uint k = o + 1; k < document.nodes[o].skip; k = document.nodes[k + 1].skip) {
			immutable key = document.nodes[k];
			if (keyEquals(document.text[key.start + 1 .. key.end - 1], name)) return Value(document, document.nodes[k + 1].id);
		}
		return Value(document);
	}

	/// Element `i`; missing past the end or if this is not an array.
	///
	/// Examples:
	/// ---
	/// auto p = parse(`[10,[20]]`);
	/// scope(exit) free(p.document);
	/// assert(integer(root(p.document)[1][0]).get == 20 && !exists(root(p.document)[2]));
	/// ---
	Value opIndex(size_t i) {
		immutable a = indexOf(document, id);
		if (a == dead || document.nodes[a].kind != Kind.array) return Value(document);
		uint e = a + 1;
		for (; e < document.nodes[a].skip && i; --i) e = document.nodes[e].skip;
		return e < document.nodes[a].skip ? Value(document, document.nodes[e].id) : Value(document);
	}
}


// --- parsing -----------------------------------------------------------------

/// How `parse` went.
enum Status : ubyte {
	ok, /// The document is ready.
	malformed, /// The text is not one JSON value.
	refused, /// An allocation was refused.
}

/// What `parse` gives: the document, empty unless `status` is `ok`.
struct Parsed {
	Document document; /// What was read.
	Status status; /// Whether it was.
}

// How deeply `parse` nests; recursion past this would overrun WebAssembly's 64 KiB default stack.
private enum uint maxDepth = 128;

private struct Parse {
	const(char)[] text;
	size_t at;
	Document* document;
	size_t written;
	bool refused;
	uint depth;
}

private void space(ref Parse p) {
	while (p.at < p.text.length && (p.text[p.at] == ' ' || p.text[p.at] == '\t' || p.text[p.at] == '\n' || p.text[p.at] == '\r')) ++p.at;
}

private bool literal(ref Parse p, const(char)[] word) {
	if (p.text.length - p.at < word.length || p.text[p.at .. p.at + word.length] != word) return false;
	p.at += word.length;
	return true;
}

private bool stringEnd(ref Parse p) {
	++p.at;
	while (p.at < p.text.length) {
		immutable c = p.text[p.at];
		if (c == '"') {
			++p.at;
			return true;
		}
		if (c < 0x20) return false;
		p.at += c == '\\' ? 2 : 1;
	}
	return false;
}

private bool numberEnd(ref Parse p) {
	immutable start = p.at;
	if (p.at < p.text.length && p.text[p.at] == '-') ++p.at;
	immutable digits = p.at;
	while (p.at < p.text.length && ((p.text[p.at] >= '0' && p.text[p.at] <= '9') || p.text[p.at] == '.' || p.text[p.at] == 'e' || p.text[p.at] == 'E' || p.text[p.at] == '+' || p.text[p.at] == '-')) ++p.at;
	return p.at > digits && p.at > start;
}

// Copies `bytes` into the document's text, which was sized for all of the input, so never grows.
private void emit(ref Parse p, const(char)[] bytes) {
	if (bytes.length) core.stdc.string.memcpy(p.document.text + p.written, bytes.ptr, bytes.length);
	p.written += bytes.length;
}

// One value at `p.at`, appended minified with its descendants, inside node `parent`. False if malformed or refused.
private bool value(ref Parse p, uint parent) {
	space(p);
	if (p.at >= p.text.length || p.depth > maxDepth) return false;
	immutable index = cast(uint) fp.dynarray.length(p.document.nodes);
	if (!fp.dynarray.pushBack(p.document.nodes, Node(Kind.null_, cast(uint) p.written, 0, 0, index, parent))) {
		p.refused = true;
		return false;
	}
	immutable c = p.text[p.at], from = p.at;
	Kind kind;
	if (c == '{' || c == '[') {
		kind = c == '{' ? Kind.object : Kind.array;
		emit(p, p.text[p.at .. p.at + 1]);
		++p.at;
		++p.depth;
		scope(exit) --p.depth;
		space(p);
		immutable close = c == '{' ? '}' : ']';
		if (p.at < p.text.length && p.text[p.at] == close) {
			emit(p, p.text[p.at .. p.at + 1]);
			++p.at;
		} else for (;;) {
			if (kind == Kind.object) {
				space(p);
				if (p.at >= p.text.length || p.text[p.at] != '"' || !value(p, index)) return false;
				space(p);
				if (p.at >= p.text.length || p.text[p.at] != ':') return false;
				emit(p, ":");
				++p.at;
			}
			if (!value(p, index)) return false;
			space(p);
			if (p.at >= p.text.length) return false;
			if (p.text[p.at] == ',') {
				emit(p, ",");
				++p.at;
				continue;
			}
			if (p.text[p.at] != close) return false;
			emit(p, p.text[p.at .. p.at + 1]);
			++p.at;
			break;
		}
	} else {
		if (c == '"') {
			kind = Kind.string_;
			if (!stringEnd(p)) return false;
		} else if (literal(p, "true")) kind = Kind.true_;
		else if (literal(p, "false")) kind = Kind.false_;
		else if (literal(p, "null")) kind = Kind.null_;
		else if (numberEnd(p)) kind = Kind.number;
		else return false;
		emit(p, p.text[from .. p.at]);
	}
	auto node = &p.document.nodes[index];
	node.kind = kind;
	node.end = cast(uint) p.written;
	node.skip = cast(uint) fp.dynarray.length(p.document.nodes);
	return true;
}

/// Parses `text`, one JSON value with whitespace around it, into a new document holding it minified; `text` need not outlive it. Containers may nest 129 deep.
///
/// Reports failure in `status`, `Status.malformed` or `Status.refused`, with the document empty.
///
/// Examples:
/// ---
/// auto p = parse(` {"a": [1, 2, {"b": null}]} `);
/// scope(exit) free(p.document);
/// assert(p.status == Status.ok && json(p.document) == `{"a":[1,2,{"b":null}]}`);
/// assert(parse(`{"a":}`).status == Status.malformed);
/// ---
Parsed parse(const(char)[] text) {
	assert(text.length < uint.max, "bc.json: text too large");
	Parsed result;
	Parse p = Parse(text, 0, &result.document);
	bool ok = text.length == 0 || fp.dynarray.growToSize(result.document.text, text.length) !is null;
	if (!ok) p.refused = true;
	else ok = value(p, dead);
	if (ok) {
		space(p);
		ok = p.at == text.length;
	}
	if (ok) {
		cast(void) fp.dynarray.removeLast(result.document.text, text.length - p.written);
		immutable count = fp.dynarray.length(result.document.nodes);
		ok = fp.dynarray.growToSize(result.document.ids, count) !is null;
		if (ok) foreach (i; 0 .. count) result.document.ids[i] = cast(uint) i;
		else p.refused = true;
	}
	if (ok) return result;
	free(result.document);
	result.status = p.refused ? Status.refused : Status.malformed;
	return result;
}


// --- reading -----------------------------------------------------------------

/// `d`'s root value; missing if `d` is empty.
///
/// Examples:
/// ---
/// Document d;
/// assert(!exists(root(d)));
/// ---
Value root(ref Document d) {
	return Value(&d, fp.dynarray.length(d.nodes) ? d.nodes[0].id : dead);
}

/// `d`'s JSON text, minified; empty for an empty document. It stays valid until the next edit.
///
/// Examples:
/// ---
/// auto p = parse("[ true ,null ]");
/// scope(exit) free(p.document);
/// assert(json(p.document) == "[true,null]");
/// ---
const(char)[] json(ref const Document d) {
	return d.text is null ? null : d.text[0 .. fp.dynarray.length(d.text)];
}

/// What `v` is: `Kind.missing` if it names no value.
///
/// Examples:
/// ---
/// auto p = parse(`{"a":"x"}`);
/// scope(exit) free(p.document);
/// assert(kind(root(p.document)) == Kind.object && kind(root(p.document)["a"]) == Kind.string_);
/// assert(kind(root(p.document)["b"]) == Kind.missing);
/// ---
Kind kind(Value v) {
	immutable n = indexOf(v.document, v.id);
	return n == dead ? Kind.missing : v.document.nodes[n].kind;
}

/// Whether `v` names a value, `null` included.
///
/// Examples:
/// ---
/// auto p = parse(`{"a":null}`);
/// scope(exit) free(p.document);
/// assert(exists(root(p.document)["a"]) && !exists(root(p.document)["b"]));
/// ---
bool exists(Value v) {
	return kind(v) != Kind.missing;
}

/// The number of elements of an array or members of an object; 0 for anything else.
///
/// Examples:
/// ---
/// auto p = parse(`[[],{"a":1,"b":2},3]`);
/// scope(exit) free(p.document);
/// assert(length(root(p.document)) == 3 && length(root(p.document)[1]) == 2 && length(root(p.document)[2]) == 0);
/// ---
size_t length(Value v) {
	immutable n = indexOf(v.document, v.id);
	if (n == dead || (v.document.nodes[n].kind != Kind.array && v.document.nodes[n].kind != Kind.object)) return 0;
	immutable step = v.document.nodes[n].kind == Kind.object ? 1 : 0;
	size_t count = 0;
	for (uint k = n + 1; k < v.document.nodes[n].skip; k = v.document.nodes[k + step].skip) ++count;
	return count;
}

/// `v`'s JSON text, minified; null if it is missing. It stays valid until the next edit.
///
/// Examples:
/// ---
/// auto p = parse(`{"id": [1, "x"]}`);
/// scope(exit) free(p.document);
/// assert(source(root(p.document)["id"]) == `[1,"x"]` && source(root(p.document)["no"]) is null);
/// ---
const(char)[] source(Value v) {
	immutable n = indexOf(v.document, v.id);
	return n == dead ? null : v.document.text[v.document.nodes[n].start .. v.document.nodes[n].end];
}

/// A string's bytes between its quotes, escapes left as written, without allocating; null if `v` is not a string. It stays valid until the next edit.
///
/// Examples:
/// ---
/// auto p = parse(`["a\"b", 1]`);
/// scope(exit) free(p.document);
/// assert(view(root(p.document)[0]) == `a\"b` && view(root(p.document)[1]) is null);
/// ---
const(char)[] view(Value v) {
	if (kind(v) != Kind.string_) return null;
	auto s = source(v);
	return s[1 .. $ - 1];
}

/// `v` as an integer; null if it is not a number, has a fraction or exponent, or does not fit in a `long`.
///
/// Examples:
/// ---
/// auto p = parse(`[-7, 1.5, "x"]`);
/// scope(exit) free(p.document);
/// assert(integer(root(p.document)[0]).get == -7 && integer(root(p.document)[1]).isNull);
/// assert(integer(root(p.document)[2]).get(3) == 3);
/// ---
std.typecons.Nullable!long integer(Value v) {
	alias Result = typeof(return);
	if (kind(v) != Kind.number) return Result.init;
	auto s = source(v);
	immutable negative = s[0] == '-';
	auto parsed = fp.string.parseUnsigned(s[negative .. $], 10);
	if (parsed.isNull || parsed.get.value > cast(ulong) long.max + negative) return Result.init;
	immutable magnitude = parsed.get.value;
	return Result(negative ? cast(long) (0UL - magnitude) : cast(long) magnitude);
}

/// `v` as a boolean; null unless it is `true` or `false`.
///
/// Examples:
/// ---
/// auto p = parse(`[false, 0]`);
/// scope(exit) free(p.document);
/// assert(boolean(root(p.document)[0]).get == false && boolean(root(p.document)[1]).isNull);
/// ---
std.typecons.Nullable!bool boolean(Value v) {
	alias Result = typeof(return);
	immutable k = kind(v);
	return k == Kind.true_ || k == Kind.false_ ? Result(k == Kind.true_) : Result.init;
}

/// A string's value with its escapes decoded, `\u` surrogate pairs included, as a new fp string the caller frees. The empty string, or anything not a string, gives a null pointer.
///
/// Returns null (not a null pointer, but no value) only if an allocation is refused.
///
/// Examples:
/// ---
/// static import fp.string;
/// auto p = parse(`"a\nbé😀"`);
/// scope(exit) free(p.document);
/// auto s = decode(root(p.document));
/// scope(exit) fp.string.free(s.get);
/// assert(fp.string.slice(s.get) == "a\nbé\U0001F600");
/// ---
std.typecons.Nullable!(char*) decode(Value v) {
	alias Result = typeof(return);
	auto s = view(v);
	char* out_ = null;
	size_t from = 0, i = 0;
	while (i < s.length) {
		if (s[i] != '\\') {
			++i;
			continue;
		}
		immutable u = unescape(s, i);
		if (!fp.string.concatenate(out_, s[from .. i]) || !fp.string.concatenate(out_, u.bytes[0 .. u.length])) {
			fp.string.free(out_);
			return Result.init;
		}
		i = from = u.next;
	}
	if (!fp.string.concatenate(out_, s[from .. $])) {
		fp.string.free(out_);
		return Result.init;
	}
	return Result(out_);
}

/// `d`'s JSON laid out for reading: one member or element per line, each nesting level indented by `indent` once more, `": "` after keys, and empty containers kept as `{}` and `[]`. A new fp string the caller frees; a null pointer for an empty document.
///
/// Returns null (not a null pointer, but no value) only if an allocation is refused.
///
/// Examples:
/// ---
/// static import fp.string;
/// auto p = parse(`{"a":[1,{}],"b":"x"}`);
/// scope(exit) free(p.document);
/// auto s = pretty(p.document, "  ");
/// scope(exit) fp.string.free(s.get);
/// assert(fp.string.slice(s.get) == "{\n  \"a\": [\n    1,\n    {}\n  ],\n  \"b\": \"x\"\n}");
/// ---
std.typecons.Nullable!(char*) pretty(ref const Document d, const(char)[] indent = "\t") {
	alias Result = typeof(return);
	char* out_ = null;
	if (fp.dynarray.length(d.nodes) && !layOut(d, 0, 0, indent, out_)) {
		fp.string.free(out_);
		return Result.init;
	}
	return Result(out_);
}

// Appends node `n` laid out at nesting `depth` to `out_`. False if refused.
private bool layOut(ref const Document d, uint n, size_t depth, const(char)[] indent, ref char* out_) {
	bool line(size_t level) {
		if (!fp.string.concatenate(out_, "\n")) return false;
		foreach (_; 0 .. level) if (!fp.string.concatenate(out_, indent)) return false;
		return true;
	}
	immutable node = d.nodes[n];
	if ((node.kind != Kind.object && node.kind != Kind.array) || node.skip == n + 1) return fp.string.concatenate(out_, d.text[node.start .. node.end]);
	immutable object = node.kind == Kind.object;
	if (!fp.string.concatenate(out_, object ? "{" : "[")) return false;
	for (uint k = n + 1; k < node.skip; k = d.nodes[k].skip) {
		if ((k > n + 1 && !fp.string.concatenate(out_, ",")) || !line(depth + 1)) return false;
		if (object) {
			if (!fp.string.concatenate(out_, d.text[d.nodes[k].start .. d.nodes[k].end]) || !fp.string.concatenate(out_, ": ")) return false;
			++k;
		}
		if (!layOut(d, k, depth + 1, indent, out_)) return false;
	}
	return line(depth) && fp.string.concatenate(out_, object ? "}" : "]");
}


// --- iterating ---------------------------------------------------------------

/// An array's elements front to back, from `elements`. Removing the front element ends it early.
struct Elements {
@nogc nothrow:
	Value front; /// The element at the front.

	/// Whether every element has been seen.
	///
	/// Examples:
	/// ---
	/// auto p = parse(`[1,2]`);
	/// scope(exit) free(p.document);
	/// auto e = elements(root(p.document));
	/// e.popFront();
	/// assert(!e.empty && integer(e.front).get == 2);
	/// e.popFront();
	/// assert(e.empty);
	/// ---
	bool empty() { return !exists(front); }

	/// Ditto
	void popFront() {
		auto d = front.document;
		immutable n = indexOf(d, front.id);
		if (n == dead) return;
		immutable next = d.nodes[n].skip;
		front = next < fp.dynarray.length(d.nodes) && d.nodes[next].parent == d.nodes[n].parent ? Value(d, d.nodes[next].id) : Value(d);
	}
}

/// The elements of array `v`; none if it is not an array.
///
/// Examples:
/// ---
/// auto p = parse(`[1,2,3]`);
/// scope(exit) free(p.document);
/// long sum = 0;
/// foreach (e; elements(root(p.document))) sum += integer(e).get;
/// assert(sum == 6);
/// ---
Elements elements(Value v) {
	immutable n = indexOf(v.document, v.id);
	if (n == dead || v.document.nodes[n].kind != Kind.array || v.document.nodes[n].skip == n + 1) return Elements(Value(v.document));
	return Elements(Value(v.document, v.document.nodes[n + 1].id));
}

/// One member of an object: its key as written, escapes and all, valid until the next edit, and its value.
struct Member {
	const(char)[] key; /// The key between its quotes.
	Value value; /// Its value.
}

/// An object's members in order, from `members`. Removing the front member ends it early.
struct Members {
@nogc nothrow:
	Value value; /// The front member's value.

	/// Whether every member has been seen.
	///
	/// Examples:
	/// ---
	/// auto p = parse(`{"a":1}`);
	/// scope(exit) free(p.document);
	/// auto m = members(root(p.document));
	/// assert(!m.empty && m.front.key == "a" && integer(m.front.value).get == 1);
	/// m.popFront();
	/// assert(m.empty);
	/// ---
	bool empty() { return !exists(value); }

	/// Ditto
	Member front() {
		immutable key = value.document.nodes[indexOf(value.document, value.id) - 1];
		return Member(value.document.text[key.start + 1 .. key.end - 1], value);
	}

	/// Ditto
	void popFront() {
		auto d = value.document;
		immutable n = indexOf(d, value.id);
		if (n == dead) return;
		immutable next = d.nodes[n].skip;
		value = next < fp.dynarray.length(d.nodes) && d.nodes[next].parent == d.nodes[n].parent ? Value(d, d.nodes[next + 1].id) : Value(d);
	}
}

/// The members of object `v`; none if it is not an object.
///
/// Examples:
/// ---
/// auto p = parse(`{"a":1,"b":2}`);
/// scope(exit) free(p.document);
/// size_t count = 0;
/// foreach (m; members(root(p.document))) if (m.key == "b") count += integer(m.value).get;
/// assert(count == 2);
/// ---
Members members(Value v) {
	immutable n = indexOf(v.document, v.id);
	if (n == dead || v.document.nodes[n].kind != Kind.object || v.document.nodes[n].skip == n + 1) return Members(Value(v.document));
	return Members(Value(v.document, v.document.nodes[n + 2].id));
}


// --- editing -----------------------------------------------------------------

// Empties `f` for the next edit, keeping its capacity.
private void reuse(ref Fragment f) {
	fp.dynarray.clear(f.text);
	fp.dynarray.clear(f.nodes);
	f.refused = false;
}

private void put(ref Fragment f, const(char)[] bytes) {
	if (!f.refused && bytes.length && !fp.dynarray.concatenate(f.text, bytes)) f.refused = true;
}

private void leaf(ref Fragment f, Kind kind, const(char)[] spelling) {
	immutable start = cast(uint) fp.dynarray.length(f.text), index = cast(uint) fp.dynarray.length(f.nodes);
	put(f, spelling);
	if (!f.refused && !fp.dynarray.pushBack(f.nodes, Node(kind, start, cast(uint) fp.dynarray.length(f.text), index + 1, 0, dead))) f.refused = true;
}

// Adds `s` as a string node, quoted and escaped.
private void quoted(ref Fragment f, const(char)[] s) {
	immutable start = cast(uint) fp.dynarray.length(f.text), index = cast(uint) fp.dynarray.length(f.nodes);
	put(f, "\"");
	size_t from = 0;
	foreach (i, c; s) {
		const(char)[] escape;
		char[6] unicode;
		switch (c) {
			case '"': escape = "\\\""; break;
			case '\\': escape = "\\\\"; break;
			case '\n': escape = "\\n"; break;
			case '\r': escape = "\\r"; break;
			case '\t': escape = "\\t"; break;
			default:
				if (c >= 0x20) continue;
				static immutable hex = "0123456789abcdef";
				unicode = ['\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]];
				escape = unicode[];
		}
		put(f, s[from .. i]);
		put(f, escape);
		from = i + 1;
	}
	put(f, s[from .. $]);
	put(f, "\"");
	if (!f.refused && !fp.dynarray.pushBack(f.nodes, Node(Kind.string_, start, cast(uint) fp.dynarray.length(f.text), index + 1, 0, dead))) f.refused = true;
}

// Adds a deep copy of `v`, from any document; a missing one is a refusal if its document saw one.
private void copy(ref Fragment f, Value v) {
	immutable n = indexOf(v.document, v.id);
	if (n == dead) {
		assert(v.document !is null && v.document.refused, "bc.json: copying a missing value");
		f.refused = true;
		return;
	}
	const d = v.document;
	immutable base = cast(uint) fp.dynarray.length(f.text), first = cast(uint) fp.dynarray.length(f.nodes), from = d.nodes[n].start;
	put(f, d.text[from .. d.nodes[n].end]);
	foreach (k; n .. d.nodes[n].skip) {
		if (f.refused) return;
		immutable node = d.nodes[k];
		immutable parent = k == n ? dead : indexOf(d, node.parent) - n + first;
		if (!fp.dynarray.pushBack(f.nodes, Node(node.kind, node.start - from + base, node.end - from + base, node.skip - n + first, 0, parent))) f.refused = true;
	}
}

// An empty container to write: what `setObject` and its kin pass as a value.
private struct Empty {
	Kind kind;
}

// Adds `value`: a bool, an integer, a string, `null`, a `Value` to copy, or an `Empty` container.
private void add(T)(ref Fragment f, T value) {
	alias U = immutable T;
	static if (is(U == immutable bool)) leaf(f, value ? Kind.true_ : Kind.false_, value ? "true" : "false");
	else static if (is(T == typeof(null))) leaf(f, Kind.null_, "null");
	else static if (is(U == immutable Empty)) leaf(f, value.kind, value.kind == Kind.object ? "{}" : "[]");
	else static if (is(U == immutable Value)) copy(f, value);
	else static if (is(T : const(char)[])) quoted(f, value);
	else static if (__traits(isIntegral, T) && !is(U == immutable char) && !is(U == immutable wchar) && !is(U == immutable dchar)) {
		char[fp.string.maxDecimalLength] buffer;
		static if (__traits(isUnsigned, T)) leaf(f, Kind.number, fp.string.formatUnsigned(value, buffer));
		else leaf(f, Kind.number, fp.string.formatSigned(value, buffer));
	} else static assert(0, "bc.json: cannot write a " ~ T.stringof);
}

// Swaps bytes [at, at+cut) and nodes [first, first+drop) inside `parent` for `f`. Returns `f`'s first id, or `dead`, unchanged, on refusal.
private uint splice(ref Document d, uint parent, uint at, uint cut, uint first, uint drop, ref const Fragment f) {
	if (f.refused) {
		d.refused = true;
		return dead;
	}
	immutable size_t bytes = fp.dynarray.length(d.text), count = fp.dynarray.length(d.nodes), ids = fp.dynarray.length(d.ids);
	immutable size_t added = fp.dynarray.length(f.text), fresh = fp.dynarray.length(f.nodes);
	assert(bytes - cut + added < uint.max && ids + fresh < dead, "bc.json: document too large");
	if (!(fp.dynarray.reserveAtLeast(d.text, bytes - cut + added) !is null) || !(fp.dynarray.reserveAtLeast(d.nodes, count - drop + fresh) !is null) || !(fp.dynarray.reserveAtLeast(d.ids, ids + fresh) !is null)) {
		d.refused = true;
		return dead;
	}
	// Unsigned wraparound makes adding these subtract when the splice shrinks.
	immutable byteShift = cast(uint) (added - cut), nodeShift = cast(uint) (fresh - drop);
	for (uint a = parent; a != dead; a = indexOf(&d, d.nodes[a].parent)) {
		d.nodes[a].end += byteShift;
		d.nodes[a].skip += nodeShift;
	}
	foreach (k; first + drop .. count) {
		d.nodes[k].start += byteShift;
		d.nodes[k].end += byteShift;
		d.nodes[k].skip += nodeShift;
	}
	foreach (k; first .. first + drop) d.ids[d.nodes[k].id] = dead;

	if (cut) cast(void) fp.dynarray.removeRange(d.text, at, cut);
	if (added) core.stdc.string.memcpy(fp.dynarray.insertUninitialized(d.text, at, added), f.text, added);
	if (drop) cast(void) fp.dynarray.removeRange(d.nodes, first, drop);
	if (fresh) {
		auto slots = fp.dynarray.insertUninitialized(d.nodes, first, fresh);
		immutable container = parent == dead ? dead : d.nodes[parent].id;
		foreach (j; 0 .. fresh) {
			Node n = f.nodes[j];
			n.start += at;
			n.end += at;
			n.skip += first;
			n.id = cast(uint) (ids + j);
			n.parent = n.parent == dead ? container : cast(uint) ids + n.parent;
			slots[j] = n;
		}
		cast(void) fp.dynarray.grow(d.ids, fresh);
		foreach (j; 0 .. fresh) d.ids[ids + j] = cast(uint) (first + j);
	}
	foreach (k; first + fresh .. fp.dynarray.length(d.nodes)) d.ids[d.nodes[k].id] = cast(uint) k;
	return fresh ? cast(uint) ids : dead;
}

// The node of `v` to edit, which must be of `kind` (any if missing), or `dead` after an earlier refusal left it missing.
private uint target(Value v, Kind kind, string message) {
	assert(v.document !is null, "bc.json: editing a value of no document");
	immutable n = indexOf(v.document, v.id);
	assert(n != dead || v.document.refused, "bc.json: editing a missing value");
	assert(n == dead || kind == Kind.missing || v.document.nodes[n].kind == kind, message);
	return n;
}

/// Replaces all of `d` with `value`: a `bool`, an integer, a string, `null`, or a `Value` (from any document, this one included) to copy. Like every edit, it records a refusal in `d.refused` as well as in what it returns, so a run of edits can be checked once at its end.
///
/// Returns the new root, or a missing value, leaving `d` as it was and setting `d.refused`, if an allocation is refused.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// set(d, "hi");
/// assert(json(d) == `"hi"`);
/// auto a = setArray(d);
/// append(a, 1);
/// assert(json(d) == `[1]`);
/// ---
Value set(T)(ref Document d, T value) {
	auto f = &d.scratch;
	scope(exit) reuse(*f);
	add(*f, value);
	return Value(&d, splice(d, dead, 0, cast(uint) fp.dynarray.length(d.text), 0, cast(uint) fp.dynarray.length(d.nodes), *f));
}

// wrapper: names a JSON container kind for the generic operation
/// Replaces all of `d` with an empty object or array, and returns it as `set` does.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// assert(kind(setObject(d)) == Kind.object && json(d) == "{}");
/// assert(kind(setArray(d)) == Kind.array && json(d) == "[]");
/// ---
Value setObject(ref Document d) { return set(d, Empty(Kind.object)); }

// wrapper: names a JSON container kind for the generic operation
/// Ditto
Value setArray(ref Document d) { return set(d, Empty(Kind.array)); }

/// Replaces `v`, which must not be missing, with `value`, as `set` takes one, keeping its place: its key, if it is a member, or its position. `v` and every value inside it read as missing from then on.
///
/// Returns the new value, or a missing value, leaving the document as it was and setting `refused`, if an allocation is refused.
///
/// Examples:
/// ---
/// auto p = parse(`[1,{"a":2},3]`);
/// scope(exit) free(p.document);
/// replace(root(p.document)[1], "x");
/// assert(json(p.document) == `[1,"x",3]`);
/// ---
Value replace(T)(Value v, T value) {
	immutable n = target(v, Kind.missing, "");
	auto d = v.document;
	if (n == dead) return Value(d);
	auto f = &d.scratch;
	scope(exit) reuse(*f);
	add(*f, value);
	immutable node = d.nodes[n];
	return Value(d, splice(*d, indexOf(d, node.parent), node.start, node.end - node.start, n, node.skip - n, *f));
}

/// Sets member `key` of `object`, which must be an object, to `value`, as `set` takes one: replacing its value, as `replace` does, if it has the member, and adding it at the end otherwise.
///
/// Returns the member's new value, or a missing value, leaving the document as it was and setting `refused`, if an allocation is refused.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// auto o = setObject(d);
/// set(o, "a", 1);
/// set(o, "b", null);
/// set(o, "a", "x\n");
/// assert(json(d) == `{"a":"x\n","b":null}`);
/// ---
Value set(T)(Value object, const(char)[] key, T value) {
	immutable o = target(object, Kind.object, "bc.json: setting a member of something not an object");
	auto d = object.document;
	if (o == dead) return Value(d);
	auto existing = object[key];
	if (exists(existing)) return replace(existing, value);
	auto f = &d.scratch;
	scope(exit) reuse(*f);
	if (d.nodes[o].skip > o + 1) put(*f, ",");
	quoted(*f, key);
	put(*f, ":");
	add(*f, value);
	immutable id = splice(*d, o, d.nodes[o].end - 1, 0, d.nodes[o].skip, 0, *f);
	return Value(d, id == dead ? dead : id + 1);
}

// wrapper: names a JSON container kind for the generic operation
/// Sets member `key` of `object` to an empty object or array, and returns it as `set` does.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// auto o = setObject(d);
/// append(setArray(o, "list"), 2);
/// set(setObject(o, "inner"), "x", true);
/// assert(json(d) == `{"list":[2],"inner":{"x":true}}`);
/// ---
Value setObject(Value object, const(char)[] key) { return set(object, key, Empty(Kind.object)); }

// wrapper: names a JSON container kind for the generic operation
/// Ditto
Value setArray(Value object, const(char)[] key) { return set(object, key, Empty(Kind.array)); }

/// Appends `value`, as `set` takes one, to `array`, which must be an array.
///
/// Returns the new element, or a missing value, leaving the document as it was and setting `refused`, if an allocation is refused.
///
/// Examples:
/// ---
/// auto p = parse(`[1]`);
/// scope(exit) free(p.document);
/// append(root(p.document), 2);
/// append(appendArray(root(p.document)), "x");
/// appendObject(root(p.document));
/// assert(json(p.document) == `[1,2,["x"],{}]`);
/// ---
Value append(T)(Value array, T value) {
	immutable a = target(array, Kind.array, "bc.json: appending to something not an array");
	auto d = array.document;
	if (a == dead) return Value(d);
	auto f = &d.scratch;
	scope(exit) reuse(*f);
	if (d.nodes[a].skip > a + 1) put(*f, ",");
	add(*f, value);
	return Value(d, splice(*d, a, d.nodes[a].end - 1, 0, d.nodes[a].skip, 0, *f));
}

/// Appends each of `values`, a slice or input range of values as `set` takes them, to `array`, which must be an array, in one edit: far cheaper than an `append` per element.
///
/// Returns the first new element, or a missing value if `values` is empty, or, leaving the document as it was and setting `refused`, if an allocation is refused.
///
/// Examples:
/// ---
/// static import std.range;
/// auto p = parse(`[0]`);
/// scope(exit) free(p.document);
/// static immutable int[3] numbers = [1, 2, 3];
/// assert(integer(appendAll(root(p.document), numbers[])).get == 1);
/// appendAll(root(p.document), std.range.only("a", "b"));
/// assert(json(p.document) == `[0,1,2,3,"a","b"]`);
/// ---
Value appendAll(R)(Value array, R values) {
	immutable a = target(array, Kind.array, "bc.json: appending to something not an array");
	auto d = array.document;
	if (a == dead) return Value(d);
	auto f = &d.scratch;
	scope(exit) reuse(*f);
	bool first = d.nodes[a].skip == a + 1;
	foreach (value; values) {
		if (!first) put(*f, ",");
		first = false;
		add(*f, value);
	}
	if (fp.dynarray.length(f.nodes) == 0 && !f.refused) return Value(d);
	return Value(d, splice(*d, a, d.nodes[a].end - 1, 0, d.nodes[a].skip, 0, *f));
}

// wrapper: names a JSON container kind for the generic operation
/// Appends an empty object or array to `array`, and returns it as `append` does.
///
/// Examples:
/// ---
/// Document d;
/// scope(exit) free(d);
/// auto a = setArray(d);
/// set(appendObject(a), "k", 1);
/// assert(json(d) == `[{"k":1}]`);
/// ---
Value appendObject(Value array) { return append(array, Empty(Kind.object)); }

// wrapper: names a JSON container kind for the generic operation
/// Ditto
Value appendArray(Value array) { return append(array, Empty(Kind.array)); }

/// Inserts `value`, as `set` takes one, into `array`, which must be an array, before element `i`, which may be one past the last. Past that, it does nothing after an earlier refusal, which may have left the array short, and asserts otherwise.
///
/// Returns the new element, or a missing value, leaving the document as it was and setting `refused`, if an allocation is refused.
///
/// Examples:
/// ---
/// auto p = parse(`[1,3]`);
/// scope(exit) free(p.document);
/// insert(root(p.document), 1, 2);
/// insert(root(p.document), 0, 0);
/// insertArray(root(p.document), 4);
/// assert(json(p.document) == `[0,1,2,3,[]]`);
/// ---
Value insert(T)(Value array, size_t i, T value) {
	immutable a = target(array, Kind.array, "bc.json: inserting into something not an array");
	auto d = array.document;
	if (a == dead) return Value(d);
	immutable before = indexOf(d, array[i].id);
	if (before == dead) {
		if (i == length(array)) return append(array, value);
		assert(d.refused, "bc.json: inserting past an array's end");
		return Value(d);
	}
	auto f = &d.scratch;
	scope(exit) reuse(*f);
	add(*f, value);
	put(*f, ",");
	return Value(d, splice(*d, a, d.nodes[before].start, 0, before, 0, *f));
}

// wrapper: names a JSON container kind for the generic operation
/// Inserts an empty object or array into `array` before element `i`, and returns it as `insert` does.
///
/// Examples:
/// ---
/// auto p = parse(`[1]`);
/// scope(exit) free(p.document);
/// insertObject(root(p.document), 0);
/// assert(json(p.document) == `[{},1]`);
/// ---
Value insertObject(Value array, size_t i) { return insert(array, i, Empty(Kind.object)); }

// wrapper: names a JSON container kind for the generic operation
/// Ditto
Value insertArray(Value array, size_t i) { return insert(array, i, Empty(Kind.array)); }

/// Removes `v` from its container, with its key if it is a member; removing the root empties the document. Every value inside it reads as missing from then on. It never allocates.
///
/// Returns false, changing nothing, if `v` is missing.
///
/// Examples:
/// ---
/// auto p = parse(`{"a":1,"b":[2,3],"c":4}`);
/// scope(exit) free(p.document);
/// auto b = root(p.document)["b"];
/// assert(remove(b[0]) && remove(root(p.document)["a"]));
/// assert(json(p.document) == `{"b":[3],"c":4}` && !remove(root(p.document)["a"]));
/// ---
bool remove(Value v) {
	auto d = v.document;
	immutable n = indexOf(d, v.id);
	if (n == dead) return false;
	Fragment nothing;
	immutable node = d.nodes[n];
	if (node.parent == dead) {
		cast(void) splice(*d, dead, 0, cast(uint) fp.dynarray.length(d.text), 0, cast(uint) fp.dynarray.length(d.nodes), nothing);
		return true;
	}
	immutable p = indexOf(d, node.parent);
	immutable first = d.nodes[p].kind == Kind.object ? n - 1 : n;
	// Minified text puts a comma right before every sibling but the first, so take that one, or else the one after.
	uint from = d.nodes[first].start, to = node.end;
	if (first > p + 1) --from;
	else if (node.skip < d.nodes[p].skip) ++to;
	cast(void) splice(*d, p, from, to - from, first, node.skip - first, nothing);
	return true;
}


version (unittest) {
	static import fp.testing;

	// Whether `d`'s nodes, ids and parents agree with parsing its text again.
	private bool consistent(ref Document d) {
		if (fp.dynarray.length(d.nodes) == 0) return json(d).length == 0;
		auto again = parse(json(d));
		scope(exit) free(again.document);
		if (again.status != Status.ok || fp.dynarray.length(again.document.nodes) != fp.dynarray.length(d.nodes)) return false;
		foreach (k; 0 .. fp.dynarray.length(d.nodes)) {
			immutable a = d.nodes[k], b = again.document.nodes[k];
			if (a.kind != b.kind || a.start != b.start || a.end != b.end || a.skip != b.skip || d.ids[a.id] != k) return false;
			if (a.parent == dead ? b.parent != dead : indexOf(&d, a.parent) != b.parent) return false;
		}
		return true;
	}
}

unittest { // parsing minifies, rejects what is not one value, and reads numbers, booleans and escapes
	auto p = parse(" {\n\t\"list\" : [0, \"a b\", {}, [ ]],\r\"n\": null } ");
	scope(exit) free(p.document);
	assert(p.status == Status.ok && json(p.document) == `{"list":[0,"a b",{},[]],"n":null}` && consistent(p.document));
	auto r = root(p.document);
	assert(length(r["list"]) == 4 && kind(r["list"][2]) == Kind.object && kind(r["n"]) == Kind.null_);
	assert(!exists(r["list"]["x"]) && !exists(r["n"][0]) && !exists(Value.init["a"]));

	foreach (bad; [`{`, `[1,]`, `{"a" 1}`, `"open`, `tru`, `1 2`, ``, `{"a":1,}`, "\"a\nb\"", `{1:2}`]) {
		auto b = parse(bad);
		assert(b.status == Status.malformed && b.document.nodes is null && b.document.text is null);
	}
	char[2 * (maxDepth + 2)] deep = '[';
	deep[maxDepth + 2 .. $] = ']';
	auto deepest = parse(deep[1 .. $ - 1]);
	scope(exit) free(deepest.document);
	assert(deepest.status == Status.ok && parse(deep[]).status == Status.malformed);

	auto numbers = parse(`[12, -7, 1.5, 99999999999999999999, "x", -9223372036854775808, 9223372036854775808, 1e3]`);
	scope(exit) free(numbers.document);
	auto n = root(numbers.document);
	assert(integer(n[0]).get == 12 && integer(n[1]).get == -7 && integer(n[5]).get == long.min);
	foreach (i; [2, 3, 4, 6, 7]) assert(integer(n[i]).isNull);
	assert(boolean(n[0]).isNull && view(n[0]) is null && source(n[9]) is null);

	auto escaped = parse(`"éÉ\uZZZZ😀\ud83dA\ude00\/\"\\\n\r\t\b\f"`);
	scope(exit) free(escaped.document);
	auto decoded = decode(root(escaped.document));
	scope(exit) fp.string.free(decoded.get);
	assert(fp.string.slice(decoded.get) == "éÉ�ZZZZ\U0001F600�A�/\"\\\n\r\t\b\f");
	assert(decode(root(escaped.document)[0]).get is null);
	auto pair = parse(`"\ud83d\ude00!"`);
	scope(exit) free(pair.document);
	auto joined = decode(root(pair.document));
	scope(exit) fp.string.free(joined.get);
	assert(fp.string.slice(joined.get) == "\U0001F600!");

	auto keys = parse(`{"a\"b":1,"é":2,"ab":3}`);
	scope(exit) free(keys.document);
	assert(integer(root(keys.document)["a\"b"]).get == 1 && integer(root(keys.document)["é"]).get == 2);
	assert(integer(root(keys.document)["ab"]).get == 3 && !exists(root(keys.document)["a"]));

	auto previous = fp.testing.limitAllocations(0);
	assert(parse("[1]").status == Status.refused && decode(root(escaped.document)).isNull && decode(r["list"][1]).isNull);
	fp.testing.restoreAllocator(previous);
	for (size_t budget = 1;; ++budget) {
		previous = fp.testing.limitAllocations(budget);
		auto starved = parse(`[1,{"a":[2]}]`);
		fp.testing.restoreAllocator(previous);
		scope(exit) free(starved.document);
		if (starved.status == Status.ok) break;
		assert(starved.status == Status.refused && starved.document.nodes is null && starved.document.text is null);
	}
}

unittest { // pretty lays a document out, and iteration sees every member and element
	auto p = parse(`{"a":[1,[]],"b":{"c":"x"},"d":{}}`);
	scope(exit) free(p.document);
	auto s = pretty(p.document);
	scope(exit) fp.string.free(s.get);
	assert(fp.string.slice(s.get) == "{\n\t\"a\": [\n\t\t1,\n\t\t[]\n\t],\n\t\"b\": {\n\t\t\"c\": \"x\"\n\t},\n\t\"d\": {}\n}");
	Document empty;
	assert(pretty(empty).get is null);
	auto previous = fp.testing.limitAllocations(0);
	assert(pretty(p.document).isNull);
	fp.testing.restoreAllocator(previous);

	char[8] seen;
	size_t count = 0;
	foreach (m; members(root(p.document))) seen[count++] = m.key[0];
	assert(seen[0 .. count] == "abd");
	count = 0;
	foreach (e; elements(root(p.document)["a"])) ++count;
	assert(count == 2 && elements(root(p.document)).empty && members(root(p.document)["a"]).empty);
}

unittest { // edits keep the text minified and the index right, values stay valid, and removal fixes commas
	Document d;
	scope(exit) free(d);
	auto o = setObject(d);
	assert(exists(set(o, "id", 1)));
	auto tags = setArray(o, "tags");
	assert(exists(set(o, "ok", true)));
	assert(exists(append(tags, "a")));
	auto inner = appendObject(tags);
	assert(exists(set(inner, "deep", null)));
	assert(exists(insert(tags, 0, 0u)));
	assert(!d.refused && json(d) == `{"id":1,"tags":[0,"a",{"deep":null}],"ok":true}` && consistent(d));
	assert(view(tags[1]) == "a" && boolean(o["ok"]).get);

	assert(exists(replace(tags, -5)));
	assert(json(d) == `{"id":1,"tags":-5,"ok":true}` && consistent(d) && !exists(inner) && !exists(inner["deep"]));
	assert(integer(tags).isNull && integer(o["tags"]).get == -5);
	assert(exists(replace(o["tags"], Value(&d, o.id))));
	assert(json(d) == `{"id":1,"tags":{"id":1,"tags":-5,"ok":true},"ok":true}` && consistent(d));
	assert(exists(set(o, "copy", o["tags"]["tags"])));
	assert(json(d) == `{"id":1,"tags":{"id":1,"tags":-5,"ok":true},"ok":true,"copy":-5}` && consistent(d));

	assert(remove(o["tags"]["id"]) && remove(o["copy"]) && remove(o["tags"]["ok"]));
	assert(json(d) == `{"id":1,"tags":{"tags":-5},"ok":true}` && consistent(d));
	assert(remove(o["tags"]["tags"]) && json(d) == `{"id":1,"tags":{},"ok":true}` && consistent(d));
	assert(remove(o["id"]) && remove(o["ok"]) && json(d) == `{"tags":{}}` && consistent(d));
	assert(remove(o) && json(d).length == 0 && !exists(root(d)) && consistent(d) && !remove(o));

	auto a = setArray(d);
	foreach (i; 0 .. 5) append(a, i);
	assert(remove(a[2]) && remove(a[0]) && remove(a[2]) && json(d) == `[1,3]` && consistent(d));
	assert(!exists(appendAll(a, (int[]).init)) && json(d) == `[1,3]`);
	Value[2] copies = [Value(&d, a[1].id), Value(&d, a.id)];
	auto bulk = appendAll(a, copies[]);
	assert(json(d) == `[1,3,3,[1,3]]` && integer(bulk).get == 3 && consistent(d));
	auto fresh = setArray(appendObject(a), "x");
	static immutable bool[2] flags = [true, false];
	assert(exists(appendAll(fresh, flags[])));
	assert(exists(append(fresh, null)));
	assert(json(d) == `[1,3,3,[1,3],{"x":[true,false,null]}]` && consistent(d));
	assert(remove(a[4]) && remove(a[3]) && remove(a[2]) && json(d) == `[1,3]` && consistent(d));
	assert(exists(insertArray(a, 2)));
	assert(exists(insertObject(a, 1)));
	assert(exists(set(d, a[2])));
	assert(json(d) == `3` && consistent(d) && !exists(a));

	auto p = parse(`{"params": {"limit": 5, "trace": true}}`);
	scope(exit) free(p.document);
	auto params = root(p.document)["params"];
	assert(exists(set(params, "limit", "ten")));
	assert(remove(params["trace"]) && json(p.document) == `{"params":{"limit":"ten"}}` && consistent(p.document));
	assert(exists(set(params, "x\ty", ulong.max)));
	assert(json(p.document) == `{"params":{"limit":"ten","x\ty":18446744073709551615}}` && integer(params["x\ty"]).isNull);

	// Writing escapes what JSON requires, and reads back as written.
	static immutable awkward = "\x01\"\\\n\r\t\U0001F600";
	auto e = setObject(params, "e");
	assert(exists(set(e, "s", awkward)));
	assert(exists(append(setArray(e, "a"), 1)));
	assert(exists(appendArray(e["a"])));
	assert(source(e) == `{"s":"\u0001\"\\\n\r\t😀","a":[1,[]]}` && consistent(p.document));
	auto back = decode(e["s"]);
	scope(exit) fp.string.free(back.get);
	assert(fp.string.slice(back.get) == awkward && !p.document.refused);

	// Copying a value an earlier refusal left missing is a refusal too.
	Document refusedBefore;
	refusedBefore.refused = true;
	assert(!exists(append(e["a"], Value(&refusedBefore))) && p.document.refused && consistent(p.document));
}

unittest { // a refused edit changes nothing but sets `refused`, and later edits on what it left missing do nothing
	auto copied = parse(`[1]`);
	scope(exit) free(copied.document);
	for (size_t budget = 0;; ++budget) {
		Document d;
		scope(exit) free(d);
		char[64] was;
		size_t wasLength;
		void mark() {
			wasLength = json(d).length;
			if (wasLength) core.stdc.string.memcpy(was.ptr, json(d).ptr, wasLength);
		}
		bool kept(bool done) { return done || json(d) == was[0 .. wasLength]; }
		auto previous = fp.testing.limitAllocations(budget);
		mark();
		auto a = setArray(d);
		assert(kept(exists(a)));
		mark();
		auto o = appendObject(a);
		assert(kept(exists(o)));
		mark();
		assert(kept(exists(set(o, "k", "a\tbcdefghijklmnopqrstuvwxyz"))));
		mark();
		assert(kept(exists(append(a, root(copied.document)))));
		mark();
		assert(kept(exists(insert(a, 1, true))));
		mark();
		static immutable string[3] words = ["x", "y\n", "z"];
		assert(kept(exists(appendAll(a, words[]))));
		immutable removed = remove(a[0]);
		fp.testing.restoreAllocator(previous);
		assert(consistent(d));
		if (d.refused) continue;
		assert(removed && json(d) == `[true,[1],"x","y\n","z"]`);
		break;
	}

	// Edits reuse the document's scratch space, so a run of them allocates only as the document grows, not once or twice per edit.
	Document many;
	scope(exit) free(many);
	auto previous = fp.testing.limitAllocations(100);
	auto list = setArray(many);
	foreach (i; 0 .. 500) {
		assert(exists(set(appendObject(list), "line", i)) && exists(append(list, "x")));
	}
	fp.testing.restoreAllocator(previous);
	assert(!many.refused && length(list) == 1000 && integer(list[998]["line"]).get == 499 && consistent(many));
}
