# PowerShell port: notes

Entry points: `skills/whitebox/scripts/{whitebox,apply-edits,validate,build-editor}.ps1`, shared helpers in `scripts/lib/wb-common.ps1`.
Arguments are read from `$args` by hand (`--work` is never bound as a PowerShell parameter). Output goes through a buffer written as raw UTF-8
bytes to the stdout/stderr streams (no BOM, `\n` only); every exit goes through `[Environment]::Exit`.

## Decisions / things that differ in form from the reference
1. **Launcher in printed commands.** `pwsh -NoProfile -File <script>` (PowerShell 7) or `powershell -NoProfile -ExecutionPolicy Bypass -File <script>` (Windows PowerShell). `build-editor` embeds `<launcher> <relative path>/apply-edits.ps1`; a path with a space is double-quoted (the reference never quotes it).
2. **`q()` quoting.** On Linux/macOS identical to the reference (JSON-style double quotes). On Windows (`\` separator) backslash is not special and a path needing quotes is single-quoted PowerShell style, because JSON-style quoting would be wrong for PowerShell.
3. **Windows paths.** Relative names inside a split are always `/`-separated (the reference would emit `\` on Windows for an explicit file list). `git ls-files` output is used as is.
4. **Uncaught exceptions.** Where the reference crashes with a Node stack trace (missing `pieces.json`, bad JSON, `check` with a nonexistent group, ...) the port prints the .NET message and script stack to stderr and exits 1. Exit code matches, text cannot.
5. **Number printing.** `WbNum` follows JS for integers, NaN and +-Infinity; non-integers use .NET round-trip format (differs from JS only for exponent forms such as 1e-7). Non-finite numbers in JSON become `null`, like `JSON.stringify`.
6. **Duplicate-key JSON.** Parsed into an ordered, case-sensitive map: last value wins, first position kept (same as JS).
7. `build-editor` re-serialises the tree with the port's own writer (parse then write, like `JSON.stringify(JSON.parse(..))`); string escapes are normalised exactly like JS (control chars as `\u00xx`, lone surrogates as `\udxxx`, U+2028/9 raw).

## PowerShell traps hit and how they are handled
- **Variable names are case-insensitive**: `$g`/`$G`, `$L`/`$l`, `$P`/`$p`, `$E`/`$e` silently alias. `/tmp`-style lint used during development: no function may contain two spellings of one name.
- **`.Count` / `.Keys` / `.Values` on any dictionary return the entry with that key name** (`$d.Count` is `7` if the map has a key "Count"; even generic `Dictionary`). The port uses `.get_Count()` / `.get_Keys()` on every map and keeps data in `OrderedDictionary` accessed only through the indexer and `.Contains()`.
- `[Array]::Sort($keys, [object[]]$items)` does not reorder `$items` (PowerShell binds the generic overload); sorting is done on an `int[]` index array instead, with a zero-padded index appended to each key so that the sort is stable.
- `[ordered]@{}` is case-insensitive; maps keyed by data use `New-Object System.Collections.Specialized.OrderedDictionary` (case-sensitive). `-eq`, `-match`, `-replace`, `-contains`, `switch` are case-insensitive: only `-ceq`, `.NET` methods and `-CaseSensitive` are used on text.
- `String.IndexOf/StartsWith/EndsWith(string)` are culture-sensitive in .NET: always called with `StringComparison.Ordinal`.
- JS vs .NET regex: `\b`, `\w`, `\d`, `\s` are Unicode in .NET (rewritten as explicit ASCII classes / lookarounds), `$` matches before a final `\n` (rewritten as `\z`), `.` also matches `\r` and U+2028/9 (rewritten as `[^\n\r  ]`), `IgnoreCase` uses `CultureInvariant`.
- Here-strings take the file's line endings; the prompt templates are normalised to `\n` before use so a CRLF checkout on Windows prints the same text.
- Source files are pure ASCII (5.1 reads BOM-less files as ANSI); non-ASCII characters (the ellipsis and the return symbol) are built from code points. `test/ps-extra.test.mjs` enforces this plus a list of forbidden constructs (`?.`, `??`, `&&`, `Add-Type`, `Set-Content`, `ConvertTo-Json`, `::new(` ...).
- JSON is read by a small tokenizer (`[regex]::Matches` + a stack machine) because `ConvertFrom-Json` differs between 5.1 and 7; `pieces.json` has a one-record-per-line fast path (falls back to the general parser if the layout is not the one `split` writes).
- `git` is run through `System.Diagnostics.Process` (bytes decoded as UTF-8, NUL separated); if it is missing or fails, the directory walk is used (same as the reference).

## Questions for the maintainer (the port follows the reference meanwhile)
- `reshape-list` archives the previous round as `reshape-archive-<epoch ms>`; the name is time dependent, so it cannot be compared in parity tests (only the existence of the archive).
- In explicit-file mode the reference loops forever if the files share no common parent other than `/`; the port stops at the root.
- Reference is silent about `--work` as the last argument without a value (crashes in `path.resolve(undefined)`); the port prints a TypeError-like message and exits 1.

## Not verified here
- **Windows PowerShell 5.1 was never run** (not available on the host). The code was reviewed against the 5.1 restrictions by hand: no `?.`/`??`/`&&`, no `::new`, no `Join-Path` with 3 arguments, no `ConvertFrom-Json`, no `Get-Content`, no `Set-Content`, `[ordered]` and `New-Object` only, `Process.Start` with an `Arguments` string (no `ArgumentList`), `Time` via `[DateTime]` arithmetic (no `ToUnixTimeMilliseconds`). Open risks to check on the Windows CI runner: that `--work` style arguments arrive in `$args` unchanged with `-File`; behaviour of `[Console]::OpenStandardOutput` with redirected pipes; .NET Framework replacement-character differences for invalid UTF-8 input; `\r\n` here-string handling (normalised in code, untested on Windows).
- Test harness on Apple silicon: the image `mcr.microsoft.com/powershell:latest` resolves to an arm32 variant that runs under qemu and crashes randomly (segfaults, "Assertion failed ... thumb_tr_translate_insn", "Object reference not set"). Use the `linux/amd64` variant (`docker build --platform linux/amd64 -t wb-pwsh -f test/docker/Dockerfile.pwsh test/docker`, run containers with `--platform linux/amd64`). `test/docker/pwsh-exec.sh` is a prefix for `WHITEBOX_PREFIX` that runs the command inside a long-lived container `wbps` in the caller's working directory (the stock `docker run -w /tmp` prefix breaks relative paths in the parity tests) and retries emulator crashes. On macOS set `TMPDIR=/private/tmp` and mount both `/tmp` and `/private/tmp`.
