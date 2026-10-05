import __future__
import ast
import importlib.util
import io
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
import tokenize
import warnings


INPUT_LIMIT = 8 * 1024 * 1024
OUTPUT_LIMIT = 4 * 1024 * 1024
DIAGNOSTIC_LIMIT = 1000
FUTURE_FLAGS = sum(getattr(__future__, name).compiler_flag for name in __future__.all_feature_names)
NOTEBOOK_COMMAND = re.compile(r"^[ \t]*(?:[A-Za-z_]\w*(?:[ \t]*,[ \t]*[A-Za-z_]\w*)*[ \t]*=[ \t]*)?(%{1,2}[A-Za-z_]\w*|!!?)")
INLINE_MATPLOTLIB = re.compile(r"^[ \t]*%matplotlib[ \t]+inline[ \t]*(?:#[^\r\n]*)?[\r\n]*$")
STRING_TOKENS = frozenset(getattr(tokenize, name) for name in (
    "STRING", "FSTRING_START", "FSTRING_MIDDLE", "FSTRING_END", "TSTRING_START", "TSTRING_MIDDLE", "TSTRING_END",
) if hasattr(tokenize, name))


def diagnostic(source_id, line, column, end_line, end_column, message, code, severity="error"):
    return {"sourceID": source_id, "line": line, "column": column, "endLine": end_line,
            "endColumn": end_column, "message": message, "code": code, "severity": severity}


def normalized(source):
    return source.replace("\r\n", "\n").replace("\r", "\n")


def prepare_source(source_id, source):
    protected = set()
    bracket_depth = 0
    try:
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            if bracket_depth:
                protected.add(token.start[0])
            if token.type == tokenize.OP:
                if token.string in ("(", "[", "{"):
                    bracket_depth += 1
                elif token.string in (")", "]", "}"):
                    bracket_depth = max(0, bracket_depth - 1)
            if token.type in STRING_TOKENS and token.end[0] > token.start[0]:
                protected.update(range(token.start[0] + 1, token.end[0] + 1))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    lines = source.splitlines(True)
    protected.update(index + 2 for index, line in enumerate(lines) if line.rstrip("\n").endswith("\\"))
    diagnostics = []
    for index, line in enumerate(lines):
        if index + 1 in protected:
            continue
        if INLINE_MATPLOTLIB.fullmatch(line):
            lines[index] = "\n" if line.endswith("\n") else ""
            continue
        command = NOTEBOOK_COMMAND.match(line)
        if command is None:
            continue
        name = command.group(1)
        diagnostics.append(diagnostic(source_id, index + 1, command.start(1) + 1,
                                      index + 1, command.end(1) + 1,
                                      "Static checks skip this IPython command: " + name, "IPYTHON", "warning"))
        if name.startswith("%%"):
            return "\n" * source.count("\n"), diagnostics
        indent = line[:len(line) - len(line.lstrip())]
        lines[index] = indent + "pass" + ("\n" if line.endswith("\n") else "")
    return "".join(lines), diagnostics


def syntax_diagnostics(sources):
    flags = getattr(ast, "PyCF_ALLOW_TOP_LEVEL_AWAIT", 0)
    diagnostics = []
    for item in sources:
        item["flags"] = flags
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                compiled = compile(item["source"], "<quanta>", "exec", flags=flags, dont_inherit=True)
            flags |= compiled.co_flags & FUTURE_FLAGS
            item["flags"] = flags
        except SyntaxError as error:
            line = max(1, error.lineno or 1)
            column = max(1, error.offset or 1)
            end_line = max(line, getattr(error, "end_lineno", None) or line)
            end_column = max(1, getattr(error, "end_offset", None) or column + 1)
            diagnostics.append(diagnostic(item["id"], line, column, end_line, end_column,
                                          error.msg, "SyntaxError"))
        except (ValueError, OverflowError, RecursionError) as error:
            diagnostics.append(diagnostic(item["id"], 1, 1, 1, 2, str(error), "SyntaxError"))
    return diagnostics


def ruff_source(item):
    source = item["source"]
    if not item.get("flags", 0) & __future__.barry_as_FLUFL.compiler_flag:
        return source
    lines = source.splitlines(True)
    previous = None
    try:
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            position = token.start if token.type == tokenize.OP and token.string == "<>" else None
            if (previous is not None and previous.type == tokenize.OP and previous.string == "<"
                    and token.type == tokenize.OP and token.string == ">" and previous.end == token.start):
                position = previous.start
            if position is not None:
                row, column = position
                line = lines[row - 1]
                lines[row - 1] = line[:column] + "!=" + line[column + 2:]
            previous = token
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return "".join(lines)


def ruff_configuration():
    for name in (".ruff.toml", "ruff.toml", "pyproject.toml"):
        path = os.path.join(os.getcwd(), name)
        if not os.path.isfile(path):
            continue
        if name == "pyproject.toml":
            with open(path, "r", encoding="utf-8") as handle:
                content = handle.read(1024 * 1024)
            if not re.search(r"(?m)^\s*\[\s*tool\.ruff(?:\s*\]|\.)", content):
                continue
        return ["--config", path]
    return ["--isolated"]


def run_ruff(arguments, source):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("RUFF_")}
    process = subprocess.Popen([sys.executable, "-I", "-m", "ruff"] + arguments,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, env=environment)
    data = source.encode("utf-8")
    position = 0
    outputs = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + 8
    try:
        with selectors.DefaultSelector() as selector:
            for handle, event, name in ((process.stdin, selectors.EVENT_WRITE, "stdin"),
                                        (process.stdout, selectors.EVENT_READ, "stdout"),
                                        (process.stderr, selectors.EVENT_READ, "stderr")):
                os.set_blocking(handle.fileno(), False)
                selector.register(handle, event, name)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("Ruff took too long to respond.")
                for key, event in selector.select(min(remaining, 0.1)):
                    if key.data == "stdin":
                        try:
                            position += os.write(key.fd, data[position:position + 65536])
                        except BrokenPipeError:
                            position = len(data)
                        if position == len(data):
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                    else:
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                            continue
                        outputs[key.data].extend(chunk)
                        if sum(map(len, outputs.values())) > OUTPUT_LIMIT:
                            raise RuntimeError("Ruff returned too much output.")
            process.wait(timeout=max(0.01, deadline - time.monotonic()))
        return process.returncode, outputs["stdout"].decode("utf-8"), outputs["stderr"].decode("utf-8", errors="replace")
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=1)
        for handle in (process.stdin, process.stdout, process.stderr):
            handle.close()


def notebook(sources):
    return json.dumps({"nbformat": 4, "nbformat_minor": 5, "metadata": {}, "cells": [
        {"cell_type": "code", "id": item["id"], "metadata": {}, "execution_count": None,
         "outputs": [], "source": item["source"]} for item in sources
    ]})


def lint_with_ruff(sources, syntax, is_notebook):
    is_notebook = is_notebook or len(sources) != 1
    filename = "__quanta__.ipynb" if is_notebook else "__quanta__.py"
    adapted = [{"id": item["id"], "source": ruff_source(item)} for item in sources]
    source = notebook(adapted) if is_notebook else adapted[0]["source"]
    arguments = ["check", "--no-cache", "--no-fix", "--no-fix-only", "--output-format", "json",
                 "--stdin-filename", filename] + ruff_configuration() + ["-"]
    status, output, errors = run_ruff(arguments, source)
    if status not in (0, 1):
        raise RuntimeError(errors.strip()[:1000] or "Ruff could not check this document.")
    entries = json.loads(output)
    if not isinstance(entries, list):
        raise RuntimeError("Ruff returned an invalid diagnostics response.")
    invalid_sources = {item["sourceID"] for item in syntax}
    diagnostics = []
    parser_mismatch = False
    for entry in entries:
        index = (entry.get("cell") or 1) - 1 if is_notebook else 0
        if not 0 <= index < len(sources):
            continue
        item = sources[index]
        start = entry["location"]
        end = entry["end_location"]
        code = entry.get("code") or "SyntaxError"
        if code in ("invalid-syntax", "SyntaxError", "E999"):
            parser_mismatch = parser_mismatch or item["id"] not in invalid_sources
            continue
        if code in ("F704", "PLE1142") and item["id"] not in invalid_sources:
            continue
        if code == "F821":
            lines = item["source"].split("\n")
            if 0 < start["row"] <= len(lines) and start["row"] == end["row"]:
                name = lines[start["row"] - 1][start["column"] - 1:end["column"] - 1]
                if name in ("display", "clear_output"):
                    continue
        severity = "error" if code in ("F821", "F822", "F823", "E902", "E999", "invalid-syntax", "SyntaxError") else "warning"
        diagnostics.append(diagnostic(item["id"], start["row"], start["column"], end["row"],
                                      end["column"], entry["message"], code, severity))
        if len(diagnostics) >= DIAGNOSTIC_LIMIT:
            break
    notices = [errors.strip()[:1000]] if errors.strip() else []
    if parser_mismatch:
        notices.append("Some syntax supported by the selected Python interpreter could not be checked by Ruff; Python syntax checks still ran.")
    return diagnostics, " ".join(notices) or None


def analyze(payload):
    sources = []
    diagnostics = []
    notices = []
    for item in payload["sources"]:
        source, skipped = prepare_source(item["id"], normalized(item["source"]))
        sources.append({"id": item["id"], "source": source})
        diagnostics.extend(skipped)
    if diagnostics:
        notices.append("IPython commands are skipped by static checks; cell-magic bodies are not checked.")
    syntax = syntax_diagnostics(sources)
    diagnostics.extend(syntax)
    tool_name = "Python syntax"
    if sources:
        if importlib.util.find_spec("ruff") is None:
            notices.append("Ruff is not installed in this Python environment. Only Python syntax is checked.")
        else:
            try:
                lint, notice = lint_with_ruff(sources, syntax, payload.get("isNotebook", False))
                diagnostics.extend(lint)
                tool_name = "Ruff + Python syntax"
                if notice:
                    notices.append(notice)
            except (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
                notices.append("Only Python syntax is checked. " + str(error)[:1000])
    order = {item["id"]: index for index, item in enumerate(sources)}
    diagnostics.sort(key=lambda item: (order[item["sourceID"]], item["line"], item["column"], item["code"]))
    if len(diagnostics) >= DIAGNOSTIC_LIMIT:
        diagnostics = diagnostics[:DIAGNOSTIC_LIMIT]
        notices.append("Showing the first 1000 diagnostics.")
    return {"diagnostics": diagnostics, "toolName": tool_name, "notice": " ".join(notices) or None}


def format_source(payload):
    if importlib.util.find_spec("ruff") is None:
        raise RuntimeError("Formatting requires Ruff in the selected Python environment. Install Ruff using Python Environment… to enable formatting.")
    source = payload["source"]
    is_notebook = payload.get("isNotebook", False)
    prepared, skipped = prepare_source("format", normalized(source))
    if not is_notebook and (skipped or prepared != normalized(source)):
        raise RuntimeError("Format this cell after removing its IPython commands; Quanta preserves them unchanged.")
    filename = "__quanta__.ipynb" if is_notebook else "__quanta__.py"
    arguments = ["format", "--no-cache", "--stdin-filename", filename] + ruff_configuration() + ["-"]
    status, output, errors = run_ruff(arguments, notebook([{"id": "format", "source": source}]) if is_notebook else source)
    if status != 0:
        raise RuntimeError(errors.strip()[:1000] or "Ruff could not format this source. Fix syntax errors first.")
    if is_notebook:
        document = json.loads(output)
        if len(document["cells"]) != 1 or document["cells"][0]["cell_type"] != "code":
            raise RuntimeError("Ruff returned an invalid formatted notebook cell.")
        output = document["cells"][0]["source"]
        if isinstance(output, list):
            output = "".join(output)
        if not isinstance(output, str):
            raise RuntimeError("Ruff returned an invalid formatted notebook cell.")
    return {"source": output}


def interrupted(signum, frame):
    raise KeyboardInterrupt()


def main():
    signal.signal(signal.SIGTERM, interrupted)
    try:
        data = sys.stdin.buffer.read(INPUT_LIMIT + 1)
        if len(data) > INPUT_LIMIT:
            raise RuntimeError("This document is too large for background Python analysis.")
        payload = json.loads(data)
        if payload["op"] == "analyze":
            response = analyze(payload)
        elif payload["op"] == "format":
            response = format_source(payload)
        else:
            raise RuntimeError("Unknown Python analysis operation.")
    except (RuntimeError, OSError, ValueError, KeyError, TypeError) as error:
        response = {"error": str(error)[:2000]}
    except KeyboardInterrupt:
        return
    sys.stdout.write(json.dumps(response, ensure_ascii=False))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
