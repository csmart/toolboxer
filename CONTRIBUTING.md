# Contributing to toolboxer

Thanks for your interest in contributing!

## Reporting issues

Please open an issue at https://github.com/csmart/toolboxer/issues with:
- What you expected to happen
- What actually happened
- Your Podman version (`podman --version`)
- Your distro and version

## Submitting changes

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Test with `./tests/test_toolboxer.bash` (or manually verify)
4. Submit a pull request

## Guidelines

- Keep it simple — toolboxer is a single Bash script and should stay that way
- Match `toolbox` CLI conventions where possible
- Test on Fedora at minimum; other distros are a bonus
- Use `shellcheck` to lint your changes:
  ```bash
  shellcheck toolboxer
  ```

## Code style

- 4 spaces for indentation (no tabs)
- Functions use `snake_case`
- Variables use `UPPER_CASE` for globals, `lower_case` for locals
- Use `[[ ]]` over `[ ]` for conditionals
