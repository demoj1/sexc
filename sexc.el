;;; sexc.el --- Major mode for SexC files -*- lexical-binding: t; -*-

;; Author: SexC contributors
;; Version: 0.1.0
;; Keywords: languages, lisp, c
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Major mode for .sexc files.
;;
;; Features:
;; - Syntax highlighting for surface keywords, IR intrinsics, and meta builtins
;; - Configurable indentation rules via `common-lisp-indent-function'
;; - Convenience compile command (`sexc/compile')
;; - Expand whole buffer to C (`sexc/expand')
;; - Eldoc symbol help in echo area

;;; Code:

(require 'cl-lib)
(require 'eldoc)
(require 'json)
(require 'lisp-mode)
(require 'subr-x)
(require 'xref)

(defgroup sexc nil
  "Editing SexC source files."
  :group 'languages)

(defcustom sexc/binary "sexc"
  "Path to the SexC compiler binary."
  :type 'string
  :group 'sexc)

(defcustom sexc/binary-fallbacks
  '("/usr/local/bin/sexc" "./sexc")
  "Fallback binary paths tried when `sexc/binary' is not executable."
  :type '(repeat string)
  :group 'sexc)

(defcustom sexc/compile-command "%b %f"
  "Compile command template used by `sexc/compile'.

Supported placeholders:
- %b: quoted `sexc/binary'
- %f: quoted current buffer file"
  :type 'string
  :group 'sexc)

(defcustom sexc/expand-command "%b -"
  "Expand command template used by `sexc/expand'.

Supported placeholders:
- %b: quoted `sexc/binary'
- %f: quoted current buffer file (when available)

The command must accept source on stdin and print generated C to stdout."
  :type 'string
  :group 'sexc)

(defcustom sexc/expand-buffer-name "*sexc-expand*"
  "Buffer name used for `sexc/expand' output."
  :type 'string
  :group 'sexc)

(defcustom sexc/surface-keywords
  '("include" "define" "defn" "decl" "block" "if" "cond"
    "while" "for" "return" "set" "cast" "struct" "union"
    "adecl" "free*"
    "zero-init" "sizeof-type" "sizeof-expr" "aref" "dot" "arrow"
    "." "->" "not" "+" "-" "*" "/" "%" "=" "not=" "<" "<=" ">"
    ">=" "&&" "and" "||" "or" "post-inc" "nop"
    "when" "unless" "incf" "decf" "incf-by" "decf-by"
    "dotimes" "for-range" "repeat"
    "|>" "||>" "|as>")
  "Surface DSL keywords/macros (no %/$ prefix)."
  :type '(repeat string)
  :group 'sexc)

(defcustom sexc/type-keywords
  '("void" "char" "short" "int" "long" "float" "double"
    "signed" "unsigned" "const" "volatile" "restrict")
  "Builtin C-like type keywords to highlight."
  :type '(repeat string)
  :group 'sexc)

(defcustom sexc/number-regexp
  "\\(?:\\_<[+-]?\\(?:0[xX][0-9A-Fa-f]+\\|[0-9]+\\(?:\\.[0-9]*\\)?\\(?:[eE][+-]?[0-9]+\\)?\\)[uUlLfF]*\\_>\\)"
  "Regexp used to highlight numeric literals in SexC buffers."
  :type 'regexp
  :group 'sexc)

(defcustom sexc/indent-rules
  '(("decl" . (&body))
    ("set" . (&body))
    ("defn" . (4 4 4 &body))
    ("struct" . (2 &body))
    ("union" . (2 &body))
    ("if" . (4 &body))
    ("when" . (4 &body))
    ("unless" . (4 &body))
    ("while" . (4 &body))
    ("for" . (4 4 4 &body))
    ("dotimes" . (4 4 &body))
    ("for-range" . (4 4 4 &body))
    ("%defmacro" . (4 4 &body))
    ("%eval" . (&body))
    ("%evals" . (&body))
    ("|>" . (&body))
    ("||>" . (&body))
    ("|as>" . (4 4 &body))
    ("$do" . (&body))
    ("$assert" . (4 4))
    ("$subst" . (4 4 4)))
  "Indentation rules applied through `common-lisp-indent-function'."
  :type '(alist :key-type string :value-type sexp)
  :group 'sexc)

(defcustom sexc/eldoc-docs
  '(("defn" . "(defn RET NAME PARAMS FORM...) -> define function")
    ("decl" . "(decl (TYPE NAME) INIT ...) -> let*-style declarations")
    ("adecl" . "(adecl (TYPE NAME) SIZE ...) -> let*-style malloc declarations")
    ("free*" . "(free* PTR...) -> emit block of free calls")
    ("set" . "(set LHS VALUE [LHS2 VALUE2 ...])")
    ("struct" . "(struct Name :fields ... [:methods (defn ...)...])")
    ("union" . "(union Name (TYPE FIELD) ...)")
    ("%eval" . "(%eval EXPR) -> evaluate compile-time expression to one form")
    ("%evals" . "(%evals EXPR) -> evaluate compile-time expression to list splice")
    ("%raw" . "(%raw PART...) -> inline C fragment in expression context")
    ("$for" . "($for (VAR LIST) BODY) -> list of BODY results")
    ("$let" . "($let ((NAME EXPR)...) BODY...) -> meta let*")
    ("$map" . "($map EXPR LIST) with `it' bound to each element")
    ("$filter" . "($filter PRED LIST) with `it' bound to each element")
    ("$reduce" . "($reduce EXPR INIT LIST) with `it' and `acc'")
    ("$dolist" . "($dolist (VAR LIST) BODY) -> list of BODY results")
    ("dot" . "(dot OBJ FIELD [FIELD...])")
    ("arrow" . "(arrow PTR FIELD [FIELD...])")
    ("." . "(. OBJ FIELD [FIELD...]) alias of dot")
    ("->" . "(-> PTR FIELD [FIELD...]) alias of arrow")
    ("|>" . "(|> INIT STEP...) -> thread INIT as first arg through each STEP")
    ("||>" . "(||> INIT STEP...) -> thread INIT as last arg through each STEP")
    ("|as>" . "(|as> INIT BINDING STEP...) -> thread with BINDING substituted in each STEP")
    ("$not" . "($not PRED) -> compile-time boolean negation")
    ("$do" . "($do EXPR...) -> evaluate sequentially, return last value")
    ("$assert" . "($assert COND MESSAGE) -> fail with MESSAGE when COND is falsey")
    ("$subst" . "($subst SYM REPLACEMENT FORM) -> replace SYM atom in FORM with REPLACEMENT")
    ("$|>" . "($|> INIT STEP...) -> meta thread-first")
    ("$||>" . "($||> INIT STEP...) -> meta thread-last")
    ("$|as>" . "($|as> INIT BINDING FORM...) -> meta thread-as with direct env binding"))
  "Eldoc mapping: symbol -> short documentation string."
  :type '(alist :key-type string :value-type string)
  :group 'sexc)

(defcustom sexc/eldoc-use-show-doc t
  "When non-nil, fetch Eldoc from `sexc show-doc` and cache results.

When nil, only `sexc/eldoc-docs` is used."
  :type 'boolean
  :group 'sexc)

(defcustom sexc/enable-completion t
  "When non-nil, enable completion-at-point via `sexc complete`."
  :type 'boolean
  :group 'sexc)

(defcustom sexc/enable-xref t
  "When non-nil, enable simple xref definitions backend for SexC files."
  :type 'boolean
  :group 'sexc)

(defvar sexc/eldoc-cache (make-hash-table :test #'equal)
  "Cache for Eldoc strings fetched via `sexc show-doc`.")

(defvar sexc/completion-cache (make-hash-table :test #'equal)
  "Cache for completion candidates fetched via `sexc complete`.")

(defvar sexc/completion-kind-cache (make-hash-table :test #'equal)
  "Cache for completion kind maps fetched via `sexc complete --json`.")

(defvar sexc/completion-meta-cache (make-hash-table :test #'equal)
  "Cache for completion metadata maps fetched via `sexc complete --json`.")

(defvar-local sexc--completion-kind-map nil
  "Alist mapping completion candidate to its kind metadata.")

(defvar-local sexc--completion-meta-map nil
  "Alist mapping completion candidate to full metadata object.")

(defun sexc/clear-eldoc-cache ()
  "Clear cached Eldoc entries fetched from compiler docs."
  (interactive)
  (clrhash sexc/eldoc-cache))

(defun sexc/clear-completion-cache ()
  "Clear cached completion entries fetched from compiler completions."
  (interactive)
  (clrhash sexc/completion-cache)
  (clrhash sexc/completion-kind-cache)
  (clrhash sexc/completion-meta-cache)
  (setq sexc--completion-kind-map nil)
  (setq sexc--completion-meta-map nil))

(defun sexc--json-alist-get (obj key)
  "Read KEY from JSON OBJ accepting symbol or string keys."
  (or (alist-get key obj)
      (alist-get (symbol-name key) obj nil nil #'string=)))

(defun sexc--resolve-binary ()
  "Return an executable SexC binary path, or nil."
  (cond
   ((and (file-name-absolute-p sexc/binary) (file-executable-p sexc/binary)) sexc/binary)
   ((executable-find sexc/binary))
   (t
    (cl-loop for p in sexc/binary-fallbacks
             for abs = (expand-file-name p default-directory)
             when (file-executable-p abs)
             return abs))))

(defun sexc/diagnose-eldoc ()
  "Show quick diagnostics for SexC Eldoc integration."
  (interactive)
  (let* ((sym (sexc--atom-at-point))
         (bin (sexc--resolve-binary))
         (mode-ok (derived-mode-p 'sexc-mode)))
    (message "sexc-mode=%s; symbol=%s; binary=%s; eldoc-use-show-doc=%s"
             mode-ok (or sym "<none>") (or bin "<missing>") sexc/eldoc-use-show-doc)))

(defun sexc--token-regexp (tokens)
  "Build regexp matching TOKENS as standalone SexC atoms."
  (if (null tokens)
      "a^"
    (concat "\\(?:^\\|[[:space:]()]\\)\\(" (regexp-opt tokens) "\\)\\(?:$\\|[[:space:]()]\\)")))

(defun sexc--font-lock-keywords ()
  "Compute font-lock rules for SexC mode."
  `((,sexc/number-regexp . font-lock-constant-face)
    (,(regexp-opt sexc/type-keywords 'symbols) . font-lock-type-face)
    ;; Prefix-based highlighting — single rule per family covers every existing
    ;; and future token without enumerating them.
    ;;   `%foo` — IR/system intrinsics
    ;;   `$foo` — compile-time meta builtins (incl. user `$defun`s)
    ;;   `:foo` — keyword atoms / metadata keys / struct section markers
    ("\\_<%[^[:space:]()]+" . font-lock-warning-face)
    ("\\_<\\$[^[:space:]()]+" . font-lock-constant-face)
    ("\\_<:[^[:space:]()]+" . font-lock-builtin-face)
    (,(sexc--token-regexp sexc/surface-keywords) (1 font-lock-keyword-face))
    ("(\\(?:defn\\)\\s-+[^()[:space:]]+\\s-+\\([^()[:space:]]+\\)"
     (1 font-lock-function-name-face))
    ("(\\(?:struct\\|union\\)\\s-+\\([^()[:space:]]+\\)"
     (1 font-lock-type-face))))

(defun sexc/apply-indent-rules ()
  "Apply indentation rules from `sexc/indent-rules'."
  (dolist (entry sexc/indent-rules)
    (let ((sym (intern (car entry)))
          (spec (cdr entry)))
      (put sym 'common-lisp-indent-function spec))))

(defun sexc/reload-config ()
  "Reload highlighting/indentation config in current SexC buffer."
  (interactive)
  (unless (derived-mode-p 'sexc-mode)
    (user-error "Current buffer is not in sexc/mode"))
  (sexc/apply-indent-rules)
  (setq-local font-lock-defaults (list (sexc--font-lock-keywords)))
  (font-lock-flush)
  (font-lock-ensure))

(defun sexc--format-command (template)
  "Render command TEMPLATE placeholders.

Supported placeholders:
- %b: quoted `sexc/binary'
- %f: quoted current buffer file"
  (let ((cmd template)
        (file (or buffer-file-name ""))
        (bin (or (sexc--resolve-binary) sexc/binary)))
    (setq cmd (replace-regexp-in-string "%b" (shell-quote-argument bin) cmd t t))
    (setq cmd (replace-regexp-in-string "%f" (shell-quote-argument file) cmd t t))
    cmd))

(defun sexc--format-compile-command (file)
  "Render `sexc/compile-command' for FILE."
  (let ((buffer-file-name file))
    (sexc--format-command sexc/compile-command)))

(defun sexc/compile ()
  "Compile current SexC buffer using `compile'."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (save-buffer)
  (let ((default-directory (or (locate-dominating-file buffer-file-name "Makefile")
                               default-directory)))
    (compile (sexc--format-compile-command buffer-file-name))))

(defun sexc--expand-range (beg end)
  "Expand SexC source from BEG to END into C output buffer."
  (let* ((cmd (sexc--format-command sexc/expand-command))
         (argv (split-string-and-unquote cmd))
         (program (car argv))
         (out-buf (get-buffer-create sexc/expand-buffer-name))
         (default-directory (or (and buffer-file-name (locate-dominating-file buffer-file-name "Makefile"))
                                default-directory)))
    (unless program
      (user-error "Invalid sexc/expand-command: %s" cmd))
    (with-current-buffer out-buf
      (read-only-mode -1)
      (erase-buffer))
    (let* ((full-cmd (concat cmd " 2>&1"))
           (status (shell-command-on-region
                    beg end
                    full-cmd
                    out-buf
                    nil)))
      (with-current-buffer out-buf
        (goto-char (point-min))
        (if (and (integerp status) (zerop status))
            (progn
              (if (fboundp 'c-ts-mode) (c-ts-mode) (c-mode))
              (read-only-mode 1))
          (compilation-mode)
          (read-only-mode 1)
          (display-buffer out-buf)
          (user-error "sexc expand failed (exit %s)" status)))
      (display-buffer out-buf))))

(defun sexc/expand ()
  "Expand active region or whole buffer SexC code into C.

If region is active, only that region is expanded.
Otherwise expand the whole buffer."
  (interactive)
  (if (use-region-p)
      (sexc--expand-range (region-beginning) (region-end))
    (sexc--expand-range (point-min) (point-max))))

(defun sexc/expand-buffer ()
  "Always expand the whole current buffer SexC code into C."
  (interactive)
  (sexc--expand-range (point-min) (point-max)))

(defun sexc--atom-bounds-at-point ()
  "Return cons of atom bounds at point, or nil."
  (cl-labels ((delim-p (ch)
                (or (null ch)
                    (memq ch '(?\s ?\t ?\n ?\r ?\( ?\) ?\" ?\; ?' ?` ?,)))))
    (save-excursion
      (when (and (not (bobp)) (delim-p (char-after)))
        (backward-char 1))
      (unless (delim-p (char-after))
        (let ((beg (progn
                     (while (and (not (bobp)) (not (delim-p (char-before))))
                       (backward-char 1))
                     (point))))
          (while (and (not (eobp)) (not (delim-p (char-after))))
            (forward-char 1))
          (cons beg (point)))))))

(defun sexc--atom-at-point ()
  "Return SexC atom-like token at point, or nil."
  (let ((bounds (sexc--atom-bounds-at-point)))
    (when bounds
      (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(defun sexc--fetch-completions (prefix)
  "Fetch completion candidates for PREFIX using `sexc complete`."
  (let* ((file (or buffer-file-name ""))
         (cache-key (cons prefix file))
         (cached (gethash cache-key sexc/completion-cache :__missing__)))
    (if (not (eq cached :__missing__))
        (progn
          (setq sexc--completion-kind-map
                 (or (gethash cache-key sexc/completion-kind-cache) nil))
          (setq sexc--completion-meta-map
                (or (gethash cache-key sexc/completion-meta-cache) nil))
          cached)
      (let* ((bin (sexc--resolve-binary))
             (with-file (if (and file (not (string-empty-p file))) (list file) nil))
             (json-items (sexc--fetch-completions-json bin prefix with-file))
             (items (if json-items
                        (mapcar (lambda (obj) (sexc--json-alist-get obj 'name)) json-items)
                      (sexc--fetch-completions-plain bin prefix with-file))))
        (puthash cache-key items sexc/completion-cache)
        (let ((kind-map
                (if json-items
                    (mapcar (lambda (obj)
                              (cons (sexc--json-alist-get obj 'name)
                                    (sexc--json-alist-get obj 'kind)))
                            json-items)
                  nil))
              (meta-map
               (if json-items
                   (mapcar (lambda (obj)
                             (cons (sexc--json-alist-get obj 'name) obj))
                           json-items)
                 nil)))
           (puthash cache-key kind-map sexc/completion-kind-cache)
           (puthash cache-key meta-map sexc/completion-meta-cache)
           (setq sexc--completion-kind-map kind-map)
           (setq sexc--completion-meta-map meta-map))
        items))))

(defun sexc--fetch-completions-plain (bin prefix with-file)
  "Fallback plain completion list from BIN for PREFIX and WITH-FILE args."
  (condition-case nil
      (if bin (apply #'process-lines bin (append (list "complete" prefix) with-file)) nil)
    (error nil)))

(defun sexc--fetch-completions-json (bin prefix with-file)
  "Fetch JSON completions from BIN for PREFIX and WITH-FILE args.

Returns a list of alists with keys `name' and `kind'."
  (condition-case nil
      (when bin
        (let* ((lines (apply #'process-lines bin (append (list "complete" "--json" prefix) with-file)))
               (json-text (car lines)))
          (when (and (stringp json-text) (fboundp 'json-parse-string))
            (json-parse-string json-text :array-type 'list :object-type 'alist))))
    (error nil)))

(defun sexc--completion-annotation (candidate)
  "Return completion annotation for CANDIDATE using compiler metadata.

Format mirrors Eldoc style: kind, signature, and short doc when available."
  (let* ((meta (cdr (assoc candidate sexc--completion-meta-map)))
         (kind-raw (or (and meta (sexc--json-alist-get meta 'kind))
                       (cdr (assoc candidate sexc--completion-kind-map))))
         (sig (and meta (sexc--display-signature candidate (sexc--json-alist-get meta 'signature))))
         (doc (and meta (sexc--json-alist-get meta 'doc)))
         (example (and meta (sexc--json-alist-get meta 'example)))
         (kind (sexc--kind-label kind-raw sig)))
    (sexc--format-symbol-summary
     :name candidate
     :kind kind
     :signature sig
     :doc doc
     :example example
     :include-name nil
     :include-example nil
     :multiline nil)))

(defun sexc--kind-label (kind signature)
  "Normalize KIND into compact tag used by completion/Eldoc.

SIGNATURE helps infer surface entries as macros."
  (pcase kind
    ("function" "fn")
    ("macro" "macro")
    ("intrinsic" "intr")
    ("meta" "macro")
    ("type" "type")
    ("surface" (if (and (stringp signature) (string-prefix-p "(" signature)) "macro" "surface"))
    (_ kind)))

(defun sexc--format-symbol-summary (&rest plist)
  "Format symbol summary string from PLIST.

Keys: :name :kind :signature :doc :example :include-name :multiline."
  (let* ((name (plist-get plist :name))
         (kind (plist-get plist :kind))
         (signature (plist-get plist :signature))
         (doc (plist-get plist :doc))
         (example (plist-get plist :example))
         (include-name (plist-get plist :include-name))
         (include-example (plist-get plist :include-example))
         (multiline (plist-get plist :multiline))
         (doc (if (and (stringp doc) (> (length doc) 80))
                  (concat (substring doc 0 77) "...")
                doc))
         (example (if (and (stringp example) (> (length example) 96))
                      (concat (substring example 0 93) "...")
                    example))
         (head
          (concat
           (if include-name (or name "") "")
           (if kind (format " [%s]" kind) "")
           (if signature (format " %s" signature) "")
           (if doc (format " - %s" doc) ""))))
    (if multiline
        (if (and include-example example)
            (concat head "\nexample: " example)
          head)
      (concat head (if (and include-example example) (format " | eg: %s" example) "")))))

(defun sexc--display-signature (candidate signature)
  "Format SIGNATURE for completion display without repeating CANDIDATE."
  (if (not (stringp signature))
      signature
    (let* ((cand (regexp-quote candidate))
           (fn-re (concat "\\`(" cand "[[:space:]]+\\(.*\\))[[:space:]]*->[[:space:]]*\\(.*\\)\\'"))
           (simple-re (concat "\\`(" cand "[[:space:]]+\\(.*\\))\\'")))
      (cond
       ((string-match fn-re signature)
        (let* ((params (match-string 1 signature))
               (ret (match-string 2 signature))
               (params
                (cond
                 ((string-equal params "()") "()")
                 ((and (string-prefix-p "((" params)
                       (string-suffix-p "))" params))
                  (substring params 1 -1))
                 (t params))))
          (format "%s -> %s" params ret)))
       ((string-match simple-re signature)
        (format "(%s)" (match-string 1 signature)))
       (t signature)))))

(defun sexc--lookup-completion-meta (sym)
  "Return completion metadata object for SYM, or nil."
  (or (cdr (assoc sym sexc--completion-meta-map))
      (progn
        (sexc--fetch-completions sym)
        (cdr (assoc sym sexc--completion-meta-map)))))

(defun sexc--eldoc-via-completion-meta (sym)
  "Return Eldoc string for SYM from completion metadata, or nil."
  (when sym
    (let* ((meta (sexc--lookup-completion-meta sym))
           (sig (and meta (sexc--display-signature sym (sexc--json-alist-get meta 'signature))))
           (kind (and meta (sexc--kind-label (sexc--json-alist-get meta 'kind) sig)))
           (doc (and meta (sexc--json-alist-get meta 'doc)))
           (example (and meta (sexc--json-alist-get meta 'example))))
      (when meta
        (sexc--format-symbol-summary
         :name sym
         :kind kind
         :signature sig
         :doc doc
         :example example
         :include-name t
         :include-example t
         :multiline t)))))

(defun sexc/completion-at-point ()
  "Completion backend for SexC symbols via compiler-aware completion."
  (when sexc/enable-completion
    (let ((bounds (sexc--atom-bounds-at-point)))
      (when bounds
        (let ((beg (car bounds))
              (end (cdr bounds)))
          (list beg
                end
                (completion-table-dynamic #'sexc--fetch-completions)
                :annotation-function #'sexc--completion-annotation
                :exclusive 'no))))))

(defun sexc/eldoc-function (&rest _ignored)
  "Return Eldoc string for symbol at point in SexC buffers.

Accept optional arguments for compatibility with newer Eldoc call conventions."
  (let ((sym (sexc--atom-at-point)))
    (or (sexc--eldoc-via-show-doc sym)
        (sexc--eldoc-via-completion-meta sym)
        (cdr (assoc sym sexc/eldoc-docs)))))

(defun sexc--eldoc-via-show-doc (sym)
  "Return Eldoc for SYM via `sexc show-doc`, or nil.

Results are cached per symbol and current buffer file path."
  (when (and sexc/eldoc-use-show-doc sym)
    (let* ((file (or buffer-file-name ""))
           (cache-key (cons sym file))
           (cached (gethash cache-key sexc/eldoc-cache :__missing__)))
      (if (not (eq cached :__missing__))
          cached
        (let ((doc (sexc--fetch-eldoc-from-compiler sym file)))
          (puthash cache-key doc sexc/eldoc-cache)
          doc)))))

(defun sexc--fetch-eldoc-from-compiler (sym file)
  "Fetch and format Eldoc string for SYM using `sexc show-doc`.

FILE is optional source path for project-aware lookup."
  (condition-case nil
      (let* ((bin (sexc--resolve-binary))
             (args (append (list "show-doc" sym)
                           (if (and file (not (string-empty-p file))) (list file) nil)))
             (lines (and bin (apply #'process-lines bin args))))
        (sexc--format-show-doc-lines lines sym))
    (error nil)))

(defun sexc--format-show-doc-lines (lines sym)
  "Build a one-line Eldoc summary from `show-doc` LINES for SYM."
  (let ((name sym)
        (kind nil)
        (sig nil)
        (first-doc nil)
        (first-example nil)
        (in-doc nil)
        (in-examples nil))
    (dolist (line lines)
      (cond
       ((string-prefix-p "Name: " line)
        (setq name (substring line 6)))
       ((string-prefix-p "Kind: " line)
        (setq kind (substring line 6)))
       ((string-prefix-p "Signature: " line)
        (setq sig (sexc--display-signature sym (substring line 11))))
       ((string-prefix-p "Doc:" line)
        (setq in-doc t)
        (setq in-examples nil))
       ((string-prefix-p "Examples:" line)
        (setq in-doc nil)
        (setq in-examples t))
       ((and in-doc (string-prefix-p "- " line) (not first-doc))
        (setq first-doc (substring line 2)))
       ((and in-examples (string-prefix-p "- `" line) (not first-example))
        (setq first-example
              (if (string-suffix-p "`" line)
                  (substring line 3 -1)
                (substring line 3))))
       ((and in-examples (string-prefix-p "- " line) (not first-example))
        (setq first-example (substring line 2)))
       ((and in-doc (not (string-prefix-p "- " line)))
        (setq in-doc nil))
       ((and in-examples (not (string-prefix-p "- " line)))
        (setq in-examples nil))))
    (when (or sig first-doc kind)
      (sexc--format-symbol-summary
       :name name
       :kind (sexc--kind-label kind sig)
       :signature sig
       :doc first-doc
       :example first-example
       :include-name t
       :include-example t
       :multiline t))))

(defun sexc--fetch-xref-json (identifier)
  "Fetch xref definitions for IDENTIFIER from compiler JSON endpoint."
  (let* ((bin (sexc--resolve-binary))
         (file (or buffer-file-name ""))
         (args (append (list "xref" "--json" identifier)
                       (if (and file (not (string-empty-p file))) (list file) nil))))
    (condition-case nil
        (when (and bin (fboundp 'json-parse-string))
          (let* ((lines (apply #'process-lines bin args))
                 (json-text (car lines)))
            (when (stringp json-text)
              (json-parse-string json-text :array-type 'list :object-type 'alist))))
      (error nil))))

(defun sexc--xref-definitions (identifier)
  "Find definition locations for IDENTIFIER using compiler xref output."
  (let ((rows (sexc--fetch-xref-json identifier)))
    (if (not rows)
        nil
      (mapcar
       (lambda (row)
         (let* ((name (sexc--json-alist-get row 'name))
                (kind (or (sexc--kind-label (sexc--json-alist-get row 'kind) nil) "sym"))
                (file (sexc--json-alist-get row 'file))
                (line (or (sexc--json-alist-get row 'line) 1))
                (col (or (sexc--json-alist-get row 'col) 1))
                (summary (format "%s [%s]" name kind)))
           (xref-make summary (xref-make-file-location file line col))))
       rows))))

(defun sexc-xref-backend ()
  "Return SexC xref backend symbol for current buffer."
  (when sexc/enable-xref 'sexc))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql sexc)))
  (sexc--atom-at-point))

(cl-defmethod xref-backend-definitions ((_backend (eql sexc)) identifier)
  (sexc--xref-definitions identifier))

;;;###autoload
(define-derived-mode sexc-mode lisp-mode "SexC"
  "Major mode for editing SexC files."
  (setq-local comment-start ";")
  (setq-local comment-end "")
  ;; SexC uses `|` inside symbol names (e.g. `|>`, `||>`, `$|>`). Without this
  ;; override the inherited lisp-mode syntax treats `|` as a string-quote
  ;; (Common Lisp `|foo bar|` quoted symbols), which breaks font-lock from the
  ;; first pipe onward.
  (modify-syntax-entry ?| "_" sexc-mode-syntax-table)
  (setq-local font-lock-defaults (list (sexc--font-lock-keywords)))
  (setq-local eldoc-documentation-functions '(sexc/eldoc-function))
  (add-hook 'completion-at-point-functions #'sexc/completion-at-point nil t)
  (add-hook 'xref-backend-functions #'sexc-xref-backend nil t)
  (eldoc-mode 1)
  (sexc/apply-indent-rules))

(defalias 'sexc/mode #'sexc-mode)
(defalias 'sexc #'sexc-mode)

(define-key sexc-mode-map (kbd "C-c C-c") #'sexc/compile)
(define-key sexc-mode-map (kbd "C-c C-e") #'sexc/expand)
(define-key sexc-mode-map (kbd "C-c C-S-e") #'sexc/expand-buffer)
(define-key sexc-mode-map (kbd "C-c C-r") #'sexc/reload-config)
(define-key sexc-mode-map (kbd "C-c C-d") #'sexc/diagnose-eldoc)

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.sexc\\'" . sexc-mode))

(provide 'sexc)

;;; sexc.el ends here
