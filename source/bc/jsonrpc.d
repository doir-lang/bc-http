/// A JSON-RPC transport: messages framed by `Content-Length` headers, read from and written to file descriptors, as Language Server Protocol clients speak over a server's stdin and stdout.
///
/// Examples:
/// ---
/// static import core.stdc.stdio;
/// auto file = core.stdc.stdio.tmpfile();
/// assert(file !is null);
/// scope(exit) cast(void) core.stdc.stdio.fclose(file);
/// immutable fd = core.stdc.stdio.fileno(file);
/// assert(send(fd, `{"a":1}`));
/// core.stdc.stdio.rewind(file);
/// Reader r = Reader(fd);
/// scope(exit) free(r);
/// assert(next(r) == `{"a":1}` && next(r) is null && r.closed);
/// ---
module bc.jsonrpc;

static import std.typecons;

static import fp.string;
static import fp.dynarray;
static import fp.file;

@nogc nothrow:


// --- reading -----------------------------------------------------------------

/// Reads framed messages from `fd`. Plain data, released by `free`; it does not close `fd`. On Windows, reading puts `fd` in binary mode, as `fp.file.readSome` does, so the C runtime does not translate line ends.
struct Reader {
	int fd; /// Where messages come from.
	bool closed; /// Set once `fd` has ended or failed, or an allocation was refused.
	private char* buffer = null; // bytes read but not yet handed out, from `start`
	private size_t start;
}

/// Releases `r`'s buffer.
///
/// Examples:
/// ---
/// Reader r = Reader(0);
/// free(r);
/// ---
void free(ref Reader r) {
	fp.dynarray.free(r.buffer);
	r.buffer = null;
	r.start = 0;
}

// Where a message's body starts in its reader's buffer, and how long it is.
private struct Frame {
	size_t bodyStart, bodyLength;
}

// The frame of the message at `r.start`, whose body may not be buffered yet; null until its header is.
private std.typecons.Nullable!Frame framed(ref const Reader r) @trusted {
	auto bytes = r.buffer[r.start .. fp.dynarray.length(r.buffer)];
	size_t end = 0;
	while (end + 4 <= bytes.length && bytes[end .. end + 4] != "\r\n\r\n") ++end;
	if (end + 4 > bytes.length) return typeof(return).init;
	size_t bodyLength = 0;
	static immutable field = "content-length:";
	for (size_t line = 0; line < end;) {
		size_t stop = line;
		while (stop < end && bytes[stop] != '\r') ++stop;
		auto header = bytes[line .. stop];
		if (header.length > field.length && fp.string.equalIgnoringAsciiCase(header[0 .. field.length], field)) {
			foreach (c; header[field.length .. $]) {
				if (c == ' ') continue;
				if (c < '0' || c > '9') break;
				bodyLength = bodyLength * 10 + (c - '0');
			}
		}
		line = stop + 2;
	}
	return typeof(return)(Frame(r.start + end + 4, bodyLength));
}

// Whether the whole of the message `frame` describes is in `r.buffer`.
private bool arrived(ref const Reader r, std.typecons.Nullable!Frame frame) {
	return !frame.isNull && frame.get.bodyStart + frame.get.bodyLength <= fp.dynarray.length(r.buffer);
}

/// Whether a whole message is already buffered, so `next` would not wait: a server drains a burst of edits before answering any.
///
/// Examples:
/// ---
/// Reader r = Reader(0);
/// assert(!buffered(r));
/// ---
bool buffered(ref const Reader r) {
	return r.buffer !is null && arrived(r, framed(r));
}

/// The next message's body, read from `r.fd` as needed; it stays valid until the next call.
///
/// Returns null, setting `r.closed`, once `fd` ends, fails, or an allocation is refused.
///
/// Examples:
/// ---
/// Reader r = Reader(-1);
/// assert(next(r) is null && r.closed);
/// ---
const(char)[] next(ref Reader r) @trusted {
	for (;;) {
		if (r.buffer !is null) {
			immutable frame = framed(r);
			if (arrived(r, frame)) {
				r.start = frame.get.bodyStart + frame.get.bodyLength;
				return r.buffer[frame.get.bodyStart .. r.start];
			}
		}
		if (r.closed) return null;
		// What was handed out goes before more is read, so the buffer holds one message at most plus what follows it.
		immutable kept = fp.dynarray.length(r.buffer) - r.start;
		if (r.start) {
			foreach (i; 0 .. kept) r.buffer[i] = r.buffer[r.start + i];
			cast(void) fp.dynarray.removeLast(r.buffer, r.start);
			r.start = 0;
		}
		// Once the header gives the length, room for the body is made once: growing per read copied a large document quadratically.
		enum size_t chunk = 1 << 16;
		size_t size = chunk;
		if (r.buffer !is null) {
			immutable frame = framed(r);
			if (!frame.isNull && frame.get.bodyStart + frame.get.bodyLength - kept > chunk) size = frame.get.bodyStart + frame.get.bodyLength - kept;
		}
		if (fp.dynarray.growToSize(r.buffer, kept + size) is null) {
			r.closed = true;
			return null;
		}
		immutable got = fp.file.readSome(r.fd, r.buffer[kept .. kept + size]);
		cast(void) fp.dynarray.removeLast(r.buffer, size - (got > 0 ? got : 0));
		if (got <= 0) r.closed = true;
	}
}


// --- writing -----------------------------------------------------------------

/// Writes `body` to `fd` as one message, its `Content-Length` header first. On Windows it puts `fd` in binary mode first, as reading does.
///
/// Returns false if `fd` fails, perhaps partway through the message.
///
/// Examples:
/// ---
/// assert(!send(-1, "{}"));
/// ---
bool send(int fd, const(char)[] body) {
	char[48] header = "Content-Length: ";
	size_t at = 16;
	char[fp.string.maxDecimalLength] digits;
	foreach (c; fp.string.formatUnsigned(body.length, digits)) header[at++] = c;
	foreach (c; "\r\n\r\n") header[at++] = c;
	return fp.file.writeAll(fd, header[0 .. at]) && fp.file.writeAll(fd, body);
}


version (unittest) {
	version (WASI) {
		static import core.sys.posix.fcntl;

		// druntime declares no lseek for WASI, whose off_t is 64 bits.
		private extern (C) long lseek(int fd, long offset, int whence);
	} else static import core.stdc.stdio;

	version (Windows) {
		private extern (C) {
			int _setmode(int fd, int mode);
			int _dup(int fd);
			int _close(int fd);
			int _lseek(int fd, int offset, int whence);
		}
	}

	private void closeFd(int fd) @trusted {
		version (Windows) cast(void) _close(fd);
		else {
			static import core.sys.posix.unistd;
			cast(void) core.sys.posix.unistd.close(fd);
		}
	}

	// A file to write messages into and read back: WASI preview 1 has neither pipes nor tmpfile.
	private int scratch() @trusted {
		version (WASI) return core.sys.posix.fcntl.open("/tmp/bc-jsonrpc-test", core.sys.posix.fcntl.O_RDWR | core.sys.posix.fcntl.O_CREAT | core.sys.posix.fcntl.O_TRUNC, 384);
		else {
			auto file = core.stdc.stdio.tmpfile();
			assert(file !is null);
			scope(exit) cast(void) core.stdc.stdio.fclose(file);
			version (Windows) return _dup(core.stdc.stdio.fileno(file));
			else {
				static import core.sys.posix.unistd;
				return core.sys.posix.unistd.dup(core.stdc.stdio.fileno(file));
			}
		}
	}

	// Moves `fd` back to its start, to read what was written.
	private bool rewind(int fd) {
		version (WASI) return lseek(fd, 0, 0) == 0;
		else version (Windows) return _lseek(fd, 0, 0) == 0;
		else {
			static import core.sys.posix.unistd;
			return core.sys.posix.unistd.lseek(fd, 0, 0) == 0;
		}
	}
}

unittest { // messages split across writes and run together come out whole and in order, and a header block without a length is skipped
	immutable fd = scratch();
	assert(fd >= 0);
	scope(exit) closeFd(fd);
	static immutable stream = "Content-Length: 7\r\nContent-Type: x\r\n\r\n{\"a\":1}content-length:2\r\n\r\n[]X-Other: 1\r\n\r\nContent-Length: 0\r\n\r\n";
	foreach (i; 0 .. stream.length) assert(fp.file.writeSome(fd, stream[i .. i + 1]) == 1);
	assert(rewind(fd));
	Reader r = Reader(fd);
	scope(exit) free(r);
	assert(next(r) == `{"a":1}`);
	assert(buffered(r) && next(r) == "[]");
	assert(next(r).length == 0 && !r.closed);
	assert(next(r).length == 0 && !r.closed);
	assert(next(r) is null && r.closed);

	// A message many reads long arrives whole, read into room made once its header is in.
	immutable big = scratch();
	assert(big >= 0);
	scope(exit) closeFd(big);
	enum size_t size = 3 << 20;
	char* body = null;
	scope(exit) fp.dynarray.free(body);
	assert(fp.dynarray.growToSize(body, size) !is null);
	foreach (i; 0 .. size) body[i] = cast(char) ('a' + i % 26);
	assert(send(big, body[0 .. size]) && rewind(big));
	Reader large = Reader(big);
	scope(exit) free(large);
	assert(next(large) == body[0 .. size]);
	assert(fp.dynarray.capacity(large.buffer) < size + (1 << 17));

	// A descriptor in text mode is switched to binary, so line ends in a body are neither added to nor taken away.
	version (Windows) {
		immutable text = scratch();
		assert(text >= 0);
		scope(exit) closeFd(text);
		enum int textMode = 0x4000;
		cast(void) _setmode(text, textMode);
		assert(send(text, "a\r\nb\nc") && rewind(text));
		cast(void) _setmode(text, textMode);
		Reader translated = Reader(text);
		scope(exit) free(translated);
		assert(next(translated) == "a\r\nb\nc");
	}

	// No room to read into closes the reader.
	static import fp.testing;
	Reader starved = Reader(big);
	scope(exit) free(starved);
	auto previous = fp.testing.limitAllocations(0);
	assert(next(starved) is null && starved.closed);
	fp.testing.restoreAllocator(previous);
}
