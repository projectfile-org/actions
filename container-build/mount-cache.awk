# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# Rewrites a Dockerfile into its mount-cache dance: every stage’s FROM/ARG/ENV skeleton, one RUN per source RUN carrying its cache mounts verbatim, a scratch collector last.
# awk -v mode=inject|extract -v target=<stage> -v context=<bind context> -f mount-cache.awk Dockerfile

BEGIN { nl = 0; nst = 0; cur = 0; acc = ""; cont = 0; nhd = 0; syntax = ""; seen_any = 0 }

# heredoc body: consume raw lines until the pending terminator
nhd > 0 {
  body = $0
  if (hd_dash[1]) sub(/^\t+/, "", body)
  if (body == hd[1]) { for (i = 1; i < nhd; i++) { hd[i] = hd[i + 1]; hd_dash[i] = hd_dash[i + 1] }; nhd-- }
  next
}

{
  line = $0
  if (!seen_any && line ~ /^#[ \t]*syntax=/) { syntax = line; next }
  seen_any = 1
  if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next
  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); acc = acc line; cont = 1; next }
  acc = acc line; cont = 0
  logical(acc); acc = ""
}

# one instruction: record FROM/ARG/ENV verbatim, a RUN’s cache mounts, and every stage reference
function logical(l,    n, t, i, kw, ref, name) {
  n = split(l, t, /[ \t]+/)
  i = (t[1] == "") ? 2 : 1
  kw = toupper(t[i])
  if (kw == "FROM") {
    nst++; cur = nst; nl++; L[nl] = l; K[nl] = "FROM"; S[nl] = nst
    ref = ""; name = ""
    for (i++; i <= n; i++) {
      if (t[i] ~ /^--/) continue
      if (ref == "") { ref = t[i]; continue }
      if (toupper(t[i]) == "AS" && i < n) { name = t[i + 1]; break }
    }
    if (name != "") name_idx[name] = nst
    deps[nst] = deps[nst] " " ref
  } else if (kw == "ARG" || kw == "ENV") {
    nl++; L[nl] = l; K[nl] = kw; S[nl] = cur
  } else if (kw == "RUN") {
    nl++; L[nl] = l; K[nl] = "RUN"; S[nl] = cur; M[nl] = ""
    for (i++; i <= n && t[i] ~ /^--/; i++) {
      if (t[i] ~ /^--mount=type=cache,/) M[nl] = M[nl] " " t[i]
      if (t[i] ~ /^--mount=/) deps[cur] = deps[cur] " " optval(substr(t[i], 9), "from")
    }
    heredoc(l)
  } else if (kw == "COPY" || kw == "ADD") {
    for (i++; i <= n && t[i] ~ /^--/; i++) if (t[i] ~ /^--from=/) deps[cur] = deps[cur] " " substr(t[i], 8)
    heredoc(l)
  }
}

# queue every heredoc marker the instruction opens
function heredoc(l,    s, w) {
  s = l
  while (match(s, /<<-?["']?[A-Za-z_][A-Za-z0-9_]*/)) {
    w = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    nhd++; hd_dash[nhd] = (w ~ /^<<-/); sub(/^<<-?["']?/, "", w); hd[nhd] = w
  }
}

# value of key=… inside a comma-separated mount option list
function optval(opts, key,    n, o, j) {
  n = split(opts, o, ",")
  for (j = 1; j <= n; j++) if (index(o[j], key "=") == 1) return substr(o[j], length(key) + 2)
  return ""
}

# the dance RUN for one source RUN: its new cache mounts, each tarred out of or back into its target
function emit_run(i,    n, t, j, run, lit, tgt, id) {
  n = split(NM[i], t, " ")
  run = "RUN"
  for (j = 1; j <= n; j++) if (t[j] != "") run = run " " t[j]
  if (mode == "inject") run = run " --mount=type=bind,from=" context ",target=/in"
  print run " \\"
  print "    set -e && mkdir -p /out \\"
  for (j = 1; j <= n; j++) {
    if (t[j] == "") continue
    lit = substr(t[j], 9)
    tgt = optval(lit, "target"); id = optval(lit, "id")
    if (id == "") id = tgt
    if (tgt == "") continue
    print " && id=\"" id "\" && h=\"$(printf '%s' \"$id\" | sha256sum | cut -c1-16)\" \\"
    if (mode == "extract") {
      print " && tar --create --file \"/out/$h.tar\" --directory \"" tgt "\" . \\"
      print " && printf '%s\\n' \"$id\" >\"/out/$h.id\" \\"
      print " && echo \"mount-cache extract id=$id bytes=$(wc -c <\"/out/$h.tar\")\" \\"
    } else {
      print " && if [ -f \"/in/$h.tar\" ]; then mkdir -p \"" tgt "\" && tar --extract --file \"/in/$h.tar\" --directory \"" tgt "\" && echo \"mount-cache inject id=$id bytes=$(wc -c <\"/in/$h.tar\")\"; else echo \"mount-cache inject id=$id (no saved tar)\"; fi \\"
    }
  }
  print " && :"
}

END {
  if (cont) logical(acc)
  tgt = nst
  if (target != "" && (target in name_idx)) tgt = name_idx[target]
  # closure: the stages the target really builds, by FROM / COPY --from / mount from= references
  q[1] = tgt; qn = 1; inc[tgt] = 1
  for (qi = 1; qi <= qn; qi++) {
    nd = split(deps[q[qi]], d, " ")
    for (j = 1; j <= nd; j++) {
      s = 0
      if (d[j] in name_idx) s = name_idx[d[j]]
      else if (d[j] ~ /^[0-9]+$/) s = d[j] + 1
      if (s > 0 && s <= nst && !(s in inc)) { inc[s] = 1; q[++qn] = s }
    }
  }
  # each cache mount literal dances once, in the first closure RUN that declares it
  ndance = 0
  for (i = 1; i <= nl; i++) {
    if (K[i] != "RUN" || !(S[i] in inc)) continue
    n = split(M[i], t, " "); NM[i] = ""
    for (j = 1; j <= n; j++) {
      if (t[j] == "" || (t[j] in seen) || t[j] ~ /,(ro|readonly)(,|=|$)/) continue
      seen[t[j]] = 1; NM[i] = NM[i] " " t[j]
    }
    if (NM[i] != "" && !(S[i] in dance)) { dance[S[i]] = 1; ndance++ }
  }
  if (ndance == 0) exit 0
  if (syntax != "") print syntax
  prev = 0
  for (i = 1; i <= nl; i++) {
    if (K[i] == "FROM") {
      print L[i]
      if (S[i] in dance) {
        print "USER 0:0"
        if (prev) print "COPY --from=" (prev - 1) " /out/ /out/"
        prev = S[i]
      }
    } else if (K[i] == "ARG" || K[i] == "ENV") {
      print L[i]
    } else if (K[i] == "RUN" && NM[i] != "") {
      emit_run(i)
    }
  }
  print "FROM scratch"
  print "COPY --from=" (prev - 1) " /out/ /"
}
