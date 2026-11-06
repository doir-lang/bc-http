/// An HTTP client shaped like fetch, for native builds and `wasm32-wasi` alike: a `Request` is plain data, `start` begins a `Fetch` without blocking, `poll` advances it, and `readBody` hands its body over as it arrives. `fetch` and `readAll` block, for code that would rather wait.
///
/// It promises only what a browser's fetch can do, so code behaves the same on every target: no setting `Host` or other connection fields, and no reading cookies. Natively it speaks HTTP/1.1 over a socket per request, through `bc.http.message`, with OpenSSL for `https`, or SChannel on Windows, checking certificates against the system's trusted ones, and resolves host names on a thread so nothing blocks. On `wasm32-wasi` it calls the host's fetch through the `bc_http` imports that `js/bc-fetch.mjs` provides, and the module must export `bc_http_wake`.
///
/// Examples:
/// ---
/// Request request = { url: "https://www.craigslist.org/" };
/// auto started = fetch(request);
/// assert(!started.isNull);
/// scope(exit) free(started.get);
/// ref f = started.get;
/// assert(f.state != State.failed && f.status == 200);
/// auto body = readAll(f);
/// assert(!body.isNull && body.get.length > 0);
/// ---
module bc.http;

static import core.stdc.errno;
static import core.stdc.string;

static import std.typecons;

static import fp.dynarray;
static import fp.string;

static import bc.http.message;

public import bc.http.message : Header;

version (WASI) {
	static import ldc.attributes;
} else version (Posix) {
	static import core.atomic;
	static import core.stdc.config;
	static import core.sys.posix.fcntl;
	static import core.sys.posix.netdb;
	static import core.sys.posix.poll;
	static import core.sys.posix.sys.socket;
	static import core.sys.posix.time;
	static import core.sys.posix.unistd;

	static import fp.pointer;

	static import bc.spinlock;
	static import bc.thread;
} else version (Windows) {
	static import core.atomic;

	static import fp.pointer;

	static import bc.spinlock;
	static import bc.thread;

	static import ldc.attributes;
} else static assert(0, "bc.http: no backend for this target");

@nogc nothrow:

version (Windows) version (D_BetterC) {
	// MSVC's linker resolves references even from template code nothing calls, and `Nullable!(const(char)[]).toHash` calls this, which druntime defines.
	private @(ldc.attributes.weak) pragma(mangle, "_D4core8internal4hash19_bytesHashUnalignedFNaNbNiNeMAxhmZm")
	size_t bytesHashUnaligned(scope const(ubyte)[] bytes, size_t seed) pure @trusted {
		foreach (b; bytes) seed = (seed ^ b) * 0x100000001B3;
		return seed;
	}
}

// --- headers -----------------------------------------------------------------

// Where one field's name and value are in its `Headers.text`; offsets, since the text moves as it grows.
private struct Field {
	size_t at;
	size_t nameLength, valueLength;
}

/// Header fields: an ordered multimap from case-insensitive names to values, owning copies of both. Plain data, released by `free`.
struct Headers {
	private char* text = null;
	private Field* fields = null;
}

/// Releases `h`'s fields, leaving it empty.
///
/// Examples:
/// ---
/// Headers h;
/// assert(append(h, "A", "1"));
/// free(h);
/// assert(length(h) == 0);
/// ---
void free(ref Headers h) {
	fp.dynarray.free(h.text);
	fp.dynarray.free(h.fields);
	h = Headers.init;
}

/// How many fields `h` has, counting repeated names separately.
///
/// Examples:
/// ---
/// Headers h;
/// scope(exit) free(h);
/// assert(append(h, "A", "1") && append(h, "a", "2") && length(h) == 2);
/// ---
size_t length(ref const Headers h) {
	return fp.dynarray.length(h.fields);
}

/// Field `i` of `h`, in the order they were added; its text stays valid until `h` next changes.
///
/// Examples:
/// ---
/// Headers h;
/// scope(exit) free(h);
/// assert(append(h, "Accept", "*/*"));
/// assert(at(h, 0) == Header("Accept", "*/*"));
/// ---
Header at(ref const Headers h, size_t i) @trusted {
	assert(i < length(h));
	immutable f = h.fields[i];
	return Header(h.text[f.at .. f.at + f.nameLength], h.text[f.at + f.nameLength .. f.at + f.nameLength + f.valueLength]);
}

/// Adds the field `name: value` after the others, even if one already has that name.
///
/// Returns false, leaving `h` as it was, if `name` is not a valid field name, `value` holds a line break or other control character, or an allocation was refused.
///
/// Examples:
/// ---
/// Headers h;
/// scope(exit) free(h);
/// assert(append(h, "Accept", "text/html") && append(h, "Accept", "text/plain"));
/// assert(!append(h, "Bad Name", "x") && !append(h, "X", "a\r\nb") && length(h) == 2);
/// ---
bool append(ref Headers h, const(char)[] name, const(char)[] value) @trusted {
	if (!bc.http.message.validName(name) || !bc.http.message.validValue(value)) return false;
	immutable at = fp.dynarray.length(h.text);
	if (name.length + value.length && fp.dynarray.grow(h.text, name.length + value.length) is null) return false;
	core.stdc.string.memcpy(h.text + at, name.ptr, name.length);
	core.stdc.string.memcpy(h.text + at + name.length, value.ptr, value.length);
	if (!fp.dynarray.pushBack(h.fields, Field(at, name.length, value.length))) {
		cast(void) fp.dynarray.removeLast(h.text, name.length + value.length);
		return false;
	}
	return true;
}

/// Removes every field named `name`, ignoring case.
///
/// Examples:
/// ---
/// Headers h;
/// scope(exit) free(h);
/// assert(append(h, "A", "1") && append(h, "B", "2") && append(h, "a", "3"));
/// remove(h, "A");
/// assert(length(h) == 1 && at(h, 0).name == "B");
/// ---
void remove(ref Headers h, const(char)[] name) {
	for (size_t i = length(h); i-- > 0;)
		if (fp.string.equalIgnoringAsciiCase(at(h, i).name, name)) cast(void) fp.dynarray.removeAt(h.fields, i);
}

/// Makes `name: value` the only field named `name`, after the others.
///
/// Returns false, leaving `h` as it was, as `append` does.
///
/// Examples:
/// ---
/// Headers h;
/// scope(exit) free(h);
/// assert(append(h, "A", "1") && append(h, "B", "2") && set(h, "a", "3"));
/// assert(length(h) == 2 && at(h, 1) == Header("a", "3"));
/// ---
bool set(ref Headers h, const(char)[] name, const(char)[] value) {
	if (!append(h, name, value)) return false;
	for (size_t i = length(h) - 1; i-- > 0;)
		if (fp.string.equalIgnoringAsciiCase(at(h, i).name, name)) cast(void) fp.dynarray.removeAt(h.fields, i);
	return true;
}

/// The value of the first field named `name`, ignoring case; it stays valid until `h` next changes.
///
/// Returns an empty `Nullable` if there is none.
///
/// Examples:
/// ---
/// Headers h;
/// scope(exit) free(h);
/// assert(append(h, "Content-Type", "text/plain"));
/// assert(get(h, "content-type").get == "text/plain" && get(h, "Accept").isNull);
/// ---
std.typecons.Nullable!(const(char)[]) get(ref const Headers h, const(char)[] name) {
	foreach (i; 0 .. length(h)) {
		auto f = at(h, i);
		if (fp.string.equalIgnoringAsciiCase(f.name, name)) return typeof(return)(f.value);
	}
	return typeof(return).init;
}

// Appends a copy of each of `from`'s fields to `to`; false, with `to` partly filled, if an allocation was refused.
private bool appendAll(ref Headers to, ref const Headers from) {
	foreach (i; 0 .. length(from)) {
		auto f = at(from, i);
		if (!append(to, f.name, f.value)) return false;
	}
	return true;
}


// --- requests and fetches ----------------------------------------------------

/// What a `Request` does when the response redirects it elsewhere.
enum Redirect : ubyte {
	follow, /// Follows the redirect, up to `maxRedirects` of them.
	error, /// Fails with `Failure.redirectRefused`.
	manual, /// Hands over the redirecting response. A browser hides it: its status is then 0 and it has no fields.
}

/// The most redirects one `Fetch` follows before failing with `Failure.tooManyRedirects`, as fetch allows.
enum ubyte maxRedirects = 20;

/// What to ask for. Plain data: `start` copies what it needs, so the request can change or be freed once it returns.
struct Request {
	const(char)[] url; /// An absolute `http` URL; a browser also takes `https` and URLs relative to the page.
	const(char)[] method = "GET"; /// A token; `get`, `post` and the other standard methods are made upper case, as fetch does.
	Headers headers; /// Fields to send. Natively, ones the connection manages, such as `Host`, `Content-Length` and `Connection`, are dropped; a browser drops more, such as `Cookie`.
	const(char)[] body; /// What to send after the head; a `GET` or `HEAD` request must have none.
	Redirect redirect = Redirect.follow; /// What to do when redirected.
	uint timeoutMs = 0; /// How long the whole exchange, body included, may take before failing with `Failure.timeout`; 0 for no limit.
}

/// Where a `Fetch` is.
enum State : ubyte {
	pending, /// Waiting for the response's head.
	head, /// The status and fields are in; the body may still be arriving.
	done, /// The whole body has arrived, though `readBody` may not have taken all of it.
	failed, /// It stopped; `Fetch.failure` says why.
}

/// Why a `Fetch` failed.
enum Failure : ubyte {
	none, /// It has not.
	invalidRequest, /// The method is not a token or is one fetch forbids, such as `CONNECT`, or a `GET` or `HEAD` request has a body.
	invalidUrl, /// The URL could not be parsed.
	unsupported, /// The URL's scheme is not one this target can fetch, such as `ftp`, or OpenSSL or SChannel could not set up `https`.
	network, /// The host could not be found or reached, its certificate was not trusted for its name, the connection broke, or the response was not HTTP.
	timeout, /// `Request.timeoutMs` passed.
	tooManyRedirects, /// It was redirected more than `maxRedirects` times. A browser does not say so, and reports `network` instead.
	redirectRefused, /// It was redirected under `Redirect.error`.
	aborted, /// `abort` stopped it.
	outOfMemory, /// An allocation was refused.
}

version (WASI) {
	// A web exchange: the host's number for it, 0 once closed.
	private struct Exchange {
		int id;
	}
} else {
	private enum Phase : ubyte { resolving, connecting, handshaking, sending, receiving }

	version (Posix) {

		// A native exchange: its connection, a copy of the request to send again when redirected, and bytes received but not yet handed over.
		private struct Exchange {
			int fd = -1;
			Phase phase;
			short events; // what `fd` must be ready for before `advance` can go on
			bool eof;
			ubyte redirects;
			Redirect redirect;
			Lookup* lookup;
			core.sys.posix.netdb.addrinfo* next; // the address to try if connecting fails
			Tls tls;
			char* method = null;
			Headers headers;
			char* payload = null;
			char* out_ = null;
			char* wire = null; // TLS records waiting to be sent
			size_t sent;
			char* in_ = null;
			bc.http.message.Body body;
			char* ready = null;
			size_t taken;
		}
	} else version (Windows) {
		// A native exchange: its connection and readiness event, a copy of the request to send again when redirected, and bytes not yet handed over.
		private struct Exchange {
			size_t fd = invalidSocket;
			void* event;
			Phase phase;
			bool eof;
			ubyte redirects;
			Redirect redirect;
			Lookup* lookup;
			AddressInfo* next; // the address to try if connecting fails
			Tls tls;
			char* method = null;
			Headers headers;
			char* payload = null;
			char* out_ = null;
			char* wire = null; // TLS records waiting to be sent
			size_t sent;
			char* in_ = null;
			bc.http.message.Body body;
			char* ready = null;
			size_t taken;
		}
	}
}

/// One request and its response, from `start` until `free`. Plain data owned by the caller; its members are read-only to it, and `free` releases it and stops it if it is still going.
struct Fetch {
	State state; /// Where it is.
	Failure failure; /// Why it failed, once `state` is `State.failed`.
	ushort status; /// The response's status, from `State.head` on.
	Headers headers; /// The response's fields, from `State.head` on.
	const(char)[] url; /// The URL fetched, the last one if it was redirected.
	private char* urlText = null;
	private ulong deadline;
	private char* whole = null;
	private Exchange exchange;
}


// --- the web backend ---------------------------------------------------------

version (WASI) {
	// The imports js/bc-fetch.mjs provides; it runs each exchange with the host's fetch, keeping its head and body until they are read.
	private extern (C) {
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "start")) int hostStart(const(char)* request, size_t length);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "state")) int hostState(int id);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "failure")) int hostFailure(int id);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "status")) int hostStatus(int id);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "headLength")) size_t hostHeadLength(int id);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "copyHead")) void hostCopyHead(int id, char* into);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "buffered")) size_t hostBuffered(int id);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "read")) size_t hostRead(int id, char* into, size_t length);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "close")) void hostClose(int id);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "generation")) int hostGeneration();
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "wait")) int hostWait(int generation, int timeoutMs);
		@(ldc.attributes.llvmAttr("wasm-import-module", "bc_http"), ldc.attributes.llvmAttr("wasm-import-name", "now")) double hostNow();
	}

	// What `hostState` reports; it matches js/bc-fetch.mjs.
	private enum HostState : int { pending, head, done, failed }

	private void release(ref Exchange e) {
		if (e.id) hostClose(e.id);
		e.id = 0;
	}

	private void fail(ref Fetch f, Failure why) {
		f.state = State.failed;
		f.failure = why;
		release(f.exchange);
	}

	// Appends `n` as a little-endian 32-bit length, the way js/bc-fetch.mjs reads a request's parts.
	private bool length32(ref char* to, size_t n) {
		char[4] bytes = [cast(char) n, cast(char) (n >> 8), cast(char) (n >> 16), cast(char) (n >> 24)];
		return fp.dynarray.concatenate(to, bytes[]);
	}

	// Serializes `r` for `hostStart`: method, URL, the redirect mode as one byte, the header lines, then the body, each but the mode after its length.
	private bool serialize(ref char* to, ref const Request r, const(char)[] method) {
		size_t fieldsLength = 0;
		foreach (i; 0 .. length(r.headers)) fieldsLength += at(r.headers, i).name.length + at(r.headers, i).value.length + 4;
		char[1] mode = [cast(char) r.redirect];
		if (!length32(to, method.length) || !fp.dynarray.concatenate(to, method) || !length32(to, r.url.length) || !fp.dynarray.concatenate(to, r.url) || !fp.dynarray.concatenate(to, mode[]) || !length32(to, fieldsLength)) return false;
		foreach (i; 0 .. length(r.headers)) {
			auto f = at(r.headers, i);
			if (!fp.dynarray.concatenate(to, f.name) || !fp.dynarray.concatenate(to, ": ") || !fp.dynarray.concatenate(to, f.value) || !fp.dynarray.concatenate(to, "\r\n")) return false;
		}
		return length32(to, r.body.length) && fp.dynarray.concatenate(to, r.body);
	}

	private bool begin(ref Fetch f, ref const Request r, const(char)[] method) {
		char* request = null;
		scope(exit) fp.dynarray.free(request);
		if (!serialize(request, r, method) || !fp.dynarray.concatenate(f.urlText, r.url)) return false;
		f.url = fp.dynarray.slice(f.urlText);
		f.exchange.id = hostStart(request, fp.dynarray.length(request));
		return true;
	}

	// Takes the head the host has: the final URL on the first line, then a field per line.
	private void readHead(ref Fetch f) @trusted {
		auto e = &f.exchange;
		char* text = null;
		scope(exit) fp.dynarray.free(text);
		immutable size = hostHeadLength(e.id);
		if (size && fp.dynarray.growToSize(text, size) is null) return fail(f, Failure.outOfMemory);
		if (size) hostCopyHead(e.id, text);
		auto rest = text[0 .. size];
		bool first = true;
		while (rest.length) {
			size_t end = 0;
			while (end + 1 < rest.length && (rest[end] != '\r' || rest[end + 1] != '\n')) ++end;
			auto line = rest[0 .. end];
			rest = rest[end + 2 > rest.length ? rest.length : end + 2 .. $];
			if (first) {
				first = false;
				fp.dynarray.clear(f.urlText);
				if (!fp.dynarray.concatenate(f.urlText, line)) return fail(f, Failure.outOfMemory);
				f.url = fp.dynarray.slice(f.urlText);
				continue;
			}
			size_t colon = 0;
			while (colon < line.length && line[colon] != ':') ++colon;
			auto value = colon + 2 <= line.length ? line[colon + 2 .. $] : null;
			if (colon < line.length && !append(f.headers, line[0 .. colon], value) && bc.http.message.validName(line[0 .. colon]) && bc.http.message.validValue(value)) return fail(f, Failure.outOfMemory);
		}
		f.status = cast(ushort) hostStatus(e.id);
		f.state = State.head;
	}

	private void advance(ref Fetch f) {
		immutable state = hostState(f.exchange.id);
		if (state == HostState.failed) return fail(f, cast(Failure) hostFailure(f.exchange.id));
		if (f.state == State.pending && state != HostState.pending) readHead(f);
		if (f.state == State.head && state == HostState.done) f.state = State.done;
	}

	private size_t buffered(ref const Fetch f) {
		return f.exchange.id ? hostBuffered(f.exchange.id) : 0;
	}

	private size_t take(ref Fetch f, char[] into) {
		return f.exchange.id ? hostRead(f.exchange.id, into.ptr, into.length) : 0;
	}

	// The generation is read before the fetches are looked at, so a change made while looking still ends the wait at once.
	private bool waitFor(Fetch*[] fs, int timeoutMs) {
		immutable generation = hostGeneration();
		foreach (f; fs) {
			if ((f.state != State.pending && f.state != State.head) || buffered(*f)) return true;
			immutable state = hostState(f.exchange.id);
			if (state == HostState.failed || (f.state == State.pending && state != HostState.pending) || (f.state == State.head && state == HostState.done)) return true;
		}
		return hostWait(generation, timeoutMs) != 0;
	}
}


// --- the native backend ------------------------------------------------------

version (WASI) {
} else {
	version (unittest) {
		static import fp.pointer;

		// Thread-local, like `fp.pointer.allocator`, so a resolving thread never uses up a failure armed for the tests.
		private bool failureArmed;
		private size_t acquisitionsLeft;
		private fp.pointer.Allocator originalAllocator;

		// Whether the acquisition about to be made, an allocation, an OpenSSL object or a thread, should fail as `failAfter` arranged.
		private bool simulatedFailure() {
			if (!failureArmed || acquisitionsLeft-- > 0) return false;
			failureArmed = false;
			fp.pointer.allocator = originalAllocator;
			return true;
		}

		private void* refusingAllocator(void* p, size_t size) {
			// A size of 0 is a free, which must neither fail nor count.
			if (size != 0 && simulatedFailure()) return null;
			return originalAllocator(p, size);
		}

		// Lets the next `count` acquisitions on this thread succeed and fails the one after.
		private void failAfter(size_t count) {
			if (!failureArmed) originalAllocator = fp.pointer.allocator;
			acquisitionsLeft = count;
			failureArmed = true;
			fp.pointer.allocator = &refusingAllocator;
		}
	}

	private void release(ref Exchange e) {
		disconnect(e);
		fp.dynarray.free(e.method);
		free(e.headers);
		fp.dynarray.free(e.payload);
		fp.dynarray.free(e.out_);
		fp.dynarray.free(e.wire);
		fp.dynarray.free(e.in_);
		fp.dynarray.free(e.ready);
		e = Exchange.init;
	}

	private void fail(ref Fetch f, Failure why) {
		f.state = State.failed;
		f.failure = why;
		disconnect(f.exchange);
	}

	// Writes request `e` for `url` into `e.out_`, replacing what was there; false if an allocation was refused.
	private bool compose(ref Exchange e, ref const bc.http.message.Url url) {
		static immutable managed = ["host", "content-length", "connection", "transfer-encoding", "keep-alive", "upgrade", "te", "trailer", "expect"];
		fp.dynarray.clear(e.out_);
		e.sent = 0;
		auto method = fp.dynarray.slice(e.method);
		if (!bc.http.message.writeRequestLine(e.out_, method, url.target) || !bc.http.message.writeField(e.out_, "Host", url.authority)) return false;
		fields: foreach (i; 0 .. length(e.headers)) {
			auto f = at(e.headers, i);
			foreach (m; managed) if (fp.string.equalIgnoringAsciiCase(f.name, m)) continue fields;
			if (!bc.http.message.writeField(e.out_, f.name, f.value)) return false;
		}
		immutable size = fp.dynarray.length(e.payload);
		if (size || method == "POST" || method == "PUT" || method == "PATCH") {
			char[fp.string.maxDecimalLength] digits;
			if (!bc.http.message.writeField(e.out_, "Content-Length", fp.string.formatUnsigned(size, digits))) return false;
		}
		return bc.http.message.writeField(e.out_, "Connection", "close") && bc.http.message.endHead(e.out_) && fp.dynarray.concatenate(e.out_, fp.dynarray.slice(e.payload));
	}

	// Starts fetching `f.url` afresh: writes the request, sets up TLS for https, and resolves the host, on a thread unless it is an address.
	private void connect(ref Fetch f) @trusted {
		auto e = &f.exchange;
		auto parsed = bc.http.message.parseUrl(f.url);
		if (parsed.isNull) return fail(f, Failure.invalidUrl);
		auto url = parsed.get;
		immutable https = fp.string.equalIgnoringAsciiCase(url.scheme, "https");
		if (!https && !fp.string.equalIgnoringAsciiCase(url.scheme, "http")) return fail(f, Failure.unsupported);
		if (url.host.length >= Lookup.host.length) return fail(f, Failure.invalidUrl);
		if (!compose(*e, url)) return fail(f, Failure.outOfMemory);

		// Whichever thread drops the last reference frees the block, so the allocator that made it travels with it.
		auto allocate = fp.pointer.allocator;
		auto l = cast(Lookup*) allocate(null, Lookup.sizeof);
		if (l is null) return fail(f, Failure.outOfMemory);
		*l = Lookup.init;
		l.memory = allocate;
		l.references = 1;
		e.lookup = l;
		core.stdc.string.memcpy(l.host.ptr, url.host.ptr, url.host.length);
		char[fp.string.maxDecimalLength] buffer;
		const digits = fp.string.formatUnsigned(url.port, buffer);
		core.stdc.string.memcpy(l.port.ptr, digits.ptr, digits.length);

		immutable address = lookUp(*l, true) == 0;
		if (https && !secure(f, l.host.ptr, address)) return;
		if (address) return dial(f, l.found);
		if (signalable(*l)) {
			core.atomic.atomicStore(l.references, 2);
			std.typecons.Nullable!(bc.thread.Thread) thread;
			bool failed = false;
			version (unittest) failed = simulatedFailure();
			if (!failed) thread = bc.thread.create(&resolveOnThread, l);
			if (!thread.isNull) {
				bc.thread.detach(thread.get);
				e.phase = Phase.resolving;
				return;
			}
			core.atomic.atomicStore(l.references, 1);
		}
		// Without a thread, resolving blocks here, as it would have before.
		if (lookUp(*l, false) != 0) return fail(f, Failure.network);
		dial(f, l.found);
	}

	// The URL `location` names, read against `base`, as a new fp dynarray; null if an allocation was refused.
	private char* resolve(const(char)[] base, const(char)[] location) {
		auto b = bc.http.message.parseUrl(base).get;
		size_t i = 0;
		while (i < location.length && ((location[i] >= 'a' && location[i] <= 'z') || (location[i] >= 'A' && location[i] <= 'Z') || (i > 0 && ((location[i] >= '0' && location[i] <= '9') || location[i] == '+' || location[i] == '-' || location[i] == '.')))) ++i;
		const(char)[][4] pieces;
		if (i > 0 && i < location.length && location[i] == ':') pieces[0] = location;
		else if (location.length >= 2 && location[0 .. 2] == "//") {
			pieces[0] = b.scheme;
			pieces[1] = ":";
			pieces[2] = location;
		} else {
			pieces[0] = base[0 .. b.scheme.length + 3 + b.authority.length];
			auto path = b.target;
			foreach (k, c; path) if (c == '?') {
				path = path[0 .. k];
				break;
			}
			if (location.length && location[0] == '/') pieces[1] = location;
			else if (location.length == 0 || location[0] == '?') {
				pieces[1] = path.length ? path : "/";
				pieces[2] = location.length ? location : b.target[path.length .. $];
			} else {
				size_t slash = path.length;
				while (slash > 0 && path[slash - 1] != '/') --slash;
				pieces[1] = slash ? path[0 .. slash] : "/";
				pieces[2] = location;
			}
		}
		char* joined = null;
		foreach (p; pieces) if (!fp.dynarray.concatenate(joined, p)) {
			fp.dynarray.free(joined);
			return null;
		}
		return joined;
	}

	// Follows the redirect to `location` that response `status` gave, or fails `f` as its request asks.
	private void redirect(ref Fetch f, ushort status, const(char)[] location) {
		auto e = &f.exchange;
		if (e.redirect == Redirect.error) return fail(f, Failure.redirectRefused);
		if (e.redirects == maxRedirects) return fail(f, Failure.tooManyRedirects);
		++e.redirects;
		char* next = resolve(f.url, location);
		if (next is null) return fail(f, Failure.outOfMemory);
		auto from = bc.http.message.parseUrl(f.url).get, to = bc.http.message.parseUrl(fp.dynarray.slice(next));
		if (to.isNull) {
			fp.dynarray.free(next);
			return fail(f, Failure.invalidUrl);
		}
		if (!fp.string.equalIgnoringAsciiCase(from.scheme, to.get.scheme) || !fp.string.equalIgnoringAsciiCase(from.host, to.get.host) || from.port != to.get.port) remove(e.headers, "authorization");
		auto method = fp.dynarray.slice(e.method);
		if ((status == 303 && method != "HEAD") || ((status == 301 || status == 302) && method == "POST")) {
			fp.dynarray.clear(e.method);
			// `begin` reserved room for it, so this allocates nothing.
			cast(void) fp.dynarray.concatenate(e.method, "GET");
			fp.dynarray.clear(e.payload);
			foreach (name; ["content-type", "content-encoding", "content-language", "content-location"]) remove(e.headers, name);
		}
		disconnect(*e);
		fp.dynarray.free(f.urlText);
		f.urlText = next;
		f.url = fp.dynarray.slice(next);
		fp.dynarray.clear(e.in_);
		e.eof = false;
		connect(f);
	}

	// Reads what `f.exchange.in_` holds: the head, which may redirect, then body bytes into `ready`, finishing `f` where the body ends.
	private void digest(ref Fetch f) @trusted {
		auto e = &f.exchange;
		if (f.state == State.pending) {
			bc.http.message.Head h;
			for (;;) {
				h = bc.http.message.parseHead(fp.dynarray.slice(e.in_), fp.dynarray.slice(e.method));
				if (h.progress == bc.http.message.Progress.needMore) {
					if (e.eof) fail(f, Failure.network);
					return;
				}
				if (h.progress == bc.http.message.Progress.malformed) return fail(f, Failure.network);
				if (h.status >= 200 || h.status < 100 || h.status == 101) break;
				cast(void) fp.dynarray.removeRange(e.in_, 0, h.size);
			}
			if (e.redirect != Redirect.manual && (h.status == 301 || h.status == 302 || h.status == 303 || h.status == 307 || h.status == 308)) {
				foreach (field; bc.http.message.fieldsOf(h))
					if (fp.string.equalIgnoringAsciiCase(field.name, "location")) return redirect(f, h.status, field.value);
			}
			foreach (field; bc.http.message.fieldsOf(h))
				if (!append(f.headers, field.name, field.value)) return fail(f, Failure.outOfMemory);
			f.status = h.status;
			f.state = State.head;
			e.body = bc.http.message.bodyOf(h);
			cast(void) fp.dynarray.removeRange(e.in_, 0, h.size);
		}
		auto d = bc.http.message.decode(e.body, fp.dynarray.slice(e.in_));
		if (d.malformed) return fail(f, Failure.network);
		if (!fp.dynarray.concatenate(e.ready, e.in_[0 .. d.produced])) return fail(f, Failure.outOfMemory);
		cast(void) fp.dynarray.removeRange(e.in_, 0, d.used);
		if (bc.http.message.ended(e.body) || (e.eof && e.body.framing == bc.http.message.Framing.close)) {
			f.state = State.done;
			disconnect(*e);
		} else if (e.eof) fail(f, Failure.network);
	}

	// Body bytes held for `readBody` past which reading stops until it takes some, so a slow reader does not make a fetch buffer without end.
	private enum size_t maxReady = 1 << 20;

	private size_t buffered(ref const Fetch f) {
		return fp.dynarray.length(f.exchange.ready) - f.exchange.taken;
	}

	private bool begin(ref Fetch f, ref const Request r, const(char)[] method) {
		auto e = &f.exchange;
		e.redirect = r.redirect;
		if (!fp.dynarray.concatenate(f.urlText, r.url) || fp.dynarray.reserve(e.method, "GET".length) is null || !fp.dynarray.concatenate(e.method, method) || !appendAll(e.headers, r.headers) || !fp.dynarray.concatenate(e.payload, r.body)) return false;
		f.url = fp.dynarray.slice(f.urlText);
		connect(f);
		return true;
	}

	private enum Pulled : ubyte { some, later, end, broken }

	private size_t take(ref Fetch f, char[] into) @trusted {
		auto e = &f.exchange;
		immutable n = buffered(f) < into.length ? buffered(f) : into.length;
		core.stdc.string.memcpy(into.ptr, e.ready + e.taken, n);
		e.taken += n;
		if (e.taken == fp.dynarray.length(e.ready)) {
			fp.dynarray.clear(e.ready);
			e.taken = 0;
		}
		return n;
	}
}

version (WASI) {
} else version (Posix) {
	// The OpenSSL 3 functions https uses; dub.json links libssl and libcrypto.
	private extern (C) {
		struct SSL_METHOD;
		struct SSL_CTX;
		struct SSL;
		struct BIO;
		struct BIO_METHOD;
		struct X509_VERIFY_PARAM;
		const(SSL_METHOD)* TLS_client_method();
		SSL_CTX* SSL_CTX_new(const(SSL_METHOD)* method);
		void SSL_CTX_free(SSL_CTX* context);
		int SSL_CTX_set_default_verify_paths(SSL_CTX* context);
		void SSL_CTX_set_verify(SSL_CTX* context, int mode, void* callback);
		SSL* SSL_new(SSL_CTX* context);
		void SSL_free(SSL* ssl);
		void SSL_set_bio(SSL* ssl, BIO* read, BIO* write);
		void SSL_set_connect_state(SSL* ssl);
		core.stdc.config.c_long SSL_ctrl(SSL* ssl, int command, core.stdc.config.c_long argument, void* pointer);
		int SSL_set1_host(SSL* ssl, const(char)* host);
		X509_VERIFY_PARAM* SSL_get0_param(SSL* ssl);
		int X509_VERIFY_PARAM_set1_ip_asc(X509_VERIFY_PARAM* parameters, const(char)* address);
		int SSL_do_handshake(SSL* ssl);
		int SSL_read(SSL* ssl, void* into, int length);
		int SSL_write(SSL* ssl, const(void)* from, int length);
		int SSL_get_error(const(SSL)* ssl, int result);
		const(BIO_METHOD)* BIO_s_mem();
		BIO* BIO_new(const(BIO_METHOD)* method);
		int BIO_free(BIO* bio);
		int BIO_read(BIO* bio, void* into, int length);
		int BIO_write(BIO* bio, const(void)* from, int length);
		size_t BIO_ctrl_pending(BIO* bio);
		void ERR_clear_error();
	}

	private enum int sslVerifyPeer = 1, sslCtrlSetTlsextHostname = 55, sslErrorWantRead = 2, sslErrorWantWrite = 3, sslErrorZeroReturn = 6;

	// One connection's TLS: the session, and the memory BIOs it reads records from and writes them to, which it owns.
	private struct Tls {
		SSL* ssl;
		BIO* read;
		BIO* write;
	}

	private __gshared SSL_CTX* tlsShared;
	private __gshared bc.spinlock.SpinLock tlsLock;

	// The context every https fetch shares, made on first use, trusting the system's certificates; null if OpenSSL could not make it.
	private SSL_CTX* tlsContext() {
		bc.spinlock.lockForWriting(tlsLock);
		scope(exit) bc.spinlock.unlockForWriting(tlsLock);
		if (tlsShared is null) {
			bool failed = false;
			version (unittest) failed = simulatedFailure();
			auto context = failed ? null : SSL_CTX_new(TLS_client_method());
			if (context is null || SSL_CTX_set_default_verify_paths(context) != 1) {
				if (context !is null) SSL_CTX_free(context);
				return null;
			}
			SSL_CTX_set_verify(context, sslVerifyPeer, null);
			tlsShared = context;
		}
		return tlsShared;
	}

	// A host name being resolved on a thread of its own, which shares it; whichever side drops the last reference frees it.
	private struct Lookup {
		shared int references;
		fp.pointer.Allocator memory; // the allocator this block came from, not the freeing thread's
		int[2] done = -1; // the thread writes a byte to `done[1]` once `error` and `found` are set
		int error;
		core.sys.posix.netdb.addrinfo* found;
		char[256] host = 0;
		char[6] port = 0;
	}

	private void drop(Lookup* l) @trusted {
		if (l is null || core.atomic.atomicOp!"-="(l.references, 1) != 0) return;
		foreach (fd; l.done) if (fd >= 0) cast(void) core.sys.posix.unistd.close(fd);
		if (l.found !is null) core.sys.posix.netdb.freeaddrinfo(l.found);
		cast(void) l.memory(cast(void*) l, 0);
	}

	private int lookUp(ref Lookup l, bool numeric) @trusted {
		core.sys.posix.netdb.addrinfo hints;
		hints.ai_socktype = core.sys.posix.sys.socket.SOCK_STREAM;
		hints.ai_flags = numeric ? core.sys.posix.netdb.AI_NUMERICHOST : 0;
		return core.sys.posix.netdb.getaddrinfo(l.host.ptr, l.port.ptr, &hints, &l.found);
	}

	private void resolveOnThread(Lookup* l) @trusted {
		l.error = lookUp(*l, false);
		immutable char one = 1;
		cast(void) core.sys.posix.unistd.write(l.done[1], &one, 1);
		drop(l);
	}

	private void nonblocking(int fd) @trusted {
		cast(void) core.sys.posix.fcntl.fcntl(fd, core.sys.posix.fcntl.F_SETFD, core.sys.posix.fcntl.FD_CLOEXEC);
		cast(void) core.sys.posix.fcntl.fcntl(fd, core.sys.posix.fcntl.F_SETFL, core.sys.posix.fcntl.fcntl(fd, core.sys.posix.fcntl.F_GETFL) | core.sys.posix.fcntl.O_NONBLOCK);
	}

	// Makes the pipe the resolving thread signals through; false if it cannot.
	private bool signalable(ref Lookup l) @trusted {
		if (core.sys.posix.unistd.pipe(l.done) != 0) return false;
		nonblocking(l.done[0]);
		nonblocking(l.done[1]);
		return true;
	}

	private void disconnect(ref Exchange e) {
		if (e.fd >= 0) cast(void) core.sys.posix.unistd.close(e.fd);
		e.fd = -1;
		drop(e.lookup);
		e.lookup = null;
		e.next = null;
		if (e.tls.ssl !is null) SSL_free(e.tls.ssl);
		e.tls = Tls.init;
		fp.dynarray.clear(e.wire);
	}

	// Starts connecting to the first address from `a` that takes a socket, remembering the rest; fails `f` if none does.
	private void dial(ref Fetch f, core.sys.posix.netdb.addrinfo* a) @trusted {
		auto e = &f.exchange;
		for (; a !is null; a = a.ai_next) {
			immutable fd = core.sys.posix.sys.socket.socket(a.ai_family, a.ai_socktype, a.ai_protocol);
			if (fd < 0) continue;
			nonblocking(fd);
			static if (__traits(compiles, core.sys.posix.sys.socket.SO_NOSIGPIPE)) {
				int one = 1;
				cast(void) core.sys.posix.sys.socket.setsockopt(fd, core.sys.posix.sys.socket.SOL_SOCKET, core.sys.posix.sys.socket.SO_NOSIGPIPE, &one, one.sizeof);
			}
			if (core.sys.posix.sys.socket.connect(fd, a.ai_addr, a.ai_addrlen) == 0 || core.stdc.errno.errno == core.stdc.errno.EINPROGRESS) {
				e.fd = fd;
				e.next = a.ai_next;
				e.phase = Phase.connecting;
				e.events = core.sys.posix.poll.POLLOUT;
				return;
			}
			cast(void) core.sys.posix.unistd.close(fd);
		}
		fail(f, Failure.network);
	}

	// Sets up TLS for `host`, checking the certificate against it as a name or, when `address`, an IP address; fails `f` if it cannot.
	private bool secure(ref Fetch f, const(char)* host, bool address) @trusted {
		auto context = tlsContext();
		if (context is null) {
			fail(f, Failure.unsupported);
			return false;
		}
		auto t = &f.exchange.tls;
		bool failed = false;
		version (unittest) failed = simulatedFailure();
		t.ssl = failed ? null : SSL_new(context);
		auto read = BIO_new(BIO_s_mem()), write = BIO_new(BIO_s_mem());
		if (t.ssl is null || read is null || write is null) {
			if (read !is null) cast(void) BIO_free(read);
			if (write !is null) cast(void) BIO_free(write);
			fail(f, Failure.outOfMemory);
			return false;
		}
		SSL_set_bio(t.ssl, read, write);
		t.read = read;
		t.write = write;
		SSL_set_connect_state(t.ssl);
		immutable named = address ? X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(t.ssl), host) == 1
			: SSL_ctrl(t.ssl, sslCtrlSetTlsextHostname, 0, cast(void*) host) == 1 && SSL_set1_host(t.ssl, host) == 1;
		if (!named) fail(f, Failure.outOfMemory);
		return named;
	}

	static if (__traits(compiles, core.sys.posix.sys.socket.MSG_NOSIGNAL)) private enum int sendFlags = core.sys.posix.sys.socket.MSG_NOSIGNAL;
	else private enum int sendFlags = 0;

	private bool wouldBlock() {
		return core.stdc.errno.errno == core.stdc.errno.EAGAIN || core.stdc.errno.errno == core.stdc.errno.EWOULDBLOCK;
	}

	// Sends what is left of the request, or of TLS's records; false until all is sent, having set `events` or failed `f`.
	private bool transmit(ref Fetch f) @trusted {
		auto e = &f.exchange;
		auto bytes = e.tls.ssl !is null ? e.wire : e.out_;
		immutable total = fp.dynarray.length(bytes);
		while (e.sent < total) {
			immutable wrote = core.sys.posix.sys.socket.send(e.fd, bytes + e.sent, total - e.sent, sendFlags);
			if (wrote < 0 && core.stdc.errno.errno == core.stdc.errno.EINTR) continue;
			if (wrote < 0 && wouldBlock()) {
				e.events = core.sys.posix.poll.POLLOUT;
				return false;
			}
			if (wrote <= 0) {
				fail(f, Failure.network);
				return false;
			}
			e.sent += wrote;
		}
		if (e.tls.ssl !is null) {
			fp.dynarray.clear(e.wire);
			e.sent = 0;
		}
		return true;
	}

	// Moves the records TLS has written into `wire`, to be sent; false if an allocation was refused.
	private bool seal(ref Exchange e) @trusted {
		for (size_t pending; (pending = BIO_ctrl_pending(e.tls.write)) > 0;) {
			immutable at = fp.dynarray.length(e.wire);
			if (fp.dynarray.grow(e.wire, pending) is null) return false;
			cast(void) BIO_read(e.tls.write, e.wire + at, cast(int) pending);
		}
		return true;
	}

	// Has TLS seal the whole request into `wire`; false, having failed `f`, if it cannot.
	private bool encrypt(ref Fetch f) @trusted {
		auto e = &f.exchange;
		immutable total = fp.dynarray.length(e.out_);
		for (size_t at = 0; at < total;) {
			immutable n = total - at < (1 << 14) ? total - at : 1 << 14;
			ERR_clear_error();
			bool failed = false;
			version (unittest) failed = simulatedFailure();
			immutable wrote = failed ? -1 : SSL_write(e.tls.ssl, e.out_ + at, cast(int) n);
			if (wrote <= 0) {
				fail(f, Failure.network);
				return false;
			}
			at += wrote;
			if (!seal(*e)) {
				fail(f, Failure.outOfMemory);
				return false;
			}
		}
		return true;
	}

	// Moves the bytes the socket has into TLS's read BIO; on `Pulled.later` it has set `events`, and on `Pulled.broken` failed `f`.
	private Pulled pull(ref Fetch f) @trusted {
		auto e = &f.exchange;
		char[1 << 14] bytes = void;
		ptrdiff_t got;
		do got = core.sys.posix.sys.socket.recv(e.fd, bytes.ptr, bytes.length, 0);
		while (got < 0 && core.stdc.errno.errno == core.stdc.errno.EINTR);
		if (got < 0 && wouldBlock()) {
			e.events = core.sys.posix.poll.POLLIN;
			return Pulled.later;
		}
		if (got == 0) return Pulled.end;
		if (got < 0) {
			fail(f, Failure.network);
			return Pulled.broken;
		}
		bool failed = false;
		version (unittest) failed = simulatedFailure();
		if (failed || BIO_write(e.tls.read, bytes.ptr, cast(int) got) != got) {
			fail(f, Failure.outOfMemory);
			return Pulled.broken;
		}
		return Pulled.some;
	}

	private void advance(ref Fetch f) @trusted {
		auto e = &f.exchange;
		while (f.state == State.pending || f.state == State.head) {
			final switch (e.phase) {
			case Phase.resolving:
				char one;
				ptrdiff_t got;
				do got = core.sys.posix.unistd.read(e.lookup.done[0], &one, 1);
				while (got < 0 && core.stdc.errno.errno == core.stdc.errno.EINTR);
				if (got <= 0) return;
				if (e.lookup.error != 0) return fail(f, Failure.network);
				dial(f, e.lookup.found);
				break;
			case Phase.connecting:
				core.sys.posix.poll.pollfd p = {e.fd, core.sys.posix.poll.POLLOUT};
				if (core.sys.posix.poll.poll(&p, 1, 0) <= 0) return;
				int error = 0;
				core.sys.posix.sys.socket.socklen_t size = error.sizeof;
				if (core.sys.posix.sys.socket.getsockopt(e.fd, core.sys.posix.sys.socket.SOL_SOCKET, core.sys.posix.sys.socket.SO_ERROR, &error, &size) != 0 || error != 0) {
					cast(void) core.sys.posix.unistd.close(e.fd);
					e.fd = -1;
					dial(f, e.next);
					break;
				}
				drop(e.lookup);
				e.lookup = null;
				e.next = null;
				e.phase = e.tls.ssl !is null ? Phase.handshaking : Phase.sending;
				break;
			case Phase.handshaking:
				ERR_clear_error();
				immutable result = SSL_do_handshake(e.tls.ssl);
				if (!seal(*e)) return fail(f, Failure.outOfMemory);
				if (!transmit(f)) return;
				if (result == 1) {
					if (!encrypt(f)) return;
					e.phase = Phase.sending;
					break;
				}
				immutable error = SSL_get_error(e.tls.ssl, result);
				if (error == sslErrorWantWrite) break;
				if (error != sslErrorWantRead) return fail(f, Failure.network);
				final switch (pull(f)) {
				case Pulled.some:
					break;
				case Pulled.end:
					return fail(f, Failure.network);
				case Pulled.later, Pulled.broken:
					return;
				}
				break;
			case Phase.sending:
				if (!transmit(f)) return;
				e.phase = Phase.receiving;
				e.events = core.sys.posix.poll.POLLIN;
				break;
			case Phase.receiving:
				if (buffered(f) >= maxReady) return;
				enum size_t chunk = 1 << 14;
				immutable kept = fp.dynarray.length(e.in_);
				if (fp.dynarray.grow(e.in_, chunk) is null) return fail(f, Failure.outOfMemory);
				if (e.tls.ssl !is null) {
					ERR_clear_error();
					immutable result = SSL_read(e.tls.ssl, e.in_ + kept, cast(int) chunk);
					cast(void) fp.dynarray.removeLast(e.in_, chunk - (result > 0 ? result : 0));
					// TLS may owe the server records even while reading, such as an answer to a key update.
					if (!seal(*e)) return fail(f, Failure.outOfMemory);
					if (fp.dynarray.length(e.wire) && !transmit(f) && f.state == State.failed) return;
					if (result <= 0) {
						immutable error = SSL_get_error(e.tls.ssl, result);
						if (error == sslErrorZeroReturn) e.eof = true;
						else if (error != sslErrorWantRead) return fail(f, Failure.network);
						else final switch (pull(f)) {
						case Pulled.some:
							continue;
						case Pulled.end:
							e.eof = true;
							break;
						case Pulled.later, Pulled.broken:
							return;
						}
					}
				} else {
					ptrdiff_t got;
					do got = core.sys.posix.sys.socket.recv(e.fd, e.in_ + kept, chunk, 0);
					while (got < 0 && core.stdc.errno.errno == core.stdc.errno.EINTR);
					cast(void) fp.dynarray.removeLast(e.in_, chunk - (got > 0 ? got : 0));
					if (got < 0 && wouldBlock()) {
						e.events = core.sys.posix.poll.POLLIN;
						return;
					}
					if (got < 0) return fail(f, Failure.network);
					if (got == 0) e.eof = true;
				}
				digest(f);
				break;
			}
		}
	}

	private bool waitFor(Fetch*[] fs, int timeoutMs) @trusted {
		core.sys.posix.poll.pollfd[maxWaited] polled;
		foreach (i, f; fs) {
			if ((f.state != State.pending && f.state != State.head) || buffered(*f)) return true;
			auto e = &f.exchange;
			polled[i] = e.phase == Phase.resolving ? core.sys.posix.poll.pollfd(e.lookup.done[0], core.sys.posix.poll.POLLIN) : core.sys.posix.poll.pollfd(e.fd, e.events);
		}
		int ready;
		do ready = core.sys.posix.poll.poll(polled.ptr, cast(core.sys.posix.poll.nfds_t) fs.length, timeoutMs);
		while (ready < 0 && core.stdc.errno.errno == core.stdc.errno.EINTR);
		return ready != 0;
	}
}

version (Windows) {
	// Winsock's FD_ event flags, each derived from the bit position its error sits at in `NetworkEvents.errors`.
	private enum int fdReadBit = 0, fdWriteBit = 1, fdConnectBit = 4, fdCloseBit = 5;
	private enum int fdRead = 1 << fdReadBit, fdWrite = 1 << fdWriteBit, fdConnect = 1 << fdConnectBit, fdClose = 1 << fdCloseBit;
	private enum int networkEventCount = 10;

	// The Winsock, SSPI and CryptoAPI functions the native backend uses; dub.json links ws2_32, secur32 and crypt32.
	private extern (Windows) {
		struct AddressInfo {
			int flags;
			int family;
			int socketType;
			int protocol;
			size_t addressLength;
			char* canonicalName;
			void* address;
			AddressInfo* next;
		}

		struct NetworkEvents {
			int happened;
			int[networkEventCount] errors;
			static assert(fdCloseBit < networkEventCount, "every FD_ bit indexes errors");
		}

		int WSAStartup(ushort requested, void* data);
		int WSAGetLastError();
		size_t socket(int family, int type, int protocol);
		pragma(mangle, "connect") int connectSocket(size_t s, const(void)* address, int length);
		int send(size_t s, const(void)* from, int length, int flags);
		int recv(size_t s, void* into, int length, int flags);
		int closesocket(size_t s);
		int getaddrinfo(const(char)* host, const(char)* port, const(AddressInfo)* hints, AddressInfo** found);
		void freeaddrinfo(AddressInfo* found);
		int WSAEventSelect(size_t s, void* event, int events);
		int WSAEnumNetworkEvents(size_t s, void* event, NetworkEvents* happened);

		void* CreateEventW(void* attributes, int manualReset, int initialState, const(wchar)* name);
		int SetEvent(void* event);
		int ResetEvent(void* event);
		int CloseHandle(void* handle);
		uint WaitForSingleObject(void* handle, uint milliseconds);
		uint WaitForMultipleObjects(uint count, const(void*)* handles, int all, uint milliseconds);
		void Sleep(uint milliseconds);

		struct SecHandle {
			size_t lower, upper;
		}

		struct SecBuffer {
			uint size;
			uint type;
			void* bytes;
		}

		struct SecBufferDesc {
			uint version_;
			uint count;
			SecBuffer* buffers;
		}

		struct StreamSizes {
			uint header, trailer, maximumMessage, buffers, blockSize;
		}

		struct CertContext {
			uint encoding;
			ubyte* encoded;
			uint encodedLength;
			void* info;
			void* store;
		}

		// SCH_CREDENTIALS, which unlike SCHANNEL_CRED allows TLS 1.3.
		struct SchCredentials {
			uint version_ = 5;
			uint format;
			uint certificateCount;
			const(CertContext*)* certificates;
			void* rootStore;
			uint mapperCount;
			void** mappers;
			uint sessionLifespan;
			uint flags;
			uint tlsParameterCount;
			void* tlsParameters;
		}

		int AcquireCredentialsHandleW(const(wchar)* principal, const(wchar)* package_, uint use, void* logonId, void* authData, void* getKey, void* getKeyArgument, SecHandle* credentials, long* expiry);
		int FreeCredentialsHandle(SecHandle* credentials);
		int InitializeSecurityContextW(SecHandle* credentials, SecHandle* context, const(wchar)* target, uint requirements, uint reserved1, uint representation, SecBufferDesc* input, uint reserved2, SecHandle* newContext, SecBufferDesc* output, uint* attributes, long* expiry);
		int AcceptSecurityContext(SecHandle* credentials, SecHandle* context, SecBufferDesc* input, uint requirements, uint representation, SecHandle* newContext, SecBufferDesc* output, uint* attributes, long* expiry);
		int DeleteSecurityContext(SecHandle* context);
		int FreeContextBuffer(void* buffer);
		int QueryContextAttributesW(SecHandle* context, uint attribute, void* into);
		int EncryptMessage(SecHandle* context, uint quality, SecBufferDesc* message, uint sequence);
		int DecryptMessage(SecHandle* context, SecBufferDesc* message, uint sequence, uint* quality);

		struct KeyUsage {
			uint count;
			const(char*)* identifiers;
		}

		struct UsageMatch {
			uint type;
			KeyUsage usage;
		}

		struct ChainPara {
			uint size = ChainPara.sizeof;
			UsageMatch usage;
		}

		struct SslPolicy {
			uint size = SslPolicy.sizeof;
			uint authType;
			uint checks;
			const(wchar)* serverName;
		}

		struct PolicyPara {
			uint size = PolicyPara.sizeof;
			uint flags;
			void* extra;
		}

		struct PolicyStatus {
			uint size = PolicyStatus.sizeof;
			uint error;
			int chainIndex;
			int elementIndex;
			void* extra;
		}

		int CertGetCertificateChain(void* engine, const(CertContext)* certificate, void* time, const(void)* store, const(ChainPara)* para, uint flags, void* reserved, const(void)** chain);
		void CertFreeCertificateChain(const(void)* chain);
		int CertVerifyCertificateChainPolicy(const(char)* policy, const(void)* chain, PolicyPara* para, PolicyStatus* status);
		int CertFreeCertificateContext(const(CertContext)* certificate);
	}

	private enum size_t invalidSocket = ~cast(size_t) 0;
	private enum int wsaeWouldBlock = 10035;
	private enum uint waitObject0 = 0, waitTimeout = 0x102, infinite = uint.max;
	private enum int secOk = 0, secContinue = 0x00090312, secExpired = 0x00090317, secRenegotiate = 0x00090321, secIncomplete = cast(int) 0x80090318;
	private enum uint secbufferEmpty = 0, secbufferData = 1, secbufferToken = 2, secbufferExtra = 5, secbufferTrailer = 6, secbufferHeader = 7;
	private enum uint credOutbound = 2, attrStreamSizes = 4, attrRemoteCertificate = 0x53, authtypeServer = 2;
	private enum uint schManualValidation = 0x8, schNoDefaultCredentials = 0x10;
	// Replay and sequence detection, confidentiality, memory SSPI allocates, and a stream.
	private enum uint iscRequirements = 0x4 | 0x8 | 0x10 | 0x100 | 0x8000, ascRequirements = 0x4 | 0x8 | 0x10 | 0x100 | 0x10000;
	private static immutable wchar[] unisp = "Microsoft Unified Security Protocol Provider\0"w;

	private shared bool winsockStarted;

	// Starts Winsock, once for the process; false if it cannot be.
	private bool startWinsock() @trusted {
		if (core.atomic.atomicLoad(winsockStarted)) return true;
		ubyte[512] data = void;
		if (WSAStartup(0x0202, data.ptr) != 0) return false;
		core.atomic.atomicStore(winsockStarted, true);
		return true;
	}

	// One TLS session run over buffers: records received wait in `records` until read, and what it writes goes where its caller says.
	private struct Tls {
		SecHandle context;
		bool live; // `context` holds a session, to be deleted
		bool done; // the handshake has finished, and not been reopened since
		StreamSizes sizes;
		char* records = null;
		wchar* name = null; // the host the certificate must name; null for a server, or a connection without TLS
		bool address; // `name` is an IP address, which is not sent as the server's name
	}

	private void end(ref Tls t) {
		if (t.live) cast(void) DeleteSecurityContext(&t.context);
		fp.dynarray.free(t.records);
		fp.dynarray.free(t.name);
		t = Tls.init;
	}

	private enum Shake : ubyte { done, more, failed, outOfMemory }

	// Takes the handshake as far as `t.records` allows, appending output to `wire`; `reopened` calls SSPI even with nothing received, as post-handshake messages need.
	private Shake handshake(ref Tls t, SecHandle* credentials, bool server, ref char* wire, bool reopened = false) @trusted {
		if (reopened) t.done = false;
		for (;;) {
			immutable held = fp.dynarray.length(t.records);
			if (held == 0 && (server || t.live) && !reopened) return Shake.more;
			reopened = false;
			SecBuffer[2] input = [SecBuffer(cast(uint) held, secbufferToken, t.records), SecBuffer(0, secbufferEmpty, null)];
			SecBufferDesc inputs = {0, 2, input.ptr};
			SecBuffer output = {0, secbufferToken, null};
			SecBufferDesc outputs = {0, 1, &output};
			uint attributes;
			immutable status = server
				? AcceptSecurityContext(credentials, t.live ? &t.context : null, &inputs, ascRequirements, 0, &t.context, &outputs, &attributes, null)
				: InitializeSecurityContextW(credentials, t.live ? &t.context : null, t.address ? null : t.name, iscRequirements, 0, 0, t.live ? &inputs : null, 0, &t.context, &outputs, &attributes, null);
			immutable kept = output.bytes is null || fp.dynarray.concatenate(wire, (cast(char*) output.bytes)[0 .. output.size]);
			if (output.bytes !is null) cast(void) FreeContextBuffer(output.bytes);
			if (status == secIncomplete) return Shake.more;
			if (status != secOk && status != secContinue) return Shake.failed;
			t.live = true;
			if (!kept) return Shake.outOfMemory;
			if (input[1].type == secbufferExtra) cast(void) fp.dynarray.removeRange(t.records, 0, held - input[1].size);
			else fp.dynarray.clear(t.records);
			if (status == secOk) {
				t.done = QueryContextAttributesW(&t.context, attrStreamSizes, &t.sizes) == secOk;
				return t.done ? Shake.done : Shake.failed;
			}
		}
	}

	private enum Sealed : ubyte { ok, failed, outOfMemory }

	// Encrypts `plain` into records appended to `wire`; on failure `wire` is as it was.
	private Sealed seal(ref Tls t, const(char)[] plain, ref char* wire) @trusted {
		immutable start = fp.dynarray.length(wire);
		while (plain.length) {
			immutable n = plain.length < t.sizes.maximumMessage ? plain.length : t.sizes.maximumMessage;
			immutable at = fp.dynarray.length(wire), size = t.sizes.header + n + t.sizes.trailer;
			if (fp.dynarray.grow(wire, size) is null) {
				cast(void) fp.dynarray.removeLast(wire, at - start);
				return Sealed.outOfMemory;
			}
			auto record = wire + at;
			core.stdc.string.memcpy(record + t.sizes.header, plain.ptr, n);
			SecBuffer[4] parts = [SecBuffer(t.sizes.header, secbufferHeader, record), SecBuffer(cast(uint) n, secbufferData, record + t.sizes.header),
				SecBuffer(t.sizes.trailer, secbufferTrailer, record + t.sizes.header + n), SecBuffer(0, secbufferEmpty, null)];
			SecBufferDesc message = {0, 4, parts.ptr};
			if (EncryptMessage(&t.context, 0, &message, 0) != secOk) {
				cast(void) fp.dynarray.removeLast(wire, at + size - start);
				return Sealed.failed;
			}
			cast(void) fp.dynarray.removeLast(wire, t.sizes.trailer - parts[2].size);
			plain = plain[n .. $];
		}
		return Sealed.ok;
	}

	private enum Opened : ubyte { some, more, closed, reopened, failed, outOfMemory }

	// Decrypts the first record `t.records` holds, appending what it carried to `plain`.
	private Opened unseal(ref Tls t, ref char* plain) @trusted {
		immutable held = fp.dynarray.length(t.records);
		if (held == 0) return Opened.more;
		SecBuffer[4] parts = [SecBuffer(cast(uint) held, secbufferData, t.records), SecBuffer.init, SecBuffer.init, SecBuffer.init];
		SecBufferDesc message = {0, 4, parts.ptr};
		immutable status = DecryptMessage(&t.context, &message, 0, null);
		if (status == secIncomplete) return Opened.more;
		if (status != secOk && status != secExpired && status != secRenegotiate) return Opened.failed;
		size_t extra = 0;
		foreach (ref p; parts) {
			// Only a record SSPI decrypted carries data; on close_notify it leaves the input marked as data.
			if (status == secOk && p.type == secbufferData && !fp.dynarray.concatenate(plain, (cast(char*) p.bytes)[0 .. p.size])) return Opened.outOfMemory;
			if (p.type == secbufferExtra) extra = p.size;
		}
		cast(void) fp.dynarray.removeRange(t.records, 0, held - extra);
		return status == secExpired ? Opened.closed : status == secRenegotiate ? Opened.reopened : Opened.some;
	}

	private __gshared SecHandle tlsShared;
	private __gshared bool tlsMade;
	private __gshared bc.spinlock.SpinLock tlsLock;
	private __gshared void* chainEngine; // null for the system's roots; the tests set one trusting only their own

	// The credentials every https fetch shares, made on first use; null if SChannel could not make them.
	private SecHandle* tlsCredentials() @trusted {
		bc.spinlock.lockForWriting(tlsLock);
		scope(exit) bc.spinlock.unlockForWriting(tlsLock);
		if (!tlsMade) {
			bool failed = false;
			version (unittest) failed = simulatedFailure();
			SchCredentials c = {flags: schManualValidation | schNoDefaultCredentials};
			if (failed || AcquireCredentialsHandleW(null, unisp.ptr, credOutbound, null, &c, null, null, &tlsShared, null) != secOk) return null;
			tlsMade = true;
		}
		return &tlsShared;
	}

	// Whether the certificate the server presented chains to a trusted root and names `t.name`; SChannel leaves this to its caller, as the credentials ask.
	private bool trusted(ref Tls t) @trusted {
		const(CertContext)* certificate;
		if (QueryContextAttributesW(&t.context, attrRemoteCertificate, &certificate) != secOk || certificate is null) return false;
		scope(exit) cast(void) CertFreeCertificateContext(certificate);
		const(char)* serverAuth = "1.3.6.1.5.5.7.3.1";
		ChainPara para = {usage: UsageMatch(0, KeyUsage(1, &serverAuth))};
		const(void)* chain;
		if (!CertGetCertificateChain(chainEngine, certificate, null, certificate.store, &para, 0, null, &chain)) return false;
		scope(exit) CertFreeCertificateChain(chain);
		SslPolicy ssl = {authType: authtypeServer, serverName: t.name};
		PolicyPara policy = {extra: &ssl};
		PolicyStatus status;
		enum sslPolicy = cast(const(char)*) 4;
		return CertVerifyCertificateChainPolicy(sslPolicy, chain, &policy, &status) && status.error == 0;
	}

	// A host name being resolved on a thread of its own, which shares it; whichever side drops the last reference frees it.
	private struct Lookup {
		shared int references;
		fp.pointer.Allocator memory; // the allocator this block came from, not the freeing thread's
		void* done; // an event the thread sets once `error` and `found` are
		int error;
		AddressInfo* found;
		char[256] host = 0;
		char[6] port = 0;
	}

	private void drop(Lookup* l) @trusted {
		if (l is null || core.atomic.atomicOp!"-="(l.references, 1) != 0) return;
		if (l.done !is null) cast(void) CloseHandle(l.done);
		if (l.found !is null) freeaddrinfo(l.found);
		cast(void) l.memory(cast(void*) l, 0);
	}

	private int lookUp(ref Lookup l, bool numeric) @trusted {
		if (!startWinsock()) return -1;
		AddressInfo hints;
		hints.socketType = 1;
		hints.flags = numeric ? 4 : 0;
		return getaddrinfo(l.host.ptr, l.port.ptr, &hints, &l.found);
	}

	private void resolveOnThread(Lookup* l) @trusted {
		l.error = lookUp(*l, false);
		cast(void) SetEvent(l.done);
		drop(l);
	}

	// Makes the event the resolving thread sets; false if it cannot.
	private bool signalable(ref Lookup l) @trusted {
		l.done = CreateEventW(null, true, false, null);
		return l.done !is null;
	}

	// Closes the exchange's socket and the event that tells of it.
	private void hangUp(ref Exchange e) @trusted {
		if (e.fd != invalidSocket) cast(void) closesocket(e.fd);
		e.fd = invalidSocket;
		if (e.event !is null) cast(void) CloseHandle(e.event);
		e.event = null;
	}

	private void disconnect(ref Exchange e) {
		hangUp(e);
		drop(e.lookup);
		e.lookup = null;
		e.next = null;
		end(e.tls);
		fp.dynarray.clear(e.wire);
	}

	// Moves a connected exchange on to its handshake or its request, done with the addresses it was trying.
	private void connected(ref Exchange e) {
		drop(e.lookup);
		e.lookup = null;
		e.next = null;
		e.phase = e.tls.name !is null ? Phase.handshaking : Phase.sending;
	}

	// Starts connecting to the first address from `a` that takes a socket, remembering the rest; fails `f` if none does.
	private void dial(ref Fetch f, AddressInfo* a) @trusted {
		auto e = &f.exchange;
		for (; a !is null; a = a.next) {
			immutable s = socket(a.family, a.socketType, a.protocol);
			if (s == invalidSocket) continue;
			// Selecting events also makes the socket nonblocking.
			bool failed = false;
			version (unittest) failed = simulatedFailure();
			auto event = failed ? null : CreateEventW(null, true, false, null);
			if (event is null) {
				cast(void) closesocket(s);
				return fail(f, Failure.outOfMemory);
			}
			e.fd = s;
			e.event = event;
			if (WSAEventSelect(s, event, fdRead | fdWrite | fdConnect | fdClose) == 0) {
				immutable at = connectSocket(s, a.address, cast(int) a.addressLength) == 0;
				if (at || WSAGetLastError() == wsaeWouldBlock) {
					e.next = a.next;
					e.phase = Phase.connecting;
					if (at) connected(*e);
					return;
				}
			}
			hangUp(*e);
		}
		fail(f, Failure.network);
	}

	// Sets up TLS for `host`, checking the certificate against it as a name or, when `address`, an IP address; fails `f` if it cannot.
	private bool secure(ref Fetch f, const(char)* host, bool address) @trusted {
		if (tlsCredentials() is null) {
			fail(f, Failure.unsupported);
			return false;
		}
		auto t = &f.exchange.tls;
		t.name = fp.string.utf16(host[0 .. core.stdc.string.strlen(host)]);
		if (t.name is null) {
			fail(f, Failure.outOfMemory);
			return false;
		}
		t.address = address;
		return true;
	}

	// Sends what is left of the request, or of TLS's records; false until all is sent, having failed `f` if it cannot be.
	private bool transmit(ref Fetch f) @trusted {
		auto e = &f.exchange;
		auto bytes = e.tls.name !is null ? e.wire : e.out_;
		immutable total = fp.dynarray.length(bytes);
		// Winsock takes a whole send, however large, while its buffer has any room, so sending in pieces keeps it from holding the whole request.
		enum size_t piece = 1 << 16;
		while (e.sent < total) {
			immutable left = total - e.sent;
			immutable wrote = send(e.fd, bytes + e.sent, cast(int) (left < piece ? left : piece), 0);
			if (wrote < 0 && WSAGetLastError() == wsaeWouldBlock) return false;
			if (wrote <= 0) {
				fail(f, Failure.network);
				return false;
			}
			e.sent += wrote;
		}
		if (e.tls.name !is null) {
			fp.dynarray.clear(e.wire);
			e.sent = 0;
		}
		return true;
	}

	// Has TLS seal the whole request into `wire`; false, having failed `f`, if it cannot.
	private bool encrypt(ref Fetch f) @trusted {
		auto e = &f.exchange;
		bool failed = false;
		version (unittest) failed = simulatedFailure();
		immutable sealed = failed ? Sealed.failed : seal(e.tls, fp.dynarray.slice(e.out_), e.wire);
		if (sealed == Sealed.ok) return true;
		fail(f, sealed == Sealed.outOfMemory ? Failure.outOfMemory : Failure.network);
		return false;
	}

	// Moves the bytes the socket has into TLS's records; on `Pulled.broken` it has failed `f`.
	private Pulled pull(ref Fetch f) @trusted {
		auto e = &f.exchange;
		char[1 << 14] bytes = void;
		immutable got = recv(e.fd, bytes.ptr, bytes.length, 0);
		if (got < 0 && WSAGetLastError() == wsaeWouldBlock) return Pulled.later;
		if (got == 0) return Pulled.end;
		if (got < 0) {
			fail(f, Failure.network);
			return Pulled.broken;
		}
		if (!fp.dynarray.concatenate(e.tls.records, bytes[0 .. got])) {
			fail(f, Failure.outOfMemory);
			return Pulled.broken;
		}
		return Pulled.some;
	}

	// Runs the handshake further, sending what it writes; false, having failed `f` or waiting to send, unless it can go on.
	private bool shake(ref Fetch f, ref Shake result, bool reopened = false) {
		auto e = &f.exchange;
		result = handshake(e.tls, &tlsShared, false, e.wire, reopened);
		if (result == Shake.outOfMemory || result == Shake.failed) {
			fail(f, result == Shake.failed ? Failure.network : Failure.outOfMemory);
			return false;
		}
		return transmit(f);
	}

	private void advance(ref Fetch f) @trusted {
		auto e = &f.exchange;
		// Reset before trying anything, so whatever becomes ready from here on sets it again.
		if (e.event !is null) cast(void) ResetEvent(e.event);
		while (f.state == State.pending || f.state == State.head) {
			final switch (e.phase) {
			case Phase.resolving:
				if (WaitForSingleObject(e.lookup.done, 0) != waitObject0) return;
				if (e.lookup.error != 0) return fail(f, Failure.network);
				dial(f, e.lookup.found);
				break;
			case Phase.connecting:
				NetworkEvents happened;
				if (WSAEnumNetworkEvents(e.fd, null, &happened) != 0) return fail(f, Failure.network);
				if (!(happened.happened & fdConnect)) return;
				if (happened.errors[fdConnectBit] != 0) {
					hangUp(*e);
					dial(f, e.next);
					break;
				}
				connected(*e);
				break;
			case Phase.handshaking:
				Shake result = Shake.done;
				if (!(e.tls.done ? transmit(f) : shake(f, result))) return;
				if (result == Shake.done) {
					if (!trusted(e.tls)) return fail(f, Failure.network);
					if (!encrypt(f)) return;
					e.phase = Phase.sending;
					break;
				}
				final switch (pull(f)) {
				case Pulled.some:
					break;
				case Pulled.end:
					return fail(f, Failure.network);
				case Pulled.later, Pulled.broken:
					return;
				}
				break;
			case Phase.sending:
				if (!transmit(f)) return;
				e.phase = Phase.receiving;
				break;
			case Phase.receiving:
				if (buffered(f) >= maxReady) return;
				if (e.tls.name !is null) {
					// A post-handshake message, such as a TLS 1.3 session ticket, reopens the handshake until SSPI has taken it.
					auto opened = e.tls.done ? unseal(e.tls, e.in_) : Opened.more;
					if (!e.tls.done || opened == Opened.reopened) {
						Shake result;
						if (!shake(f, result, opened == Opened.reopened) && f.state == State.failed) return;
						if (result == Shake.done) continue;
						opened = Opened.more;
					}
					final switch (opened) {
					case Opened.some:
						break;
					case Opened.closed:
						e.eof = true;
						break;
					case Opened.more:
						final switch (pull(f)) {
						case Pulled.some:
							continue;
						case Pulled.end:
							e.eof = true;
							break;
						case Pulled.later, Pulled.broken:
							return;
						}
						break;
					case Opened.reopened:
						assert(0);
					case Opened.failed:
						return fail(f, Failure.network);
					case Opened.outOfMemory:
						return fail(f, Failure.outOfMemory);
					}
				} else {
					enum size_t chunk = 1 << 14;
					immutable kept = fp.dynarray.length(e.in_);
					if (fp.dynarray.grow(e.in_, chunk) is null) return fail(f, Failure.outOfMemory);
					immutable got = recv(e.fd, e.in_ + kept, cast(int) chunk, 0);
					cast(void) fp.dynarray.removeLast(e.in_, chunk - (got > 0 ? got : 0));
					if (got < 0 && WSAGetLastError() == wsaeWouldBlock) return;
					if (got < 0) return fail(f, Failure.network);
					if (got == 0) e.eof = true;
				}
				digest(f);
				break;
			}
		}
	}

	private bool waitFor(Fetch*[] fs, int timeoutMs) @trusted {
		static assert(maxWaited <= 64, "bc.http: WaitForMultipleObjects waits on at most 64 handles");
		void*[maxWaited] handles;
		foreach (i, f; fs) {
			if ((f.state != State.pending && f.state != State.head) || buffered(*f)) return true;
			handles[i] = f.exchange.phase == Phase.resolving ? f.exchange.lookup.done : f.exchange.event;
		}
		immutable limit = timeoutMs < 0 ? infinite : cast(uint) timeoutMs;
		if (fs.length == 0) {
			Sleep(limit);
			return false;
		}
		return WaitForMultipleObjects(cast(uint) fs.length, handles.ptr, false, limit) != waitTimeout;
	}
}



// --- fetching ----------------------------------------------------------------

// Which clock a deadline is measured in: the host's on WASI, where the fetch runs there, and bc-threads' monotonic one elsewhere.
private ulong milliseconds() {
	version (WASI) return cast(ulong) hostNow();
	else return bc.thread.monotonicMilliseconds();
}

private bool going(ref const Fetch f) {
	return f.state == State.pending || f.state == State.head;
}

// Fails `f` with `Failure.timeout` if its deadline has passed.
private void expire(ref Fetch f, ulong now) {
	if (going(f) && f.deadline && now >= f.deadline) fail(f, Failure.timeout);
}

/// Releases everything `f` holds, stopping it first if it is still going, and leaves it empty.
///
/// Examples:
/// ---
/// Request r = { url: "not a url" };
/// auto f = start(r);
/// free(f.get);
/// assert(f.get.url.length == 0);
/// ---
void free(ref Fetch f) {
	release(f.exchange);
	free(f.headers);
	fp.dynarray.free(f.urlText);
	fp.dynarray.free(f.whole);
	f = Fetch.init;
}

/// Begins fetching `r` without waiting for anything: natively it starts resolving the host on a thread of its own, or connecting at once to an IP address. A request it can tell is wrong at once, such as one with an invalid method or URL, comes back already in `State.failed`, with `failure` saying why.
///
/// Returns an empty `Nullable` only if an allocation was refused.
///
/// Examples:
/// ---
/// Request r = { url: "ftp://example.com/" };
/// auto f = start(r);
/// scope(exit) free(f.get);
/// assert(f.get.state == State.failed && f.get.failure == Failure.unsupported);
/// ---
std.typecons.Nullable!Fetch start(ref const Request r) {
	static immutable standard = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"];
	static immutable forbidden = ["CONNECT", "TRACE", "TRACK"];
	Fetch f;
	if (r.timeoutMs) f.deadline = milliseconds() + r.timeoutMs;
	const(char)[] method = r.method;
	foreach (m; standard) if (fp.string.equalIgnoringAsciiCase(method, m)) method = m;
	bool refused = !bc.http.message.validName(method) || ((method == "GET" || method == "HEAD") && r.body.length);
	foreach (m; forbidden) if (fp.string.equalIgnoringAsciiCase(method, m)) refused = true;
	if (refused) {
		f.state = State.failed;
		f.failure = Failure.invalidRequest;
		return typeof(return)(f);
	}
	if (!begin(f, r, method)) {
		free(f);
		return typeof(return).init;
	}
	return typeof(return)(f);
}

/// Advances `f` as far as it can without waiting, and returns its state.
///
/// Examples:
/// ---
/// Request r = { url: "http://[" };
/// auto f = start(r);
/// scope(exit) free(f.get);
/// assert(poll(f.get) == State.failed);
/// ---
State poll(ref Fetch f) {
	if (going(f)) advance(f);
	expire(f, milliseconds());
	return f.state;
}

/// Stops `f` if it is still going, failing it with `Failure.aborted`.
///
/// Examples:
/// ---
/// Request r = { url: "not a url" };
/// auto f = start(r);
/// scope(exit) free(f.get);
/// abort(f.get);
/// assert(f.get.failure == Failure.invalidUrl);
/// ---
void abort(ref Fetch f) {
	if (going(f)) fail(f, Failure.aborted);
}

/// The most fetches one `wait` call watches.
enum size_t maxWaited = 64;

/// Waits until one of `fs` can make progress, has body bytes to read, or has finished, or until `timeoutMs` passes; a negative `timeoutMs` waits as long as it takes. Then `poll` the ones of interest. It wakes for a fetch whose `Request.timeoutMs` passes, too. In a browser it cannot wait on the main thread; use `setWake` there instead.
///
/// Returns false if `timeoutMs` passed first.
///
/// Examples:
/// ---
/// Request r = { url: "not a url" };
/// auto f = start(r);
/// scope(exit) free(f.get);
/// Fetch*[1] fs = [&f.get()];
/// assert(wait(fs[], 0));
/// ---
bool wait(Fetch*[] fs, int timeoutMs) {
	assert(fs.length <= maxWaited, "bc.http.wait: too many fetches");
	immutable now = milliseconds();
	foreach (f; fs) {
		if (!going(*f) || (f.deadline && now >= f.deadline)) return true;
		if (f.deadline && (timeoutMs < 0 || f.deadline - now < timeoutMs)) timeoutMs = cast(int) (f.deadline - now);
	}
	if (waitFor(fs, timeoutMs)) return true;
	immutable later = milliseconds();
	foreach (f; fs) if (f.deadline && later >= f.deadline) return true;
	return false;
}

private __gshared void function(void* context) @nogc nothrow wakeHook;
private __gshared void* wakeContext;

/// Has `hook` called with `context` whenever a fetch may have progressed on its own, so `poll` is worth calling; null stops it. Only a host that runs fetches beside the caller calls it: a browser's main thread, which cannot `wait`. Natively a fetch progresses only inside `poll`, so it is never called.
///
/// Examples:
/// ---
/// static void woken(void* context) @nogc nothrow { ++*cast(int*) context; }
/// int count = 0;
/// setWake(&woken, &count);
/// setWake(null, null);
/// ---
void setWake(void function(void* context) @nogc nothrow hook, void* context) {
	wakeHook = hook;
	wakeContext = context;
}

version (WASI) {
	/// Called by js/bc-fetch.mjs when a fetch has progressed while no `wait` was blocked on it; it calls the `setWake` hook. The module must export it.
	///
	/// Examples:
	/// ---
	/// version (WASI) bc_http_wake();
	/// ---
	export extern (C) void bc_http_wake() {
		if (wakeHook !is null) wakeHook(wakeContext);
	}
}

/// Copies up to `into.length` bytes of `f`'s body that have arrived into `into`, polling `f` first if none are waiting, and returns how many: 0 if none have arrived yet, so `wait` and try again.
///
/// Returns an empty `Nullable` once the whole body has been read, or if `f` failed, even with bytes still unread; `f.failure` tells the two apart.
///
/// Examples:
/// ---
/// Request r = { url: "not a url" };
/// auto f = start(r);
/// scope(exit) free(f.get);
/// char[16] buffer;
/// assert(readBody(f.get, buffer[]).isNull);
/// ---
std.typecons.Nullable!size_t readBody(ref Fetch f, char[] into) {
	if (f.state != State.failed && buffered(f) == 0 && f.state != State.done) cast(void) poll(f);
	if (f.state == State.failed || (f.state == State.done && buffered(f) == 0)) return typeof(return).init;
	return typeof(return)(take(f, into));
}

/// Starts fetching `r` and waits until its response's head has arrived or it has failed; then `f.status` and `f.headers` are set. Read the body with `readAll` or `readBody`.
///
/// Returns an empty `Nullable` only if an allocation was refused; otherwise check the fetch's `state`.
///
/// Examples:
/// ---
/// Request r = { url: "http://example.com/", body: "x" };
/// auto f = fetch(r);
/// scope(exit) free(f.get);
/// assert(f.get.failure == Failure.invalidRequest);
/// ---
std.typecons.Nullable!Fetch fetch(ref const Request r) {
	auto f = start(r);
	if (f.isNull) return f;
	Fetch*[1] fs = [&f.get()];
	while (poll(f.get) == State.pending) cast(void) wait(fs[], -1);
	return f;
}

/// Waits for the rest of `f`'s body and returns all of it that `readBody` had not taken. It belongs to `f`, valid until `free(f)`, and calling this again returns it again.
///
/// Returns an empty `Nullable` if `f` failed; if an allocation was refused, it fails `f` with `Failure.outOfMemory` first.
///
/// Examples:
/// ---
/// Request r = { url: "not a url" };
/// auto f = start(r);
/// scope(exit) free(f.get);
/// assert(readAll(f.get).isNull);
/// ---
std.typecons.Nullable!(const(char)[]) readAll(ref Fetch f) @trusted {
	enum size_t chunk = 1 << 14;
	if (f.state == State.failed) return typeof(return).init;
	Fetch*[1] fs = [&f];
	for (;;) {
		immutable kept = fp.dynarray.length(f.whole);
		if (fp.dynarray.grow(f.whole, chunk) is null) {
			fail(f, Failure.outOfMemory);
			return typeof(return).init;
		}
		auto got = readBody(f, f.whole[kept .. kept + chunk]);
		cast(void) fp.dynarray.removeLast(f.whole, got.isNull ? chunk : chunk - got.get);
		if (got.isNull) return f.state == State.done ? typeof(return)(fp.dynarray.slice(f.whole)) : typeof(return).init;
		if (got.get == 0) cast(void) wait(fs[], -1);
	}
}


unittest { // headers: order, repeats, case-insensitive lookup, replacing and removing, and refusals leaving them as they were
	static import fp.testing;
	Headers h;
	scope(exit) free(h);
	assert(get(h, "a").isNull && length(h) == 0);
	assert(append(h, "A", "1") && append(h, "B", "") && append(h, "a", "3"));
	assert(get(h, "A").get == "1" && get(h, "b").get == "" && length(h) == 3);
	assert(set(h, "A", "4") && length(h) == 2 && at(h, 0) == Header("B", "") && at(h, 1) == Header("A", "4"));
	remove(h, "missing");
	remove(h, "b");
	assert(length(h) == 1 && get(h, "a").get == "4");
	assert(!append(h, "", "x") && !set(h, "A", "\n") && get(h, "a").get == "4");

	auto previous = fp.testing.limitAllocations(0);
	assert(!append(h, "Some-Long-Name", "a value long enough to need more room") && !set(h, "A", "a value long enough to need more room"));
	fp.testing.restoreAllocator(previous);
	assert(length(h) == 1 && get(h, "a").get == "4");

	// Room for the text but not the field takes the text back.
	Headers fresh;
	previous = fp.testing.limitAllocations(1);
	assert(!append(fresh, "A", "1"));
	fp.testing.restoreAllocator(previous);
	scope(exit) free(fresh);
	assert(length(fresh) == 0 && fp.dynarray.length(fresh.text) == 0);
}

unittest { // requests refused before any I/O: invalid and forbidden methods, a body on GET, bad URLs and unsupported schemes
	static immutable Request[5] bad = [Request("http://h/", "CONNECT"), Request("http://h/", "track"), Request("http://h/", ""), Request("http://h/", "A B"), Request("http://h/", "get", Headers.init, "x")];
	foreach (ref b; bad) {
		auto f = start(b);
		scope(exit) free(f.get);
		assert(f.get.state == State.failed && f.get.failure == Failure.invalidRequest);
		assert(readBody(f.get, null).isNull && readAll(f.get).isNull);
	}
	// A browser reads an empty URL as relative to the page, so only elsewhere is it invalid.
	version (WASI) static immutable urls = ["http://", "http://u@h/", "ftp://h/"];
	else static immutable urls = ["", "http://", "http://u@h/", "ftp://h/"];
	foreach (url; urls) {
		Request r = {url: url};
		auto f = start(r);
		scope(exit) free(f.get);
		assert(poll(f.get) == State.failed && f.get.failure == (url == "ftp://h/" ? Failure.unsupported : Failure.invalidUrl));
	}

	static import fp.testing;
	Request r = {url: "http://127.0.0.1:1/", method: "post"};
	auto previous = fp.testing.limitAllocations(0);
	assert(start(r).isNull);
	fp.testing.restoreAllocator(previous);
	// `readAll` on a fetch already failed keeps its failure, allocating nothing.
	Request invalid = {url: "http://"};
	auto f = start(invalid);
	scope(exit) free(f.get);
	assert(poll(f.get) == State.failed);
	previous = fp.testing.limitAllocations(0);
	assert(readAll(f.get).isNull);
	fp.testing.restoreAllocator(previous);
	assert(f.get.failure == Failure.invalidUrl);
}

unittest { // a wake hook can be set, is called with its context, and can be cleared
	static void woken(void* context) { ++*cast(int*) context; }
	int count = 0;
	setWake(&woken, &count);
	assert(wakeHook is &woken && wakeContext is &count);
	wakeHook(wakeContext);
	assert(count == 1);
	setWake(null, null);
	assert(wakeHook is null);
}

version (WASI) {
} else {
	version (unittest) {
		// Self-signed certificates and their keys, valid until 2126; the tests trust `trustedPem` and `otherPem` but never `untrustedPem`.
		private static immutable trustedPem = `-----BEGIN CERTIFICATE-----
MIIBsDCCAVegAwIBAgIUXqarJNeDvR2AWY0ogQOJUhWMHG0wCgYIKoZIzj0EAwIw
HzEdMBsGA1UEAwwUYmMtaHR0cCB0ZXN0IHRydXN0ZWQwIBcNMjYxMDMwMjI0NDA5
WhgPMjEyNjEwMDYyMjQ0MDlaMB8xHTAbBgNVBAMMFGJjLWh0dHAgdGVzdCB0cnVz
dGVkMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAENUOXjhwjz/+7mX3E0vMNARET
3uFy+pYCFiT91r+MoXBLhUNN/SPwV0QDBquenqSfLxrphMZ/TAhysdBVqVisqKNv
MG0wHQYDVR0OBBYEFA3bcd2K6jsBln7FuWXBcdPxDHjnMB8GA1UdIwQYMBaAFA3b
cd2K6jsBln7FuWXBcdPxDHjnMBoGA1UdEQQTMBGHBH8AAAGCCWxvY2FsaG9zdDAP
BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCICHx7R5OY9FML3RshofP
M0xgEtS6jlI4j+m5wEwIk9rvAiBhnuVoXdcUry9wjx/jxnY7ukZ5lykaOQx75xS8
Q7qdyg==
-----END CERTIFICATE-----
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgKTR6AW73lmrfWRUw
3fPv9TcWyS6yDMiFQTpk5pTFNqahRANCAAQ1Q5eOHCPP/7uZfcTS8w0BERPe4XL6
lgIWJP3Wv4yhcEuFQ039I/BXRAMGq56epJ8vGumExn9MCHKx0FWpWKyo
-----END PRIVATE KEY-----
`;
		private static immutable untrustedPem = `-----BEGIN CERTIFICATE-----
MIIBtTCCAVugAwIBAgIUAK6iK3X4oyO1R3D5Hh0zdi5TqNcwCgYIKoZIzj0EAwIw
ITEfMB0GA1UEAwwWYmMtaHR0cCB0ZXN0IHVudHJ1c3RlZDAgFw0yNjEwMzAyMjQ0
MDlaGA8yMTI2MTAwNjIyNDQwOVowITEfMB0GA1UEAwwWYmMtaHR0cCB0ZXN0IHVu
dHJ1c3RlZDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBeM/kpCog8xgCEmWc/K
BE7T1ZdWIt7Gd9gQzmvq1BG2SR/yoMtQTCfwV0SecBqvgSDfhpUBzFBuJqJPCNBN
soOjbzBtMB0GA1UdDgQWBBSDQ+Hn8C6XtXU17LY57/FU5m/lbDAfBgNVHSMEGDAW
gBSDQ+Hn8C6XtXU17LY57/FU5m/lbDAaBgNVHREEEzARhwR/AAABgglsb2NhbGhv
c3QwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiA1gsNf7MGRDBH9
qT9fjUhjqPFJjafvw3Tix3j30myO/QIhAJfXqle21XybN+ru2VPnn76COBvh7hYj
K7SnAL4jbrho
-----END CERTIFICATE-----
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgbUN8CRMZjwsf3c02
qKrGyOzfgimMquiYsGk2ULpuKFGhRANCAAQXjP5KQqIPMYAhJlnPygRO09WXViLe
xnfYEM5r6tQRtkkf8qDLUEwn8FdEnnAar4Eg34aVAcxQbiaiTwjQTbKD
-----END PRIVATE KEY-----
`;
		private static immutable otherPem = `-----BEGIN CERTIFICATE-----
MIIBqDCCAU6gAwIBAgIUM04Q1Ai/wfY4MHRC8UDtg/ayXpQwCgYIKoZIzj0EAwIw
HTEbMBkGA1UEAwwSYmMtaHR0cCB0ZXN0IG90aGVyMCAXDTI2MTAzMDIyNDQwOVoY
DzIxMjYxMDA2MjI0NDA5WjAdMRswGQYDVQQDDBJiYy1odHRwIHRlc3Qgb3RoZXIw
WTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ6T+Pk1SWfBndZX7rjSq1bdUi8BUdd
UP+9cS5i1BreZ2RpGl/v9TimKp7olca0PrqZMNVoPAO2koyM5/TRKC5Po2owaDAd
BgNVHQ4EFgQUVwv7vGJsm3K6P4ny83jpvnjnsIYwHwYDVR0jBBgwFoAUVwv7vGJs
m3K6P4ny83jpvnjnsIYwFQYDVR0RBA4wDIIKb3RoZXIudGVzdDAPBgNVHRMBAf8E
BTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIBIdcKdHd9xuAJPDg6SolwYLiV6jeVoj
z7K03+cgTepdAiEAvex/f7BcFD8rcEddShNjmSUesFIuVY1fdPDy4RkO9aU=
-----END CERTIFICATE-----
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgrGZRMuFtqxgqeo6U
v9P3aXc10vF/TGGje9Rm7rKiYFmhRANCAAQ6T+Pk1SWfBndZX7rjSq1bdUi8BUdd
UP+9cS5i1BreZ2RpGl/v9TimKp7olca0PrqZMNVoPAO2koyM5/TRKC5P
-----END PRIVATE KEY-----
`; // for other.test only

		// `http://` or `https://`, then `host`, the port, and `path`, in `s.url`.
		private const(char)[] address(ref Server s, const(char)[] path, const(char)[] host = "127.0.0.1") @trusted {
			size_t n = 0;
			foreach (c; s.tls !is null ? "https://" : "http://") s.url[n++] = c;
			foreach (c; host) s.url[n++] = c;
			s.url[n++] = ':';
			char[fp.string.maxDecimalLength] digits;
			foreach (c; fp.string.formatUnsigned(s.port, digits)) s.url[n++] = c;
			foreach (c; path) s.url[n++] = c;
			return s.url[0 .. n];
		}

		// Steps the server and polls `f` in turn until `f` reaches `until` or stops.
		private State drive(ref Server s, ref Fetch f, const(char[])[] responses, State until = State.done) {
			Fetch*[1] fs = [&f];
			foreach (_; 0 .. 10_000) {
				step(s, responses);
				immutable state = poll(f);
				if (state >= until) return state;
				cast(void) wait(fs[], 1);
			}
			assert(0, "drive: the fetch never got there");
		}
	}
}

version (WASI) {
} else version (Posix) {
	version (unittest) {
		static import core.sys.posix.netinet.in_;

		// A one-thread loopback server for the tests: it answers each connection with the next of its responses, then closes it.
		private struct Server {
			int listener = -1;
			int client = -1;
			ushort port;
			size_t served;
			char* request = null; // the last request received, whole
			char[64] url = 0;
			SSL_CTX* tls; // for an https server, made by `listenTls`
			SSL* session;
			bool truncate; // hang up without TLS's close_notify, as a connection cut short does
		}

		// What a test https server needs of OpenSSL beyond what the client uses.
		private extern (C) {
			struct X509;
			struct X509_STORE;
			struct EVP_PKEY;
			const(SSL_METHOD)* TLS_server_method();
			BIO* BIO_new_mem_buf(const(void)* bytes, int length);
			X509* PEM_read_bio_X509(BIO* bio, X509** into, void* password, void* context);
			EVP_PKEY* PEM_read_bio_PrivateKey(BIO* bio, EVP_PKEY** into, void* password, void* context);
			void X509_free(X509* certificate);
			void EVP_PKEY_free(EVP_PKEY* key);
			int SSL_CTX_use_certificate(SSL_CTX* context, X509* certificate);
			int SSL_CTX_use_PrivateKey(SSL_CTX* context, EVP_PKEY* key);
			X509_STORE* SSL_CTX_get_cert_store(const(SSL_CTX)* context);
			int X509_STORE_add_cert(X509_STORE* store, X509* certificate);
			int SSL_set_fd(SSL* ssl, int fd);
			void SSL_set_accept_state(SSL* ssl);
			int SSL_shutdown(SSL* ssl);
		}

		private X509* certificate(const(char)[] pem) @trusted {
			auto bio = BIO_new_mem_buf(pem.ptr, cast(int) pem.length);
			scope(exit) cast(void) BIO_free(bio);
			auto x = PEM_read_bio_X509(bio, null, null, null);
			assert(x !is null);
			return x;
		}

		private __gshared bool trusting;

		// Has every https fetch trust `trustedPem` and `otherPem`, as if a CA had issued them.
		private void trustTestCertificates() @trusted {
			if (trusting) return;
			trusting = true;
			foreach (pem; [trustedPem, otherPem]) {
				auto x = certificate(pem);
				assert(X509_STORE_add_cert(SSL_CTX_get_cert_store(tlsContext()), x) == 1);
				X509_free(x);
			}
		}

		private Server listen() @trusted {
			Server s;
			s.listener = core.sys.posix.sys.socket.socket(core.sys.posix.sys.socket.AF_INET, core.sys.posix.sys.socket.SOCK_STREAM, 0);
			assert(s.listener >= 0);
			core.sys.posix.netinet.in_.sockaddr_in a;
			a.sin_family = core.sys.posix.sys.socket.AF_INET;
			a.sin_addr.s_addr = core.sys.posix.netinet.in_.htonl(core.sys.posix.netinet.in_.INADDR_LOOPBACK);
			assert(core.sys.posix.sys.socket.bind(s.listener, cast(core.sys.posix.sys.socket.sockaddr*) &a, a.sizeof) == 0 && core.sys.posix.sys.socket.listen(s.listener, 8) == 0);
			core.sys.posix.sys.socket.socklen_t size = a.sizeof;
			assert(core.sys.posix.sys.socket.getsockname(s.listener, cast(core.sys.posix.sys.socket.sockaddr*) &a, &size) == 0);
			s.port = core.sys.posix.netinet.in_.ntohs(a.sin_port);
			cast(void) core.sys.posix.fcntl.fcntl(s.listener, core.sys.posix.fcntl.F_SETFL, core.sys.posix.fcntl.O_NONBLOCK);
			// Room up front, so tests failing the client's allocations in turn never fail the server's instead.
			assert(fp.dynarray.reserve(s.request, 1 << 16) !is null);
			return s;
		}

		// A loopback https server presenting the certificate and key in `pem`.
		private Server listenTls(const(char)[] pem) @trusted {
			static import core.stdc.signal;
			static import core.sys.posix.signal;
			// The test server writes through SSL_set_fd, so a client hanging up mid-handshake must not kill the tests.
			cast(void) core.stdc.signal.signal(core.sys.posix.signal.SIGPIPE, core.stdc.signal.SIG_IGN);
			trustTestCertificates();
			auto s = listen();
			s.tls = SSL_CTX_new(TLS_server_method());
			auto x = certificate(pem);
			scope(exit) X509_free(x);
			auto bio = BIO_new_mem_buf(pem.ptr, cast(int) pem.length);
			scope(exit) cast(void) BIO_free(bio);
			auto key = PEM_read_bio_PrivateKey(bio, null, null, null);
			scope(exit) EVP_PKEY_free(key);
			assert(s.tls !is null && SSL_CTX_use_certificate(s.tls, x) == 1 && SSL_CTX_use_PrivateKey(s.tls, key) == 1);
			return s;
		}

		// Ends the connection to the client.
		private void hangUp(ref Server s) {
			if (s.session !is null) {
				if (!s.truncate) cast(void) SSL_shutdown(s.session);
				SSL_free(s.session);
			}
			s.session = null;
			cast(void) core.sys.posix.unistd.close(s.client);
			s.client = -1;
		}

		private void close(ref Server s) {
			if (s.client >= 0) hangUp(s);
			cast(void) core.sys.posix.unistd.close(s.listener);
			fp.dynarray.free(s.request);
			if (s.tls !is null) SSL_CTX_free(s.tls);
		}

		// Accepts, reads a whole request, and answers it with `responses[s.served]`, as far as it can without waiting.
		private void step(ref Server s, const(char[])[] responses) @trusted {
			if (s.client < 0) {
				if (s.served == responses.length) return;
				s.client = core.sys.posix.sys.socket.accept(s.listener, null, null);
				if (s.client < 0) return;
				cast(void) core.sys.posix.fcntl.fcntl(s.client, core.sys.posix.fcntl.F_SETFL, core.sys.posix.fcntl.O_NONBLOCK);
				fp.dynarray.clear(s.request);
				if (s.tls !is null) {
					s.session = SSL_new(s.tls);
					assert(s.session !is null && SSL_set_fd(s.session, s.client) == 1);
					SSL_set_accept_state(s.session);
				}
			}
			char[4096] buffer;
			ptrdiff_t got;
			if (s.session !is null) {
				got = SSL_read(s.session, buffer.ptr, buffer.length);
				immutable error = SSL_get_error(s.session, cast(int) got);
				if (got <= 0 && error != sslErrorWantRead && error != sslErrorWantWrite) {
					// The client refused the handshake, as the tests of bad certificates expect.
					++s.served;
					return hangUp(s);
				}
			} else got = core.sys.posix.sys.socket.recv(s.client, buffer.ptr, buffer.length, 0);
			if (got > 0) assert(fp.dynarray.concatenate(s.request, buffer[0 .. got]));
			auto text = fp.dynarray.slice(s.request);
			size_t end = 0;
			while (end + 4 <= text.length && text[end .. end + 4] != "\r\n\r\n") ++end;
			if (end + 4 > text.length) return;
			size_t length = 0;
			static immutable field = "\r\nContent-Length: ";
			foreach (i; 0 .. end) if (i + field.length <= end && text[i .. i + field.length] == field)
				for (size_t at = i + field.length; at < end && text[at] >= '0' && text[at] <= '9'; ++at) length = length * 10 + (text[at] - '0');
			if (text.length < end + 4 + length) return;
			const(char)[] response = responses[s.served++];
			while (response.length) {
				immutable wrote = s.session !is null ? SSL_write(s.session, response.ptr, cast(int) response.length) : core.sys.posix.sys.socket.send(s.client, response.ptr, response.length, 0);
				if (wrote <= 0 && (s.session !is null ? SSL_get_error(s.session, cast(int) wrote) == sslErrorWantWrite : core.stdc.errno.errno == core.stdc.errno.EAGAIN)) continue;
				assert(wrote > 0);
				response = response[wrote .. $];
			}
			hangUp(s);
		}

		// Accepts the connection the client has started, waiting for it.
		private void acceptClient(ref Server s) @trusted {
			core.sys.posix.poll.pollfd p = {s.listener, core.sys.posix.poll.POLLIN};
			assert(core.sys.posix.poll.poll(&p, 1, 5000) == 1);
			s.client = core.sys.posix.sys.socket.accept(s.listener, null, null);
			assert(s.client >= 0);
		}

		// Hangs up on the client, with a reset if `abruptly`, else having read what it sent, so the client sees its stream end.
		private void cutOff(ref Server s, bool abruptly) @trusted {
			if (abruptly) {
				core.sys.posix.sys.socket.linger l = {l_onoff: 1, l_linger: 0};
				assert(core.sys.posix.sys.socket.setsockopt(s.client, core.sys.posix.sys.socket.SOL_SOCKET, core.sys.posix.sys.socket.SO_LINGER, &l, l.sizeof) == 0);
			} else {
				char[4096] buffer;
				cast(void) core.sys.posix.fcntl.fcntl(s.client, core.sys.posix.fcntl.F_SETFL, core.sys.posix.fcntl.O_NONBLOCK);
				while (core.sys.posix.sys.socket.recv(s.client, buffer.ptr, buffer.length, 0) > 0) {}
			}
			cast(void) core.sys.posix.unistd.close(s.client);
			s.client = -1;
		}

		// Drops the context https fetches share, and the tests' trust in it, so the next fetch makes it afresh.
		private void forgetTls() {
			if (tlsShared !is null) SSL_CTX_free(tlsShared);
			tlsShared = null;
			trusting = false;
		}

		// Whether `e` has sent its TLS client hello and waits on the server's answer.
		private bool helloSent(ref const Exchange e) {
			return e.phase == Phase.handshaking && e.events == core.sys.posix.poll.POLLIN;
		}

		// An address no socket connects to, too short to be one.
		private core.sys.posix.netdb.addrinfo unusableAddress(ref ubyte[16] storage) @trusted {
			core.sys.posix.netdb.addrinfo a = {ai_family: core.sys.posix.sys.socket.AF_INET, ai_socktype: core.sys.posix.sys.socket.SOCK_STREAM, ai_addr: cast(core.sys.posix.sys.socket.sockaddr*) storage.ptr, ai_addrlen: 1};
			return a;
		}
	}
}

version (Windows) {
	version (unittest) {
		pragma(lib, "ncrypt");

		// What the tests' loopback server needs beyond what the client uses.
		private extern (Windows) {
			struct PollFd {
				size_t fd;
				short events;
				short revents;
			}

			struct Linger {
				ushort onoff;
				ushort linger;
			}

			struct NCryptBuffer {
				uint size;
				uint type;
				void* bytes;
			}

			struct NCryptBufferDesc {
				uint version_;
				uint count;
				NCryptBuffer* buffers;
			}

			struct KeyProviderInfo {
				const(wchar)* container;
				const(wchar)* provider;
				uint providerType;
				uint flags;
				uint parameterCount;
				void* parameters;
				uint keySpec;
			}

			// CERT_CHAIN_ENGINE_CONFIG as of Windows 8, which added the exclusive root store.
			struct EngineConfig {
				uint size = EngineConfig.sizeof;
				void* restrictedRoot, restrictedTrust, restrictedOther;
				uint additionalStoreCount;
				void** additionalStores;
				uint flags, urlRetrievalTimeout, maximumCachedCertificates, cycleDetectionModulus;
				void* exclusiveRoot, exclusiveTrustedPeople;
				uint exclusiveFlags;
			}

			int bind(size_t s, const(void)* address, int length);
			pragma(mangle, "listen") int listenOn(size_t s, int backlog);
			size_t accept(size_t s, void* address, int* length);
			int getsockname(size_t s, void* address, int* length);
			int ioctlsocket(size_t s, int command, uint* argument);
			int setsockopt(size_t s, int level, int option, const(void)* value, int length);
			int WSAPoll(PollFd* fds, uint count, int timeout);
			int ApplyControlToken(SecHandle* context, SecBufferDesc* input);

			const(CertContext)* CertCreateCertificateContext(uint encoding, const(ubyte)* encoded, uint length);
			int CertSetCertificateContextProperty(const(CertContext)* certificate, uint property, uint flags, const(void)* data);
			void* CertOpenStore(const(char)* provider, uint encoding, size_t cryptProvider, uint flags, const(void)* parameter);
			int CertCloseStore(void* store, uint flags);
			int CertAddCertificateContextToStore(void* store, const(CertContext)* certificate, uint disposition, const(CertContext)** added);
			int CertCreateCertificateChainEngine(EngineConfig* config, void** engine);
			void CertFreeCertificateChainEngine(void* engine);

			int NCryptOpenStorageProvider(size_t* provider, const(wchar)* name, uint flags);
			int NCryptImportKey(size_t provider, size_t importKey, const(wchar)* blobType, NCryptBufferDesc* parameters, size_t* key, const(ubyte)* data, uint length, uint flags);
			int NCryptFinalizeKey(size_t key, uint flags);
			int NCryptDeleteKey(size_t key, uint flags);
			int NCryptFreeObject(size_t handle);
		}

		private static immutable wchar[] keyStorage = "Microsoft Software Key Storage Provider\0"w;

		// The https side of a test server; its key is stored under `name` because SChannel will not use one held only in memory.
		private struct ServerTls {
			SecHandle credentials;
			const(CertContext)* certificate;
			size_t provider, key;
			wchar[32] name = 0;
		}

		// A one-thread loopback server for the tests: it answers each connection with the next of its responses, then closes it.
		private struct Server {
			size_t listener = invalidSocket;
			size_t listener6 = invalidSocket; // the same port on ::1, as `localhost` may try that first, and a refused connection takes Windows seconds
			size_t client = invalidSocket;
			ushort port;
			size_t served;
			char* request = null; // the last request received, whole
			char[64] url = 0;
			ServerTls* tls; // for an https server, made by `listenTls`
			Tls session;
			char* wire = null; // records to send the client
			bool truncate; // hang up without TLS's close_notify, as a connection cut short does
			bool corrupt; // spoil the response's last record, so the client cannot decrypt it
		}

		// The DER bytes of the PEM block `label` names in `pem`, as a new fp dynarray.
		private char* der(const(char)[] pem, const(char)[] label) @trusted {
			static import fp.string;
			char[64] begin = 0, end_ = 0;
			size_t b = 0, e = 0;
			foreach (c; "-----BEGIN ") begin[b++] = c;
			foreach (c; "-----END ") end_[e++] = c;
			foreach (c; label) {
				begin[b++] = c;
				end_[e++] = c;
			}
			foreach (c; "-----") {
				begin[b++] = c;
				end_[e++] = c;
			}
			immutable from = fp.string.find(pem, begin[0 .. b], 0), to = fp.string.find(pem, end_[0 .. e], 0);
			assert(from != fp.pointer.notFound && to != fp.pointer.notFound);
			char* bytes = null;
			uint bits = 0, count = 0;
			foreach (c; pem[from + b .. to]) {
				int v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26 : c >= '0' && c <= '9' ? c - '0' + 52 : c == '+' ? 62 : c == '/' ? 63 : -1;
				if (v < 0) continue;
				bits = bits << 6 | v;
				count += 6;
				if (count >= 8) {
					count -= 8;
					assert(fp.dynarray.pushBack(bytes, cast(char) (bits >> count)));
				}
			}
			return bytes;
		}

		private const(CertContext)* certificate(const(char)[] pem) @trusted {
			auto bytes = der(pem, "CERTIFICATE");
			scope(exit) fp.dynarray.free(bytes);
			auto x = CertCreateCertificateContext(0x10001, cast(const(ubyte)*) bytes, cast(uint) fp.dynarray.length(bytes));
			assert(x !is null);
			return x;
		}

		private __gshared void* trustedRoots; // kept open as long as the engine trusting it

		// Has every https fetch trust `trustedPem` and `otherPem`, and no other roots, as if a CA had issued them.
		private void trustTestCertificates() @trusted {
			if (chainEngine !is null) return;
			enum memoryStore = cast(const(char)*) 2;
			auto store = trustedRoots = CertOpenStore(memoryStore, 0, 0, 0, null);
			assert(store !is null);
			foreach (pem; [trustedPem, otherPem]) {
				auto x = certificate(pem);
				assert(CertAddCertificateContextToStore(store, x, 4, null));
				cast(void) CertFreeCertificateContext(x);
			}
			EngineConfig config = {exclusiveRoot: store};
			assert(CertCreateCertificateChainEngine(&config, &chainEngine));
		}

		// Drops the credentials https fetches share, and the tests' trust, so the next fetch makes them afresh.
		private void forgetTls() {
			if (tlsMade) cast(void) FreeCredentialsHandle(&tlsShared);
			tlsMade = false;
			if (chainEngine !is null) CertFreeCertificateChainEngine(chainEngine);
			chainEngine = null;
			if (trustedRoots !is null) cast(void) CertCloseStore(trustedRoots, 0);
			trustedRoots = null;
		}

		private void nonblocking(size_t s) @trusted {
			uint one = 1;
			enum int fionbio = cast(int) 0x8004667E;
			assert(ioctlsocket(s, fionbio, &one) == 0);
		}

		// A loopback http server, on port `first` if both 127.0.0.1 and ::1 have it free, else on one the system picks.
		private Server listen(ushort first = 0) @trusted {
			assert(startWinsock());
			Server s;
			foreach (attempt; 0 .. 16) {
				s.listener = socket(2, 1, 0);
				assert(s.listener != invalidSocket);
				ubyte[16] a = 0;
				a[0] = 2;
				if (attempt == 0) {
					a[2] = cast(ubyte) (first >> 8);
					a[3] = cast(ubyte) first;
				}
				a[4] = 127;
				a[7] = 1;
				int size = a.length;
				assert(bind(s.listener, a.ptr, a.length) == 0 && listenOn(s.listener, 8) == 0 && getsockname(s.listener, a.ptr, &size) == 0);
				s.port = cast(ushort) (a[2] << 8 | a[3]);
				s.listener6 = socket(23, 1, 0);
				if (s.listener6 == invalidSocket) break;
				ubyte[28] b = 0;
				b[0] = 23;
				b[2 .. 4] = a[2 .. 4];
				b[23] = 1;
				if (bind(s.listener6, b.ptr, b.length) == 0 && listenOn(s.listener6, 8) == 0) break;
				// Something else holds the port on ::1, so try another.
				cast(void) closesocket(s.listener);
				cast(void) closesocket(s.listener6);
				s.listener = s.listener6 = invalidSocket;
			}
			assert(s.listener != invalidSocket);
			nonblocking(s.listener);
			if (s.listener6 != invalidSocket) nonblocking(s.listener6);
			// Room up front, so tests failing the client's allocations in turn never fail the server's instead.
			assert(fp.dynarray.reserve(s.request, 1 << 16) !is null && fp.dynarray.reserve(s.session.records, 1 << 16) !is null && fp.dynarray.reserve(s.wire, 1 << 16) !is null);
			return s;
		}

		private __gshared uint keysMade;

		// A loopback https server presenting the certificate and key in `pem`.
		private Server listenTls(const(char)[] pem) @trusted {
			static import core.stdc.stdlib;
			trustTestCertificates();
			auto s = listen();
			s.tls = cast(ServerTls*) core.stdc.stdlib.malloc(ServerTls.sizeof);
			assert(s.tls !is null);
			*s.tls = ServerTls.init;
			auto t = s.tls;
			t.certificate = certificate(pem);
			size_t n = 0;
			foreach (c; "bc-http-test-") t.name[n++] = c;
			for (uint v = keysMade++; ; v /= 10) {
				t.name[n++] = cast(wchar) ('0' + v % 10);
				if (v < 10) break;
			}
			auto key = der(pem, "PRIVATE KEY");
			scope(exit) fp.dynarray.free(key);
			NCryptBuffer named = {cast(uint) ((n + 1) * wchar.sizeof), 45, t.name.ptr};
			NCryptBufferDesc parameters = {0, 1, &named};
			enum uint overwrite = 0x80, doNotFinalize = 0x400;
			assert(NCryptOpenStorageProvider(&t.provider, keyStorage.ptr, 0) == 0);
			assert(NCryptImportKey(t.provider, 0, "PKCS8_PRIVATEKEY"w.ptr, &parameters, &t.key, cast(const(ubyte)*) key, cast(uint) fp.dynarray.length(key), overwrite | doNotFinalize) == 0);
			assert(NCryptFinalizeKey(t.key, 0) == 0);
			KeyProviderInfo info = {container: t.name.ptr, provider: keyStorage.ptr};
			enum uint keyProviderInfo = 2;
			assert(CertSetCertificateContextProperty(t.certificate, keyProviderInfo, 0, &info));
			SchCredentials c = {certificateCount: 1, certificates: &t.certificate};
			enum uint credInbound = 1;
			assert(AcquireCredentialsHandleW(null, unisp.ptr, credInbound, null, &c, null, null, &t.credentials, null) == secOk);
			return s;
		}

		// Sends all of `bytes` to the client, waiting for room as it must; false if the client has gone.
		private bool sendAll(ref Server s, const(char)[] bytes) @trusted {
			while (bytes.length) {
				immutable wrote = send(s.client, bytes.ptr, cast(int) bytes.length, 0);
				if (wrote < 0 && WSAGetLastError() == wsaeWouldBlock) continue;
				if (wrote <= 0) return false;
				bytes = bytes[wrote .. $];
			}
			return true;
		}

		// Ends the connection to the client.
		private void hangUp(ref Server s) @trusted {
			if (s.tls !is null && s.session.done && !s.truncate) {
				uint shutdown = 1;
				SecBuffer token = {shutdown.sizeof, secbufferToken, &shutdown};
				SecBufferDesc tokens = {0, 1, &token};
				SecBuffer output = {0, secbufferToken, null};
				SecBufferDesc outputs = {0, 1, &output};
				uint attributes;
				if (ApplyControlToken(&s.session.context, &tokens) == secOk) cast(void) AcceptSecurityContext(&s.tls.credentials, &s.session.context, null, ascRequirements, 0, &s.session.context, &outputs, &attributes, null);
				if (output.bytes !is null) {
					cast(void) sendAll(s, (cast(char*) output.bytes)[0 .. output.size]);
					cast(void) FreeContextBuffer(output.bytes);
				}
			}
			if (s.session.live) cast(void) DeleteSecurityContext(&s.session.context);
			auto records = s.session.records;
			fp.dynarray.clear(records);
			s.session = Tls.init;
			s.session.records = records;
			fp.dynarray.clear(s.wire);
			cast(void) closesocket(s.client);
			s.client = invalidSocket;
		}

		private void close(ref Server s) @trusted {
			static import core.stdc.stdlib;
			if (s.client != invalidSocket) hangUp(s);
			cast(void) closesocket(s.listener);
			if (s.listener6 != invalidSocket) cast(void) closesocket(s.listener6);
			fp.dynarray.free(s.request);
			fp.dynarray.free(s.wire);
			end(s.session);
			if (s.tls !is null) {
				cast(void) FreeCredentialsHandle(&s.tls.credentials);
				cast(void) CertFreeCertificateContext(s.tls.certificate);
				cast(void) NCryptDeleteKey(s.tls.key, 0);
				cast(void) NCryptFreeObject(s.tls.provider);
				core.stdc.stdlib.free(s.tls);
			}
		}

		private size_t acceptEither(ref Server s) @trusted {
			auto client = accept(s.listener, null, null);
			if (client == invalidSocket && s.listener6 != invalidSocket) client = accept(s.listener6, null, null);
			return client;
		}

		// Accepts, reads a whole request, and answers it with `responses[s.served]`, as far as it can without waiting.
		private void step(ref Server s, const(char[])[] responses) @trusted {
			if (s.client == invalidSocket) {
				if (s.served == responses.length) return;
				s.client = acceptEither(s);
				if (s.client == invalidSocket) return;
				fp.dynarray.clear(s.request);
			}
			char[4096] buffer;
			immutable got = recv(s.client, buffer.ptr, buffer.length, 0);
			if (s.tls !is null) {
				if (got > 0) assert(fp.dynarray.concatenate(s.session.records, buffer[0 .. got]));
				// The client hanging up, or refusing the handshake, as the tests of bad certificates expect.
				bool gone = got == 0 || (got < 0 && WSAGetLastError() != wsaeWouldBlock);
				if (!s.session.done) {
					immutable shake = handshake(s.session, &s.tls.credentials, true, s.wire);
					// A client refusing the certificate may hang up before the server's last handshake message, such as a session ticket.
					gone = !sendAll(s, fp.dynarray.slice(s.wire)) || gone || shake == Shake.failed;
					fp.dynarray.clear(s.wire);
				}
				for (Opened opened; !gone && s.session.done && (opened = unseal(s.session, s.request)) != Opened.more;) gone = opened != Opened.some;
				if (gone) {
					++s.served;
					return hangUp(s);
				}
			} else if (got > 0) assert(fp.dynarray.concatenate(s.request, buffer[0 .. got]));
			auto text = fp.dynarray.slice(s.request);
			size_t end = 0;
			while (end + 4 <= text.length && text[end .. end + 4] != "\r\n\r\n") ++end;
			if (end + 4 > text.length) return;
			size_t length = 0;
			static immutable field = "\r\nContent-Length: ";
			foreach (i; 0 .. end) if (i + field.length <= end && text[i .. i + field.length] == field)
				for (size_t at = i + field.length; at < end && text[at] >= '0' && text[at] <= '9'; ++at) length = length * 10 + (text[at] - '0');
			if (text.length < end + 4 + length) return;
			const(char)[] response = responses[s.served++];
			if (s.tls !is null) {
				assert(seal(s.session, response, s.wire) == Sealed.ok);
				if (s.corrupt) s.wire[fp.dynarray.length(s.wire) - 1] ^= 1;
				response = fp.dynarray.slice(s.wire);
			}
			assert(sendAll(s, response));
			hangUp(s);
		}

		// Accepts the connection the client has started, waiting for it.
		private void acceptClient(ref Server s) @trusted {
			enum short pollRead = 0x100;
			PollFd[2] p = [PollFd(s.listener, pollRead), PollFd(s.listener6, pollRead)];
			assert(WSAPoll(p.ptr, s.listener6 == invalidSocket ? 1 : 2, 5000) >= 1);
			s.client = acceptEither(s);
			assert(s.client != invalidSocket);
		}

		// Hangs up on the client, with a reset if `abruptly`, else having read what it sent, so the client sees its stream end.
		private void cutOff(ref Server s, bool abruptly) @trusted {
			if (abruptly) {
				Linger l = {onoff: 1, linger: 0};
				enum int solSocket = 0xFFFF, soLinger = 0x80;
				assert(setsockopt(s.client, solSocket, soLinger, &l, l.sizeof) == 0);
			} else {
				char[4096] buffer;
				while (recv(s.client, buffer.ptr, buffer.length, 0) > 0) {}
			}
			cast(void) closesocket(s.client);
			s.client = invalidSocket;
		}

		// Whether `e` has sent its TLS client hello and waits on the server's answer.
		private bool helloSent(ref const Exchange e) {
			return e.phase == Phase.handshaking && fp.dynarray.length(e.wire) == 0;
		}

		// An address no socket connects to, too short to be one.
		private AddressInfo unusableAddress(ref ubyte[16] storage) @trusted {
			return AddressInfo(0, 2, 1, 0, 1, null, storage.ptr, null);
		}
	}

	unittest { // SChannel's rarer turns: a record that will not seal or decrypt, a reopened handshake waiting on more, and the test server leaving a port ::1 holds
		Tls t;
		t.sizes.header = 5;
		t.sizes.trailer = 16;
		t.sizes.maximumMessage = 16;
		char* wire = null;
		scope(exit) fp.dynarray.free(wire);
		assert(fp.dynarray.concatenate(wire, "kept"));
		assert(seal(t, "plain", wire) == Sealed.failed && fp.dynarray.slice(wire) == "kept");

		auto s = listenTls(trustedPem);
		scope(exit) close(s);
		static immutable responses = ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"];
		s.corrupt = true;
		Request r = {url: address(s, "/")};
		auto f = start(r);
		scope(exit) free(f.get);
		assert(drive(s, f.get, responses) == State.failed && f.get.failure == Failure.network);

		s.corrupt = false;
		s.served = 0;
		auto g = start(r);
		scope(exit) free(g.get);
		auto e = &g.get.exchange;
		Fetch*[1] gs = [&g.get()];
		while (e.phase != Phase.receiving) {
			step(s, responses);
			assert(poll(g.get) == State.pending);
			cast(void) wait(gs[], 1);
		}
		// The server sends its session ticket only with the response, so the handshake reopened here has nothing to go on.
		assert(e.tls.done && fp.dynarray.length(e.tls.records) == 0);
		e.tls.done = false;
		assert(poll(g.get) == State.pending && !e.tls.done);
		e.tls.done = true;
		assert(drive(s, g.get, responses) == State.done && readAll(g.get).get == "ok");

		auto held = socket(23, 1, 0);
		if (held == invalidSocket) return;
		scope(exit) cast(void) closesocket(held);
		ubyte[28] b = 0;
		b[0] = 23;
		b[23] = 1;
		int size = b.length;
		assert(bind(held, b.ptr, b.length) == 0 && getsockname(held, b.ptr, &size) == 0);
		immutable taken = cast(ushort) (b[2] << 8 | b[3]);
		auto moved = listen(taken);
		scope(exit) close(moved);
		assert(moved.port != taken && moved.listener6 != invalidSocket);
	}
}

version (WASI) {
} else {

	unittest { // a GET and its response by length: the request sent, the status, fields and body, and the URL
		static import fp.string;
		auto s = listen();
		scope(exit) close(s);
		static immutable responses = ["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"];
		Request r = {url: address(s, "/path?q=1")};
		assert(append(r.headers, "Accept", "text/plain") && append(r.headers, "Host", "ignored") && append(r.headers, "connection", "keep-alive"));
		scope(exit) free(r.headers);
		auto f = start(r);
		scope(exit) free(f.get);
		assert(drive(s, f.get, responses) == State.done);
		auto sent = fp.dynarray.slice(s.request);
		assert(sent[0 .. 25] == "GET /path?q=1 HTTP/1.1\r\nH");
		assert(fp.string.contains(sent, "\r\nAccept: text/plain\r\n", 0) && fp.string.contains(sent, "\r\nConnection: close\r\n\r\n", 0));
		assert(!fp.string.contains(sent, "ignored", 0) && !fp.string.contains(sent, "keep-alive", 0) && !fp.string.contains(sent, "Content-Length", 0));
		assert(f.get.status == 200 && get(f.get.headers, "content-type").get == "text/plain" && f.get.url == r.url);
		assert(readAll(f.get).get == "hello" && readAll(f.get).get == "hello");

		static import fp.testing;
		s.served = 0;
		auto g = start(r);
		scope(exit) free(g.get);
		assert(drive(s, g.get, responses, State.head) >= State.head);
		auto previous = fp.testing.limitAllocations(0);
		assert(readAll(g.get).isNull);
		fp.testing.restoreAllocator(previous);
		assert(g.get.failure == Failure.outOfMemory);
	}

	unittest { // a POST's body and length are sent, a chunked body read a little at a time, and an interim response skipped
		static import fp.string;
		auto s = listen();
		scope(exit) close(s);
		static immutable responses = ["HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n"];
		Request r = {url: address(s, ""), method: "post", body: "{\"a\":1}"};
		auto f = start(r);
		scope(exit) free(f.get);
		assert(drive(s, f.get, responses, State.head) >= State.head && f.get.status == 201);
		assert(fp.string.startsWith(fp.dynarray.slice(s.request), "POST / HTTP/1.1\r\n", 0));
		assert(fp.string.endsWith(fp.dynarray.slice(s.request), "\r\nContent-Length: 7\r\nConnection: close\r\n\r\n{\"a\":1}", 0));
		char[64] body;
		size_t n = 0;
		char[2] small;
		Fetch*[1] fs = [&f.get()];
		for (;;) {
			auto got = readBody(f.get, small[]);
			if (got.isNull) break;
			foreach (i; 0 .. got.get) body[n + i] = small[i];
			n += got.get;
			if (got.get == 0) cast(void) wait(fs[], 10);
		}
		assert(f.get.state == State.done && body[0 .. n] == "abcdefg");
	}

	unittest { // a body ended by the connection closing; HEAD and 204 responses with no body; and a response cut short failing
		auto s = listen();
		scope(exit) close(s);
		static immutable responses = ["HTTP/1.1 200 OK\r\n\r\nto the end", "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n", "HTTP/1.1 204 No Content\r\n\r\n",
			"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", "garbage\r\n\r\n", ""];
		static immutable methods = ["GET", "HEAD", "GET", "GET", "GET", "GET", "GET"];
		static immutable bodies = ["to the end", "", ""];
		foreach (i, method; methods) {
			Request r = {url: address(s, "/"), method: method};
			auto f = start(r);
			scope(exit) free(f.get);
			immutable state = drive(s, f.get, responses);
			if (i < bodies.length) assert(state == State.done && readAll(f.get).get == bodies[i]);
			else assert(state == State.failed && f.get.failure == Failure.network && readAll(f.get).isNull);
		}
	}

	unittest { // redirects: relative and absolute locations, POST turned to GET on 303, refused, manual, and too many
		static import fp.string;
		auto s = listen();
		scope(exit) close(s);
		Request r = {url: address(s, "/a/b?x"), method: "POST", body: "data"};
		assert(append(r.headers, "Content-Type", "text/plain") && append(r.headers, "Authorization", "secret"));
		scope(exit) free(r.headers);
		static immutable chain = ["HTTP/1.1 307 Temporary\r\nLocation: c\r\n\r\n", "HTTP/1.1 303 See Other\r\nLocation: /d?y\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"];
		auto f = start(r);
		scope(exit) free(f.get);
		assert(drive(s, f.get, chain) == State.done && readAll(f.get).get == "ok");
		assert(fp.string.endsWith(f.get.url, "/d?y", 0));
		auto last = fp.dynarray.slice(s.request);
		assert(fp.string.startsWith(last, "GET /d?y HTTP/1.1\r\n", 0) && !fp.string.contains(last, "Content-Type", 0) && fp.string.contains(last, "Authorization: secret", 0));

		static immutable once = ["HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\n\r\n"];
		foreach (mode; [Redirect.error, Redirect.manual]) {
			s.served = 0;
			Request m = {url: address(s, "/"), redirect: mode};
			auto g = start(m);
			scope(exit) free(g.get);
			immutable state = drive(s, g.get, once);
			if (mode == Redirect.error) assert(state == State.failed && g.get.failure == Failure.redirectRefused);
			else assert(state == State.done && g.get.status == 302 && get(g.get.headers, "location").get == "/");
		}

		s.served = 0;
		static immutable invalid = ["HTTP/1.1 302 Found\r\nLocation: http://\r\n\r\n"];
		Request v = {url: address(s, "/")};
		auto bad = start(v);
		scope(exit) free(bad.get);
		assert(drive(s, bad.get, invalid) == State.failed && bad.get.failure == Failure.invalidUrl);

		s.served = 0;
		const(char)[][maxRedirects + 1] loop = "HTTP/1.1 301 Moved\r\nLocation: /\r\n\r\n";
		Request l = {url: address(s, "/")};
		auto g = start(l);
		scope(exit) free(g.get);
		assert(drive(s, g.get, loop[]) == State.failed && g.get.failure == Failure.tooManyRedirects && s.served == maxRedirects + 1);
	}

	unittest { // resolving locations against a URL
		static import fp.string;
		static immutable cases = [
			["http://h:1/a/b?q", "c", "http://h:1/a/c"], ["http://h/a/b", "/x", "http://h/x"], ["http://h/a", "//g/p", "http://g/p"],
			["http://h/a?q", "?r", "http://h/a?r"], ["http://h", "x", "http://h/x"], ["http://h/a?q", "", "http://h/a?q"],
			["http://h/a", "https://o/", "https://o/"], ["http://h", "?r", "http://h/?r"]];
		foreach (c; cases) {
			char* got = resolve(c[0], c[1]);
			scope(exit) fp.dynarray.free(got);
			assert(fp.dynarray.slice(got) == c[2]);
		}

		static import fp.testing;
		auto previous = fp.testing.limitAllocations(0);
		assert(resolve("http://h/a", "b") is null);
		fp.testing.restoreAllocator(previous);
	}

	unittest { // a timeout fails a fetch the server never answers, an abort stops one, and a refused connection fails
		auto s = listen();
		scope(exit) close(s);
		Request r = {url: address(s, "/"), timeoutMs: 20};
		auto f = start(r);
		scope(exit) free(f.get);
		Fetch*[1] fs = [&f.get()];
		while (poll(f.get) == State.pending) cast(void) wait(fs[], -1);
		assert(f.get.failure == Failure.timeout);

		Request a = {url: address(s, "/")};
		auto g = start(a);
		scope(exit) free(g.get);
		abort(g.get);
		assert(poll(g.get) == State.failed && g.get.failure == Failure.aborted);

		Request refused = {url: "http://127.0.0.1:1/"};
		auto h = fetch(refused);
		scope(exit) free(h.get);
		assert(h.get.state == State.failed && h.get.failure == Failure.network);

		// Waiting on no fetches waits out the time.
		assert(!wait(null, 1));

		// An address no socket can connect to at all is passed over at once.
		ubyte[16] nowhere;
		auto unusable = unusableAddress(nowhere);
		Fetch d;
		scope(exit) free(d);
		dial(d, &unusable);
		assert(d.state == State.failed && d.failure == Failure.network);
	}

	unittest { // a request too big to send at once waits for room, and fails when the server resets the connection
		auto s = listen();
		scope(exit) close(s);
		enum size_t size = 1 << 26;
		char* body = null;
		scope(exit) fp.dynarray.free(body);
		assert(fp.dynarray.growToSize(body, size) !is null);
		core.stdc.string.memset(body, 'x', size);
		Request r = {url: address(s, "/"), method: "PUT", body: body[0 .. size]};
		auto f = start(r);
		scope(exit) free(f.get);
		auto e = &f.get.exchange;
		Fetch*[1] fs = [&f.get()];
		while (e.sent == 0) {
			assert(poll(f.get) == State.pending);
			cast(void) wait(fs[], 10);
		}
		assert(e.phase == Phase.sending && e.sent < fp.dynarray.length(e.out_));
		version (Posix) assert(e.events == core.sys.posix.poll.POLLOUT);
		acceptClient(s);
		cutOff(s, true);
		while (poll(f.get) == State.pending) cast(void) wait(fs[], 10);
		assert(f.get.failure == Failure.network);
	}

	unittest { // a host name resolved on a thread, trying each of its addresses; freeing a fetch mid-lookup; and a name that does not resolve
		auto s = listen();
		scope(exit) close(s);
		static immutable responses = ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"];
		Request gone = {url: address(s, "/", "localhost")};
		auto g = start(gone);
		assert(g.get.exchange.phase == Phase.resolving);
		free(g.get);

		Request r = {url: address(s, "/", "localhost")};
		auto f = start(r);
		scope(exit) free(f.get);
		assert(drive(s, f.get, responses) == State.done && readAll(f.get).get == "ok");

		Request nowhere = {url: "http://nowhere.invalid/"};
		auto n = fetch(nowhere);
		scope(exit) free(n.get);
		assert(n.get.state == State.failed && n.get.failure == Failure.network);
	}

	unittest { // https: bodies by length and chunked, by address and by name, a redirect to plain http, and certificates refused for trust or name
		auto s = listenTls(trustedPem);
		scope(exit) close(s);
		auto plain = listen();
		scope(exit) close(plain);
		static immutable responses = ["HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecret", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n"];
		foreach (i, host; ["127.0.0.1", "localhost"]) {
			s.served = i;
			Request r = {url: address(s, "/", host)};
			auto f = start(r);
			scope(exit) free(f.get);
			assert(drive(s, f.get, responses[0 .. i + 1]) == State.done && readAll(f.get).get == (i ? "hi" : "secret"));
		}

		char[96] location = 0;
		size_t n = 0;
		foreach (c; "HTTP/1.1 302 Found\r\nLocation: ") location[n++] = c;
		foreach (c; address(plain, "/x")) location[n++] = c;
		foreach (c; "\r\n\r\n") location[n++] = c;
		s.served = 0;
		Request r = {url: address(s, "/")};
		auto f = start(r);
		scope(exit) free(f.get);
		const(char[])[1] redirecting = [location[0 .. n]];
		static immutable landed = ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nhere"];
		Fetch*[1] fs = [&f.get()];
		while (poll(f.get) == State.pending) {
			step(s, redirecting[]);
			step(plain, landed);
			cast(void) wait(fs[], 1);
		}
		assert(readAll(f.get).get == "here" && f.get.url == address(plain, "/x"));

		foreach (pem; [untrustedPem, otherPem]) {
			auto bad = listenTls(pem);
			scope(exit) close(bad);
			Request b = {url: address(bad, "/")};
			auto g = start(b);
			scope(exit) free(g.get);
			assert(drive(bad, g.get, responses[0 .. 1]) == State.failed && g.get.failure == Failure.network);
			foreach (_; 0 .. 10_000) if (bad.served == 0) step(bad, responses[0 .. 1]);
			assert(bad.served == 1);
		}
	}

	unittest { // an https fetch fails, rather than going on, when an allocation is refused mid-handshake
		static import fp.testing;
		auto s = listenTls(trustedPem);
		scope(exit) close(s);
		Request r = {url: address(s, "/")};
		auto f = start(r);
		scope(exit) free(f.get);
		static immutable responses = ["HTTP/1.1 200 OK\r\n\r\n"];
		auto previous = fp.testing.limitAllocations(0);
		immutable state = drive(s, f.get, responses);
		fp.testing.restoreAllocator(previous);
		assert(state == State.failed && f.get.failure == Failure.outOfMemory);
	}

	unittest { // an https server hanging up mid-handshake, by reset or end of stream, fails the fetch; a body ends with the stream, close_notify or not
		foreach (abruptly; [false, true]) {
			auto s = listenTls(trustedPem);
			scope(exit) close(s);
			Request r = {url: address(s, "/")};
			auto f = start(r);
			scope(exit) free(f.get);
			auto e = &f.get.exchange;
			Fetch*[1] fs = [&f.get()];
			while (!helloSent(*e)) {
				assert(poll(f.get) == State.pending);
				cast(void) wait(fs[], 10);
			}
			acceptClient(s);
			cutOff(s, abruptly);
			while (poll(f.get) == State.pending) cast(void) wait(fs[], 10);
			assert(f.get.failure == Failure.network);
		}

		auto s = listenTls(trustedPem);
		scope(exit) close(s);
		static immutable responses = ["HTTP/1.1 200 OK\r\n\r\nto the end", "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort"];
		// Ended by close_notify or not, a body read until the end is whole, and one shorter than its length is not.
		foreach (truncate; [true, false]) {
			s.truncate = truncate;
			s.served = 0;
			foreach (i; 0 .. responses.length) {
				Request r = {url: address(s, "/")};
				auto f = start(r);
				scope(exit) free(f.get);
				immutable state = drive(s, f.get, responses);
				if (i == 0) assert(state == State.done && readAll(f.get).get == "to the end");
				else assert(state == State.failed && f.get.failure == Failure.network);
			}
		}
	}

	unittest { // every acquisition a fetch makes, failed in turn, fails it with `Failure.outOfMemory` or `Failure.unsupported`, or is worked around, as a thread to resolve on is
		static immutable responses = ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"];
		// Bigger than one TLS record, so sealing the request needs more room than the handshake did.
		static immutable char[20_000] payload = 'x';
		foreach (secure; [false, true]) {
			for (size_t i = 0;; ++i) {
				auto s = secure ? listenTls(trustedPem) : listen();
				scope(exit) close(s);
				Request r = {url: address(s, "/", "localhost"), method: "POST", body: payload[]};
				auto allocator = fp.pointer.allocator;
				failAfter(i);
				auto f = start(r);
				if (f.isNull) continue;
				scope(exit) free(f.get);
				immutable state = drive(s, f.get, responses);
				// The failure restores the allocator; if it never came, the fetch made fewer than `i` acquisitions, so each has been failed.
				immutable failed = fp.pointer.allocator is allocator;
				if (!failed) while (!simulatedFailure()) {}
				// OpenSSL does not say why a write failed, so that one fails as `Failure.network`.
				if (state == State.failed) assert(failed && (f.get.failure == Failure.outOfMemory || (secure && f.get.failure == Failure.network)));
				else assert(readAll(f.get).get == "ok");
				if (!failed) break;
			}
		}

		// The context https fetches share is made on first use, so only then can making it fail.
		for (size_t i = 0;; ++i) {
			forgetTls();
			failAfter(i);
			Request r = {url: "https://127.0.0.1:1/"};
			auto f = start(r);
			if (f.isNull) continue;
			scope(exit) free(f.get);
			if (f.get.failure == Failure.unsupported) break;
			assert(f.get.failure == Failure.outOfMemory);
		}
		forgetTls();
	}
}

version (WASI) {
	version (unittest) {
		static import core.stdc.stdlib;

		// The test server's URL that tools/wasi.py passes, followed by `path`, in `buffer`.
		private const(char)[] address(ref char[128] buffer, const(char)[] path) @trusted {
			auto base = core.stdc.stdlib.getenv("BC_HTTP_TEST_URL");
			assert(base !is null, "BC_HTTP_TEST_URL is not set");
			size_t n = 0;
			for (; base[n]; ++n) buffer[n] = base[n];
			foreach (c; path) buffer[n++] = c;
			return buffer[0 .. n];
		}
	}

	unittest { // through the host's fetch: a GET, a POST echoed back, and a body read a little at a time as it arrives
		static import fp.string;
		char[128] url;
		Request r = {url: address(url, "/hello")};
		auto f = fetch(r);
		scope(exit) free(f.get);
		assert(f.get.state >= State.head && f.get.status == 200 && get(f.get.headers, "Content-Type").get == "text/plain");
		assert(readAll(f.get).get == "hello" && fp.string.endsWith(f.get.url, "/hello", 0));

		Request p = {url: address(url, "/echo"), method: "post", body: "data"};
		assert(append(p.headers, "Accept", "text/x-test"));
		scope(exit) free(p.headers);
		auto g = fetch(p);
		scope(exit) free(g.get);
		assert(readAll(g.get).get == "POST data" && get(g.get.headers, "x-accept").get == "text/x-test");

		Request c = {url: address(url, "/chunks")};
		auto h = start(c);
		scope(exit) free(h.get);
		char[64] body;
		size_t n = 0;
		char[2] small;
		Fetch*[1] fs = [&h.get()];
		for (;;) {
			auto got = readBody(h.get, small[]);
			if (got.isNull) break;
			foreach (i; 0 .. got.get) body[n + i] = small[i];
			n += got.get;
			if (got.get == 0) cast(void) wait(fs[], -1);
		}
		assert(h.get.state == State.done && body[0 .. n] == "abcdefg");
	}

	unittest { // a body bigger than the host holds at once arrives whole, and redirects are followed, refused, or handed over
		static import fp.string;
		char[128] url;
		Request r = {url: address(url, "/big")};
		auto f = fetch(r);
		scope(exit) free(f.get);
		auto text = readAll(f.get).get;
		assert(text.length == 3 << 20);
		foreach (i, c; text) assert(c == cast(char) ('a' + i % 26));

		Request follow = {url: address(url, "/redirect")};
		auto g = fetch(follow);
		scope(exit) free(g.get);
		assert(g.get.status == 200 && fp.string.endsWith(g.get.url, "/hello", 0) && readAll(g.get).get == "hello");

		Request refuse = {url: address(url, "/redirect"), redirect: Redirect.error};
		auto h = fetch(refuse);
		scope(exit) free(h.get);
		assert(h.get.state == State.failed && h.get.failure == Failure.redirectRefused);

		Request manual = {url: address(url, "/redirect"), redirect: Redirect.manual};
		auto m = fetch(manual);
		scope(exit) free(m.get);
		// Node hands over the redirect itself; a browser hides it, as `Redirect.manual` says.
		assert(m.get.status == 302 ? get(m.get.headers, "location").get == "/hello" : m.get.status == 0 && length(m.get.headers) == 0);
	}

	unittest { // a timeout fails a fetch the server never answers, an abort stops one, and a refused connection fails
		char[128] url;
		Request r = {url: address(url, "/never"), timeoutMs: 50};
		auto f = fetch(r);
		scope(exit) free(f.get);
		assert(f.get.state == State.failed && f.get.failure == Failure.timeout);

		Request a = {url: address(url, "/never")};
		auto g = start(a);
		scope(exit) free(g.get);
		abort(g.get);
		assert(poll(g.get) == State.failed && g.get.failure == Failure.aborted);

		Request refused = {url: "http://127.0.0.1:1/"};
		auto h = fetch(refused);
		scope(exit) free(h.get);
		assert(h.get.state == State.failed && h.get.failure == Failure.network);
	}
}
