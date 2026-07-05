# Contributing to ntp-tools

## How to contribute

Pull requests are welcome. Open an issue first to discuss significant changes.

1. Fork the repository
2. Create a branch (`git checkout -b feat/my-feature`)
3. Make your changes
4. Open a pull request against `master`

## Requirements for contributions

- Code must pass ShellCheck with no errors or warnings
- New features should include at least a smoke test (run the command and verify it exits cleanly)
- Keep changes focused — one feature or fix per PR
- Follow the existing code style (bash, no external dependencies beyond `python3` and `openssl`)

## Running tests

```bash
bash build.sh
./dist/ntp-tools --version
./dist/ntp-tools --help
./dist/ntp-tools check --help
```

## Reporting bugs

Open an issue on [GitHub Issues](https://github.com/TheHuman00/ntp-tools/issues).  
For security vulnerabilities, see [SECURITY.md](SECURITY.md).
