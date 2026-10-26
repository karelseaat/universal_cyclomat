# Universal Cyclomatic Complexity Tool

A lightweight, fast, and universal tool to measure cyclomatic complexity across multiple programming languages. Built in Nim.

## Features

- 🚀 **Fast**: Built with Nim for native performance.
- 🌍 **Universal**: Supports Python, Java, JavaScript, TypeScript, PHP, C, C++, and Go.
- 📊 **Statistics**: View total, average, min, and max complexity.
- 🤖 **CI/CD Ready**: Set complexity thresholds (`--max`) to fail builds on complex code.
- 🔬 **PCC Metric**: Calculates Pseudo-Cyclomatic Complexity (Complexity / Function Count) to estimate function-level complexity.
- 📄 **JSON Output**: Easy integration with other tools. Use `--json-array` for batch output.
- 🔍 **Flexible**: Exclude patterns and recursive directory scanning.
- 🔧 **Language Override**: Use `--lang` for stdin or non-standard language mappings.

## Installation

You need [Nim](https://nim-lang.org/install.html) installed.

### Option A: Standalone CLI

```bash
make build
# Creates ./cyclomat binary
```

### Option B: Python Library

To build the Python extension, you first need the `nimpy` package:

```bash
nimble install nimpy
make pylib
# Creates cyclomat.so (Linux/Mac) or cyclomat.pyd (Windows)
```

## Usage

### CLI Usage

```bash
./cyclomat [options] <file_or_directory>...
```

### Options

| Flag | Description |
|------|-------------|
| `-s`, `--stats` | Show summary statistics (Total, Avg, Max, Min) |
| `-j`, `--json` | Output results in JSON format |
| `--json-array` | Output results as a JSON array (instead of NDJSON) |
| `-f`, `--functions` | Show per-function complexity breakdown |
| `-m`, `--max:N` | Fail (exit code 1) if any file exceeds complexity N |
| `-e`, `--exclude:PAT` | Exclude files or directories matching the pattern |
| `--lang:LANG` | Override language (python, js, jsx, ts, tsx, go, golang, php, c, h, cpp, c++, hpp, java) |
| `-h`, `--help` | Show help message |
| `-V`, `--version` | Show version information |

### Examples

**Basic Scan**
```bash
./cyclomat src/
```

**With Statistics**
```bash
./cyclomat --stats src/
```

**CI Pipeline (Fail if complexity > 10)**
```bash
./cyclomat --max:10 src/
```

**Ignore folders**
```bash
./cyclomat --exclude:tests --exclude:vendor src/
```

**JSON Output (NDJSON)**
```bash
./cyclomat --json src/
# {"file": "src/utils.js", "complexity": 10, "functions": 4, "pcc": 2.5, "function_list": [{"name": "foo", "complexity": 4, "line": 1}]}
```

**JSON Array Output**
```bash
./cyclomat --json --json-array src/
# [{"file": "src/utils.js", "complexity": 10, "functions": 4, "pcc": 2.5, "function_list": [...]}]
```

**Per-Function Breakdown**
```bash
./cyclomat --functions src/
# src/utils.js: 10 (PCC: 2.50)
#   foo: 4 (line 1)
#   bar: 6 (line 12)
```

**Analyze from stdin**
```bash
cat src/utils.js | ./cyclomat --lang js -
```

## Python Library Usage

You can use `cyclomat` as a Python extension module for high-performance analysis.

1. **Compile the extension**:
   ```bash
   make pylib
   # Creates cyclomat.so (Linux/Mac) or cyclomat.pyd (Windows)
   ```

2. **Use in Python**:
   ```python
   import cyclomat

   # Analyze a file
   result = cyclomat.analyze_file("src/utils.js")
   print(result)
   # {'file': 'src/utils.js', 'complexity': 10, 'functions': 4, 'pcc': 2.5}

   # Analyze raw content
   code = "def foo(): if True: pass"
   result = cyclomat.analyze_content(code, "test.py")
   print(result)
   # {'file': 'test.py', 'complexity': 2, 'functions': 1, 'pcc': 2.0}
   ```

## Understanding Metrics

### Total Complexity (File-Level)
The tool calculates the total cyclomatic complexity for each file. This is the sum of all decision points (branches) in the file + 1.

### PCC (Pseudo Cyclomatic Complexity)
Because total complexity can be misleading for large files with many small functions, the tool also calculates **PCC**.

**Formula:**
```math
PCC = \frac{\text{Total File Complexity}}{\text{Number of Functions}}
```

**Interpretation:**
*   **Low PCC (< 5)**: Indicates the file is composed of simple, small functions. Generally healthy.
*   **High PCC (> 10)**: Indicates the file likely contains one or more complex "God functions" or deeply nested logic.
*   **Warning**: PCC is an average. A file with 1 massive function (Complexity 50) and 49 tiny getters (Complexity 1) will show a low PCC (~2). Use PCC to measure **complexity density**.

## Supported Languages

| Language | Extensions |
|----------|------------|
| Python | `.py` |
| JavaScript | `.js`, `.jsx`, `.mjs`, `.cjs` |
| TypeScript | `.ts`, `.tsx`, `.mts`, `.cts` |
| Java | `.java` |
| Go | `.go` |
| PHP | `.php` |
| C | `.c`, `.h` |
| C++ | `.cpp`, `.hpp`, `.cc`, `.cxx`, `.hh` |

## How it Works

The tool uses a custom lexer to efficiently scan source code for control flow structures (like `if`, `for`, `while`, `case`, `catch`, `&&`, `||`). It respects string literals, comments, and word boundaries to avoid false positives. It does not perform full AST parsing, making it extremely fast.
