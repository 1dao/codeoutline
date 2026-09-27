# Third-party notices

The preview package bundles xnet2lua at the commit recorded in `build-info.json`,
including its HTTP codec. Its BSD-2-Clause notice is copied into `licenses/`.
The libdeflate and yyjson notices are also copied from the pinned source tree.

CodeOutline uses BSD-2-Clause. The default minilua build includes these notices:

| Component | Source in xnet2lua | Packaged notice |
| --- | --- | --- |
| Lua / minilua | `3rd/minilua.h` | `licenses/lua-minilua.txt` (MIT) |
| lua-cmsgpack | `xlua/lua_cmsgpack.c` | `licenses/lua-cmsgpack.txt` (MIT) |
| rpmalloc | `3rd/rpmalloc/` | `licenses/rpmalloc.txt` (source public-domain dedication) |
| Mbed TLS 3.6.5 | `3rd/mbedtls3/` | `licenses/mbedtls.txt` (Apache-2.0 option) |
| CodeOutline | `scripts/codeoutline/` | `LICENSE` (BSD-2-Clause) |

No ripgrep executable is bundled. An installed `rg` is used when available;
otherwise the Lua directory walker is used with the limitations in README.md.
The MCP SDK is a development test dependency and is not in either runtime package.

Lua, minilua, cmsgpack, and rpmalloc notices were extracted from the pinned runtime
sources. Mbed TLS's complete dual-license text is preserved from its
[v3.6.5 upstream LICENSE](https://github.com/Mbed-TLS/mbedtls/blob/v3.6.5/LICENSE);
this distribution selects its Apache-2.0 option. Recheck this inventory when the
runtime commit or build options change (in particular, LuaJIT is not bundled).

Staged npm manifests remain `private: true` until platform validation and release
configuration are complete. The project license does not replace dependency licenses.
