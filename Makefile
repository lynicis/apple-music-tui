.PHONY: all run build test clean

all: test build

run:
	swift run apple-music-tui

build:
	swift build -c release

test:
	swift test

clean:
	swift package clean
