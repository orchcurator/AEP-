#!/usr/bin/env python3
"""Generate a compact signature map of a repository.

Feed this to an LLM instead of full file bodies; let it request specific files.
Python: parsed with `ast` (accurate). JS/TS: regex heuristics (best-effort).

Usage: repo-map.py [ROOT] [--max-files N] [--out FILE]
"""
import argparse, ast, os, re, sys

SKIP_DIRS = {".git", "node_modules", "venv", ".venv", "__pycache__", "dist", "build", ".next", ".ai"}
TS_PATTERNS = [
    re.compile(r"^export\s+(?:default\s+)?(?:async\s+)?function\s+(\w+)\s*(\([^)]*\))(?:\s*:\s*([^\{]+))?", re.M),
    re.compile(r"^export\s+(?:default\s+)?class\s+(\w+)", re.M),
    re.compile(r"^export\s+(?:interface|type)\s+(\w+)", re.M),
    re.compile(r"^export\s+const\s+(\w+)\s*(?::[^=]+)?=\s*(?:async\s*)?\(", re.M),
]

def py_signatures(path):
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except (SyntaxError, UnicodeDecodeError):
        return ["  (unparseable)"]
    out = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            out.append(f"  def {node.name}({ast.unparse(node.args)})" + (f" -> {ast.unparse(node.returns)}" if node.returns else ""))
        elif isinstance(node, ast.ClassDef):
            out.append(f"  class {node.name}")
            for sub in node.body:
                if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)) and not sub.name.startswith("_"):
                    out.append(f"    .{sub.name}({ast.unparse(sub.args)})")
    return out

def ts_signatures(path):
    try:
        src = open(path, encoding="utf-8").read()
    except UnicodeDecodeError:
        return []
    out = []
    for pat in TS_PATTERNS:
        for m in pat.finditer(src):
            out.append("  " + " ".join(g for g in m.groups() if g).strip())
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--max-files", type=int, default=500)
    ap.add_argument("--out")
    a = ap.parse_args()
    lines, n = [], 0
    for d, dirs, files in os.walk(a.root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            p = os.path.join(d, f)
            ext = os.path.splitext(f)[1]
            if ext == ".py":
                sigs = py_signatures(p)
            elif ext in (".ts", ".tsx", ".js", ".jsx"):
                sigs = ts_signatures(p)
            else:
                continue
            if not sigs:
                continue
            lines.append(os.path.relpath(p, a.root))
            lines.extend(sigs)
            n += 1
            if n >= a.max_files:
                break
        if n >= a.max_files:
            break
    text = "\n".join(lines) + "\n"
    if a.out:
        open(a.out, "w").write(text)
    else:
        sys.stdout.write(text)

if __name__ == "__main__":
    main()
