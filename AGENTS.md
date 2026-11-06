# Agent guidelines for bc-fetch

## Comments

- Keep comments minimal.
  Write one only where the code does something difficult to follow on its own: a non-obvious invariant, a subtle memory or lifetime rule, a workaround for a compiler bug, or why an apparently simpler approach would be wrong.
  Do not restate what the code already says.
- Cap every free-standing comment (a `//` or `/* */` block that is not a documentation comment) at 25 words.
  If it needs more, the code or its documentation should carry the explanation instead.
- Editors here soft-wrap, so write each comment, and each paragraph of a DDoc comment, on a single line rather than hard-wrapping it at a column.
- Do not leave commented-out code, change logs, or notes about what was changed in a comment; those belong in commit messages.

## Documentation

- Put a DDoc comment (`///` or `/** */`) directly above every publicly accessible definition: each public or package-visible function, struct, enum, alias, template, mixin template, and module-level variable.
  Private helpers do not need one.
- Every DDoc comment on a function or template includes an example of its use in an `Examples:` section, as a `---` code block:

  ```d
  /// Writes `true` or `false`.
  ///
  /// Examples:
  /// ---
  /// Writer w;
  /// scope(exit) free(w);
  /// boolean(w, true);
  /// assert(fp.string.slice(w.text) == "true");
  /// ---
  void boolean(ref Writer w, bool b) { ... }
  ```

- Keep examples short, and make them correct against the current API: they should compile and pass as written under `-betterC`.
  Check them with `python3 tools/doctest.py`, which compiles and runs every example and reports public definitions missing documentation or an example.
- A DDoc comment is documentation, not a free-standing comment, so the 25-word cap does not apply to it, but keep it as brief as the definition allows.

## Style

- Prefer plain-data structs operated on by free functions that take them by `ref` (for example `beginObject(w)`, `free(w)`), rather than methods.
  Use member functions only for operator overloads and for what a language protocol requires to be a member, such as range primitives (`empty`, `front`, `popFront`) or an `alias this` target.
- Prefer fully qualified names to aliasing imports: call `bc.json.free(w)` rather than `import bc.json : jsonFree = free;` or `alias jsonFree = bc.json.free;`.
  A `static import` keeps a module's names out of scope so every use has to be qualified.
- One bc module uses another, or a libfp module, through a `static import`, so every call names its layer (`bc.json.parse`, `fp.dynarray.pushBack`).
  The exception is a `public import` that re-exports names as part of the module's own API.
- Name everything in camelCase.
  Add a trailing underscore only when the plain name is a D keyword (`out_`, `null_`, `string_`).
- Make names document themselves, so neither a comment nor a wrapper is needed to explain them:
  - Spell words out: no C-heritage names or abbreviations (`allocate`, not `malloc`; `context`, not `ctx`; `array`, not `da`).
  - Name the effect or the result, not the mechanism (`lockForReading`, not `readLock`; `wordEnd` for a function returning where a word ends).
  - Do not repeat what the qualified module path or the types already say: calls are always qualified, so `fp.pointer.allocate` needs no `Memory`.
  - Name a sentinel for what it means where it is used, and split a sentinel that would mean two things (`notInterned` and `refused`, not one `none`).
  - Purpose suffixes read `ForReading`/`ForWriting` (`lockForWriting`, `getForWriting`, `mapForWriting`).
  - Keep the words every reader already knows: `free`, `length`, `find`, `insert`, `hash`, `create`, `contains`, `pushBack`, `pushFront`, `removeAt`.
- Avoid one-line wrappers: a function whose body only forwards to another call, fixing an argument or two or reaching into a field, adds a name to learn and hides the call it stands for.
  Write the call out at each use, even when it is long.
  Before keeping a wrapper, see whether renaming what it wraps would make the direct call read as well.
  A wrapper a protocol requires (a hook found by name, an accessor of a private field) is marked `// wrapper: <reason>` on the line above its documentation comment.
- Indent with tabs.
- Under a `@nogc nothrow:` label, do not repeat those attributes on the declarations it already covers, including struct members and `version` blocks.

## Failure and invariants

- Every function that can fail says in its DDoc how it reports failure (null, `false`, an empty `Nullable`, `fp.pointer.notFound`), and what state it leaves its arguments in; prefer leaving them as they were.
- Never drop the result of a call that can fail: check it, or discard it explicitly with `cast(void)` when failure is impossible or harmless there.
  Tests assert on it.
- When a limit on one value follows from another (such as a bit position), name the constant once, derive the others from it, and `assert` the limit where the value is accepted.
- Put test-only code, such as helper functions and globals the tests use, inside `version(unittest)`.

## Organization

- Where possible, group related definitions into sections (for example: types and layout, queries, creation and freeing, growth, removal), separated by blank lines, and order them so a reader meets a type before the functions built on it.
- Whenever possible, define a function before anything that uses it, so a module reads bottom-up from its building blocks.
  When functions use each other in a cycle, define first the one that more of the module uses.
- Keep a module's unittests in the same order as the code they test.
- Prefer merging a new test case into an existing `unittest` block covering the same section over adding a new block; add one only when no existing block fits.

## Layering

libfp is the bottom of a stack: bc-threads builds on it; libdiagnose, libECRS, Mizu and bc-fetch on those; DOIR on all of them.
Every library in the stack forwards these rules.

- Put code in the lowest library that has everything it needs.
  A library above may hold only what is specific to it: threads in bc-threads, entities in libECRS, diagnostics in libdiagnose, networking in bc-fetch, the language in DOIR.
  Before writing a helper, search the libraries below for it; if it is missing, add it there, with a test, rather than locally.
- Only libfp, bc-threads, bc-fetch and Mizu's FFI layer (`mizu.ffi`, which loads and calls into native libraries) import `core.sys.*` or call OS APIs; everything else reaches the OS through them.
- View a plain field atomically through `bc.platform.asShared`, never a hand-written `cast(shared …)`.
- Hold owned memory in a struct through `fp.lifecycle.Owned` rather than hand-written `finalize` and `copyTo` hooks.
- Compare and hash a value through `fp.lifecycle.equal` and `fp.lifecycle.contentHash`, which use its hooks if it declares them.
  Never `memcmp` or hash a struct's raw bytes: its padding is in them.
- Check these rules with `python3 tools/lint.py`, which every library keeps a copy of, each with its own `CONFIG` and the same `PUSHED` registry.
  When code moves into a lower library, add the pattern it replaced to `PUSHED` in every copy, with the replacement as its hint, so the old way cannot come back.

## Bugs

- If you find a bug while working, fix it, with a test that would have caught it, rather than only reporting it.
  Only when the fix would likely take a long time, report it instead, saying what you found and where.
