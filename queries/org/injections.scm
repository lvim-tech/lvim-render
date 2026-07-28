; extends

; The org grammar ships highlights and markup queries and NO injections, so a `#+begin_src lua`
; block is one flat `contents` node with no language behind it — the code inside reads as plain
; prose. This file is the missing half: the block's second `expr` (the one after the kind) IS the
; language name, and `contents` is what that language should parse.
;
; `; extends` on the first line so this MERGES with anything the grammar or another plugin ships
; rather than replacing it.
; `injection.include-children` is REQUIRED here and is the whole difference between working and
; not: without it Neovim injects only the content node's own text MINUS its named children, and
; org's `contents` is nothing but named `expr` children — so the injected region came out as the
; whitespace between the tokens (measured: eleven one-character ranges) and the code stayed
; uncoloured while the injection looked present.
((block
   .
   (expr) @_kind
   .
   (expr) @injection.language
   .
   (contents) @injection.content)
 (#eq? @_kind "src")
 (#set! injection.include-children))
