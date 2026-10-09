//! Zed client for the CodeOutline language server. The server (indexing,
//! protocol and resolution) is the Lua `codeoutline lsp --stdio`; this
//! extension only locates and launches it.
//!
//! Lookup order: `lsp.codeoutline.binary` in Zed settings, then
//! `codeoutline` on the worktree's PATH. `initialization_options` from the
//! same settings pass through unchanged (for example
//! `{ "features": { "definition": false } }` beside another server).

use zed_extension_api::{self as zed, settings::LspSettings, LanguageServerId, Result};

const SERVER: &str = "codeoutline";

struct CodeOutline;

impl CodeOutline {
    fn settings(worktree: &zed::Worktree) -> Option<LspSettings> {
        LspSettings::for_worktree(SERVER, worktree).ok()
    }

    // On Windows an npm global install (or a native archive) puts
    // `codeoutline.cmd` on PATH beside an extensionless shell script. Zed's
    // lookup completes the name from PATHEXT and skips the script, and Zed
    // starts batch files through cmd.exe, so the shim runs as installed and
    // still selects installed updates. Name the shim explicitly in case the
    // lookup does not complete extensions.
    fn find(worktree: &zed::Worktree) -> Option<String> {
        worktree.which(SERVER).or_else(|| match zed::current_platform().0 {
            zed::Os::Windows => worktree.which("codeoutline.cmd"),
            _ => None,
        })
    }
}

impl zed::Extension for CodeOutline {
    fn new() -> Self {
        CodeOutline
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let binary = Self::settings(worktree).and_then(|settings| settings.binary);
        let env = binary
            .as_ref()
            .and_then(|binary| binary.env.clone())
            .map(|env| env.into_iter().collect())
            .unwrap_or_default();
        // A configured path wins; its arguments replace the defaults, so a
        // source checkout can run `xnet command.lua ... lsp --stdio`.
        if let Some(path) = binary.as_ref().and_then(|binary| binary.path.clone()) {
            let args = binary
                .and_then(|binary| binary.arguments)
                .unwrap_or_else(|| vec!["lsp".into(), "--stdio".into()]);
            return Ok(zed::Command { command: path, args, env });
        }
        if let Some(path) = Self::find(worktree) {
            return Ok(zed::Command {
                command: path,
                args: vec!["lsp".into(), "--stdio".into()],
                env,
            });
        }
        Err("codeoutline was not found on PATH; install CodeOutline 0.2.0 or newer \
             (npm install -g codeoutline) or set lsp.codeoutline.binary.path in Zed settings"
            .into())
    }

    fn language_server_initialization_options(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Option<zed::serde_json::Value>> {
        Ok(Self::settings(worktree).and_then(|settings| settings.initialization_options))
    }
}

zed::register_extension!(CodeOutline);
