# shellcheck shell=bash
# axi_rows <table> <listing> <rows|items> <field> [<field>...]: validated
# selected fields, as TAB-separated rows or JSON-escaped todo items. Item mode
# keeps decoded values inside its byte-oriented parser through normalization,
# codepoint-safe truncation, and JSON escaping, so NUL and UTF-8 never cross an
# unsafe shell-string boundary. A successful empty listing must carry the tool's
# explicit count-zero scalar; a non-empty listing must carry the expected table
# header with every requested field and the declared number of parseable rows.
# Anything else is incompatible rather than an empty board.
#
# A field named `raw:<field>` prints that column's RAW listing token instead of
# its decoded value, for a caller that decodes the value itself because the
# shared decoder would destroy it - it folds a JSON newline into a space, and a
# multi-line body's line structure is exactly what a body reader needs. A raw
# token is still a JSON string, so it carries no real tab or newline and stays
# one field of one row; every token in the row is still decoded for validation,
# so a raw request cannot smuggle a malformed row past this parser.
axi_rows() {
  local table=$1 listing=$2 output=$3
  shift 3
  LC_ALL=C awk -v table="$table" -v output="$output" -v item_max="${ITEM_MAX:-200}" -v want="$*" '
    function hex_value(hex,   i, digit, value) {
      if (length(hex) != 4) return -1
      value = 0
      for (i = 1; i <= 4; i++) {
        digit = index("0123456789abcdef", tolower(substr(hex, i, 1))) - 1
        if (digit < 0) return -1
        value = value * 16 + digit
      }
      return value
    }
    function utf8(code) {
      if (code <= 127) return sprintf("%c", code)
      if (code <= 2047) {
        return sprintf("%c%c", 192 + int(code / 64), 128 + code % 64)
      }
      return sprintf("%c%c%c", 224 + int(code / 4096), \
        128 + int(code / 64) % 64, 128 + code % 64)
    }
    function decode_token(token,   i, c, nxt, hex, code, value) {
      sub(/^[[:space:]]+/, "", token)
      sub(/[[:space:]]+$/, "", token)
      if (substr(token, 1, 1) != "\"") {
        if (index(token, "\"") != 0) { token_bad = 1; return "" }
        return token
      }
      if (length(token) < 2 || substr(token, length(token), 1) != "\"") {
        token_bad = 1
        return ""
      }
      token = substr(token, 2, length(token) - 2)
      value = ""; i = 1
      while (i <= length(token)) {
        c = substr(token, i, 1)
        if (c != "\\") { value = value c; i++; continue }
        nxt = substr(token, i + 1, 1)
        if (nxt == "\"" || nxt == "\\" || nxt == "/") {
          value = value nxt; i += 2; continue
        }
        if (nxt == "b") { value = value sprintf("%c", 8); i += 2; continue }
        if (nxt == "f") { value = value sprintf("%c", 12); i += 2; continue }
        if (nxt == "n" || nxt == "r" || nxt == "t") {
          value = value " "; i += 2; continue
        }
        if (nxt == "u") {
          hex = substr(token, i + 2, 4)
          code = hex_value(hex)
          if (code < 0 || (code >= 55296 && code <= 57343)) {
            token_bad = 1
            return ""
          }
          if (code == 9 || code == 10 || code == 13) value = value " "
          else value = value utf8(code)
          i += 6
          continue
        }
        token_bad = 1
        return ""
      }
      return value
    }
    function split_row(line, out,   n, i, c, token, inq, nxt) {
      n = 0; token = ""; inq = 0; i = 1
      while (i <= length(line)) {
        c = substr(line, i, 1)
        if (inq && c == "\\") {
          nxt = substr(line, i + 1, 1)
          if (nxt == "") return -1
          token = token c nxt; i += 2; continue
        }
        if (c == "\"") { inq = !inq; token = token c; i++; continue }
        if (c == "," && !inq) {
          token_bad = 0
          # Validate through a copy: a raw: field wants this token verbatim, and
          # an awk that passes an array element into a mutating parameter would
          # hand back this cell already decoded.
          validation = token
          decode_token(validation)
          if (token_bad) return -1
          out[++n] = token
          token = ""; i++; continue
        }
        token = token c; i++
      }
      if (inq) return -1
      token_bad = 0
      validation = token
      decode_token(validation)
      if (token_bad) return -1
      out[++n] = token
      return n
    }
    function byte_value(c) {
      if (c == nul) return 0
      return byte_of[c]
    }
    function utf8_step(s, pos,   b, b2, b3, b4) {
      b = byte_value(substr(s, pos, 1))
      if (b <= 127) return 1
      b2 = byte_value(substr(s, pos + 1, 1))
      if (b >= 194 && b <= 223 && b2 >= 128 && b2 <= 191) return 2
      b3 = byte_value(substr(s, pos + 2, 1))
      if (b == 224 && b2 >= 160 && b2 <= 191 && b3 >= 128 && b3 <= 191) return 3
      if (b >= 225 && b <= 236 && b2 >= 128 && b2 <= 191 && b3 >= 128 && b3 <= 191) return 3
      if (b == 237 && b2 >= 128 && b2 <= 159 && b3 >= 128 && b3 <= 191) return 3
      if (b >= 238 && b <= 239 && b2 >= 128 && b2 <= 191 && b3 >= 128 && b3 <= 191) return 3
      b4 = byte_value(substr(s, pos + 3, 1))
      if (b == 240 && b2 >= 144 && b2 <= 191 && b3 >= 128 && b3 <= 191 && b4 >= 128 && b4 <= 191) return 4
      if (b >= 241 && b <= 243 && b2 >= 128 && b2 <= 191 && b3 >= 128 && b3 <= 191 && b4 >= 128 && b4 <= 191) return 4
      if (b == 244 && b2 >= 128 && b2 <= 143 && b3 >= 128 && b3 <= 191 && b4 >= 128 && b4 <= 191) return 4
      return 0
    }
    function text_length(s,   pos, count, step) {
      pos = 1; count = 0
      while (pos <= length(s)) {
        step = utf8_step(s, pos)
        if (step == 0) { utf8_bad = 1; return 0 }
        pos += step; count++
      }
      return count
    }
    function text_prefix(s, limit,   pos, count, step) {
      pos = 1; count = 0
      while (pos <= length(s) && count < limit) {
        step = utf8_step(s, pos)
        if (step == 0) { utf8_bad = 1; return "" }
        pos += step; count++
      }
      return substr(s, 1, pos - 1)
    }
    function json_string(s,   i, c, b, result) {
      result = "\""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); b = byte_value(c)
        if (b == 34) result = result "\\\""
        else if (b == 92) result = result "\\\\"
        else if (b <= 31) result = result sprintf("\\u%04x", b)
        else result = result c
      }
      return result "\""
    }
    function todo_json(id, title,   prefix, effective_max, title_max, title_len) {
      gsub(/[\t\r\n]/, " ", title)
      gsub(/ +/, " ", title)
      sub(/^ /, "", title); sub(/ $/, "", title)
      if (title == "") title = "-"
      prefix = id " - "
      utf8_bad = 0
      effective_max = item_max
      if (effective_max < text_length(prefix) + 1) effective_max = text_length(prefix) + 1
      title_max = effective_max - text_length(prefix)
      title_len = text_length(title)
      if (utf8_bad) return ""
      if (title_len > title_max) {
        if (title_max == 1) title = "…"
        else title = text_prefix(title, title_max - 1) "…"
      }
      if (utf8_bad) return ""
      return json_string(prefix title)
    }
    BEGIN {
      nul = sprintf("%c", 0)
      for (i = 0; i <= 255; i++) byte_of[sprintf("%c", i)] = i
      nwant = split(want, wanted, " ")
      for (i = 1; i <= nwant; i++) {
        if (wanted[i] ~ /^raw:/) { raw_is[i] = 1; sub(/^raw:/, "", wanted[i]) }
      }
    }
    $0 == "count: 0" { zero_count = 1; next }
    table == "tasks" && /^tasks: 0 .*tasks in this backlog$/ { zero_scalar = 1; next }
    table == "ready" && $0 == "ready: 0 unblocked queued tasks" { zero_scalar = 1; next }
    /^help\[/ { exit }
    /^(tasks|ready)\[[0-9]+\]\{.*\}:$/ {
      name = $0
      sub(/\[.*/, "", name)
      if (name != table) { rows = 0; next }
      spec = $0
      sub(/^[a-z]+\[[0-9]+\]\{/, "", spec)
      sub(/\}:$/, "", spec)
      declared = $0
      sub(/^[a-z]+\[/, "", declared)
      sub(/\].*$/, "", declared)
      for (key in index_of) delete index_of[key]
      ncol = split(spec, cols, ",")
      for (i = 1; i <= ncol; i++) index_of[cols[i]] = i
      for (i = 1; i <= nwant; i++) if (!index_of[wanted[i]]) bad = 1
      header = 1
      rows = 1
      next
    }
    rows && /^[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      for (key in cells) delete cells[key]
      ncells = split_row(line, cells)
      if (ncells != ncol) { bad = 1; next }
      out = ""
      for (i = 1; i <= nwant; i++) {
        col = index_of[wanted[i]]
        if (i > 1) out = out "\t"
        if (col) {
          decoded = cells[col]
          if (!raw_is[i]) decoded = decode_token(decoded)
          out = out decoded
        }
      }
      if (output == "items") {
        out = todo_json(decode_token(cells[index_of["id"]]), decode_token(cells[index_of["title"]]))
        if (utf8_bad) { bad = 1; next }
      }
      print out
      seen++
      next
    }
    { rows = 0 }
    END {
      if (header) {
        if (bad || seen != declared) exit 3
        exit 0
      }
      if (zero_count && zero_scalar) exit 0
      exit 3
    }
  ' <<< "$listing"
}

