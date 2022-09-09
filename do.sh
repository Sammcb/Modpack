#!/bin/sh

print_info() {
	printf "\e[1;35m$1\e[0m - \e[0;37m$2\e[0m\n"
}

help() {
	print_info help "Display callable targets"
	print_info build "Compile a release executable"
	print_info clean "Remove build directories"
}

build() {
	swift build -c release
}

clean() {
	rm -rf .build
	rm -rf .swiftpm
	rm -f Package.resolved
}

if [ ${1:+x} ]; then
	$1
else
	help
fi