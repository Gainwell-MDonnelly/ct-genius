---
name: generateLinuxScript
description: Generate a production-ready Linux shell script following best practices
argument-hint: Describe the script's purpose and required functionality (e.g., "scan dir, compress, transfer via SFTP")
---
Generate a Linux shell script that performs the specified operations. The script should follow Linux/Bash best practices including:

## Required Features
Based on the user's requirements, implement the core functionality they describe (e.g., file scanning, compression, file transfers, etc.)

## Best Practices to Include
- Use `set -euo pipefail` for strict error handling
- Use `readonly` for constants and configuration variables
- Implement proper signal trapping (EXIT, INT, TERM) with cleanup functions
- Use lock files to prevent concurrent execution
- Include comprehensive logging with timestamps and severity levels
- Support environment variable configuration with sensible defaults
- Implement retry logic for network operations
- Use secure practices (key-based auth, proper file permissions)
- Include a usage/help function with documentation
- Support dry-run mode for testing
- Use proper quoting and IFS handling for shellcheck compliance
- Organize code into modular, reusable functions
- Include a detailed header comment block with script metadata

## Output Format
Provide a complete, executable shell script with:
1. Configuration section with customizable variables
2. Utility functions (logging, cleanup, error handling)
3. Core business logic functions
4. Main function with argument parsing
5. Inline comments explaining complex logic
