import os, strutils, strformat, parseopt, json, std/cmdline
import config

when defined(python):
  import nimpy
  import nimpy/py_utils
  import nimpy/py_lib

type
  Language* = enum
    langPython, langCStyle, langGo, langUnknown

  FuncInfo* = object
    name*: string
    complexity*: int
    line*: int

  AnalysisResult* = object
    complexity*: int
    functions*: int
    funcList*: seq[FuncInfo]

  Stats* = object
    count*: int
    total*: int
    min*: int
    max*: int
    filesOverThreshold*: int
    totalFunctions*: int
    maxFuncComplexity*: int
    maxFuncName*: string
    maxFuncFile*: string

  Options* = object
    showStats*: bool
    jsonOutput*: bool
    jsonArray*: bool
    showFunctions*: bool
    maxComplexity*: int
    langOverride*: Language
    langName*: string
    excludePatterns*: seq[string]
    paths*: seq[string]

  ## Raised by `parseArgs` for any terminal flow (help, version, bad input).
  ## `main` catches it and calls the real `quit(e.code)` so the exit code
  ## propagates without `parseArgs` being forced to hard-exit.
  QuitSignal* = object of CatchableError
    code*: int

  FuncFrame = object
    name: string
    startCx: int
    line: int
    depth: int # braceDepth for C-style/Go, indent for Python

proc detectLanguage*(filename: string): Language =
  let ext = splitFile(filename).ext.toLowerAscii()
  case ext
  of ".py": return langPython
  of ".java", ".js", ".jsx", ".ts", ".tsx", ".php", ".mjs", ".cjs", ".mts", ".cts": return langCStyle
  of ".c", ".h", ".cpp", ".hpp", ".cc", ".hh", ".cxx": return langCStyle
  of ".go": return langGo
  else: return langUnknown

proc isTsExt*(ext: string): bool =
  let e = ext.toLowerAscii()
  return e in [".ts", ".tsx", ".mts", ".cts"]

proc isPhpExt*(ext: string): bool =
  let e = ext.toLowerAscii()
  return e == ".php"

proc langFromString*(s: string): Language =
  case s.toLowerAscii()
  of "py", "python": langPython
  of "go", "golang": langGo
  of "c", "h", "cpp", "c++", "hpp", "java", "js", "javascript", "jsx", "ts", "typescript", "tsx", "php": langCStyle
  else: langUnknown

# Recursive glob pattern matching (* and ?)
proc globMatch*(pattern, text: string): bool =
  var pi = 0
  var ti = 0
  var starP = -1
  var starT = -1
  while ti < text.len:
    if pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti]):
      pi.inc
      ti.inc
    elif pi < pattern.len and pattern[pi] == '*':
      starP = pi
      starT = ti
      pi.inc
    elif starP >= 0:
      pi = starP + 1
      starT.inc
      ti = starT
    else:
      return false
  while pi < pattern.len and pattern[pi] == '*':
    pi.inc
  return pi == pattern.len

proc isExcluded*(path: string, patterns: seq[string]): bool =
  if patterns.len == 0: return false
  let normalizedPath = path.replace('\\', '/')
  let base = splitFile(normalizedPath).name & splitFile(normalizedPath).ext
  let parts = normalizedPath.split('/')

  for pat in patterns:
    let normPat = pat.replace('\\', '/')
    if globMatch(normPat, normalizedPath) or globMatch(normPat, base):
      return true
    if '/' notin normPat:
      for part in parts:
        if part.len > 0 and globMatch(normPat, part):
          return true
  return false

proc skipString(content: string, start: int, quote: string, res: var string): int =
  var i = start + quote.len
  while i < content.len:
    if i + quote.len <= content.len and content[i ..< i+quote.len] == quote:
      return i + quote.len
    if content[i] == '\\' and quote != "'''" and quote != "`":
      if i + 1 < content.len and content[i+1] == '\n':
        res.add('\n')
      i += 2
    else:
      if content[i] == '\n':
        res.add('\n')
      i += 1
  return i

proc cleanSource*(content: string, lang: Language): string =
  var i = 0
  var res = newStringOfCap(content.len)

  case lang
  of langCStyle, langGo:
    while i < content.len:
      # Single-line comment
      if i + 1 < content.len and content[i] == '/' and content[i+1] == '/':
        i += 2
        while i < content.len and content[i] != '\n':
          i.inc
      # Multi-line comment
      elif i + 1 < content.len and content[i] == '/' and content[i+1] == '*':
        i += 2
        while i + 1 < content.len and not (content[i] == '*' and content[i+1] == '/'):
          if content[i] == '\n':
            res.add('\n')
          i.inc
        i = min(i + 2, content.len)
      # Template literals / raw strings
      elif content[i] == '`':
        res.add("``")
        i = skipString(content, i, "`", res)
      # Double / single quote strings
      elif content[i] == '"' or content[i] == '\'':
        let q = $content[i]
        res.add(q & q)
        i = skipString(content, i, q, res)
      else:
        res.add(content[i])
        i.inc

  of langPython:
    while i < content.len:
      # Comments
      if content[i] == '#':
        while i < content.len and content[i] != '\n':
          i.inc
      # Triple quotes
      elif i + 2 < content.len and content[i ..< i+3] == "\"\"\"":
        res.add("\"\"\"\"\"\"")
        i = skipString(content, i, "\"\"\"", res)
      elif i + 2 < content.len and content[i ..< i+3] == "'''":
        res.add("''''''")
        i = skipString(content, i, "'''", res)
      # Single quotes
      elif content[i] == '"' or content[i] == '\'':
        let q = $content[i]
        res.add(q & q)
        i = skipString(content, i, q, res)
      else:
        res.add(content[i])
        i.inc

  else:
    return content

  return res

proc isNullableTypePos(content: string, qpos: int): bool =
  if qpos < 0 or qpos >= content.len:
    return false
  let nextCh = content[qpos + 1]
  if nextCh notin {'a'..'z', 'A'..'Z', '_', '$'}:
    return false
  var j = qpos - 1
  while j >= 0 and content[j] in {' ', '\t'}:
    j.dec
  if j < 0:
    return false
  let beforeCh = content[j]
  if beforeCh in {'(', ',', ':', '<', '&'}:
    return true
  var ls = j
  while ls > 0 and content[ls-1] notin {'\n', '\r'}:
    ls.dec
  var word = ""
  var k = ls
  while k <= j and content[k] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    word.add(content[k])
    k.inc
  if word in ["public", "private", "protected", "static", "var", "readonly", "final", "abstract", "internal"]:
    return true
  if word.startsWith("$"):
    return false
  return false

proc calculateComplexity*(content: string, lang: Language, tsLike: bool = false, phpLike: bool = false): AnalysisResult =
  var complexity = 1
  var functions = 0
  var funcList: seq[FuncInfo] = @[]
  var funcStack: seq[FuncFrame] = @[]

  let cleaned = cleanSource(content, lang)

  const
    controlKeywords = [
      "if", "for", "while", "switch", "catch", "foreach", "do", "else", "try",
      "finally", "synchronized", "sync", "with", "using", "lock", "match", "elseif",
      "return", "break", "continue"
    ]
    pythonKeywords = ["if", "elif", "for", "while", "except", "and", "or", "match", "case"]
    cstyleKeywords = ["if", "for", "while", "case", "catch", "elseif", "foreach"]
    goKeywords = ["if", "for", "case", "default"]

  var keywords: seq[string] = @[]
  if lang == langPython:
    keywords = @pythonKeywords
  elif lang == langCStyle:
    keywords = @cstyleKeywords
  elif lang == langGo:
    keywords = @goKeywords
  else:
    return AnalysisResult(complexity: 0, functions: 0, funcList: @[])

  var currentLine = 1
  var parenDepth = 0
  var braceDepth = 0

  var lastWord = ""
  var topParenName = ""
  var justClosedTopParen = false
  var afterArrow = false
  var arrowName = "(arrow)"
  var pendingControlKw = ""

  var i = 0
  while i < cleaned.len:
    let ch = cleaned[i]

    if ch == '\n':
      currentLine.inc
      i.inc

      # Python function indentation check on newline
      if lang == langPython and parenDepth == 0 and funcStack.len > 0:
        var j = i
        while j < cleaned.len and cleaned[j] in {' ', '\t'}:
          j.inc
        if j < cleaned.len and cleaned[j] notin {'\n', '\r'}:
          var ls = j
          while ls > 0 and cleaned[ls-1] notin {'\n', '\r'}:
            ls.dec
          var indent = 0
          var k = ls
          while k < j and cleaned[k] in {' ', '\t'}:
            k.inc
            indent.inc

          while funcStack.len > 0 and indent <= funcStack[^1].depth:
            let f = funcStack.pop()
            let fnCx = (complexity - f.startCx) + 1
            funcList.add(FuncInfo(name: f.name, complexity: fnCx, line: f.line))
      continue

    if ch in {' ', '\t', '\r'}:
      i.inc
      continue

    # Words / Identifiers
    if ch in {'a'..'z', 'A'..'Z', '_'}:
      var word = ""
      let wordStart = i
      while i < cleaned.len and (cleaned[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
        word.add(cleaned[i])
        i.inc

      let prevChar = if wordStart > 0: cleaned[wordStart-1] else: '\0'

      # Check keyword match (require prevChar != '.' to avoid false positives like obj.match or re.match)
      if prevChar != '.':
        for k in keywords:
          if word == k:
            complexity += 1
            break

      # Control keyword tracking
      if prevChar != '.' and word in controlKeywords:
        pendingControlKw = word
        justClosedTopParen = false # Control keywords break function header sequence

      # Python def detection
      if lang == langPython and word == "def" and prevChar != '.':
        functions += 1
        var p = i
        while p < cleaned.len and cleaned[p] in {' ', '\t'}:
          p.inc
        var fnName = ""
        while p < cleaned.len and (cleaned[p] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
          fnName.add(cleaned[p])
          p.inc
        if fnName.len == 0:
          fnName = "(anonymous)"

        var ls = wordStart
        while ls > 0 and cleaned[ls-1] notin {'\n', '\r'}:
          ls.dec
        var ind = 0
        var k = ls
        while k < wordStart and cleaned[k] in {' ', '\t'}:
          k.inc
          ind.inc

        funcStack.add(FuncFrame(name: fnName, startCx: complexity, line: currentLine, depth: ind))

      lastWord = word
      continue

    # Operators and Punctuation
    else:
      case ch
      of '(':
        if parenDepth == 0:
          if pendingControlKw.len > 0:
            topParenName = pendingControlKw
          elif lastWord.len > 0:
            topParenName = lastWord
          else:
            topParenName = ""
        parenDepth.inc
        justClosedTopParen = false
        i.inc

      of ')':
        if parenDepth > 0:
          parenDepth.dec
        if parenDepth == 0:
          justClosedTopParen = true
        i.inc

      of '{':
        braceDepth.inc
        if (lang == langCStyle or lang == langGo) and justClosedTopParen and topParenName notin controlKeywords:
          functions += 1
          var displayFnName = topParenName
          if displayFnName.len == 0 or displayFnName == "function" or displayFnName == "func" or displayFnName == "fn":
            displayFnName = "(anonymous)"
          funcStack.add(FuncFrame(name: displayFnName, startCx: complexity, line: currentLine, depth: braceDepth))
        elif (lang == langCStyle or lang == langGo) and afterArrow:
          funcStack.add(FuncFrame(name: arrowName, startCx: complexity, line: currentLine, depth: braceDepth))

        justClosedTopParen = false
        afterArrow = false
        pendingControlKw = ""
        i.inc

      of '}':
        if (lang == langCStyle or lang == langGo) and funcStack.len > 0 and funcStack[^1].depth == braceDepth:
          let f = funcStack.pop()
          let fnCx = (complexity - f.startCx) + 1
          funcList.add(FuncInfo(name: f.name, complexity: fnCx, line: f.line))
        if braceDepth > 0:
          braceDepth.dec
        justClosedTopParen = false
        afterArrow = false
        pendingControlKw = ""
        i.inc

      of ';':
        justClosedTopParen = false
        pendingControlKw = ""
        afterArrow = false
        i.inc

      of '?':
        if lang == langCStyle:
          if i > 0 and cleaned[i-1] == '<':
            i += 1 # PHP open tag, skip the '?'
          elif i + 1 < cleaned.len and cleaned[i+1] == '>':
            i += 2 # PHP close tag, skip ?>
          elif i + 1 < cleaned.len and cleaned[i+1] == '-' and i + 2 < cleaned.len and cleaned[i+2] == '>':
            i += 3 # PHP nullsafe ?->
          elif phpLike and isNullableTypePos(cleaned, i):
            i += 1 # Nullable type like ?string, not a ternary
          elif i + 1 < cleaned.len and cleaned[i+1] == '?':
            i += 2 # Nullish coalescing ??
          elif i + 1 < cleaned.len and cleaned[i+1] == '.':
            i += 2 # Optional chaining ?.
          elif tsLike and i + 1 < cleaned.len:
            var p = i + 1
            while p < cleaned.len and cleaned[p] in {' ', '\t'}:
              p.inc
            if p < cleaned.len and cleaned[p] == ':':
              i += 1 # Skip optional param ?
            else:
              complexity += 1
              i += 1
          else:
            complexity += 1
            i += 1
        else:
          i += 1

      of '=':
        if (lang == langCStyle or lang == langGo) and i + 1 < cleaned.len and cleaned[i+1] == '>':
          if justClosedTopParen and topParenName.len > 0 and topParenName notin controlKeywords and topParenName notin ["fn", "function", "func"]:
            arrowName = topParenName
          if justClosedTopParen:
            functions += 1
            afterArrow = true
            justClosedTopParen = false
            i += 2
          else:
            i += 2
        else:
          justClosedTopParen = false
          i += 1

      of '&':
        if (lang == langCStyle or lang == langGo) and i + 1 < cleaned.len and cleaned[i+1] == '&':
          complexity += 1
          i += 2
        else:
          i += 1

      of '|':
        if (lang == langCStyle or lang == langGo) and i + 1 < cleaned.len and cleaned[i+1] == '|':
          complexity += 1
          i += 2
        else:
          i += 1

      else:
        i.inc

  # Pop remaining functions at EOF
  while funcStack.len > 0:
    let f = funcStack.pop()
    let fnCx = (complexity - f.startCx) + 1
    funcList.add(FuncInfo(name: f.name, complexity: fnCx, line: f.line))

  # Fallback: if file has non-empty content, ensure at least 1 function count
  if functions == 0 and cleaned.strip().len > 0:
    functions = 1

  return AnalysisResult(complexity: complexity, functions: functions, funcList: funcList)

# ---------------------------------------------------------------------------
# Python Extension API
# ---------------------------------------------------------------------------

when defined(python):
  proc analysisToPyDict(filename: string, res: AnalysisResult): PyObject =
    let dict = pyDict()
    let pcc = if res.functions > 0: res.complexity.float / res.functions.float else: 0.0
    dict["file"] = filename
    dict["complexity"] = res.complexity
    dict["functions"] = res.functions
    dict["pcc"] = pcc

    let rawList = pyLib.PyList_New(0)
    if rawList.isNil:
      raise newException(ValueError, "Failed to create Python list")
    var flist: PyObject
    flist.rawPyObj = rawList
    for f in res.funcList:
      let fd = pyDict()
      fd["name"] = f.name
      fd["complexity"] = f.complexity
      fd["line"] = f.line
      flist.append(fd)
    dict["function_list"] = flist
    return dict

  proc analyze_file*(filename: string): PyObject {.exportpy.} =
    let lang = detectLanguage(filename)
    if lang == langUnknown:
      return pyDict()

    try:
      let content = readFile(filename)
      let tsLike = isTsExt(splitFile(filename).ext)
      let phpLike = isPhpExt(splitFile(filename).ext) and lang == langCStyle
      let res = calculateComplexity(content, lang, tsLike, phpLike)
      return analysisToPyDict(filename, res)
    except CatchableError:
      return pyDict()

  proc analyze_content*(content: string, filename: string): PyObject {.exportpy.} =
    let lang = detectLanguage(filename)
    if lang == langUnknown:
      return pyDict()

    try:
      let tsLike = isTsExt(splitFile(filename).ext)
      let phpLike = isPhpExt(splitFile(filename).ext) and lang == langCStyle
      let res = calculateComplexity(content, lang, tsLike, phpLike)
      return analysisToPyDict(filename, res)
    except CatchableError:
      return pyDict()

# ---------------------------------------------------------------------------
# CLI Implementation
# ---------------------------------------------------------------------------

proc recordFileAnalysis*(filename: string, res: AnalysisResult, stats: var Stats, opts: Options): JsonNode =
  let pcc = if res.functions > 0: res.complexity.float / res.functions.float else: 0.0

  stats.count += 1
  stats.total += res.complexity
  stats.totalFunctions += res.functions
  if stats.min == -1 or res.complexity < stats.min: stats.min = res.complexity
  if res.complexity > stats.max: stats.max = res.complexity

  if opts.maxComplexity > 0 and res.complexity > opts.maxComplexity:
    stats.filesOverThreshold += 1

  for f in res.funcList:
    if f.complexity > stats.maxFuncComplexity:
      stats.maxFuncComplexity = f.complexity
      stats.maxFuncName = f.name
      stats.maxFuncFile = filename

  var jFList = newJArray()
  for f in res.funcList:
    jFList.add(%*{"name": f.name, "complexity": f.complexity, "line": f.line})

  let jObj = %*{
    "file": filename,
    "complexity": res.complexity,
    "functions": res.functions,
    "pcc": pcc,
    "function_list": jFList
  }

  if opts.jsonOutput and not opts.jsonArray:
    echo $jObj
  elif not opts.jsonOutput:
    if opts.maxComplexity > 0 and res.complexity > opts.maxComplexity:
      echo fmt"{filename}: {res.complexity} (PCC: {pcc:.2f}) (EXCEEDS {opts.maxComplexity})"
    else:
      echo fmt"{filename}: {res.complexity} (PCC: {pcc:.2f})"

    if opts.showFunctions and res.funcList.len > 0:
      for f in res.funcList:
        echo fmt"  {f.name}: {f.complexity} (line {f.line})"

  return jObj

proc processContent(content, filename: string, lang: Language, tsLike: bool, phpLike: bool, stats: var Stats, opts: Options): JsonNode =
  let res = calculateComplexity(content, lang, tsLike, phpLike)
  return recordFileAnalysis(filename, res, stats, opts)

proc deriveTsPhpLike*(filename: string, opts: Options): tuple[tsLike, phpLike: bool] =
  if opts.langOverride != langUnknown:
    let ln = opts.langName.toLowerAscii()
    result.tsLike = ln in ["ts", "tsx", "typescript", "mts", "cts"]
    result.phpLike = ln == "php"
  else:
    result.tsLike = isTsExt(splitFile(filename).ext)
    result.phpLike = isPhpExt(splitFile(filename).ext)

proc processFile(filename: string, stats: var Stats, opts: Options): JsonNode =
  if isExcluded(filename, opts.excludePatterns):
    return nil

  var lang = opts.langOverride
  if lang == langUnknown:
    lang = detectLanguage(filename)
  if lang == langUnknown:
    return nil

  let (tsLike, phpLike) = deriveTsPhpLike(filename, opts)

  try:
    let content = readFile(filename)
    return processContent(content, filename, lang, tsLike, phpLike, stats, opts)
  except IOError:
    if not opts.jsonOutput:
      stderr.writeLine(fmt"Error reading {filename}")
    return nil

proc walk*(path: string, stats: var Stats, opts: Options, jsonList: var seq[JsonNode]) =
  if isExcluded(path, opts.excludePatterns):
    return

  if path == "-":
    var lang = opts.langOverride
    if lang == langUnknown:
      if not opts.jsonOutput:
        stderr.writeLine("Error: Must specify --lang when reading from stdin (-)")
      return
    let content = stdin.readAll()
    let (tsLike, phpLike) = deriveTsPhpLike("<stdin>", opts)
    let jNode = processContent(content, "<stdin>", lang, tsLike, phpLike, stats, opts)
    if jNode != nil and opts.jsonArray:
      jsonList.add(jNode)
    return

  if fileExists(path):
    let jNode = processFile(path, stats, opts)
    if jNode != nil and opts.jsonArray:
      jsonList.add(jNode)
  elif dirExists(path):
    let baseDir = splitFile(path.replace('\\', '/')).name
    if baseDir == ".git":
      return
    for kind, p in walkDir(path):
      if kind == pcFile:
        let jNode = processFile(p, stats, opts)
        if jNode != nil and opts.jsonArray:
          jsonList.add(jNode)
      elif kind == pcDir:
        walk(p, stats, opts, jsonList)
  else:
    if not opts.jsonOutput:
      stderr.writeLine(fmt"Path not found: {path}")

proc showHelp() =
  echo fmt"{ToolName} v{Version} - Universal Cyclomatic Complexity Tool"
  echo """
Usage: cyclomat [options] <file_or_directory>...

Options:
  -s, --stats          Show summary statistics
  -j, --json           Output results in NDJSON format
  --json-array         Output results as a JSON array
  -f, --functions      Show per-function complexity breakdown
  -m, --max:N          Fail if complexity exceeds N
  -e, --exclude:PAT    Exclude files/dirs matching pattern (supports * and ?)
  --lang:LANG          Override language (python, js, ts, go, php, c, cpp, java)
  -h, --help           Show this help message
  -V, --version        Show version information
"""

proc showVersion() =
  echo fmt"{ToolName} v{Version}"

proc newQuitSignal(code: int): ref QuitSignal =
  result = new QuitSignal
  result.code = code

proc parseArgs*(args: seq[string]): Options =
  var opts = Options(
    showStats: false,
    jsonOutput: false,
    jsonArray: false,
    showFunctions: false,
    maxComplexity: 0,
    langOverride: langUnknown,
    langName: "",
    excludePatterns: @[],
    paths: @[]
  )

  for kind, key, val in getopt(args):
    case kind
    of cmdLongOption, cmdShortOption:
      if key == "":
        opts.paths.add("-") # stdin
        continue
      case key
      of "stats", "s": opts.showStats = true
      of "json", "j": opts.jsonOutput = true
      of "json-array":
        opts.jsonOutput = true
        opts.jsonArray = true
      of "functions", "f": opts.showFunctions = true
      of "max", "m":
        try:
          opts.maxComplexity = parseInt(val)
        except ValueError:
          stderr.writeLine("Invalid max complexity value: " & val)
          raise newQuitSignal(1)
      of "exclude", "e":
        opts.excludePatterns.add(val)
      of "lang":
        opts.langName = val.toLowerAscii()
        opts.langOverride = langFromString(val)
        if opts.langOverride == langUnknown:
          stderr.writeLine("Unknown language specified for --lang: " & val)
          raise newQuitSignal(1)
      of "help", "h":
        showHelp()
        raise newQuitSignal(0)
      of "version", "V":
        showVersion()
        raise newQuitSignal(0)
      else:
        stderr.writeLine("Unknown option: " & key)
    of cmdArgument:
      opts.paths.add(key)
    of cmdEnd:
      break

  if opts.paths.len == 0:
    showHelp()
    raise newQuitSignal(1)

  return opts

proc main*() =
  var opts: Options
  try:
    opts = parseArgs(commandLineParams())
  except QuitSignal as e:
    quit(e.code)

  var stats = Stats(
    count: 0,
    total: 0,
    min: -1,
    max: 0,
    filesOverThreshold: 0,
    totalFunctions: 0,
    maxFuncComplexity: 0,
    maxFuncName: "",
    maxFuncFile: ""
  )

  var jsonList: seq[JsonNode] = @[]

  for path in opts.paths:
    walk(path, stats, opts, jsonList)

  # Output stats / json-array
  if opts.jsonOutput:
    if opts.jsonArray:
      var outNode: JsonNode
      if opts.showStats:
        let avg = if stats.count > 0: stats.total.float / stats.count.float else: 0.0
        let avgPcc = if stats.totalFunctions > 0: stats.total.float / stats.totalFunctions.float else: 0.0
        let statsNode = %*{
          "files": stats.count,
          "total_complexity": stats.total,
          "total_functions": stats.totalFunctions,
          "avg_complexity": avg,
          "avg_pcc": avgPcc,
          "max_complexity": stats.max,
          "min_complexity": stats.min,
          "over_threshold": stats.filesOverThreshold,
          "max_func_complexity": stats.maxFuncComplexity,
          "max_func_name": stats.maxFuncName,
          "max_func_file": stats.maxFuncFile
        }
        outNode = %*{"files": jsonList, "stats": statsNode}
      else:
        outNode = %jsonList
      echo $outNode
    elif opts.showStats:
      let avg = if stats.count > 0: stats.total.float / stats.count.float else: 0.0
      let avgPcc = if stats.totalFunctions > 0: stats.total.float / stats.totalFunctions.float else: 0.0
      let statsNode = %*{
        "stats": {
          "files": stats.count,
          "total_complexity": stats.total,
          "total_functions": stats.totalFunctions,
          "avg_complexity": avg,
          "avg_pcc": avgPcc,
          "max_complexity": stats.max,
          "min_complexity": stats.min,
          "over_threshold": stats.filesOverThreshold,
          "max_func_complexity": stats.maxFuncComplexity,
          "max_func_name": stats.maxFuncName,
          "max_func_file": stats.maxFuncFile
        }
      }
      echo $statsNode
  elif opts.showStats and stats.count > 0:
    let avg = stats.total.float / stats.count.float
    let avgPcc = if stats.totalFunctions > 0: stats.total.float / stats.totalFunctions.float else: 0.0

    echo "\n--------------------------------------------------"
    echo fmt"Total Files:       {stats.count}"
    echo fmt"Total Complexity:  {stats.total}"
    echo fmt"Total Functions:   {stats.totalFunctions}"
    echo fmt"Average Complexity:{avg:.2f} (per file)"
    echo fmt"Average PCC:       {avgPcc:.2f} (complexity / function)"
    echo fmt"Max Complexity:    {stats.max}"
    echo fmt"Min Complexity:    {stats.min}"
    if stats.maxFuncComplexity > 0:
      echo fmt"Max Function Cx:   {stats.maxFuncComplexity} ({stats.maxFuncName} in {stats.maxFuncFile})"
    if opts.maxComplexity > 0:
      echo fmt"Files > {opts.maxComplexity}:      {stats.filesOverThreshold}"
    echo "--------------------------------------------------"

  if stats.filesOverThreshold > 0:
    quit(1)

when isMainModule and not defined(testing) and not defined(python):
  main()
