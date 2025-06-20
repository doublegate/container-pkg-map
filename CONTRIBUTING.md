# Contributing to Container Package Mapper

Thank you for your interest in contributing to Container Package Mapper! This document provides guidelines and instructions for contributing to the project.

## Getting Started

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR-USERNAME/container-pkg-map.git
   cd container-pkg-map
   ```
3. Add the upstream repository:
   ```bash
   git remote add upstream https://github.com/doublegate/container-pkg-map.git
   ```

## Development Process

### 1. Create a Branch

Create a new branch for your feature or bugfix:
```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/issue-description
```

### 2. Make Your Changes

- Follow the existing code style and conventions
- Test your changes thoroughly
- Update documentation if needed
- Add comments for complex logic

### 3. Test Your Changes

Before submitting, ensure:
- The script runs without errors
- Test with `--dry-run` flag first
- Test both CLI and GUI modes if applicable
- Verify package mapping works correctly
- Check error handling with invalid inputs

### 4. Commit Your Changes

Write clear, descriptive commit messages:
```bash
git add .
git commit -m "feat: add support for openSUSE containers"
# or
git commit -m "fix: handle API timeout gracefully"
```

### 5. Push and Create Pull Request

```bash
git push origin feature/your-feature-name
```

Then create a Pull Request on GitHub.

## Code Style Guidelines

### Shell Script Standards

- Use `#!/usr/bin/env bash` shebang
- Enable strict mode: `set -euo pipefail`
- Use `readonly` for constants
- Quote variables: `"$variable"`
- Use `[[ ]]` for conditionals
- Indent with 4 spaces

### Function Guidelines

- Start functions with a descriptive comment
- Use local variables: `local var_name`
- Return meaningful exit codes
- Handle errors gracefully

Example:
```bash
# Maps a Fedora package to its Arch equivalent
# Arguments:
#   $1 - Package name
# Returns:
#   0 on success, 1 on failure
map_package() {
    local package="$1"
    local result
    
    # Implementation here
    
    return 0
}
```

### Variable Naming

- Use UPPERCASE for constants and globals
- Use lowercase for local variables
- Use descriptive names
- Prefix booleans with `is_` or `has_`

## Testing Guidelines

### Manual Testing Checklist

- [ ] Test backup creation
- [ ] Test restore functionality
- [ ] Verify package mapping accuracy
- [ ] Check container detection
- [ ] Test with different compression options
- [ ] Verify dry-run mode
- [ ] Test GUI mode with Zenity
- [ ] Check error handling

### Test Scenarios

1. **Basic Backup/Restore**
   ```bash
   ./ultimate_migration_script.sh --dry-run backup
   ./ultimate_migration_script.sh backup ~/test-backup
   ./ultimate_migration_script.sh restore ~/test-backup
   ```

2. **Package Mapping**
   ```bash
   ./ultimate_migration_script.sh --max-packages 10 --verbose backup
   ```

3. **Error Conditions**
   - Missing dependencies
   - No internet connection
   - Invalid backup directory
   - Insufficient permissions

## Reporting Issues

When reporting issues, please include:

1. **System Information**:
   - Fedora variant and version
   - Bash version (`bash --version`)
   - List of installed dependencies

2. **Steps to Reproduce**:
   - Exact commands used
   - Any error messages
   - Expected vs actual behavior

3. **Logs**:
   - Contents of `migrate.log`
   - Output with `--verbose` flag

## Feature Requests

When proposing new features:

1. Check existing issues first
2. Describe the use case
3. Provide examples if possible
4. Consider backward compatibility

## API Usage

When working with the Repology API:

- Respect rate limits (1 request/second)
- Always use the configured User-Agent
- Implement proper error handling
- Cache responses appropriately

## Documentation

- Update README.md for user-facing changes
- Update CLAUDE.md for architectural changes
- Keep comments in sync with code
- Document any new dependencies

## Pull Request Process

1. Ensure your branch is up to date with upstream
2. Write a clear PR description
3. Reference any related issues
4. Wait for review and address feedback
5. Squash commits if requested

## Questions?

Feel free to open an issue for any questions about contributing. We're here to help!

Thank you for contributing to Container Package Mapper!