# RZA editor support

This directory separates lightweight editor support from full LSP clients. Choose the
component you need; installing the RZA compiler does not require any editor submodule.

## Components

- **Emacs:** `editors/emacs` in this repository. Highlighting needs neither the compiler nor a
  submodule.
- **Vim:** `editors/vim` in this repository. Highlighting needs neither the compiler nor a
  submodule.
- **Neovim:** [`wtorso/rza-nvim`](https://github.com/wtorso/rza-nvim), pinned at
  `editors/nvim`. Highlighting needs no compiler; optional LSP requires it. Initialize the
  submodule only to develop this client.
- **VS Code:** [`wtorso/rza-vscode`](https://github.com/wtorso/rza-vscode), pinned at
  `editors/vscode`. Diagnostics and other LSP features require the compiler. Initialize the
  submodule only to develop this client.

Emacs and Vim provide lightweight filetype, comment, and syntax support. Neovim includes the
same kind of support and an optional `require("rza").setup(...)` adapter for the real
`rez3asm --lsp` server. VS Code is a complete extension with its own dependencies, packaging,
and integration tests. No LSP client reimplements compiler diagnostics or language semantics.

## Install and submodules

For Emacs, add the checkout-specific directory to `load-path`:

```elisp
(add-to-list 'load-path "/absolute/path/to/rza/editors/emacs")
(require 'rza-mode)
```

Opening a `.rza` file now selects `rza-mode`. You can also run `M-x rza-mode`.

For Vim, add the runtime directory in `vimrc`:

```vim
set runtimepath^=/absolute/path/to/rza/editors/vim
filetype plugin on
syntax enable
```

Restart Vim after changing the configuration. The release archive includes these lightweight
files and this guide. It does not include `.gitmodules`, `editors/nvim`, or `editors/vscode`;
Neovim and VS Code are distributed separately from their own repositories.

To develop an external client, initialize only the required submodule:

```sh
git submodule update --init editors/nvim
git submodule update --init editors/vscode
```

The main repository pins the exact revisions used by integration CI. Ordinary compiler users
do not need to initialize either submodule.

## Verify

Emacs byte compilation, ERT tests, and real headless Vim checks run from the repository root:

```sh
bash editors/tests/run.sh
```

The runner requires `emacs` and `vim`, not `nvim`. It checks filetype/comment configuration,
token groups, all 240 active integer/floating operation/type spellings, and inactive forms.

Neovim syntax and real LSP integration tests use the pinned client checkout and an executable
compiler:

```sh
RZA_COMPILER=/absolute/path/to/rez3asm bash editors/nvim/test/run.sh
```

VS Code unit, package, Extension Host, and production-dependency checks run in the VS Code
repository and in the main integration job.

## Placement rule

Future lightweight syntax-only modes, such as Sublime Text highlighting, belong in this
repository. Full LSP clients with their own API, dependencies, tests, or release lifecycle
belong in dedicated repositories pinned by gitlinks, following Neovim and VS Code. Highlighting
must not require the compiler; LSP always uses `rez3asm --lsp`.
