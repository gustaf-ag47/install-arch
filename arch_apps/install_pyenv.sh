#!/bin/bash

# Function to install pyenv
install_pyenv() {
	echo "Installing dependencies for pyenv..."
	sudo pacman -S --needed base-devel openssl zlib xz

	echo "Cloning pyenv repository..."
	git clone https://github.com/pyenv/pyenv.git ~/.pyenv

	echo "Setting up pyenv environment variables..."
	echo 'export PYENV_ROOT="$HOME/.pyenv"' >>~/.bashrc
	echo 'export PATH="$PYENV_ROOT/bin:$PATH"' >>~/.bashrc
	echo 'eval "$(pyenv init --path)"' >>~/.bashrc
	echo 'eval "$(pyenv init -)"' >>~/.bash_profile

	echo "pyenv installation complete. Please restart your shell for the changes to take effect."
}

# Function to install poetry
install_poetry() {
	echo "Installing poetry..."
	curl -sSL https://raw.githubusercontent.com/python-poetry/poetry/master/get-poetry.py | python -

	echo 'export PATH="$HOME/.poetry/bin:$PATH"' >>~/.bashrc

	echo "poetry installation complete. Please restart your shell for the changes to take effect."
}

# Check for Git
if ! command -v git &>/dev/null; then
	echo "Git is not installed. Installing Git..."
	sudo pacman -S git
fi

# Install pyenv
install_pyenv

# Install poetry
install_poetry

echo "Script completed."

# alias ls=exa
