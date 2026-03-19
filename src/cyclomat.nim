import os, strutils, strformat, parseopt, json

# Conditional import for Python Library mode
when defined(python):
  import nimpy

type
  Language = enum
    langPython, langCStyle, langGo, langUnknown
  
  Stats = object
    count: int
    total: int
    min: int
    max: int
    filesOverThreshold: int
    totalFunctions: int
    
  Options = object
    showStats: bool
    jsonOutput: bool
    maxComplexity: int # 0 means no limit
    excludePatterns: seq[string]
    paths: seq[string]

proc detectLanguage(filename: string): Language =
  let ext = splitFile(filename).ext.toLowerAscii()
  case ext
  # Python
  of ".py": return langPython
  
  # C-Style Languages (Java, JS, PHP, C, C++, TypeScript)
  of ".java", ".js", ".jsx", ".ts", ".tsx", ".php": return langCStyle
  of ".c", ".h": return langCStyle
  of ".cpp", ".hpp", ".cc", ".hh", ".cxx": return langCStyle

  # Go
  of ".go": return langGo
  
  else: return langUnknown

proc skipString(content: string, start: int, quote: string): int =
  var i = start + quote.len
  while i < content.len:
    # Check for end quote match
    if i + quote.len <= content.len and content[i ..< i+quote.len] == quote:
      return i + quote.len
      
    # Handle escapes (basic)
    if content[i] == '\\': 
      i += 2 
    else: 
      i += 1
  return i

proc cleanSource(content: string, lang: Language): string =
  var i = 0
  var res = newStringOfCap(content.len)
  
  if lang == langCStyle:
    while i < content.len:
      # Single line comment
      if i+1 < content.len and content[i] == '/' and content[i+1] == '/':
        i += 2
        while i < content.len and content[i] != '\n': i.inc
        res.add('\n')
      # Multi line comment
      elif i+1 < content.len and content[i] == '/' and content[i+1] == '*':
        i += 2
        while i+1 < content.len and not (content[i] == '*' and content[i+1] == '/'): i.inc
        i += 2
      # Strings
      elif content[i] == '"' or content[i] == '\'':
        let q = $content[i]
        res.add(q & q) # Keep empty string to preserve structure
        i = skipString(content, i, q)
      else:
        res.add(content[i])
        i.inc
        
  elif lang == langGo:
    while i < content.len:
      # Single line comment
      if i+1 < content.len and content[i] == '/' and content[i+1] == '/':
        i += 2
        while i < content.len and content[i] != '\n': i.inc
        res.add('\n')
      # Multi line comment
      elif i+1 < content.len and content[i] == '/' and content[i+1] == '*':
        i += 2
        while i+1 < content.len and not (content[i] == '*' and content[i+1] == '/'): i.inc
        i += 2
      # Raw Strings (backticks)
      elif content[i] == '`':
        let q = "`"
        res.add("``")
        i = skipString(content, i, q)
      # Strings
      elif content[i] == '"' or content[i] == '\'':
        let q = $content[i]
        res.add(q & q)
        i = skipString(content, i, q)
      else:
        res.add(content[i])
        i.inc
        
  elif lang == langPython:
    while i < content.len:
      # Comments
      if content[i] == '#':
        while i < content.len and content[i] != '\n': i.inc
        res.add('\n')
      # Triple quotes
      elif i+2 < content.len and content[i ..< i+3] == "\"\"\"":
        res.add("\"\"\"\"\"\"")
        i = skipString(content, i, "\"\"\"")
      elif i+2 < content.len and content[i ..< i+3] == "'''":
        res.add("''''''")
        i = skipString(content, i, "'''")
      # Single quotes
      elif content[i] == '"' or content[i] == '\'':
        let q = $content[i]
        res.add(q & q)
        i = skipString(content, i, q)
      else:
        res.add(content[i])
        i.inc
  else:
    return content
  
  return res

proc calculateComplexity(originalContent: string, lang: Language): tuple[complexity: int, functions: int] =
  var complexity = 1
  var functions = 0
  
  # Strip comments and strings to avoid false positives
  let content = cleanSource(originalContent, lang)
  
  # Keyword sets
  var keywords: seq[string]
  if lang == langPython:
    keywords = @["if", "elif", "for", "while", "except", "and", "or"]
  elif lang == langCStyle:
    keywords = @["if", "for", "while", "case", "catch"]
  elif lang == langGo:
    keywords = @["if", "for", "case"] # Go has no while (uses for), select is container (cases count)
  else:
    return (0, 0)

  # State for function counting (C-Style)
  var expectingBlock = false
  var lastNonSpaceChar: char = '\0'

  # Tokenize and count
  var i = 0
  while i < content.len:
    # Skip whitespace but track last char
    if content[i] in {' ', '\t', '\n', '\r'}:
      i.inc
      continue

    # Handle words (keywords)
    if content[i] in {'a'..'z', 'A'..'Z', '_'}:
      var word = ""
      while i < content.len and (content[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
        word.add(content[i])
        i.inc
      
      # Determine keyword match
      var isKeyword = false
      for k in keywords:
        if word == k:
          complexity += 1
          if lang == langCStyle: expectingBlock = true
          isKeyword = true
          break
      
      # Function counting
      if lang == langPython:
         if word == "def": functions += 1
      elif lang == langGo:
         if word == "func": functions += 1
      # Removed CStyle "function" because ') {' heuristic covers it
      
      # Correctly update lastNonSpaceChar: it should be the LAST char of the word
      if word.len > 0: lastNonSpaceChar = word[word.len-1]
      continue

    # Handle Operators and Punctuation
    else:
      let c = content[i]
      var handled = false
      
      # Function heuristic Check BEFORE updating lastNonSpaceChar
      if lang == langCStyle:
         if c == '{':
           if lastNonSpaceChar == ')' and not expectingBlock:
               functions += 1
           expectingBlock = false
           # We processed {
         elif c == '}' or c == ';':
           expectingBlock = false

      # Handle C-Style operators (and Go)
      if lang == langCStyle or lang == langGo:
        if c == '?' and (i+1 >= content.len or content[i+1] != '?'):
          if lang != langGo:
             complexity += 1
          lastNonSpaceChar = '?'
          i.inc
          handled = true
        elif i+1 < content.len and (
           (content[i] == '&' and content[i+1] == '&') or
           (content[i] == '|' and content[i+1] == '|')
        ):
          complexity += 1
          lastNonSpaceChar = content[i+1]
          i += 2
          handled = true
        
        # JS/TS Arrow functions
        elif lang == langCStyle and i+1 < content.len and content[i] == '=' and content[i+1] == '>':
           functions += 1
           lastNonSpaceChar = '>'
           i += 2
           handled = true
      
      if not handled:
        lastNonSpaceChar = c
        i.inc


  # Ensure at least 1 function to avoid division by zero if file is not empty
  if functions == 0 and content.strip().len > 0:
    functions = 1
    
  return (complexity, functions)

# ---------------------------------------------------------------------------
# Python API
# ---------------------------------------------------------------------------

when defined(python):
  proc analyze_file(filename: string): PyObject {.exportpy.} =
    let lang = detectLanguage(filename)
    if lang == langUnknown:
      return pyDict() # Return empty dict if unknown language

    try:
      let content = readFile(filename)
      let (c, f) = calculateComplexity(content, lang)
      let pcc = if f > 0: c.float / f.float else: 0.0
      
      let res = pyDict()
      res["file"] = filename
      res["complexity"] = c
      res["functions"] = f
      res["pcc"] = pcc
      return res
    except:
      return pyDict()

  proc analyze_content(content: string, filename: string): PyObject {.exportpy.} =
    let lang = detectLanguage(filename)
    if lang == langUnknown:
      return pyDict()

    let (c, f) = calculateComplexity(content, lang)
    let pcc = if f > 0: c.float / f.float else: 0.0
    
    let res = pyDict()
    res["file"] = filename
    res["complexity"] = c
    res["functions"] = f
    res["pcc"] = pcc
    return res

# ---------------------------------------------------------------------------
# CLI Implementation
# ---------------------------------------------------------------------------

proc processFile(filename: string, stats: var Stats, opts: Options) =
  # Check exclusions first
  for pattern in opts.excludePatterns:
    if filename.contains(pattern): return

  let lang = detectLanguage(filename)
  if lang == langUnknown: return

  try:
    let content = readFile(filename)
    let (c, functions) = calculateComplexity(content, lang)
    let pcc = if functions > 0: c.float / functions.float else: 0.0
    
    if opts.jsonOutput:
      # Fix: Use explicit type and conversion to string to resolve ambiguity
      var jObj = %*{"file": filename, "complexity": c, "functions": functions, "pcc": pcc}
      echo $jObj
    else:
      if opts.maxComplexity > 0 and c > opts.maxComplexity:
        echo fmt"{filename}: {c} (PCC: {pcc:.2f}) (EXCEEDS {opts.maxComplexity})"
      else:
        echo fmt"{filename}: {c} (PCC: {pcc:.2f})"
    
    stats.count += 1
    stats.total += c
    stats.totalFunctions += functions
    if stats.min == -1 or c < stats.min: stats.min = c
    if c > stats.max: stats.max = c
    
    if opts.maxComplexity > 0 and c > opts.maxComplexity:
      stats.filesOverThreshold += 1
      
  except IOError:
    if not opts.jsonOutput:
      echo fmt"Error reading {filename}"

proc walk(path: string, stats: var Stats, opts: Options) =
  # Check exclusions for directories too
  for pattern in opts.excludePatterns:
    if path.contains(pattern): return

  if fileExists(path):
    processFile(path, stats, opts)
  elif dirExists(path):
    for kind, p in walkDir(path):
      if kind == pcFile:
        processFile(p, stats, opts)
      elif kind == pcDir:
        walk(p, stats, opts)
  else:
    if not opts.jsonOutput:
      echo fmt"Path not found: {path}"

proc main() =
  var opts = Options(
    showStats: false, 
    jsonOutput: false, 
    maxComplexity: 0, 
    excludePatterns: @[], 
    paths: @[]
  )
  
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "stats", "s": opts.showStats = true
      of "json", "j": opts.jsonOutput = true
      of "max", "m": 
        try: opts.maxComplexity = parseInt(val)
        except ValueError: echo "Invalid max complexity value"
      of "exclude", "e": opts.excludePatterns.add(val)
    of cmdArgument:
      opts.paths.add(key)
    of cmdEnd: break
  
  if opts.paths.len == 0:
    echo """Usage: cyclomat [options] <file_or_directory>...

Options:
  -s, --stats          Show summary statistics
  -j, --json           Output results in JSON format
  -m, --max:N          Fail if complexity exceeds N
  -e, --exclude:PAT    Exclude files/dirs matching pattern
"""
    quit(1)

  var stats = Stats(count: 0, total: 0, min: -1, max: 0, filesOverThreshold: 0, totalFunctions: 0)

  for path in opts.paths:
    walk(path, stats, opts)
    
  if opts.showStats and not opts.jsonOutput and stats.count > 0:
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
    if opts.maxComplexity > 0:
      echo fmt"Files > {opts.maxComplexity}:      {stats.filesOverThreshold}"
    echo "--------------------------------------------------"

  if stats.filesOverThreshold > 0:
    quit(1)

when isMainModule and not defined(testing) and not defined(python):
  main()
