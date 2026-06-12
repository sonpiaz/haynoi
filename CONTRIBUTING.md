# Contributing

Thanks for your interest in contributing to Haynoi!

## Reporting Issues

- Use [GitHub Issues](https://github.com/sonpiaz/haynoi/issues) to report bugs
- Include steps to reproduce, expected vs actual behavior, and your macOS version

## Submitting PRs

1. Fork the repo and create a branch from `v2-rebuild`
2. Name your branch `feat/description` or `fix/description`
3. Make your changes and ensure `make build` passes
4. Write a clear PR description explaining what changed and why
5. Submit the PR against `v2-rebuild`

## Local Development

```bash
git clone https://github.com/sonpiaz/haynoi.git
cd haynoi
brew install xcodegen
make run
```

## Code Style

- Swift 5.9 / SwiftUI
- Follow existing patterns in the codebase
- No third-party dependencies unless absolutely necessary
