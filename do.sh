#!/bin/sh

print_info() {
	printf "\e[1;35m$1\e[0m - \e[0;37m$2\e[0m\n"
}

help() {
	print_info help "Display callable targets"
	print_info build "Compile a release executable"
	print_info clean "Remove build directories"
	print_info update "Check for package updates (need to manually change versions in Package.swift)"
}

build() {
	swift build -c release
}

clean() {
	rm -rf .build
	rm -rf .swiftpm
	rm -f Package.resolved
}

update() {
	swift package update
}

if [ ${1:+x} ]; then
	$1
else
	help
fi
