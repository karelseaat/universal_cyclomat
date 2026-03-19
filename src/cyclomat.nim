import os, strutils, pegs, strformat, parseopt, json

type
  Language = enum
    langPython, langCStyle, langUnknown
  
  Stats = object
    count: int
    total: int
    min: int
    max: int
    filesOverThreshold: int
    
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
  
  else: return langUnknown

# Simplified PEG grammars using \w for word characters
const pythonPeg = """
  match <- keyword
  keyword <- ('if' / 'elif' / 'for' / 'while' / 'except' / 'and' / 'or') !\w
"""

const cStylePeg = """
  match <- keyword / operator
  keyword <- ('if' / 'for' / 'while' / 'case' / 'catch') !\w
  operator <- '&&' / '||' / '?'
"""

proc calculateComplexity(content: string, lang: Language): int =
  var complexity = 1
  let patternStr = case lang
    of langPython: pythonPeg
    of langCStyle: cStylePeg
    else: ""
  
  if patternStr == "": return 0
  
  try:
    let p = peg(patternStr)
    for s in findAll(content, p):
      complexity += 1
  except Exception as e:
    echo fmt"Error in regex for {lang}: {e.msg}"

  return complexity

proc processFile(filename: string, stats: var Stats, opts: Options) =
  # Check exclusions first
  for pattern in opts.excludePatterns:
    if filename.contains(pattern): return

  let lang = detectLanguage(filename)
  if lang == langUnknown: return

  try:
    let content = readFile(filename)
    let c = calculateComplexity(content, lang)
    
    if opts.jsonOutput:
      # Fix: Use explicit type and conversion to string to resolve ambiguity
      var jObj = %*{"file": filename, "complexity": c}
      echo $jObj
    else:
      if opts.maxComplexity > 0 and c > opts.maxComplexity:
        echo fmt"{filename}: {c} (EXCEEDS {opts.maxComplexity})"
      else:
        echo fmt"{filename}: {c}"
    
    stats.count += 1
    stats.total += c
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

  var stats = Stats(count: 0, total: 0, min: -1, max: 0, filesOverThreshold: 0)

  for path in opts.paths:
    walk(path, stats, opts)
    
  if opts.showStats and not opts.jsonOutput and stats.count > 0:
    let avg = stats.total.float / stats.count.float
    echo "\n--------------------------------------------------"
    echo fmt"Total Files:       {stats.count}"
    echo fmt"Total Complexity:  {stats.total}"
    echo fmt"Average Complexity: {avg:.2f}"
    echo fmt"Max Complexity:    {stats.max}"
    echo fmt"Min Complexity:    {stats.min}"
    if opts.maxComplexity > 0:
      echo fmt"Files > {opts.maxComplexity}:      {stats.filesOverThreshold}"
    echo "--------------------------------------------------"

  if stats.filesOverThreshold > 0:
    quit(1)

when isMainModule:
  main()
