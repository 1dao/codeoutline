# Third-party notices

The preview package bundles xnet2lua at the commit recorded in `build-info.json`,
including its HTTP codec. Its BSD-2-Clause notice is copied into `licenses/`.
The libdeflate and yyjson notices are also copied from the pinned source tree.

CodeOutline uses BSD-2-Clause. Release packages use the LuaJIT runtime
(`tools/build-runtime.*`); the packaging tool ships the notice for whichever Lua
the runtime links, recorded as `lua` in `build-info.json`:

| Component | Source in xnet2lua | Packaged notice |
| --- | --- | --- |
| LuaJIT (release; includes Lua 5.1 notice) | `3rd/luajit/` | `licenses/luajit.txt` (MIT) |
| Lua / minilua (embedded-Lua builds only) | `3rd/minilua.h` | `licenses/lua-minilua.txt` (MIT) |
| lua-cmsgpack | `xlua/lua_cmsgpack.c` | `licenses/lua-cmsgpack.txt` (MIT) |
| Mbed TLS 3.6.5 | `3rd/mbedtls3/` | `licenses/mbedtls.txt` (Apache-2.0 option) |
| CodeOutline | `scripts/codeoutline/` | `LICENSE` (BSD-2-Clause) |

No ripgrep executable is bundled. An installed `rg` is used when available;
otherwise the Lua directory walker is used with the limitations in README.md.
The MCP SDK is a development test dependency and is not in either runtime package.

Lua, minilua, and cmsgpack notices were extracted from the pinned runtime
sources. The runtime is built without rpmalloc (`WITH_RPMALLOC=0`), so its code
is not linked and no notice ships for it. Mbed TLS's complete dual-license text is preserved from its
[v3.6.5 upstream LICENSE](https://github.com/Mbed-TLS/mbedtls/blob/v3.6.5/LICENSE);
this distribution selects its Apache-2.0 option. The LuaJIT notice is copied from
`3rd/luajit/COPYRIGHT`. Recheck this inventory when the runtime commit or build
options change.

Staged npm manifests remain `private: true` until platform validation and release
configuration are complete. The project license does not replace dependency licenses.
