.PHONY: generate build run clean

# Generate Xcode project from project.yml
generate:
	xcodegen generate

# Open in Xcode
open: generate
	open Haynoi.xcodeproj

# Build via xcodebuild
build: generate
	xcodebuild -project Haynoi.xcodeproj -scheme Haynoi -configuration Debug build

# Run the built app
run: build
	open build/Debug/Haynoi.app

# Clean
clean:
	rm -rf build DerivedData .build
	rm -rf Haynoi.xcodeproj
