/// A reactor module for tests/wasi/run.mjs's main-thread check: it fetches a URL without ever blocking, reading the body only when the `setWake` hook says the fetch progressed.
module reactor;

static import bc.http;

@nogc nothrow:

private __gshared char[256] url;
private __gshared bc.http.Fetch fetch;
private __gshared char[16] body;
private __gshared size_t got;
private __gshared int woken;

private void count(void* context) {
	++woken;
}

// wrapper: the host finds this hook by name and writes the URL through it
/// Where the host writes the URL before calling `begin`.
extern (C) export char* urlBuffer() {
	return url.ptr;
}

/// Starts fetching the `length` bytes of URL in `urlBuffer`; 0 if it could not.
extern (C) export int begin(size_t length) {
	bc.http.setWake(&count, null);
	bc.http.Request r = {url: url[0 .. length]};
	auto f = bc.http.start(r);
	if (f.isNull) return 0;
	fetch = f.get;
	return 1;
}

/// Reads what has arrived: 0 while more is to come, 1 once the body is whole and is `hello`, -1 otherwise.
extern (C) export int step() {
	for (;;) {
		auto n = bc.http.readBody(fetch, body[got .. $]);
		if (n.isNull) return fetch.state == bc.http.State.done && body[0 .. got] == "hello" ? 1 : -1;
		if (n.get == 0) return 0;
		got += n.get;
	}
}

// wrapper: the host reads this hook by name to check the wake fired
/// How many times the `setWake` hook was called.
extern (C) export int wakes() {
	return woken;
}
