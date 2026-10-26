import unittest
import json
import os
import std/tempfiles
import ../src/cyclomat

proc parseTry(args: seq[string]): tuple[raised: bool, code: int, opts: Options] =
  try:
    let o = parseArgs(args)
    result = (false, -1, o)
  except QuitSignal as e:
    result = (true, e.code, Options())

suite "Cyclomat Test Suite":

  test "Language Detection":
    check detectLanguage("foo.py") == langPython
    check detectLanguage("foo.js") == langCStyle
    check detectLanguage("foo.ts") == langCStyle
    check detectLanguage("foo.cpp") == langCStyle
    check detectLanguage("foo.go") == langGo
    check detectLanguage("foo.unknown") == langUnknown
    check isTsExt(".ts") == true
    check isTsExt(".tsx") == true
    check isTsExt(".js") == false

  test "Glob Exclusion Matching":
    check globMatch("*.js", "foo.js") == true
    check globMatch("*.js", "foo.py") == false
    check globMatch("src/*", "src/utils.nim") == true
    check isExcluded("src/vendor/lib.js", @["vendor"]) == true
    check isExcluded("src/main.js", @["*.py"]) == false
    check isExcluded("build/output.js", @["build/*"]) == true

  test "Word Boundaries (test_boundary.js)":
    let code = """
var my_if = 1;
var endif = 2;
var if_value = 3;
if (true) {
}
"""
    let res = calculateComplexity(code, langCStyle)
    # Total complexity: 1 (base) + 1 (if) = 2
    check res.complexity == 2

  test "False-positive Function Counting in Control Structures":
    let phpCode = """<?php
if (true) { }
foreach ($a as $b) { }
while (true) { }
switch ($x) { case 1: break; }
function realFunc() { }
"""
    let res = calculateComplexity(phpCode, langCStyle)
    # Functions should be 1 (realFunc), NOT 3 or 5!
    check res.functions == 1
    check res.funcList.len == 1
    check res.funcList[0].name == "realFunc"

  test "TypeScript Optional Chaining and Nullish Coalescing":
    let tsCode = """
const a = obj?.prop;
const b = obj ?? defaultVal;
function test(x?: number) {
  if (x) return 1;
  return 0;
}
"""
    let res = calculateComplexity(tsCode, langCStyle, tsLike = true)
    # Total complexity: 1 (base) + 1 (if) = 2.
    # ?. and ?? and x?: should NOT count as decision points!
    check res.complexity == 2
    check res.functions == 1

  test "Python Match / Case and Method Dot Guard":
    let pyCode = """
import re

def handle_command(command):
    match command:
        case "quit":
            return 0
        case "start":
            return 1
        case _:
            return -1

def other_func():
    m = re.match("a", "abc")
    return m
"""
    let res = calculateComplexity(pyCode, langPython)
    # Total complexity: 1 (base) + 1 (match) + 3 (case) = 5
    # re.match should NOT count as keyword match due to dot guard!
    check res.complexity == 5
    check res.functions == 2
    check res.funcList.len == 2
    check res.funcList[0].name == "handle_command"
    check res.funcList[1].name == "other_func"

  test "Go Select / Switch and Functions":
    let goCode = """
package main

func main() {
    for i := 0; i < 10; i++ { }
    switch x {
    case 1:
    case 2:
    default:
    }
    select {
    case <-ch:
    default:
    }
}

func helper() int {
    return 1
}
"""
    let res = calculateComplexity(goCode, langGo)
    # Total complexity: 1 (base) + 1 (for) + 2 (switch cases) + 1 (default) + 1 (select case) + 1 (default) = 7
    check res.complexity == 7
    check res.functions == 2
    check res.funcList.len == 2
    check res.funcList[0].name == "main"
    check res.funcList[1].name == "helper"

  test "Per-Function Metrics":
    let code = """
function simple() {
  return 1;
}

function complex(a, b) {
  if (a) {
    if (b) {
      return 2;
    }
  }
  return 0;
}
"""
    let res = calculateComplexity(code, langCStyle)
    check res.functions == 2
    check res.funcList.len == 2
    check res.funcList[0].name == "simple"
    check res.funcList[0].complexity == 1
    check res.funcList[1].name == "complex"
    check res.funcList[1].complexity == 3

  test "Source Cleaning Preserves Line Numbers":
    let code = """
// line 1 comment
/* line 2 multi
   line comment */
function foo() {
  // line 5 comment
  return 1;
}
"""
    let cleaned = cleanSource(code, langCStyle)
    let res = calculateComplexity(cleaned, langCStyle)
    check res.functions == 1
    check res.funcList[0].line == 4

  test "JavaScript Arrow Function Single Count":
    let jsCode = """
const foo = (x) => { return x; };
"""
    let res = calculateComplexity(jsCode, langCStyle, tsLike = true)
    check res.functions == 1
    check res.funcList.len == 1
    check res.funcList[0].name == "foo"

  test "PHP Open Tag and Foreach Complexity":
    let phpCode = """<?php
if (true) { }
foreach ($a as $b) { }
while (true) { }
function real() { }
"""
    let res = calculateComplexity(phpCode, langCStyle, tsLike = false, phpLike = true)
    check res.complexity == 4
    check res.functions == 1

  test "PHP Array Arrow Not Counted as Function":
    let phpCode = """<?php
$handlers = [
    "a" => function () { return 1; },
];
function real() { return 2; }
"""
    let res = calculateComplexity(phpCode, langCStyle, tsLike = false, phpLike = true)
    check res.functions == 2

  test "PHP Nullable Types Not Ternary":
    let phpCode = """<?php
function hasNullable(?string $name): ?int {
    return null;
}
"""
    let res = calculateComplexity(phpCode, langCStyle, tsLike = false, phpLike = true)
    check res.complexity == 1
    check res.functions == 1

  test "C-style Ternary, && and || Decision Points":
    let cCode = """
int calc(int a, int b) {
    return a > 0 ? a : b;
}
int check(int a, int b) {
    if (a > 0 && b > 0 || a == b) {
        return 1;
    }
    return 0;
}
"""
    let res = calculateComplexity(cCode, langCStyle)
    # Total: 1 (base) + 1 (ternary) + 1 (if) + 1 (&&) + 1 (||) = 5
    check res.complexity == 5
    check res.functions == 2
    check res.funcList.len == 2
    check res.funcList[0].name == "calc"
    check res.funcList[0].complexity == 2
    check res.funcList[1].name == "check"
    check res.funcList[1].complexity == 4

  test "langFromString CLI Aliases":
    check langFromString("python") == langPython
    check langFromString("py") == langPython
    check langFromString("GO") == langGo
    check langFromString("golang") == langGo
    check langFromString("js") == langCStyle
    check langFromString("jsx") == langCStyle
    check langFromString("typescript") == langCStyle
    check langFromString("tsx") == langCStyle
    check langFromString("c") == langCStyle
    check langFromString("c++") == langCStyle
    check langFromString("hpp") == langCStyle
    check langFromString("java") == langCStyle
    check langFromString("php") == langCStyle
    check langFromString("rust") == langUnknown
    check langFromString("") == langUnknown

  test "JSON Output Shape (recordFileAnalysis)":
    var stats = Stats()
    var opts = Options(jsonOutput: true, jsonArray: true)
    let res = calculateComplexity("function foo() { if (a) { return 1; } return 0; }", langCStyle)
    let node = recordFileAnalysis("foo.js", res, stats, opts)
    check node["file"].getStr() == "foo.js"
    check node["complexity"].getBiggestInt() == 2
    check node["functions"].getBiggestInt() == 1
    check node["pcc"].getFloat() == 2.0
    check node["function_list"].len == 1
    check node["function_list"][0]["name"].getStr() == "foo"
    check node["function_list"][0]["complexity"].getBiggestInt() == 2
    check stats.count == 1
    check stats.total == 2
    check stats.max == 2
    check stats.totalFunctions == 1

  test "Max Complexity Threshold Counting":
    var stats = Stats()
    var opts = Options(jsonOutput: true, jsonArray: true, maxComplexity: 2)
    let r1 = calculateComplexity("function a() { if (x) { return 1; } return 0; }", langCStyle)
    let r2 = calculateComplexity("function b() { if (x) { if (y) { return 1; } } return 0; }", langCStyle)
    check r1.complexity == 2
    check r2.complexity == 3
    discard recordFileAnalysis("a.js", r1, stats, opts)
    discard recordFileAnalysis("b.js", r2, stats, opts)
    check stats.filesOverThreshold == 1
    check stats.count == 2

  test "Directory Walk with Exclude Patterns":
    let tmpDir = createTempDir("cyclomat_test_", "")
    try:
      createDir(tmpDir / "vendor")
      writeFile(tmpDir / "a.js", "function f() { if (x) { return 1; } }")
      writeFile(tmpDir / "b.py", "def g():\n    if True:\n        pass\n")
      writeFile(tmpDir / "vendor/c.js", "function v() { if (x) { return 1; } }")
      writeFile(tmpDir / "notes.txt", "if if if")

      var stats = Stats()
      var opts = Options(jsonOutput: true, jsonArray: true,
                         langOverride: langUnknown, excludePatterns: @["vendor"])
      var jsonList: seq[JsonNode] = @[]
      walk(tmpDir, stats, opts, jsonList)

      # vendor/c.js excluded, notes.txt unsupported language
      check stats.count == 2
      check jsonList.len == 2
      var files: seq[string] = @[]
      for j in jsonList: files.add(j["file"].getStr())
      check (tmpDir / "a.js") in files
      check (tmpDir / "b.py") in files
    finally:
      removeFile(tmpDir / "a.js")
      removeFile(tmpDir / "b.py")
      removeFile(tmpDir / "vendor/c.js")
      removeFile(tmpDir / "notes.txt")
      removeDir(tmpDir / "vendor")
      removeDir(tmpDir)

  test "parseArgs terminal flows raise QuitSignal":
    let r1 = parseTry(@["--help", "x.js"])
    check r1.raised and r1.code == 0
    let r2 = parseTry(@["--version"])
    check r2.raised and r2.code == 0
    let r3 = parseTry(@["--lang", "bogus", "x.js"])
    check r3.raised and r3.code == 1
    let r4 = parseTry(@["--max", "abc", "x.js"])
    check r4.raised and r4.code == 1
    let r5 = parseTry(@[])
    check r5.raised and r5.code == 1

  test "parseArgs flags and values":
    let a = parseTry(@["-j", "f.js"]).opts
    check a.jsonOutput and not a.jsonArray
    let b = parseTry(@["--json-array", "f.js"]).opts
    check b.jsonOutput and b.jsonArray
    let c = parseTry(@["--max:5", "f.js"]).opts
    check c.maxComplexity == 5
    let d = parseTry(@["--lang:go", "f.js"]).opts
    check d.langOverride == langGo
    check d.langName == "go"
    let e = parseTry(@["--lang:ts", "f.js"]).opts
    check e.langOverride == langCStyle
    check e.langName == "ts"
    let f = parseTry(@["--exclude:vendor", "--exclude:build", "f.js"]).opts
    check f.excludePatterns == @["vendor", "build"]
    let g = parseTry(@["f.js", "g.py"]).opts
    check g.paths == @["f.js", "g.py"]
    let h = parseTry(@["-"])
    check not h.raised
    check h.opts.paths == @["-"]

  test "deriveTsPhpLike override branch":
    let ts = Options(langOverride: langCStyle, langName: "ts")
    check deriveTsPhpLike("any.txt", ts) == (true, false)
    let tsx = Options(langOverride: langCStyle, langName: "tsx")
    check deriveTsPhpLike("any.txt", tsx) == (true, false)
    let php = Options(langOverride: langCStyle, langName: "php")
    check deriveTsPhpLike("any.txt", php) == (false, true)
    let c = Options(langOverride: langCStyle, langName: "c")
    check deriveTsPhpLike("any.txt", c) == (false, false)
    let py = Options(langOverride: langPython, langName: "python")
    check deriveTsPhpLike("any.txt", py) == (false, false)

  test "deriveTsPhpLike extension branch":
    let dflt = Options(langOverride: langUnknown)
    check deriveTsPhpLike("x.ts", dflt) == (true, false)
    check deriveTsPhpLike("x.tsx", dflt) == (true, false)
    check deriveTsPhpLike("x.mts", dflt) == (true, false)
    check deriveTsPhpLike("x.cts", dflt) == (true, false)
    check deriveTsPhpLike("x.js", dflt) == (false, false)
    check deriveTsPhpLike("x.php", dflt) == (false, true)
    check deriveTsPhpLike("x.py", dflt) == (false, false)

  test "processFile via walk: .txt analyzed with --lang override":
    let tmpDir = createTempDir("cyclomat_lang_", "")
    try:
      writeFile(tmpDir / "notes.txt", "if (a) { if (b) { } }")
      var stats = Stats()
      var opts = Options(jsonOutput: true, jsonArray: true,
                         langOverride: langCStyle, langName: "c")
      var jsonList: seq[JsonNode] = @[]
      walk(tmpDir, stats, opts, jsonList)
      check stats.count == 1
      check jsonList.len == 1
      check jsonList[0]["complexity"].getBiggestInt() == 3
    finally:
      removeFile(tmpDir / "notes.txt")
      removeDir(tmpDir)
