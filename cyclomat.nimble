# Package

version       = "0.1.0"
author        = "Copilot"
description   = "Universal Cyclomatic Complexity Tool"
license       = "MIT"
srcDir        = "src"
bin           = @["cyclomat"]

# Dependencies

requires "nim >= 2.0.0"
requires "treesitter >= 0.1.0"
requires "treesitter_python >= 0.1.0"
requires "treesitter_php >= 0.1.0"
requires "treesitter_javascript >= 0.1.0"
requires "treesitter_java >= 0.1.0"
