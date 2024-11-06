#!/bin/bash

# Function to install Java
install_java() {
	echo "Updating package index..."
	sudo pacman -Syu

	echo "Installing Java..."
	sudo pacman -S jre-openjdk
}

# Function to set JAVA_HOME
set_java_home() {
	java_path=$(which java)
	if [ -z "$java_path" ]; then
		echo "Java not found. Attempting to install."
		install_java
		java_path=$(which java)
	fi

	if [ -n "$java_path" ]; then
		echo "Setting JAVA_HOME..."
		echo "export JAVA_HOME=$(dirname $(dirname $java_path))" >>~/.bashrc
		echo "JAVA_HOME set. Please log out and log back in for the changes to take effect."
	else
		echo "Failed to install Java. Please install it manually."
	fi
}

# Check if Java is installed
java -version &>/dev/null
if [ $? -eq 0 ]; then
	echo "Java is already installed."
	set_java_home
else
	echo "Java is not installed."
	install_java
	set_java_home
fi

echo "Script completed."
