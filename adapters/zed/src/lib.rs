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
        if let Some(path) = worktree.which(SERVER) {
            return Ok(zed::Command {
                command: path,
                args: vec!["lsp".into(), "--stdio".into()],
                env,
            });
        }
        Err("codeoutline was not found on PATH; install it (npm install -g codeoutline) \
             or set lsp.codeoutline.binary.path in Zed settings"
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
