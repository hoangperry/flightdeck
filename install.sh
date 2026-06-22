#!/usr/bin/env bash
# install.sh — bootstrap the agentic-native terminal setup on macOS.
# Idempotent: safe to run repeatedly. Backs up conflicting files before stowing.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_PHYS="$(cd "$DOTFILES" && pwd -P)"  # symlink-resolved, for stow-aware backup
BACKUP="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
PACKAGES=(fish starship tmux ghostty nvim git bat lazygit atuin yazi bin)

info()  { printf "\033[1;34m::\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m!\033[0m %s\n" "$*"; }

# 1. Homebrew ---------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"

# 2. Packages ---------------------------------------------------------------
info "Installing packages from Brewfile..."
brew bundle --file="$DOTFILES/Brewfile"
ok "packages installed"

# 3. Back up conflicts then stow -------------------------------------------
info "Stowing dotfiles..."
mkdir -p "$BACKUP"
for pkg in "${PACKAGES[@]}"; do
  while IFS= read -r rel; do
    target="$HOME/$rel"
    # Skip anything already stowed. A previous run may have folded a whole
    # directory into a symlink (e.g. ~/.config/ghostty -> $DOTFILES/...), so the
    # final path component looks like a real file even though it lives in the
    # repo. Resolving the parent's physical path catches that case; backing such
    # a file up would move the repo's own files out and break the package.
    parent="$(dirname "$target")"
    if [ -d "$parent" ]; then
      phys="$(cd "$parent" && pwd -P)/$(basename "$target")"
      case "$phys" in "$DOTFILES_PHYS"/*) continue ;; esac
    fi
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      mkdir -p "$BACKUP/$(dirname "$rel")"
      mv "$target" "$BACKUP/$rel"
      warn "backed up ~/$rel"
    fi
  done < <(cd "$DOTFILES/$pkg" && find . -type f | sed 's|^\./||')
  stow --dir="$DOTFILES" --target="$HOME" --restow "$pkg"
done
rmdir "$BACKUP" 2>/dev/null && info "no conflicts to back up" || ok "backups at $BACKUP"

# 4. fish as login shell ----------------------------------------------------
FISH="$(command -v fish)"
if ! grep -qx "$FISH" /etc/shells 2>/dev/null; then
  info "Adding fish to /etc/shells (needs sudo)..."
  echo "$FISH" | sudo tee -a /etc/shells >/dev/null || warn "skip: add $FISH to /etc/shells manually"
fi
if [ "${SHELL:-}" != "$FISH" ]; then
  warn "Set fish as default shell with: chsh -s $FISH"
fi

# 5. fish plugins (fisher) — installs everything listed in fish_plugins -------
info "Installing fish plugins..."
fish -c '
  if not functions -q fisher
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
    fisher install jorgebucaran/fisher
  end
  fisher update
' || warn "fisher step partial — re-run later"

# 6. tmux plugin manager + plugins -----------------------------------------
TPM="$HOME/.config/tmux/plugins/tpm"
# Re-clone if absent or a previous clone left it incomplete (no runnable bin) —
# a [ -d ] check alone treats an empty/broken dir as "already installed".
if [ ! -x "$TPM/bin/install_plugins" ]; then
  rm -rf "$TPM"
  git clone -q https://github.com/tmux-plugins/tpm "$TPM" || warn "tpm clone failed"
fi
info "Installing tmux plugins..."
if [ -x "$TPM/bin/install_plugins" ]; then
  "$TPM/bin/install_plugins" >/dev/null 2>&1 || warn "open tmux and press prefix+I to finish"
else
  warn "tpm missing — open tmux and press prefix+I to finish"
fi

# 7. bat (+delta) Catppuccin theme -----------------------------------------
info "Building bat Catppuccin theme (also used by delta)..."
BAT_THEMES="$(bat --config-dir)/themes"; mkdir -p "$BAT_THEMES"
for f in Mocha Macchiato Frappe Latte; do
  curl -fsSL "https://github.com/catppuccin/bat/raw/main/themes/Catppuccin%20$f.tmTheme" \
    -o "$BAT_THEMES/Catppuccin $f.tmTheme" 2>/dev/null || true
done
bat cache --build >/dev/null 2>&1 && ok "bat themes built" || warn "bat cache build failed"

# 8. yazi Catppuccin flavors (mocha = dark, latte = light) ------------------
info "Installing yazi flavors..."
add_yazi_flavor() {  # $1 = flavor name, e.g. catppuccin-mocha
  local name="$1" dir="$HOME/.config/yazi/flavors/$1.yazi"
  [ -f "$dir/flavor.toml" ] && return 0          # already installed & intact
  rm -rf "$dir"                                  # clear an empty/broken clone
  ya pkg add "yazi-rs/flavors:$name" >/dev/null 2>&1 || true
  [ -f "$dir/flavor.toml" ] && ok "yazi flavor $name" \
    || warn "yazi flavor $name skipped (run 'ya pkg add yazi-rs/flavors:$name')"
}
add_yazi_flavor catppuccin-mocha
add_yazi_flavor catppuccin-latte

# 9. LazyVim plugin sync ----------------------------------------------------
info "Syncing Neovim plugins (LazyVim)..."
nvim --headless "+Lazy! sync" +qa 2>/dev/null || warn "open nvim to finish plugin install"

ok "Done. Next: 'chsh -s $FISH', restart the terminal, run 'tmux' and 'wt <branch>'."
