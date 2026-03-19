# Universal Cyclomatic Complexity Tool

A lightweight, fast, and universal tool to measure cyclomatic complexity across multiple programming languages. Built in Nim.

## Features

- 🚀 **Fast**: Built with Nim for native performance.
- 🌍 **Universal**: Supports Python, Java, JavaScript, TypeScript, PHP, C, and C++.
- 📊 **Statistics**: View total, average, min, and max complexity.
- 🤖 **CI/CD Ready**: Set complexity thresholds (`--max`) to fail builds on complex code.
- 📄 **JSON Output**: Easy integration with other tools.
- 🔍 **Flexible**: Exclude patterns and recursive directory scanning.

## Installation

You need [Nim](https://nim-lang.org/install.html) installed.

```bash
# Compile the tool
nim c -d:release src/cyclomat.nim
```

This will create the `src/cyclomat` binary.

## Usage

```bash
./src/cyclomat [options] <file_or_directory>...
```

### Options

| Flag | Description |
|------|-------------|
| `-s`, `--stats` | Show summary statistics (Total, Avg, Max, Min) |
| `-j`, `--json` | Output results in JSON format |
| `-m`, `--max:N` | Fail (exit code 1) if any file exceeds complexity N |
| `-e`, `--exclude:PAT` | Exclude files or directories matching the pattern |

### Examples

**Basic Scan**
```bash
./src/cyclomat src/
```

**With Statistics**
```bash
./src/cyclomat --stats src/
```

**CI Pipeline (Fail if complexity > 10)**
```bash
./src/cyclomat --max:10 src/
```

**Ignore folders**
```bash
./src/cyclomat --exclude:tests --exclude:vendor src/
```

## Supported Languages

| Language | Extensions |
|----------|------------|
| Python | `.py` |
| JavaScript | `.js`, `.jsx` |
| TypeScript | `.ts`, `.tsx` |
| Java | `.java` |
| PHP | `.php` |
| C | `.c`, `.h` |
| C++ | `.cpp`, `.hpp`, `.cc`, `.cxx` |

## How it Works

The tool uses Parsing Expression Grammars (PEGs) to efficiently scan source code for control flow structures (like `if`, `for`, `while`, `case`, `catch`, `&&`, `||`). It does not require full AST parsing, making it extremely fast and tolerant of partial code.
